import Foundation
import Testing
@testable import CompanionCore

@MainActor struct SafeSleepTests {
    @Test func onlyRequestsSleepOnceAfterNativeHoldAndOverrideAreReleased()async{
        var stopped=false,override=true;var stops=0,sleeps=0
        let result=await SafeSleep.perform(id:"fixture",authorized:{true},state:{SleepPreparationState(stopped:stopped,sleepDisabled:override)},stop:{stops+=1;stopped=true},requestSleep:{sleeps+=1;return true},wait:{override=false})
        XCTAssertEqual(result.status,"ok");XCTAssertEqual(stops,1);XCTAssertEqual(sleeps,1)
    }
    @Test func unknownInitialStateCannotIssueAnyPowerAction()async{
        var effects=0
        let result=await SafeSleep.perform(id:"fixture",authorized:{true},state:{SleepPreparationState(stopped:nil,sleepDisabled:nil)},stop:{effects+=1},requestSleep:{effects+=1;return true},wait:{})
        XCTAssertEqual(result.status,"error");XCTAssertEqual(effects,0)
    }
    @Test func manualGlobalOverrideDoesNotGetSilentlyChangedOrBypassed()async{
        var stops=0,sleeps=0
        let result=await SafeSleep.perform(id:"fixture",authorized:{true},state:{SleepPreparationState(stopped:true,sleepDisabled:true)},stop:{stops+=1},requestSleep:{sleeps+=1;return true},wait:{})
        XCTAssertEqual(result.status,"error");XCTAssertEqual(stops,1);XCTAssertEqual(sleeps,0)
    }
    @Test func revocationOrNativeLifecycleChangeDuringPreparationPreventsSleep()async{
        var allowed=true,sleeps=0
        let result=await SafeSleep.perform(id:"fixture",authorized:{allowed},state:{SleepPreparationState(stopped:true,sleepDisabled:true)},stop:{},requestSleep:{sleeps+=1;return true},wait:{allowed=false})
        XCTAssertEqual(result.status,"uncertain");XCTAssertEqual(sleeps,0)
    }
    @Test func systemRejectionIsNeverReportedAsCompletedSleep()async{
        let result=await SafeSleep.perform(id:"fixture",authorized:{true},state:{SleepPreparationState(stopped:true,sleepDisabled:false)},stop:{},requestSleep:{false},wait:{})
        XCTAssertEqual(result.status,"error")
    }
    @Test func revocationDuringInitialReadPreventsEvenTheStopRequest()async{
        var allowed=true,effects=0
        _=await SafeSleep.perform(id:"fixture",authorized:{allowed},state:{allowed=false;return SleepPreparationState(stopped:true,sleepDisabled:false)},stop:{effects+=1},requestSleep:{effects+=1;return true},wait:{})
        XCTAssertEqual(effects,0)
    }
}
