import Foundation

struct CompanionObservationPower {
    var snapshot: PowerSourceSnapshot
    var providerComplete = true
    var chargingComplete = true
}
struct CompanionObservationProcesses { var commands: [String]; var complete = true }
struct CompanionObservationVolumes { var snapshot: VolumeSnapshot; var complete = true }
struct CompanionObservationMedia {
    var snapshot: MediaActivitySnapshot
    var cameraComplete = true
    var microphoneComplete = true
    var capturersComplete = true
    var audioComplete = true
}
struct CompanionObservationBluetooth { var snapshot: BluetoothSnapshot; var complete = true }
struct CompanionObservationGaming { var snapshot: GamingSnapshot; var complete = true }
struct CompanionObservationDownload { var newestWrite: Date?; var complete = true }
struct CompanionObservationAgents { var snapshot: AgentSnapshot; var negativeComplete: Bool }

/// Optional readings distinguish a verified empty/false value from a failed,
/// denied or cold read. Defaults intentionally do no work.
struct CompanionObservationDependencies {
    var power: () -> CompanionObservationPower? = { nil }
    var displays: () -> DisplaySnapshot? = { nil }
    var network: () -> NetworkSnapshot? = { nil }
    var workspace: () -> WorkspaceSnapshot? = { nil }
    var processes: () -> CompanionObservationProcesses? = { nil }
    var volumes: () -> CompanionObservationVolumes? = { nil }
    var cpu: () -> Double? = { nil }
    var media: () -> CompanionObservationMedia? = { nil }
    var vpn: () -> Bool? = { nil }
    var bluetooth: () -> CompanionObservationBluetooth? = { nil }
    var calendar: () -> Bool? = { nil }
    var gaming: () -> CompanionObservationGaming? = { nil }
    var throughput: () -> Double? = { nil }
    var downloads: (URL) -> CompanionObservationDownload? = { _ in nil }
    var agents: () -> CompanionObservationAgents? = { nil }
    var controllers: () -> Int? = { nil }
}

