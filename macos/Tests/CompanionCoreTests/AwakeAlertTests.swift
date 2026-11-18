import Foundation
import Testing
@testable import CompanionCore

struct AwakeAlertTests {
    let start = Date(timeIntervalSince1970: 50_400)

    func sample(
        lidClosed: Bool, now: Date, idle: TimeInterval = 0, brewing: Bool = true,
        wake: MacAlertWakeState = .full, display: MacDisplayAvailability? = nil
    ) -> MacAwakeReading {
        .init(wake: wake, lidClosed: lidClosed, displayAvailability: display ?? (lidClosed ? .unavailable : .available), isBrewing: brewing,
              brew: brewing ? .init(startedAt: start, mode: .manual,
                                    endsAt: start + 86_400, returnsToAutomatic: true) : nil,
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

    @Test func lidAlertRequiresOneMinuteOfContinuousFullWake() throws {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: false, now: start), now: start)
        for elapsed in [1.0, 3, 10, 60] {
            #expect(machine.observeAwake(sample(lidClosed: true, now: start + elapsed), now: start + elapsed).isEmpty)
        }
        let event = try #require(machine.observeAwake(
            sample(lidClosed: true, now: start + 61), now: start + 61).first)
        #expect(event.alertPhase == .active)
    }

    @Test func lidSoundOccursAtObservedClosureBeforeThePhoneDelay() {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: false, now: start), now: start)
        let sound1 = machine.consumeLidClosureSound()
        #expect(!sound1)
        #expect(machine.observeAwake(sample(lidClosed: true, now: start + 1), now: start + 1).isEmpty)
        let sound2 = machine.consumeLidClosureSound()
        #expect(sound2)
        let sound3 = machine.consumeLidClosureSound()
        #expect(!sound3)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 61), now: start + 61)
        let sound4 = machine.consumeLidClosureSound()
        #expect(!sound4)
    }

    @Test func wakingAlreadyClosedNeverPlaysTheClosureSound() {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: true, now: start), now: start)
        let sound5 = machine.consumeLidClosureSound()
        #expect(!sound5)
        _ = machine.observeAwake(sample(lidClosed: false, now: start + 1), now: start + 1)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 2, wake: .dark), now: start + 2)
        let sound6 = machine.consumeLidClosureSound()
        #expect(!sound6)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 3), now: start + 3)
        let sound7 = machine.consumeLidClosureSound()
        #expect(!sound7)
        machine.resumedAfterUnknownInterval()
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 4), now: start + 4)
        let sound8 = machine.consumeLidClosureSound()
        #expect(!sound8)
    }

    @Test func shortClosedLidWakeNeverCreatesAnAlert() {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: false, now: start, brewing: false), now: start)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 1, brewing: false), now: start + 1)
        #expect(machine.observeAwake(sample(lidClosed: true, now: start + 9, brewing: false), now: start + 9).isEmpty)
        #expect(machine.observedSleep(now: start + 10) == nil)
    }

    @Test func brewingThatEndsDuringTheDelayIsRemembered() throws {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: false, now: start), now: start)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 1), now: start + 1)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 31, brewing: false), now: start + 31)
        let event = try #require(machine.observeAwake(
            sample(lidClosed: true, now: start + 61, brewing: false), now: start + 61).first)
        #expect(event.body == "Keepresso is no longer brewing.")
    }

    @Test func darkWakeBreaksTheClosedLidDelay() {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: true, now: start), now: start)
        #expect(machine.observeAwake(sample(lidClosed: true, now: start + 59, wake: .dark), now: start + 59).isEmpty)
        #expect(machine.observeAwake(sample(lidClosed: true, now: start + 60), now: start + 60).isEmpty)
        #expect(machine.observeAwake(sample(lidClosed: true, now: start + 119), now: start + 119).isEmpty)
        #expect(machine.observeAwake(sample(lidClosed: true, now: start + 120), now: start + 120).count == 1)
    }

    @Test func ongoingLidAlertUpdatesWhenBrewingEndsThenResolves() throws {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: false, now: start), now: start)
        #expect(machine.observeAwake(sample(lidClosed: true, now: start + 1), now: start + 1).isEmpty)
        let opened = machine.observeAwake(sample(lidClosed: true, now: start + 61), now: start + 61).first
        let first = try #require(opened)
        #expect(first.alertPhase == .active)
        #expect(first.title == "Your Mac is running with the lid closed")
        let updated = machine.observeAwake(
            sample(lidClosed: true, now: start + 62, brewing: false), now: start + 62).first
        let ended = try #require(updated)
        #expect(ended.incidentId == first.incidentId)
        #expect(ended.alertPhase == .updated)
        #expect(ended.body == "Keepresso is no longer brewing.")
        let resolved = machine.observeAwake(
            sample(lidClosed: false, now: start + 63, brewing: false), now: start + 63).first
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
        #expect(machine.observeAwake(sample(lidClosed: true, now: start + 3_661), now: start + 3_661)
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

    @Test func initiallyClosedWakeStartsAPhoneIncidentAndSleepResolvesIt() throws {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: true, now: start), now: start)
        let status = machine.observeAwake(sample(lidClosed: true, now: start + 60), now: start + 60).first
        let alert = try #require(status)
        #expect(alert.alertPhase == .active)
        let resolution = machine.observedSleep(now: start + 61)
        let removed = try #require(resolution)
        #expect(removed.alertPhase == .resolved)
        #expect(removed.incidentId == alert.incidentId)
    }


    @Test func screenOffSharesTheMinuteAndIncidentWithClosedLid() throws {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: false, now: start), now: start)
        _ = machine.observeAwake(sample(lidClosed: false, now: start + 1, display: .unavailable), now: start + 1)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 30), now: start + 30)
        #expect(machine.observeAwake(sample(lidClosed: true, now: start + 60), now: start + 60).isEmpty)
        let first = try #require(machine.observeAwake(sample(lidClosed: true, now: start + 61), now: start + 61).first)
        #expect(first.awakeContext == .lidClosed)
        let changed = try #require(machine.observeAwake(sample(lidClosed: false, now: start + 62, display: .unavailable), now: start + 62).first)
        #expect(changed.incidentId == first.incidentId)
        #expect(changed.awakeContext == .screenOff)
        #expect(changed.title == "Your Mac is running with the screen off")
        #expect(changed.alertPhase == .updated)
        #expect(machine.observeAwake(sample(lidClosed: false, now: start + 151, display: .unavailable), now: start + 151).isEmpty)
        let refreshed = try #require(machine.observeAwake(sample(lidClosed: false, now: start + 152, display: .unavailable), now: start + 152).first)
        #expect(refreshed.incidentId == first.incidentId)
        let resolved = try #require(machine.observeAwake(sample(lidClosed: true, now: start + 153, display: .available), now: start + 153).first)
        #expect(resolved.alertPhase == .resolved)
        #expect(resolved.incidentId == first.incidentId)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 154), now: start + 154)
        let next = try #require(machine.observeAwake(sample(lidClosed: true, now: start + 214), now: start + 214).first)
        #expect(next.incidentId != first.incidentId)
    }

    @Test func glassIgnoresExternalMonitorStandbyAndNeedsAPhysicalClosure() {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: false, now: start, brewing: false), now: start)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 1, brewing: false, display: .available), now: start + 1)
        let dockingSound = machine.consumeLidClosureSound()
        #expect(!dockingSound)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 2, brewing: false), now: start + 2)
        let standbySound = machine.consumeLidClosureSound()
        #expect(!standbySound)
        _ = machine.observeAwake(sample(lidClosed: false, now: start + 3, brewing: false, display: .unavailable), now: start + 3)
        let openStandbySound = machine.consumeLidClosureSound()
        #expect(!openStandbySound)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 4, brewing: false), now: start + 4)
        let closureSound = machine.consumeLidClosureSound()
        #expect(closureSound)
    }

    @Test func unknownDisplayBreaksConfirmationButDoesNotInventResolution() throws {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: false, now: start, display: .unavailable), now: start)
        _ = machine.observeAwake(sample(lidClosed: false, now: start + 59, display: .unknown), now: start + 59)
        _ = machine.observeAwake(sample(lidClosed: false, now: start + 60, display: .unavailable), now: start + 60)
        #expect(machine.observeAwake(sample(lidClosed: false, now: start + 119, display: .unavailable), now: start + 119).isEmpty)
        let first = try #require(machine.observeAwake(sample(lidClosed: false, now: start + 120, display: .unavailable), now: start + 120).first)
        #expect(machine.observeAwake(sample(lidClosed: false, now: start + 121, display: .unknown), now: start + 121).isEmpty)
        let resolved = try #require(machine.observeAwake(sample(lidClosed: false, now: start + 122), now: start + 122).first)
        #expect(resolved.alertPhase == .resolved)
        #expect(resolved.incidentId == first.incidentId)
    }

    @Test func normalDesktopPreservesTheHourReminder() throws {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: false, now: start), now: start)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 2_400, idle: 2_400, display: .available), now: start + 2_400)
        let events = machine.observeAwake(sample(lidClosed: true, now: start + 3_600, idle: 3_600, display: .available), now: start + 3_600)
        #expect(events.count == 1)
        #expect(events.first?.kind == "unattended_brew")
    }

    @Test func nonVisibleTimeCountsButNeverRearmsAnAlreadySentHour() {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: false, now: start), now: start)
        _ = machine.observeAwake(sample(lidClosed: false, now: start + 2_400, idle: 2_400, display: .unavailable), now: start + 2_400)
        _ = machine.observeAwake(sample(lidClosed: false, now: start + 2_460, idle: 2_460, display: .unavailable), now: start + 2_460)
        let hour = machine.observeAwake(sample(lidClosed: false, now: start + 3_600, idle: 3_600), now: start + 3_600)
        #expect(hour.filter { $0.kind == "unattended_brew" }.count == 1)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 3_601, idle: 3_601), now: start + 3_601)
        let later = machine.observeAwake(sample(lidClosed: false, now: start + 7_200, idle: 7_200), now: start + 7_200)
        #expect(!later.contains { $0.kind == "unattended_brew" })
        _ = machine.observedSleep(now: start + 8_000)
        _ = machine.observeAwake(sample(lidClosed: false, now: start + 11_600, idle: 11_600), now: start + 11_600)
        #expect(machine.observeAwake(sample(lidClosed: false, now: start + 15_200, idle: 15_200), now: start + 15_200).isEmpty)
    }

    @Test func restartNeverRestoresAnUnconsumedSoundCue() throws {
        var machine = ReminderMachine()
        _ = machine.observeAwake(sample(lidClosed: false, now: start), now: start)
        _ = machine.observeAwake(sample(lidClosed: true, now: start + 1), now: start + 1)
        machine = try WireJSON.decoder.decode(ReminderMachine.self, from: WireJSON.encoder.encode(machine))
        machine.resumedAfterUnknownInterval()
        let sound = machine.consumeLidClosureSound()
        #expect(!sound)
    }

    @Test func criticalUpdatesAndRecoveryShareOneIncident() throws {
        var machine = ReminderMachine()
        let critical = MacThermalReading(state: .critical, brewingPaused: true)
        let onset = machine.observeHeat(critical, exposure: .init(lidClosed: true, isBrewing: true), now: start)
        let first = try #require(onset)
        #expect(first.alertPhase == .active)
        #expect(machine.observeHeat(critical, exposure: .init(lidClosed: true, isBrewing: true), now: start + 29) == nil)
        let saved = try WireJSON.encoder.encode(machine)
        machine = try WireJSON.decoder.decode(ReminderMachine.self, from: saved)
        machine.resumedAfterUnknownInterval()
        let fresh = machine.observeHeat(critical, exposure: .init(lidClosed: true, isBrewing: true), now: start + 30)
        let heartbeat = try #require(fresh)
        #expect(heartbeat.alertPhase == .updated)
        #expect(heartbeat.incidentId == first.incidentId)
        #expect(machine.observeHeat(.init(state: .unknown), exposure: .init(lidClosed: true, isBrewing: true), now: start + 31) == nil)
        let recovered = machine.observeHeat(.init(state: .serious), exposure: .init(lidClosed: true, isBrewing: true), now: start + 35)
        let cooled = try #require(recovered)
        #expect(cooled.alertPhase == .resolved)
        #expect(cooled.thermalState == .serious)
        #expect(cooled.incidentId == first.incidentId)
        #expect(cooled.title == "Your Mac has been critically hot")
    }
}
