import Foundation

public enum CompanionSetupKind: String, Codable, CaseIterable, Sendable {
    case bluetooth, location, calendar, folders, steam, accessibility
}

public enum CompanionSetupStatus: String, Codable, Sendable {
    case authorized, undetermined, denied, restricted, unavailable, skipped
}

/// Requirement tokens describe configuration only. A previously handled superset
/// covers removed rules, while a new folder, permission or executable reopens setup.
public struct CompanionSetupScope: Codable, Equatable, Sendable {
    public let buildIdentity: String
    public let requirements: [String]
    public let steps: [CompanionSetupKind]

    public init(buildIdentity: String, requirements: [String], steps: [CompanionSetupKind]) {
        self.buildIdentity = buildIdentity
        self.requirements = Array(Set(requirements)).sorted()
        var seen = Set<CompanionSetupKind>()
        self.steps = steps.filter { seen.insert($0).inserted }
    }
}

@MainActor public protocol CompanionSetupStorage: AnyObject {
    func load() -> Data?
    func save(_ data: Data)
}

/// Status must be metadata-only; only request may ask for consent or prepare files.
@MainActor public protocol CompanionSetupPermissionDriving: AnyObject {
    func status(for kind: CompanionSetupKind) -> CompanionSetupStatus
    func request(_ kind: CompanionSetupKind) async -> CompanionSetupStatus
    func cancel()
}

/// Drivers publish framework callbacks without making the flow poll or request.
@MainActor public protocol CompanionSetupStatusNotifying: AnyObject {
    var onStatusChange: (() -> Void)? { get set }
}

/// Owns one foreground setup session. It never creates an observation engine.
/// Requests run serially; abandoning a session releases its waiter immediately,
/// even when the external OS/file operation cannot itself be cancelled.
@MainActor public final class CompanionSetupFlow {
    public enum Phase { case welcome, requesting, summary }
    public private(set) var presented = false
    public private(set) var running = false
    public private(set) var current: CompanionSetupKind?
    public private(set) var phase: Phase = .welcome
    public private(set) var outcomes: [CompanionSetupKind: CompanionSetupStatus] = [:]
    public private(set) var activeScope: CompanionSetupScope?
    public var onChange: (() -> Void)?
    public private(set) var restartSuggested = false
    private var openedSettings: CompanionSetupKind?
    private var returnedSettings: CompanionSetupKind?

    private let eligible: () -> Bool
    private let scope: () -> CompanionSetupScope
    private let driver: CompanionSetupPermissionDriving
    private let storage: CompanionSetupStorage
    private var generation: UInt64 = 0
    private var requestTask: Task<Void, Never>?
    private var pending: (id: UUID, continuation: CheckedContinuation<CompanionSetupStatus, Never>)?

    private struct Record: Codable {
        let version: Int
        let scope: CompanionSetupScope
        let deferred: Bool
        let outcomes: [CompanionSetupKind: CompanionSetupStatus]
        let resumeSummary: Bool?
        func covers(_ candidate: CompanionSetupScope) -> Bool {
            version == 1 && !candidate.buildIdentity.isEmpty && scope.buildIdentity == candidate.buildIdentity &&
                Set(candidate.requirements).isSubset(of: Set(scope.requirements))
        }
    }

    public init(scope: @escaping () -> CompanionSetupScope,
                driver: CompanionSetupPermissionDriving, storage: CompanionSetupStorage, eligible: @escaping () -> Bool = { true }) {
        self.eligible = eligible
        self.scope = scope
        self.driver = driver
        self.storage = storage
        (driver as? CompanionSetupStatusNotifying)?.onStatusChange = { [weak self] in
            self?.refreshFrameworkStatuses()
        }
    }

    /// Root calls this only after foreground startup/handoff has settled. Merely
    /// constructing the flow, or evaluating this method, never requests consent.
    public func presentIfNeeded(returningFromSettings: Bool = false) {
        guard eligible(), !running else { return }
        if presented { refreshFrameworkStatuses(returningFromSettings: returningFromSettings); return }
        let candidate = scope()
        if let data = storage.load(), data.count <= 65_536,
           let record = try? JSONDecoder().decode(Record.self, from: data) {
            if record.resumeSummary == true {
                // Restart is a one-shot continuation, never a new consent grant.
                // Exact scope, including step ordering, is required here.
                if record.version == 1, !candidate.buildIdentity.isEmpty, record.scope == candidate {
                    activeScope = candidate
                    outcomes = record.outcomes.filter { candidate.steps.contains($0.key) }
                    phase = .summary
                    presented = true
                    persist(deferred: false)
                    refreshFrameworkStatuses()
                    onChange?()
                    return
                }
                show(candidate)
                return
            }
            if record.covers(candidate) { return }
        }
        show(candidate)
    }

    public func preparePairing(bluetoothAuthorized: Bool) -> Bool {
        guard eligible() else { return false }
        if !bluetoothAuthorized { review(); return false }
        presentIfNeeded()
        return !presented
    }

    public func review() {
        guard eligible(), !running else { return }
        show(scope())
    }

    private func show(_ scope: CompanionSetupScope) {
        activeScope = scope
        restartSuggested = false
        openedSettings = nil
        returnedSettings = nil
        outcomes = [:]
        current = nil
        phase = .welcome
        presented = true
        onChange?()
    }

    public func start() async {
        guard eligible(), presented, !running, phase == .welcome, !Task.isCancelled else { return }
        // Re-evaluate configuration at Continue, then keep that scope fixed until
        // Finish. A new rule added while an OS dialog is open remains unhandled.
        await run(scope())
    }