/// Tracks availability of the exact sample consumed by a native trigger.
/// Assessment never probes a second time or consults a newly completed cache.
private final class ObservationRead<Value> {
    let fetch: () -> Value?
    private(set) var last: Value?
    private var sampled = false
    init(_ fetch: @escaping () -> Value?) { self.fetch = fetch }
    func read(_ fallback: Value) -> Value {
        if !sampled { last = fetch(); sampled = true }
        return last ?? fallback
    }
    func beginSample() { sampled = false; last = nil }
    var ready: Bool { last != nil }
}
private final class ObservationPower: PowerSourceMonitoring {
    let input: ObservationRead<CompanionObservationPower>
    init(_ input: ObservationRead<CompanionObservationPower>) { self.input = input }
    var current: PowerSourceSnapshot { input.read(.init(snapshot: .init(provider: .unknown, isCharging: false, hasBattery: false), providerComplete: false, chargingComplete: false)).snapshot }
}
private final class ObservationDisplay: DisplayMonitoring {
    let input: ObservationRead<DisplaySnapshot>
    init(_ input: ObservationRead<DisplaySnapshot>) { self.input = input }
    var current: DisplaySnapshot { input.read(.init(externalDisplayCount: 0, totalDisplayCount: 0)) }
}
private final class ObservationNetwork: NetworkMonitoring {
    let input: ObservationRead<NetworkSnapshot>
    init(_ input: ObservationRead<NetworkSnapshot>) { self.input = input }
    var current: NetworkSnapshot { input.read(.init(ssid: nil)) }
}
private final class ObservationWorkspace: WorkspaceMonitoring {
    let input: ObservationRead<WorkspaceSnapshot>
    init(_ input: ObservationRead<WorkspaceSnapshot>) { self.input = input }
    var current: WorkspaceSnapshot { input.read(.init(runningBundleIDs: [])) }
}
private final class ObservationProcesses: ProcessListing {
    let input: ObservationRead<CompanionObservationProcesses>
    init(_ input: ObservationRead<CompanionObservationProcesses>) { self.input = input }
    var current: [String] { input.read(.init(commands: [], complete: false)).commands }
}
private final class ObservationVolumes: VolumeMonitoring {
    let input: ObservationRead<CompanionObservationVolumes>
    init(_ input: ObservationRead<CompanionObservationVolumes>) { self.input = input }
    var current: VolumeSnapshot { input.read(.init(snapshot: .init(volumeNames: []), complete: false)).snapshot }
}
private final class ObservationCPU: CPULoadReading {
    let input: ObservationRead<Double>
    init(_ input: ObservationRead<Double>) { self.input = input }
    func currentLoad() -> Double? { _ = input.read(0); return input.last }
}
private final class ObservationMedia: MediaActivityMonitoring {
    let input: ObservationRead<CompanionObservationMedia>
    init(_ input: ObservationRead<CompanionObservationMedia>) { self.input = input }
    var current: MediaActivitySnapshot { input.read(.init(snapshot: .init())).snapshot }
}
private final class ObservationVPN: VPNMonitoring {
    let input: ObservationRead<Bool>
    init(_ input: ObservationRead<Bool>) { self.input = input }
    var isConnected: Bool { input.read(false) }
}
private final class ObservationBluetooth: BluetoothMonitoring {
    let input: ObservationRead<CompanionObservationBluetooth>
    init(_ input: ObservationRead<CompanionObservationBluetooth>) { self.input = input }
    var current: BluetoothSnapshot { input.read(.init(snapshot: .init(), complete: false)).snapshot }
}
private final class ObservationCalendar: CalendarMonitoring {
    let input: ObservationRead<Bool>
    init(_ input: ObservationRead<Bool>) { self.input = input }
    var isEventInProgress: Bool { input.read(false) }
}
private final class ObservationGaming: GamingMonitoring {
    let input: ObservationRead<CompanionObservationGaming>
    init(_ input: ObservationRead<CompanionObservationGaming>) { self.input = input }
    var current: GamingSnapshot { input.read(.init(snapshot: .init(), complete: false)).snapshot }
}
private final class ObservationThroughput: NetworkThroughputReading {
    let input: ObservationRead<Double>
    init(_ input: ObservationRead<Double>) { self.input = input }
    func currentBytesPerSecond() -> Double? { _ = input.read(0); return input.last }
}
private final class ObservationDownloads: DownloadFolderScanning {
    let approved: (URL) -> Bool
    let fetch: (URL) -> CompanionObservationDownload?
    var readings: [URL: CompanionObservationDownload] = [:]
    private var attempted: Set<URL> = []
    func beginSample() { readings.removeAll(); attempted.removeAll() }
    init(approved: @escaping (URL) -> Bool, fetch: @escaping (URL) -> CompanionObservationDownload?) { self.approved = approved; self.fetch = fetch }
    func newestPartialDownloadWrite(in folder: URL) -> Date? {
        if let sample = readings[folder] { return sample.newestWrite }
        if attempted.contains(folder) { return nil }
        attempted.insert(folder)
        guard approved(folder) else { return nil }
        let sample = fetch(folder); readings[folder] = sample
        return sample?.newestWrite
    }
}
private final class ObservationAgents: AgentActivityMonitoring {
    let input: ObservationRead<CompanionObservationAgents>
    let evidenceOnly: Bool
    init(_ input: ObservationRead<CompanionObservationAgents>, evidenceOnly: Bool) {
        self.input = input
        self.evidenceOnly = evidenceOnly
    }
    var current: AgentSnapshot {
        var snapshot = input.read(.init(snapshot: .empty, negativeComplete: false)).snapshot
        if evidenceOnly {
            for index in snapshot.sessions.indices { snapshot.sessions[index].evidenceOnly = true }
        }
        return snapshot
    }
}
private final class ObservationControllers: ControllerMonitoring {
    let input: ObservationRead<Int>
    init(_ input: ObservationRead<Int>) { self.input = input }
    var connectedCount: Int { input.read(0) }
}
private final class ObservationSteam: SteamDownloadMonitoring {
    let monitor: SteamDownloadMonitoring
    let available: () -> Bool
    private(set) var ready = false
    private var sampled = false
    private var value = false
    func beginSample() { sampled = false; ready = false }
    init(_ monitor: SteamDownloadMonitoring, available: @escaping () -> Bool) { self.monitor = monitor; self.available = available }
    var isDownloading: Bool {
        // The injected monitor owns filesystem authorization and starts its
        // own read here; readiness belongs to that returned reading.
        if !sampled {
            value = monitor.isDownloading
            ready = value || available()
            sampled = true
        }
        return value
    }
}

