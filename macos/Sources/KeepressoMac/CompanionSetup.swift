import AppKit
import ApplicationServices
import Combine
import CompanionCore
import CoreBluetooth
import CoreLocation
import EventKit
import KeepressoCore

@MainActor final class CompanionSetup: ObservableObject {
    @Published var presented = false {
        didSet {
            // Dismissing the sheet is an explicit deferral. Lifecycle handoff
            // uses cancelForLifecycleChange instead and never saves a skip.
            if !presented, !synchronizing, flow.presented { flow.deferSetup() }
        }
    }
    var running: Bool { flow.running }
    var restartSuggested: Bool { flow.restartSuggested }
    @Published private(set) var restarting = false
    @Published private(set) var restartFailed = false
    var restartApp: (() async -> Bool)?
    var steamConsent: Data? { readSteamConsent() }
    var phase: CompanionSetupFlow.Phase { flow.phase }
    var current: CompanionSetupKind? { flow.current }
    var steps: [CompanionSetupKind] { flow.activeScope?.steps ?? [] }
    var outcomes: [CompanionSetupKind: CompanionSetupStatus] { flow.outcomes }

    private let flow: CompanionSetupFlow
    private let readSteamConsent: () -> Data?
    private var synchronizing = false

    convenience init(eligible: @escaping () -> Bool, rules: @escaping () -> [TriggerRule], buildIdentity: @escaping () -> String,
                     requestFolders: @escaping () async -> Bool,
                     requestSteam: @escaping () async -> Data?, steamReady: @escaping (Data?) -> Bool,
                     directTriggerControl: @escaping () -> Bool) {
        let defaults = UserDefaults.standard
        let driver = CompanionMacSetupDriver(requestFolders: requestFolders,
                                             requestSteam: requestSteam, steamReady: steamReady,
                                             directTriggerControl: directTriggerControl, defaults: defaults)
        self.init(scope: {
            let requirements = CompanionSetupRequirements(rules: rules())
            var steps = requirements.permissionNames.compactMap(CompanionSetupKind.init(rawValue:))
            var tokens = requirements.permissionNames.map { "permission:\($0)" }
            if !requirements.folders.isEmpty {
                steps.append(.folders)
                tokens += requirements.folders.map { "folder:\($0.absoluteString)" }
            }
            if requirements.needsSteam { steps.append(.steam); tokens.append("steam") }
            if requirements.remoteControls { steps.append(.accessibility); tokens.append("optional-remote-controls") }
            return CompanionSetupScope(buildIdentity: buildIdentity(), requirements: tokens, steps: steps)
        }, driver: driver, storage: CompanionSetupDefaults(defaults: defaults), eligible: eligible, steamConsent: { driver.steamConsent })
    }

    /// An alternate dependency boundary for tests: no framework object, defaults
    /// domain, folder probe or system permission is created by this initializer.
    init(scope: @escaping () -> CompanionSetupScope, driver: CompanionSetupPermissionDriving,
         storage: CompanionSetupStorage, eligible: @escaping () -> Bool = { true }, steamConsent: @escaping () -> Data? = { nil }) {
        flow = CompanionSetupFlow(scope: scope, driver: driver, storage: storage, eligible: eligible)
        readSteamConsent = steamConsent
        flow.onChange = { [weak self] in self?.synchronize() }
    }

    func preparePairing(bluetoothAuthorized: Bool) -> Bool { flow.preparePairing(bluetoothAuthorized: bluetoothAuthorized) }
    func presentIfNeeded(returningFromSettings: Bool = false) { flow.presentIfNeeded(returningFromSettings: returningFromSettings) }
    func frameworkStatusChanged() { flow.refreshFrameworkStatuses() }
    func review() { flow.review() }
    func start() async { await flow.start() }
    func manualRecheck() async { restartFailed = false; await flow.manualRecheck() }
    func checkpointForRestart() -> Bool { flow.checkpointForRestart() }
    func restart() async {
        guard restartSuggested, !restarting, let restartApp else { return }
        restarting = true
        restartFailed = !(await restartApp())
        restarting = false
    }
    func deferSetup() { flow.deferSetup() }
    func finish() { flow.finish() }
    func cancelForLifecycleChange() { flow.cancelForLifecycleChange() }
    func skipCurrent() { flow.skipCurrent() }

    func openSettings(for kind: CompanionSetupKind) {
        let pane: String
        switch kind {
        case .bluetooth: pane = "Privacy_Bluetooth"
        case .location: pane = "Privacy_LocationServices"
        case .calendar: pane = "Privacy_Calendars"
        case .folders, .steam: pane = "Privacy_FilesAndFolders"
        case .accessibility: pane = "Privacy_Accessibility"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            if NSWorkspace.shared.open(url) { flow.settingsOpened(for: kind) }
        }
    }

    private func synchronize() {
        synchronizing = true
        // Publishing also refreshes the view's computed phase/outcomes.
        presented = flow.presented
        synchronizing = false
    }
}

@MainActor private final class CompanionSetupDefaults: CompanionSetupStorage {
    private let defaults: UserDefaults
    private let key = "companionGuidedSetupV1"
    init(defaults: UserDefaults) { self.defaults = defaults }
    func load() -> Data? { defaults.data(forKey: key) }
    func save(_ data: Data) { defaults.set(data, forKey: key) }
}