    /// This owner action is the only summary path that can revalidate local
    /// folders/Steam. Keep the presented scope fixed until Finish or Review.
    public func manualRecheck() async {
        guard canRefresh, let activeScope else { return }
        await run(activeScope, preservingSettingsReturn: true)
    }

    private func run(_ startingScope: CompanionSetupScope, preservingSettingsReturn: Bool = false) async {
        activeScope = startingScope
        restartSuggested = false
        openedSettings = nil
        if !preservingSettingsReturn { returnedSettings = nil }
        generation &+= 1
        let run = generation
        running = true
        phase = .requesting
        outcomes = [:]
        onChange?()
        await withTaskCancellationHandler {
            for step in startingScope.steps {
                guard valid(run) else { return }
                current = step
                onChange?()
                // Publication is synchronous: an observer can close/defer setup
                // before a request waiter exists. Do not resume that old run.
                guard valid(run) else { return }
                let status = driver.status(for: step)
                let result = status == .undetermined ? await request(step, run: run) : status
                guard valid(run) else { return }
                outcomes[step] = result
                onChange?()
            }
            guard valid(run) else { return }
            current = nil
            running = false
            phase = .summary
            restartSuggested = requiresRestart(for: outcomes)
            onChange?()
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                self.cancelForLifecycleChange()
            }
        }
    }

    private var canRefresh: Bool {
        eligible() && presented && !running && phase == .summary && !Task.isCancelled
    }

    /// Metadata only: no request, folder read, Steam probe or engine creation.
    public func refreshFrameworkStatuses(returningFromSettings: Bool = false) {
        guard canRefresh, let activeScope else { return }
        let run = generation
        var refreshed = outcomes
        for step in activeScope.steps where step != .folders && step != .steam {
            let status = driver.status(for: step)
            // An injected getter/delegate can synchronously cancel this session.
            guard canRefresh, generation == run else { return }
            refreshed[step] = status
        }
        if returningFromSettings, let openedSettings {
            returnedSettings = openedSettings
            self.openedSettings = nil
        }
        let needsRestart = requiresRestart(for: refreshed)
        let changed = outcomes != refreshed || restartSuggested != needsRestart
        outcomes = refreshed
        restartSuggested = needsRestart
        if changed { onChange?() }
    }

    private func requiresRestart(for statuses: [CompanionSetupKind: CompanionSetupStatus]) -> Bool {
        if let returnedSettings, statuses[returnedSettings] == .authorized {
            self.returnedSettings = nil
        }
        return returnedSettings.map { statuses[$0] != .authorized } ?? false
    }

    public func settingsOpened(for kind: CompanionSetupKind) {
        guard canRefresh, activeScope?.steps.contains(kind) == true,
              kind != .folders, kind != .steam else { return }
        openedSettings = kind
        returnedSettings = nil
        restartSuggested = false
        onChange?()
    }

    /// Called only after the relaunch helper acknowledges that it is waiting.
    @discardableResult public func checkpointForRestart() -> Bool {
        guard canRefresh else { return false }
        return persist(deferred: false, resumeSummary: true)
    }

    private func valid(_ run: UInt64) -> Bool {
        eligible() && generation == run && running && presented && !Task.isCancelled
    }

    private func request(_ step: CompanionSetupKind, run: UInt64) async -> CompanionSetupStatus {
        // Validate again at creation, including reentrancy from an injected
        // status getter or cancellation before this async function is entered.
        guard valid(run) else { return .unavailable }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            pending = (id, continuation)
            requestTask = Task { [weak self, driver] in
                guard self?.valid(run) == true else {
                    self?.resolve(.unavailable, id: id)
                    return
                }
                let status = await driver.request(step)
                self?.resolve(status, id: id)
            }
        }
    }

    private func resolve(_ status: CompanionSetupStatus, id: UUID) {
        guard pending?.id == id else { return }
        let continuation = pending?.continuation
        pending = nil
        requestTask = nil
        continuation?.resume(returning: status)
    }

    public func skipCurrent() {
        guard running, pending != nil else { return }
        releaseRequest(as: .skipped)
    }

    private func releaseRequest(as status: CompanionSetupStatus) {
        let continuation = pending?.continuation
        pending = nil
        requestTask?.cancel()
        requestTask = nil
        driver.cancel()
        continuation?.resume(returning: status)
    }

    public func finish() {
        guard presented, !running, phase == .summary else { return }
        persist(deferred: false)
        presented = false
        onChange?()
    }

    public func deferSetup() {
        guard presented else { return }
        persist(deferred: true)
        cancelForLifecycleChange()
    }

    @discardableResult private func persist(deferred: Bool, resumeSummary: Bool = false) -> Bool {
        guard let activeScope, !activeScope.buildIdentity.isEmpty else { return false }
        let record = Record(version: 1, scope: activeScope, deferred: deferred, outcomes: outcomes, resumeSummary: resumeSummary)
        guard let data = try? JSONEncoder().encode(record), data.count <= 65_536 else { return false }
        storage.save(data)
        return storage.load() == data
    }

    /// Handoff/Quit must not turn interrupted onboarding into an explicit skip.
    public func cancelForLifecycleChange() {
        generation &+= 1
        running = false
        presented = false
        current = nil
        outcomes = [:]
        restartSuggested = false
        openedSettings = nil
        returnedSettings = nil
        phase = .welcome
        releaseRequest(as: .unavailable)
        onChange?()
    }
}