/// Read-only, bounded-observer inputs for every pinned TriggerRule. All matching,
/// EMA, hysteresis and grace decisions remain in the unchanged TriggerFactory.
public final class CompanionObservationInputs {
    public private(set) lazy var factory = makeFactory(evidenceOnly: false)
    public private(set) lazy var evidenceOnlyFactory = makeFactory(evidenceOnly: true)
    private let now: () -> Date
    private let power: ObservationRead<CompanionObservationPower>
    private let displays: ObservationRead<DisplaySnapshot>
    private let network: ObservationRead<NetworkSnapshot>
    private let workspace: ObservationRead<WorkspaceSnapshot>
    private let processes: ObservationRead<CompanionObservationProcesses>
    private let volumes: ObservationRead<CompanionObservationVolumes>
    private let cpu: ObservationRead<Double>
    private let media: ObservationRead<CompanionObservationMedia>
    private let vpn: ObservationRead<Bool>
    private let bluetooth: ObservationRead<CompanionObservationBluetooth>
    private let calendar: ObservationRead<Bool>
    private let gaming: ObservationRead<CompanionObservationGaming>
    private let throughput: ObservationRead<Double>
    private let downloads: ObservationDownloads
    private let agents: ObservationRead<CompanionObservationAgents>
    private let controllers: ObservationRead<Int>
    private let steam: ObservationSteam

    public convenience init(hookRecords: @escaping @Sendable (Date) -> [AgentHooks.HookRecord], hooksAvailable: @escaping @Sendable () -> Bool, folderApproved: @escaping (URL) -> Bool, steam: SteamDownloadMonitoring, steamAvailable: @escaping () -> Bool, now: @escaping () -> Date = Date.init) {
        self.init(dependencies: .system(hookRecords: hookRecords, hooksAvailable: hooksAvailable, now: now), folderApproved: folderApproved, steam: steam, steamAvailable: steamAvailable, now: now)
    }

    init(dependencies d: CompanionObservationDependencies, folderApproved: @escaping (URL) -> Bool, steam monitor: SteamDownloadMonitoring, steamAvailable: @escaping () -> Bool, now: @escaping () -> Date = Date.init) {
        power = ObservationRead(d.power); displays = ObservationRead(d.displays)
        network = ObservationRead(d.network); workspace = ObservationRead(d.workspace)
        processes = ObservationRead(d.processes); volumes = ObservationRead(d.volumes)
        cpu = ObservationRead(d.cpu); media = ObservationRead(d.media)
        vpn = ObservationRead(d.vpn); bluetooth = ObservationRead(d.bluetooth)
        calendar = ObservationRead(d.calendar); gaming = ObservationRead(d.gaming)
        throughput = ObservationRead(d.throughput); agents = ObservationRead(d.agents)
        controllers = ObservationRead(d.controllers)
        downloads = ObservationDownloads(approved: folderApproved, fetch: d.downloads)
        steam = ObservationSteam(monitor, available: steamAvailable)
        self.now = now
    }

    private func makeFactory(evidenceOnly: Bool) -> TriggerFactory {
        TriggerFactory(
            powerSource: ObservationPower(power), displays: ObservationDisplay(displays),
            network: ObservationNetwork(network), workspace: ObservationWorkspace(workspace),
            processes: ObservationProcesses(processes), volumes: ObservationVolumes(volumes),
            cpu: ObservationCPU(cpu), media: ObservationMedia(media), vpn: ObservationVPN(vpn),
            bluetooth: ObservationBluetooth(bluetooth), calendar: ObservationCalendar(calendar),
            gaming: ObservationGaming(gaming), throughput: ObservationThroughput(throughput),
            downloads: downloads, agents: ObservationAgents(agents, evidenceOnly: evidenceOnly),
            controllers: ObservationControllers(controllers), steam: steam, now: now
        )
    }