/// Thin, foreground-only permission driver. Managers/stores outlive the OS
/// choice, including a skipped/cancelled flow; no scanning or radio mutation.
@MainActor private final class CompanionMacSetupDriver: NSObject, CompanionSetupPermissionDriving, CompanionSetupStatusNotifying,
                                                        CBCentralManagerDelegate, CLLocationManagerDelegate {
    var onStatusChange: (() -> Void)?
    private static let steamKey = "companionSteamLocalConsentV1"
    private static let accessibilityAskedKey = "companionSetupAccessibilityAskedV1"
    private let requestFolders: () async -> Bool
    private let requestSteam: () async -> Data?
    private let steamReady: (Data?) -> Bool
    private let directTriggerControl: () -> Bool
    private let defaults: UserDefaults
    private var bluetooth: CBCentralManager?
    private var location: CLLocationManager?
    private var calendar: EKEventStore?
    private var accessibilityWait: Task<Void, Never>?
    private var pending: (id: UUID, kind: CompanionSetupKind, continuation: CheckedContinuation<CompanionSetupStatus, Never>)?
    private(set) var steamConsent: Data?

    init(requestFolders: @escaping () async -> Bool,
         requestSteam: @escaping () async -> Data?, steamReady: @escaping (Data?) -> Bool,
         directTriggerControl: @escaping () -> Bool, defaults: UserDefaults) {
        self.requestFolders = requestFolders
        self.requestSteam = requestSteam
        self.steamReady = steamReady
        self.directTriggerControl = directTriggerControl
        self.defaults = defaults
        steamConsent = defaults.data(forKey: Self.steamKey)
        super.init()
    }

    func status(for kind: CompanionSetupKind) -> CompanionSetupStatus {
        switch kind {
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .authorized
            case .notDetermined: return .undetermined
            case .restricted: return .restricted
            case .denied: return .denied
            @unknown default: return .unavailable
            }
        case .location:
            let value = locationManager().authorizationStatus
            if value == .authorizedAlways || value == .authorized { return .authorized }
            if value == .notDetermined { return .undetermined }
            return value == .restricted ? .restricted : .denied
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .authorized
            case .notDetermined: return .undetermined
            case .restricted: return .restricted
            case .denied, .writeOnly: return .denied
            default: return .unavailable
            }
        case .folders, .steam:
            // An old local proof cannot reveal a later TCC revocation or Steam
            // library change. Each explicit Continue revalidates these reads;
            // system permissions above still skip when already authorized.
            return .undetermined
        case .accessibility:
            if directTriggerControl() || AXIsProcessTrusted() { return .authorized }
            return defaults.bool(forKey: Self.accessibilityAskedKey) ? .denied : .undetermined
        }
    }

    func request(_ kind: CompanionSetupKind) async -> CompanionSetupStatus {
        guard !Task.isCancelled else { return .unavailable }
        let current = status(for: kind)
        guard current == .undetermined else { return current }
        NSApp.activate(ignoringOtherApps: true)
        if kind == .folders {
            let ready = await requestFolders()
            return Task.isCancelled ? .unavailable : (ready ? .authorized : .denied)
        }
        if kind == .steam {
            // Revalidation invalidates the old proof immediately, including if
            // the new local choice is denied, cancelled or finishes too late.
            steamConsent = nil
            defaults.removeObject(forKey: Self.steamKey)
            let data = await requestSteam()
            guard !Task.isCancelled else { return .unavailable }
            guard steamReady(data), let data, data.count <= 32_768 else { return .unavailable }
            steamConsent = data
            defaults.set(data, forKey: Self.steamKey)
            return .authorized
        }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            pending = (id, kind, continuation)
            switch kind {
            case .bluetooth:
                if bluetooth == nil {
                    bluetooth = CBCentralManager(delegate: self, queue: .main,
                        options: [CBCentralManagerOptionShowPowerAlertKey: false])
                }
                completeIfDecided(kind)
            case .location:
                locationManager().requestWhenInUseAuthorization()
            case .calendar:
                if calendar == nil { calendar = EKEventStore() }
                calendar?.requestFullAccessToEvents { [weak self] _, _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.complete(self.status(for: .calendar), id: id)
                        self.onStatusChange?()
                    }
                }
            case .accessibility:
                defaults.set(true, forKey: Self.accessibilityAskedKey)
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                if AXIsProcessTrustedWithOptions(options) { complete(.authorized, id: id) }
                else {
                    // AX has no authorization callback. Poll only during this
                    // active optional step, at most 20 seconds, with Skip in UI.
                    accessibilityWait = Task { [weak self] in
                        for _ in 0..<40 {
                            guard let self, !Task.isCancelled else { return }
                            if AXIsProcessTrusted() { self.complete(.authorized, id: id); return }
                            if !NSApp.isActive { self.complete(.denied, id: id); return }
                            do { try await Task.sleep(for: .milliseconds(500)) }
                            catch { return }
                        }
                        self?.complete(.denied, id: id)
                    }
                }
            case .folders, .steam: complete(.unavailable, id: id)
            }
        }
    }

    func cancel() {
        accessibilityWait?.cancel()
        accessibilityWait = nil
        let continuation = pending?.continuation
        pending = nil
        continuation?.resume(returning: .unavailable)
    }

    private func locationManager() -> CLLocationManager {
        if let location { return location }
        let manager = CLLocationManager()
        location = manager
        manager.delegate = self
        return manager
    }

    private func completeIfDecided(_ kind: CompanionSetupKind) {
        guard let pending, pending.kind == kind else { return }
        let value = status(for: kind)
        if value != .undetermined { complete(value, id: pending.id) }
    }

    private func complete(_ status: CompanionSetupStatus, id: UUID) {
        guard pending?.id == id else { return }
        let continuation = pending?.continuation
        pending = nil
        accessibilityWait?.cancel()
        accessibilityWait = nil
        continuation?.resume(returning: status)
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            self?.completeIfDecided(.bluetooth)
            self?.onStatusChange?()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.completeIfDecided(.location)
            self?.onStatusChange?()
        }
    }
}
