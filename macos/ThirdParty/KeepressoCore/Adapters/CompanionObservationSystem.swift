import Foundation
import AppKit
import CoreGraphics
import CoreLocation
import CoreWLAN
import CoreBluetooth
import IOBluetooth
import EventKit
import IOKit.ps
import IOKit.hid
import GameController

/// Cache value and completion are committed under one lock. A caller receives
/// one coherent optional value, never readiness for an older cached false.
final class CompanionObservationCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var fetchedAt: Date?
    private var refreshing = false
    private let ttl: TimeInterval
    private let now: () -> Date
    private let fetch: @Sendable () -> Value?
    init(ttl: TimeInterval = 3, now: @escaping () -> Date, fetch: @escaping @Sendable () -> Value?) {
        self.ttl = ttl; self.now = now; self.fetch = fetch
    }
    func read() -> Value? {
        let result: (Value?, Bool) = locked {
            let stale = fetchedAt.map { now().timeIntervalSince($0) >= ttl } ?? true
            let start = stale && !refreshing
            if start { refreshing = true }
            // Expired input is not current proof, even while revalidating.
            return (stale ? nil : value, start)
        }
        if result.1 {
            Task.detached { [weak self] in
                guard let self else { return }
                let fetched = self.fetch()
                self.locked { self.value = fetched; self.fetchedAt = self.now(); self.refreshing = false }
            }
        }
        return result.0
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

extension CompanionObservationDependencies {
    static func system(hookRecords: @escaping @Sendable (Date) -> [AgentHooks.HookRecord], hooksAvailable: @escaping @Sendable () -> Bool, now: @escaping () -> Date) -> Self {
        var d = Self()
        let sharedPS = SharedPSSnapshot(now: now)
        let processes = CompanionObservationCache<CompanionObservationProcesses>(now: now) {
            guard let raw = sharedPS.fetchRaw() else { return nil }
            return CompanionObservationSystem.processes(raw)
        }
        let vpn = CompanionObservationCache<Bool>(now: now) {
            guard let output = SCUtilVPNMonitor.runSCUtil(), output.contains("Available network connection services") else { return nil }
            return SCUtilVPNMonitor.hasConnectedService(in: output)
        }
        let calendar = CompanionObservationCache<[CalendarEventWindow]>(ttl: 60, now: now) {
            guard let windows = EventKitCalendarMonitor.fetchSystem(), EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
            return windows
        }
        let agent = CompanionObservationCache<CompanionObservationAgents>(now: now) {
            guard let raw = sharedPS.fetchRaw(), CompanionObservationSystem.validPS(raw) else { return nil }
            return CompanionObservationAgentReader.read(raw: raw, now: now(), hookRecords: hookRecords, hooksAvailable: hooksAvailable)
        }
        let cpu = HostCPULoadReader(); let throughput = GetifaddrsThroughputReader()
        let media = TTLCache<CompanionObservationMedia>(ttl: 1.5, now: now, probe: CompanionObservationHAL.read)
        let scanner = CompanionObservationDownloadScanner()
        d.power = CompanionObservationSystem.power
        d.displays = CompanionObservationSystem.displays
        d.network = CompanionObservationSystem.network
        d.workspace = { NSWorkspaceMonitor().current }
        d.processes = { processes.read() }
        d.volumes = CompanionObservationSystem.volumes
        d.cpu = { cpu.currentLoad() }
        d.media = { media.current }
        d.vpn = { vpn.read() }
        d.bluetooth = CompanionObservationSystem.bluetooth
        d.calendar = {
            guard let windows = CompanionObservationSystem.permitted(EKEventStore.authorizationStatus(for: .event) == .fullAccess, read: { calendar.read() }) else { return nil }
            return EventKitCalendarMonitor.hasTimedEvent(in: windows, at: now())
        }
        d.gaming = CompanionObservationSystem.gaming
        d.throughput = { throughput.currentBytesPerSecond() }
        d.downloads = { scanner.read(in: $0) }
        d.agents = { agent.read() }
        d.controllers = CompanionObservationSystem.controllers
        return d
    }
}

enum CompanionObservationSystem {
    static func permitted<Value>(_ allowed: Bool, read: () -> Value?) -> Value? { guard allowed else { return nil }; return read() }

    static func validPS(_ raw: String) -> Bool {
        // A successful empty injected listing is valid; the system runner
        // separately rejects empty stdout. Never accept silently skipped rows.
        let lines = raw.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let samples = PSAgentActivityMonitor.parse(raw)
        return samples.count == lines.count && samples.allSatisfy { ($0.pid > 0 || ($0.pid == 0 && $0.ppid == 0 && $0.command == "kernel_task")) && $0.ppid >= 0 && $0.pcpu.isFinite && $0.pcpu >= 0 }
    }
    /// Process-exists matching needs independently verified commands, unlike
    /// the agent reader's strictly complete ancestry/CPU tree.
    static func processes(_ raw: String) -> CompanionObservationProcesses {
        var commands: [String] = []; var complete = true
        for line in raw.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let rows = PSAgentActivityMonitor.parse(String(line))
            // Native command parsing accepts PID zero; validPS additionally
            // requires a complete tree and restricts zero to kernel_task.
            guard rows.count == 1, let row = rows.first, row.pid >= 0, row.ppid >= 0,
                  row.pcpu.isFinite, row.pcpu >= 0 else { complete = false; continue }
            commands.append(row.command)
        }
        return .init(commands: commands, complete: complete)
    }
    static func power(provider: PowerSourceSnapshot.Provider, charging: [Bool?]?) -> CompanionObservationPower? {
        .init(snapshot: .init(provider: provider, isCharging: charging?.contains { $0 == true } == true, hasBattery: charging?.isEmpty == false),
              providerComplete: provider != .unknown, chargingComplete: charging?.allSatisfy { $0 != nil } == true)
    }
    static func power() -> CompanionObservationPower? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        let provider: PowerSourceSnapshot.Provider
        switch IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? {
        case kIOPSACPowerValue: provider = .ac
        case kIOPSBatteryPowerValue: provider = .battery
        default: provider = .unknown
        }
        let charging = (IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]).map {
            (IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any])?[kIOPSIsChargingKey] as? Bool
        }
        return power(provider: provider, charging: charging)
    }
    static func displays() -> DisplaySnapshot? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return .init(externalDisplayCount: 0, totalDisplayCount: 0) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success, count <= ids.count else { return nil }
        let active = ids.prefix(Int(count))
        return .init(externalDisplayCount: active.filter { CGDisplayIsBuiltin($0) == 0 }.count, totalDisplayCount: active.count)
    }
    static func network() -> NetworkSnapshot? {
        let status = CLLocationManager().authorizationStatus
        return permitted(CLLocationManager.locationServicesEnabled() && status == .authorizedAlways) {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        if let ssid = interface.ssid() { return .init(ssid: ssid) }
        // A nil SSID can be privacy redaction even after authorization. Only
        // the explicitly powered-off interface proves no association.
        return interface.powerOn() ? nil : .init(ssid: nil)
        }
    }
    static func volumes(urls: [URL]?, name: (URL) throws -> String?) -> CompanionObservationVolumes? {
        guard let urls else { return nil }
        var names: Set<String> = []; var complete = true
        for url in urls where url.path != "/" {
            guard let value = try? name(url) else { complete = false; continue }
            names.insert(value)
        }
        return .init(snapshot: .init(volumeNames: names), complete: complete)
    }
    static func volumes() -> CompanionObservationVolumes? {
        volumes(urls: FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes])) {
            try $0.resourceValues(forKeys: [.volumeNameKey]).volumeName
        }
    }
    struct BluetoothDevice { var name: String?; var connected: Bool? }
    struct HIDDevice {
        var vendorID: Int?
        var transport: String?
        var productID: Int?
        var location: Int? = nil
    }
    static func bluetooth(devices: [BluetoothDevice]?) -> CompanionObservationBluetooth? {
        guard let devices else { return nil }
        var paired: [String] = []; var connected: [String] = []; var complete = true
        for device in devices {
            let name = device.name.flatMap { $0.isEmpty ? nil : $0 }
            if let name { paired.append(name) }
            guard let isConnected = device.connected else { complete = false; continue }
            guard isConnected else { continue }
            guard let name else { complete = false; continue }
            connected.append(name)
        }
        return .init(snapshot: .init(pairedDeviceNames: paired, connectedDeviceNames: connected), complete: complete)
    }
    static func bluetooth() -> CompanionObservationBluetooth? {
        permitted(CBManager.authorization == .allowedAlways) {
            bluetooth(devices: (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.map {
                BluetoothDevice(name: $0.name, connected: $0.isConnected())
            })
        }
    }
    static func gaming(bundleID: String?, path: String?, pid: Int32? = nil, metadata: () -> [String: Any]?) -> CompanionObservationGaming {
        var snapshot = GamingSnapshot(frontmostBundleID: bundleID, frontmostBundlePath: path, frontmostPID: pid)
        // Native cloud-client and Steam-path matches are sufficient without
        // reading category metadata (which may be unavailable).
        if GamingTrigger.isGame(snapshot) { return .init(snapshot: snapshot, complete: false) }
        guard let info = metadata() else { return .init(snapshot: snapshot, complete: false) }
        if let category = info["LSApplicationCategoryType"], !(category is String) { return .init(snapshot: snapshot, complete: false) }
        snapshot.frontmostCategoryType = info["LSApplicationCategoryType"] as? String
        return .init(snapshot: snapshot)
    }
    static func gaming() -> CompanionObservationGaming? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .init(snapshot: .init()) }
        return gaming(bundleID: app.bundleIdentifier, path: app.bundleURL?.path, pid: app.processIdentifier) {
            app.bundleURL.flatMap(Bundle.init(url:))?.infoDictionary
        }
    }
    static func controllerCount(frameworkCount: Int, devices: [HIDDevice]?) -> Int? {
        if frameworkCount > 0 { return frameworkCount }
        guard let devices else { return nil }
        var valve: [SteamControllerHID.Device] = []; var complete = true
        for device in devices {
            guard let vendor = device.vendorID else { complete = false; continue }
            guard vendor == SteamControllerHID.valveVendorID else { continue }
            guard let transport = device.transport, !transport.isEmpty, let product = device.productID else { complete = false; continue }
            valve.append(.init(transport: transport, productID: product, location: device.location))
        }
        let count = SteamControllerHID.distinctHardwareCount(devices: valve)
        return count > 0 || complete ? count : nil
    }
    static func controllers() -> Int? {
        let frameworkCount = GCController.controllers().count
        if frameworkCount > 0 { return frameworkCount }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var devices: [HIDDevice] = []
        while true {
            let service = IOIteratorNext(iterator); if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
                devices.append(.init(vendorID: nil, transport: nil, productID: nil)); continue
            }
            devices.append(.init(vendorID: IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
                                 transport: IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
                                 productID: IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
                                 location: IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int))
        }
        // Enumeration only: never open a HID device or read input reports.
        return controllerCount(frameworkCount: frameworkCount, devices: devices)
    }
}
