import Foundation
import Testing
import KeepressoCore
@testable import CompanionCore

struct ManualTriggerHistoryTests {
    private let first=Date(timeIntervalSince1970:100)
    private func assessment(state:String="ready",time:Date?=nil,satisfied:Bool?=true)->TriggerPreview {
        var result=TriggerPreview();result.state=state;result.checkedAt=time ?? first;result.combined=satisfied
        result.rules=[.init(id:"0",label:"Microphone",satisfied:satisfied,inGrace:true,graceRemaining:12,details:[])]
        return result
    }
    private func canonical(_ json:String)throws->Data {
        try WireJSON.encoder.encode(CompanionObserverSettings.decode(Data(json.utf8)).ruleSet)
    }
    @Test func ordinaryPollsAndUnrelatedSettingsPreserveTheCompletedResult()throws {
        let a=try canonical(#"{"triggersEnabled":true,"ruleSet":{"combine":"any","rules":[]},"theme":"light"}"#)
        let b=try canonical(#"{"theme":"dark","ruleSet":{"rules":[],"combine":"any"},"triggersEnabled":false}"#)
        var history=ManualTriggerHistory();history.configure(ruleSet:a,rules:[])
        history.complete(assessment())
        for _ in 0..<50 { history.configure(ruleSet:b,rules:[]) }
        XCTAssertEqual(history.preview.checkedAt,first);XCTAssertEqual(history.preview.combined,true)
        XCTAssertEqual(history.preview.rules.first?.satisfied,true);XCTAssertEqual(history.preview.rules.first?.graceRemaining,12)
        XCTAssertEqual(history.preview.state,"ready");XCTAssertEqual(history.preview.outdated,false)
    }
    @Test func changedRulesAndLifecycleOnlyFlagTheHistoricalAssessment()throws {
        var history=ManualTriggerHistory();history.configure(ruleSet:Data("any".utf8),rules:[])
        history.complete(assessment());history.configure(ruleSet:Data("all".utf8),rules:[])
        XCTAssertEqual(history.preview.outdated,true)
        history.invalidate()
        XCTAssertEqual(history.preview.checkedAt,first);XCTAssertEqual(history.preview.state,"ready")
        XCTAssertEqual(history.preview.combined,true);XCTAssertEqual(history.preview.rules.first?.inGrace,true)
    }
    @Test func progressFailureAndCancellationPreserveAssessmentAndLaterSuccessClearsError() {
        var history=ManualTriggerHistory();history.complete(assessment())
        history.begin();XCTAssertEqual(history.preview.checking,true)
        XCTAssertEqual(history.preview.checkedAt,first);XCTAssertEqual(history.preview.state,"ready")
        history.fail("Couldn't check triggers. Try again.")
        XCTAssertEqual(history.preview.checking,false);XCTAssertNotNil(history.preview.checkError)
        XCTAssertEqual(history.preview.combined,true);XCTAssertEqual(history.preview.checkedAt,first)
        history.begin();history.cancel()
        XCTAssertEqual(history.preview.checking,false);XCTAssertEqual(history.preview.rules.first?.satisfied,true)
        history.begin();history.complete(assessment(state:"unknown",time:Date(timeIntervalSince1970:200),satisfied:nil))
        XCTAssertEqual(history.preview.checkedAt,Date(timeIntervalSince1970:200));XCTAssertEqual(history.preview.state,"unknown")
        XCTAssertNil(history.preview.combined);XCTAssertNil(history.preview.rules.first?.satisfied)
        XCTAssertNil(history.preview.checkError);XCTAssertEqual(history.preview.outdated,false)
    }
    @Test func successfulEmptyAndPartialAssessmentsReplaceExactlyButMalformedResultsDoNot() {
        var history=ManualTriggerHistory();history.complete(assessment())
        var empty=TriggerPreview();empty.state="ready";empty.checkedAt=Date(timeIntervalSince1970:200);empty.combined=false
        history.complete(empty)
        XCTAssertTrue(history.preview.rules.isEmpty);XCTAssertEqual(history.preview.checkedAt,empty.checkedAt)
        history.complete(assessment(state:"unknown",time:Date(timeIntervalSince1970:300),satisfied:nil))
        var failure=TriggerPreview();failure.state="error"
        history.complete(failure)
        XCTAssertEqual(history.preview.checkedAt,Date(timeIntervalSince1970:300));XCTAssertEqual(history.preview.state,"unknown")
        XCTAssertEqual(history.preview.rules.count,1);XCTAssertNotNil(history.preview.checkError)
    }
    @Test func initialConfigurationSeedsUnknownRowsWithoutClaimingACheck() {
        var history=ManualTriggerHistory();history.configure(ruleSet:Data(),rules:assessment(satisfied:nil).rules)
        XCTAssertEqual(history.preview.rules.count,1);XCTAssertNil(history.preview.checkedAt)
        history.begin();history.fail("Unavailable")
        XCTAssertEqual(history.preview.state,"not_checked");XCTAssertNil(history.preview.checkedAt)
        XCTAssertEqual(history.preview.checkError,"Unavailable")
    }
    @Test func optionalMetadataDecodesOldPayloadsAndRoundTripsNewPayloads()throws {
        let old=try WireJSON.decoder.decode(TriggerPreview.self,from:Data(#"{"state":"ready","rules":[]}"#.utf8))
        XCTAssertNil(old.checking);XCTAssertNil(old.outdated);XCTAssertNil(old.checkError)
        var history=ManualTriggerHistory();history.complete(assessment());history.invalidate();history.begin();history.fail("Unavailable")
        let decoded=try WireJSON.decoder.decode(TriggerPreview.self,from:WireJSON.encoder.encode(history.preview))
        XCTAssertEqual(decoded.checking,false);XCTAssertEqual(decoded.outdated,true);XCTAssertEqual(decoded.checkError,"Unavailable")
        XCTAssertEqual(decoded.combined,true)
    }
}