    /// Start one serialized engine tick / ruleStates cycle. A shared input is
    /// read lazily once, so a cache completing between two rules cannot bless
    /// an earlier cold false. Clear TriggerGateController's rule-state cache
    /// for the same cycle (rebuild with identical rules retains its triggers).
    public func beginSample() {
        power.beginSample(); displays.beginSample(); network.beginSample()
        workspace.beginSample(); processes.beginSample(); volumes.beginSample()
        cpu.beginSample(); media.beginSample(); vpn.beginSample()
        bluetooth.beginSample(); calendar.beginSample(); gaming.beginSample()
        throughput.beginSample(); downloads.beginSample(); agents.beginSample()
        controllers.beginSample(); steam.beginSample()
    }

    public func assessed(_ state: RuleState) -> Bool? {
        let ready: Bool
        switch state.rule {
        case .powerSource(let match):
            if match == .charging {
                ready = power.last?.chargingComplete == true || (state.satisfied && !state.inGrace && power.last?.snapshot.isCharging == true)
            } else { ready = power.last?.providerComplete == true }
        case .externalDisplay: ready = displays.ready
        case .wifiSSID: ready = network.ready
        case .app: ready = workspace.ready
        case .process: ready = processes.last?.complete == true || (state.satisfied && !state.inGrace && processes.last?.commands.isEmpty == false)
        case .timeWindow: ready = true
        case .volumeMounted: ready = volumes.last?.complete == true || (state.satisfied && !state.inGrace && volumes.last?.snapshot.volumeNames.isEmpty == false)
        case .cpuLoad: ready = cpu.ready
        case .mediaInUse(let device):
            let sample = media.last
            let complete = device == .camera ? sample?.cameraComplete == true : sample?.microphoneComplete == true
            let active = device == .camera ? sample?.snapshot.cameraInUse == true : sample?.snapshot.microphoneInUse == true
            ready = complete || (state.satisfied && active)
        case .micInUse(let rule):
            ready = media.last?.capturersComplete == true || (state.satisfied && media.last.map {
                MediaInUseTrigger.captures(rule.apps.map(\.bundleID), in: $0.snapshot.micCapturingBundleIDs)
            } == true)
        case .audioPlaying:
            ready = media.last?.audioComplete == true || (state.satisfied && media.last?.snapshot.audioPlaying == true)
        case .vpnConnected: ready = vpn.ready
        case .bluetoothDevice:
            // The pinned factory already compared this rule's name. A true
            // non-grace RuleState proves a direct match in the frozen subset.
            ready = bluetooth.last?.complete == true || (state.satisfied && !state.inGrace && bluetooth.last?.snapshot.connectedDeviceNames.isEmpty == false)
        case .calendarEvent: ready = calendar.ready
        case .gaming:
            ready = gaming.last?.complete == true || (state.satisfied && gaming.last.map { GamingTrigger.isGame($0.snapshot) } == true)
        case .throughput: ready = throughput.ready
        case .downloadInFolder(let folder):
            let sample = downloads.readings[folder]
            // Freshness is decided by the pinned DownloadInFolderTrigger.
            // Its direct (non-grace) true plus this consumed marker is proof;
            // a held true after an incomplete stale/missing marker is not.
            ready = sample?.complete == true || (state.satisfied && !state.inGrace && sample?.newestWrite != nil)
        case .agentActivity: ready = agents.ready && ((state.satisfied && !state.inGrace) || agents.last?.negativeComplete == true)
        case .controllerConnected: ready = controllers.ready
        case .steamDownload: ready = steam.ready
        }
        return ready ? state.satisfied : nil
    }
}
