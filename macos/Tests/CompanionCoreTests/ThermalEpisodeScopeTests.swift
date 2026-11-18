import Foundation
import Testing
@testable import CompanionCore

struct ThermalEpisodeScopeTests {
    let t = Date(timeIntervalSince1970: 50_400)
    let outside = MacThermalAlertExposure(lidClosed: false, isBrewing: false)
    let brewing = MacThermalAlertExposure(lidClosed: false, isBrewing: true)

    @Test func onsetRequiresClosedLidBrewingOrATrustedThermalPause() {
        for exposure in [outside, .init(lidClosed: nil, isBrewing: nil)] {
            var machine = ReminderMachine()
            #expect(machine.observeHeat(.init(state: .critical), exposure: exposure, now: t) == nil)
        }
        for exposure in [brewing, .init(lidClosed: true, isBrewing: false)] {
            var machine = ReminderMachine()
            #expect(machine.observeHeat(.init(state: .critical), exposure: exposure, now: t)?.alertPhase == .active)
        }
        var machine = ReminderMachine()
        #expect(machine.observeHeat(.init(state: .critical, brewingPaused: true), exposure: outside, now: t)?.alertPhase == .active)
    }

    @Test func stoppingBrewingAndOpeningLidCannotEndAPersistedCriticalEpisode() throws {
        var machine = ReminderMachine()
        let onset = machine.observeHeat(.init(state: .critical), exposure: brewing, now: t)
        let first = try #require(onset)
        machine = try WireJSON.decoder.decode(ReminderMachine.self, from: WireJSON.encoder.encode(machine))
        machine.resumedAfterUnknownInterval()
        let update = machine.observeHeat(.init(state: .critical), exposure: outside, now: t + 30)
        let continued = try #require(update)
        #expect(continued.incidentId == first.incidentId)
        #expect(continued.alertPhase == .updated)
        #expect(machine.observeHeat(.init(state: .unknown), exposure: outside, now: t + 31) == nil)
        let cooling = machine.observeHeat(.init(state: .serious), exposure: outside, now: t + 32)
        let recovered = try #require(cooling)
        #expect(recovered.incidentId == first.incidentId)
        #expect(recovered.alertPhase == .resolved)
        #expect(recovered.thermalState == .serious)
        #expect(machine.observeHeat(.init(state: .critical), exposure: outside, now: t + 33) == nil)
    }

    @Test func nativeGuardScopeIsAnOnsetGateAndFiveMinuteThrottleSurvivesFlapping() throws {
        var machine = ReminderMachine()
        let guardActive = MacThermalReading(state: .serious, guardActive: true)
        #expect(machine.observeHeat(guardActive, exposure: outside, now: t) == nil)
        #expect(machine.observeHeat(guardActive, exposure: brewing, now: t + 1)?.thermalSeverity == .serious)
        #expect(machine.observeHeat(guardActive, exposure: outside, now: t + 300) == nil)
        #expect(machine.observeHeat(guardActive, exposure: outside, now: t + 301)?.thermalSeverity == .serious)
        _ = machine.observeHeat(.init(state: .nominal, guardActive: false), exposure: outside, now: t + 302)
        #expect(machine.observeHeat(guardActive, exposure: outside, now: t + 303) == nil)
    }

    @Test func stalePauseEvidenceCannotArmANewOutsideScopeEpisode() throws {
        let report = try WireJSON.decoder.decode(NativeThermalReport.self, from: Data(#"{"thermalState":"critical","thermalBrewingPaused":true}"#.utf8))
        let stale = MacThermalReading(system: .critical, report: report, writtenAt: t - 16, now: t)
        var machine = ReminderMachine()
        #expect(machine.observeHeat(stale, exposure: outside, now: t) == nil)
    }
}
