import Foundation
import Testing
@testable import CompanionCore

struct AwakeAlertTests {
    let start = Date(timeIntervalSince1970: 50_400)

    func sample(
        lidClosed: Bool, now: Date, idle: TimeInterval = 0, brewing: Bool = true,
        wake: MacAlertWakeState = .full
    ) -> MacAwakeReading {
        .init(wake: wake, lidClosed: lidClosed, isBrewing: brewing,
              brew: brewing ? .init(startedAt: start, mode: .manual,
                                    endsAt: start + 10_800, returnsToAutomatic: true) : nil,
              lastUserInputAt: now - idle)
    }

    @Test func cachedFullWakeCannotOverrideCurrentDarkWakeOrUnknown() {
        #expect(MacAlertWakeState.full.corroborated(by: .init(systemCapabilities: 0x1)) == .dark)
        #expect(MacAlertWakeState.full.corroborated(by: .init(systemCapabilities: nil)) == .unknown)
        #expect(MacAlertWakeState.full.corroborated(by: .init(systemCapabilities: 0x3)) == .full)
    }

    @Test func onlyOneUnattendedAlertUntilInputReturns() throws {
        var machine = ReminderMachine()
        for elapsed in [0.0, 2_700, 6_299] {
            let now = start + elapsed
            #expect(machine.observeAwake(sample(lidClosed: false, now: now, idle: max(0, elapsed - 2_700)), now: now).isEmpty)
        }
        let first = machine.observeAwake(
            sample(lidClosed: false, now: start + 6_300, idle: 3_600), now: start + 6_300)
        let alert = try #require(first.first)
        #expect(alert.kind == "unattended_brew")
        #expect(alert.title.contains("has been running unattended since"))
        #expect(alert.body.contains("then returns to Automatic"))
        #expect(alert.title.contains((start + 2_700).formatted(date: .omitted, time: .shortened)))
        machine.resumedAfterUnknownInterval()
        #expect(machine.observeAwake(sample(lidClosed: false, now: start + 9_901, idle: 7_201), now: start + 9_901).isEmpty)
        _ = machine.observeAwake(sample(lidClosed: false, now: start + 10_000), now: start + 10_000)
        #expect(machine.observeAwake(
            sample(lidClosed: false, now: start + 13_600, idle: 3_600), now: start + 13_600).count == 1)
    }

    @Test func ongoingLidAlertUpdatesWhenBrewingEndsThenResolves() throws {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: false, now: start), now: start)
        #expect(machine.observeAwake(sample(lidClosed: true, now: start + 1), now: start + 1).isEmpty)
        let opened = machine.observeAwake(sample(lidClosed: true, now: start + 3), now: start + 3).first
        let first = try #require(opened)
        #expect(first.alertPhase == .active)
        #expect(first.title == "Your Mac is running with the lid closed")
        let updated = machine.observeAwake(
            sample(lidClosed: true, now: start + 4, brewing: false), now: start + 4).first
        let ended = try #require(updated)
        #expect(ended.incidentId == first.incidentId)
        #expect(ended.alertPhase == .updated)
        #expect(ended.body == "Keepresso is no longer brewing.")
        let resolved = machine.observeAwake(
            sample(lidClosed: false, now: start + 5, brewing: false), now: start + 5).first
        let closed = try #require(resolved)
        #expect(closed.alertPhase == .resolved)
        #expect(closed.incidentId == first.incidentId)
    }

    @Test func routineSnoozeDoesNotSuppressTheLidAlert() {
        var machine = ReminderMachine()
        machine.snooze(now: start)
        _ = machine.observeAwake(sample(lidClosed: false, now: start), now: start)
        #expect(machine.observeAwake(sample(lidClosed: false, now: start + 3_600, idle: 3_600),
                                    now: start + 3_600).isEmpty)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 3_601), now: start + 3_601)
        #expect(machine.observeAwake(sample(lidClosed: true, now: start + 3_603), now: start + 3_603)
            .first?.alertPhase == .active)
    }

    @Test func darkWakeCreatesNoAlertsAndRestartsUnattendedTiming() {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: false, now: start), now: start)
        #expect(machine.observeAwake(
            sample(lidClosed: true, now: start + 3_601, idle: 3_601, wake: .dark), now: start + 3_601).isEmpty)
        #expect(machine.observeAwake(
            sample(lidClosed: false, now: start + 3_602, idle: 3_602), now: start + 3_602).isEmpty)
    }

    @Test func initiallyClosedStatusIsSilentAndSleepResolvesIt() throws {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: true, now: start), now: start)
        let status = machine.observeAwake(sample(lidClosed: true, now: start + 2), now: start + 2).first
        let alert = try #require(status)
        #expect(alert.alertPhase == .updated)
        let resolution = machine.observedSleep(now: start + 3)
        let removed = try #require(resolution)
        #expect(removed.alertPhase == .resolved)
        #expect(removed.incidentId == alert.incidentId)
    }

    @Test func criticalUpdatesAndRecoveryShareOneIncident() throws {
        var machine = ReminderMachine()
        let critical = MacThermalReading(state: .critical, brewingPaused: true)
        let onset = machine.observeHeat(critical, now: start)
        let first = try #require(onset)
        #expect(first.alertPhase == .active)
        #expect(machine.observeHeat(critical, now: start + 29) == nil)
        let saved = try WireJSON.encoder.encode(machine)
        machine = try WireJSON.decoder.decode(ReminderMachine.self, from: saved)
        machine.resumedAfterUnknownInterval()
        let fresh = machine.observeHeat(critical, now: start + 30)
        let heartbeat = try #require(fresh)
        #expect(heartbeat.alertPhase == .updated)
        #expect(heartbeat.incidentId == first.incidentId)
        #expect(machine.observeHeat(.init(state: .unknown), now: start + 31) == nil)
        let recovered = machine.observeHeat(.init(state: .serious), now: start + 35)
        let cooled = try #require(recovered)
        #expect(cooled.alertPhase == .resolved)
        #expect(cooled.thermalState == .serious)
        #expect(cooled.incidentId == first.incidentId)
        #expect(cooled.title == "Your Mac has been critically hot")
    }
}
