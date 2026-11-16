import Foundation
import Testing
@testable import CompanionCore

@MainActor struct SafeSleepTests {
    @Test func onlyRequestsSleepOnceAfterNativeHoldAndOverrideAreReleased()async{
        var stopped=false,override=true;var stops=0,sleeps=0
        let result=await SafeSleep.perform(id:"fixture",authorized:{true},state:{SleepPreparationState(stopped:stopped,sleepDisabled:override)},stop:{stops+=1;stopped=true},requestSleep:{sleeps+=1;return .willSleep},wait:{override=false})
        XCTAssertEqual(result.status,"ok");XCTAssertEqual(stops,1);XCTAssertEqual(sleeps,1)
        #expect(result.sleepOutcome == .goingToSleep)
        #expect(result.message == "Going to sleep")
    }
    @Test func unknownInitialStateCannotIssueAnyPowerAction()async{
        var effects=0
        let result=await SafeSleep.perform(id:"fixture",authorized:{true},state:{SleepPreparationState(stopped:nil,sleepDisabled:nil)},stop:{effects+=1},requestSleep:{effects+=1;return .willSleep},wait:{})
        XCTAssertEqual(result.status,"error");XCTAssertEqual(effects,0)
        #expect(result.sleepOutcome == .couldNotRequestSleep)
    }
    @Test func manualGlobalOverrideDoesNotGetSilentlyChangedOrBypassed()async{
        var stops=0,sleeps=0
        let result=await SafeSleep.perform(id:"fixture",authorized:{true},state:{SleepPreparationState(stopped:true,sleepDisabled:true)},stop:{stops+=1},requestSleep:{sleeps+=1;return .willSleep},wait:{})
        XCTAssertEqual(result.status,"error");XCTAssertEqual(stops,0);XCTAssertEqual(sleeps,0)
        #expect(result.sleepOutcome == .couldNotRequestSleep)
    }
    @Test func revocationOrNativeLifecycleChangeDuringPreparationPreventsSleep()async{
        var allowed=true,sleeps=0
        let result=await SafeSleep.perform(id:"fixture",authorized:{allowed},state:{SleepPreparationState(stopped:false,sleepDisabled:true)},stop:{},requestSleep:{sleeps+=1;return .willSleep},wait:{allowed=false})
        XCTAssertEqual(result.status,"uncertain");XCTAssertEqual(sleeps,0)
        #expect(result.sleepOutcome == .couldNotRequestSleep)
    }
    @Test func systemRejectionIsNeverReportedAsCompletedSleep()async{
        let result=await SafeSleep.perform(id:"fixture",authorized:{true},state:{SleepPreparationState(stopped:true,sleepDisabled:false)},stop:{},requestSleep:{.rejected},wait:{})
        #expect(result.status == "error")
        #expect(result.sleepOutcome == .couldNotRequestSleep)
        #expect(result.message == "Couldn’t request sleep")
    }
    @Test func revocationDuringInitialReadPreventsEvenTheStopRequest()async{
        var allowed=true,effects=0
        _=await SafeSleep.perform(id:"fixture",authorized:{allowed},state:{allowed=false;return SleepPreparationState(stopped:true,sleepDisabled:false)},stop:{effects+=1},requestSleep:{effects+=1;return .willSleep},wait:{})
        XCTAssertEqual(effects,0)
    }
    @Test func acceptanceWithoutPowerEvidenceIsNeverGoingToSleep() async {
        let result = await SafeSleep.perform(id: "fixture", authorized: { true },
            state: { SleepPreparationState(stopped: true, sleepDisabled: false) },
            stop: {}, requestSleep: { .unconfirmed })
        #expect(result.status == "uncertain")
        #expect(result.sleepOutcome == .couldNotRequestSleep)
    }

    @Test func verifiedFullWakeAfterAcceptanceReportsCouldNotSleep() async {
        let result = await SafeSleep.perform(id: "fixture", authorized: { true },
            state: { SleepPreparationState(stopped: true, sleepDisabled: false) },
            stop: {}, requestSleep: { .stillAwake })
        #expect(result.status == "error")
        #expect(result.sleepOutcome == .couldNotSleep)
        #expect(result.message == "Couldn’t sleep")
    }
    @Test func releasingTheClosedLidHoldCanStartSleepBeforeAnySystemRequest() async {
        var connected = true
        var willSleep = false
        var stops = 0
        var systemRequests = 0

        let result = await SafeSleep.perform(
            id: "fixture", authorized: { connected },
            state: { SleepPreparationState(stopped: false, sleepDisabled: true) },
            stop: {
                stops += 1
                willSleep = true
                connected = false
            },
            observedWillSleep: { willSleep },
            requestSleep: { systemRequests += 1; return .willSleep }
        )

        #expect(result.sleepOutcome == .goingToSleep)
        #expect(stops == 1)
        #expect(systemRequests == 0)
    }

    @Test func sleepObservedDuringPreparationWinsOverLostReadAndAuthorization() async {
        var connected = true
        var willSleep = false
        var stopped = false
        var systemRequests = 0

        let result = await SafeSleep.perform(
            id: "fixture", authorized: { connected },
            state: {
                if stopped {
                    willSleep = true
                    connected = false
                    return nil
                }
                return SleepPreparationState(stopped: false, sleepDisabled: true)
            },
            stop: { stopped = true },
            observedWillSleep: { willSleep },
            requestSleep: { systemRequests += 1; return .willSleep }
        )

        #expect(result.sleepOutcome == .goingToSleep)
        #expect(systemRequests == 0)
    }

    @Test func existingSleepEvidenceCannotBypassAConfirmedBlockedRequest() async {
        var effects = 0
        let result = await SafeSleep.perform(
            id: "fixture", authorized: { true },
            state: { SleepPreparationState(stopped: true, sleepDisabled: true) },
            stop: { effects += 1 },
            observedWillSleep: { true },
            requestSleep: { effects += 1; return .willSleep }
        )
        #expect(result.sleepOutcome == .couldNotRequestSleep)
        #expect(effects == 0)
    }
}
