import Testing
@testable import CompanionCore

struct MacDisplayAvailabilityTests {
    let builtInAwake = MacDisplaySample(isBuiltIn: true, isAsleep: false)
    let externalAwake = MacDisplaySample(isBuiltIn: false, isAsleep: false)
    let externalAsleep = MacDisplaySample(isBuiltIn: false, isAsleep: true)

    @Test func closedBuiltInCannotSupplyUsableScreen() {
        #expect(MacDisplayAvailability.assess(lidClosed: true, displays: [builtInAwake]) == .unavailable)
    }
    @Test func oneAwakeExternalSufficesEvenWithOtherUnknownOrSleepingScreens() {
        #expect(MacDisplayAvailability.assess(lidClosed: true, displays: [builtInAwake, externalAsleep, externalAwake, .init(isBuiltIn: false, isAsleep: nil)]) == .available)
    }
    @Test func sleepingExternalDoesNotMakeTheClosedPanelUsable() {
        #expect(MacDisplayAvailability.assess(lidClosed: true, displays: [builtInAwake, externalAsleep]) == .unavailable)
    }
    @Test func openPanelCanSupplyUsableScreenAndAllAsleepMeansUnavailable() {
        #expect(MacDisplayAvailability.assess(lidClosed: false, displays: [builtInAwake, externalAsleep]) == .available)
        #expect(MacDisplayAvailability.assess(lidClosed: false, displays: [.init(isBuiltIn: true, isAsleep: true), externalAsleep]) == .unavailable)
    }
    @Test func missingTopologyAndUncertainSleepAreNotEvidenceOfAllOff() {
        #expect(MacDisplayAvailability.assess(lidClosed: true, displays: nil) == .unknown)
        #expect(MacDisplayAvailability.assess(lidClosed: false, displays: []) == .unknown)
        #expect(MacDisplayAvailability.assess(lidClosed: nil, displays: []) == .unknown)
        #expect(MacDisplayAvailability.assess(lidClosed: false, displays: [.init(isBuiltIn: false, isAsleep: nil)]) == .unknown)
        #expect(MacDisplayAvailability.assess(lidClosed: true, displays: []) == .unavailable)
    }
    @Test func unknownLidCannotMakeBuiltInPanelVisibleButExternalStillCan() {
        #expect(MacDisplayAvailability.assess(lidClosed: nil, displays: [builtInAwake]) == .unknown)
        #expect(MacDisplayAvailability.assess(lidClosed: nil, displays: [builtInAwake, externalAwake]) == .available)
    }
    @Test func injectedOnlineSourceIncludesSleepingAndMirroredScreens() {
        let reader = MacDisplayAvailabilityReader(readOnlineDisplays: { [.init(isBuiltIn: false, isAsleep: true)] })
        #expect(reader.read(lidClosed: false) == .unavailable)
        #expect(MacDisplayAvailabilityReader(readOnlineDisplays: { nil }).read(lidClosed: true) == .unknown)
    }
}
