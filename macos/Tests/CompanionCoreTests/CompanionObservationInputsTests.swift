import Foundation
import Testing
@testable import KeepressoCore

// These fixtures catch a missing type path, unsafe false on absent input, and
// changes that bypass the pinned factory's matching and smoothing rules.
struct CompanionObservationInputsTests {
    final class Steam: SteamDownloadMonitoring { var isDownloading = false }
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    let folder = URL(fileURLWithPath: "/fixture/downloads")

    func dependencies(active: Bool) -> CompanionObservationDependencies {
        var d = CompanionObservationDependencies()
        d.power = { .init(snapshot: PowerSourceSnapshot(provider: active ? .ac : .battery, isCharging: active, hasBattery: true)) }
        d.displays = { DisplaySnapshot(externalDisplayCount: active ? 1 : 0, totalDisplayCount: 1) }
        d.network = { NetworkSnapshot(ssid: active ? "Fixture" : "Other") }
        d.workspace = { WorkspaceSnapshot(runningBundleIDs: active ? ["org.fixture.call"] : []) }
        d.processes = { .init(commands: active ? ["/fixture/worker --job"] : []) }
        d.volumes = { .init(snapshot: VolumeSnapshot(volumeNames: active ? ["FixtureDisk"] : [])) }
        d.cpu = { active ? 0.95 : 0 }
        d.media = { CompanionObservationMedia(snapshot: MediaActivitySnapshot(cameraInUse: active, microphoneInUse: active, audioPlaying: active, micCapturingBundleIDs: active ? ["org.fixture.call.helper"] : [])) }
        d.vpn = { active }
        d.bluetooth = { .init(snapshot: BluetoothSnapshot(connectedDeviceNames: active ? ["FIXTURE PAD"] : [])) }
        d.calendar = { active }
        d.gaming = { .init(snapshot: GamingSnapshot(frontmostCategoryType: active ? "public.app-category.action-games" : "public.app-category.productivity")) }
        d.throughput = { active ? 1_000_000 : 0 }
        d.downloads = { _ in CompanionObservationDownload(newestWrite: active ? instant : nil) }
        d.agents = { CompanionObservationAgents(snapshot: active ? AgentSnapshot(sessions: [AgentSession(pid: 42, agent: "codex", tty: nil, cpuPercent: 0, hookState: .working)]) : .empty, negativeComplete: true) }
        d.controllers = { active ? 1 : 0 }
        return d
    }
    func rules(active: Bool) -> [TriggerRule] {
        let minute = Calendar.current.component(.hour, from: instant) * 60 + Calendar.current.component(.minute, from: instant)
        return [.powerSource(.onACPower), .externalDisplay, .wifiSSID("Fixture"), .app(AppRule(bundleID: "org.fixture.call")), .process("WORKER"),
            .timeWindow(TimeWindowRule(startMinutes: active ? minute : (minute + 2) % 1440, endMinutes: active ? (minute + 1) % 1440 : (minute + 3) % 1440)),
            .volumeMounted("FixtureDisk"), .cpuLoad(thresholdPercent: 50), .mediaInUse(.camera), .micInUse(MicInUseRule(apps: [.init(bundleID: "org.fixture.call")])),
            .audioPlaying, .vpnConnected, .bluetoothDevice("fixture pad"), .calendarEvent, .gaming, .throughput(kilobytesPerSecond: 100), .downloadInFolder(folder),
            .agentActivity(AgentRule(grace: 0)), .controllerConnected, .steamDownload]
    }
    func inputs(_ d: CompanionObservationDependencies, steam: Steam, available: @escaping () -> Bool = { true }) -> CompanionObservationInputs {
        CompanionObservationInputs(dependencies: d, folderApproved: { _ in true }, steam: steam, steamAvailable: available, now: { instant })
    }
    func state(_ rule: TriggerRule, inputs: CompanionObservationInputs) -> RuleState {
        let trigger = inputs.factory.makeTrigger(for: rule)
        trigger.tick()
        return RuleState(rule: rule, satisfied: trigger.isSatisfied(), inGrace: false)
    }
    @Test func allTwentyTypesUseFactoryAndAuditedPositiveAndNegativeInputs() {
        for active in [true, false] {
            let steam = Steam(); steam.isDownloading = active
            let input = inputs(dependencies(active: active), steam: steam)
            let cases = rules(active: active)
            #expect(cases.count == 20)
            for rule in cases {
                #expect(input.assessed(state(rule, inputs: input)) == active, "\(rule)")
            }
        }
    }
    @Test func absentInputCannotTurnIntoFalseOrStaleTrue() {
        let input = inputs(CompanionObservationDependencies(), steam: Steam(), available: { false })
        for rule in rules(active: false) {
            if case .timeWindow = rule { continue }
            #expect(input.assessed(state(rule, inputs: input)) == nil, "\(rule)")
            #expect(input.assessed(RuleState(rule: rule, satisfied: true, inGrace: true)) == nil, "\(rule)")
        }
    }
    @Test func coldCPUAndThroughputStayUnknownThenFeedPinnedEMA() {
        var cpu: Double?; var throughput: Double?
        var d = dependencies(active: false); d.cpu = { cpu }; d.throughput = { throughput }
        let input = inputs(d, steam: Steam())
        for rule in [TriggerRule.cpuLoad(thresholdPercent: 50), .throughput(kilobytesPerSecond: 100)] {
            let t = input.factory.makeTrigger(for: rule)
            input.beginSample(); t.tick(); #expect(input.assessed(RuleState(rule: rule, satisfied: t.isSatisfied(), inGrace: false)) == nil)
            cpu = 1; throughput = 1_000_000
            input.beginSample(); t.tick(); #expect(input.assessed(RuleState(rule: rule, satisfied: t.isSatisfied(), inGrace: false)) == true)
            cpu = 0; throughput = 0
            input.beginSample(); t.tick(); #expect(input.assessed(RuleState(rule: rule, satisfied: t.isSatisfied(), inGrace: false)) == true)
            cpu = nil; throughput = nil
            input.beginSample(); t.tick()
            #expect(input.assessed(RuleState(rule: rule, satisfied: t.isSatisfied(), inGrace: false)) == nil)
        }
    }
    @Test func unusedInputsAreNotRead() {
        var d = CompanionObservationDependencies()
        d.processes = { Issue.record("unused process list read"); return .init(commands: []) }
        d.media = { Issue.record("unused media read"); return nil }
        d.calendar = { Issue.record("unused calendar read"); return false }
        let input = inputs(d, steam: Steam())
        let rule = rules(active: true)[5]
        #expect(input.assessed(state(rule, inputs: input)) == true)
    }
}
