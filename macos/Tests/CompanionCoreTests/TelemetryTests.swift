import Foundation
import Testing
import KeepressoCore
@testable import CompanionCore

struct TelemetryTests {
    @Test func nativeThermalObservationRequiresMatchingFreshActiveEvidence() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let data = Data(#"{"thermalState":"fair","thermalGuardActive":true,"thermalBrewingPaused":true}"#.utf8)
        let native = try WireJSON.decoder.decode(NativeThermalReport.self, from: data)
        let fresh = MacThermalReading(system: .fair, report: native, writtenAt: now.addingTimeInterval(-5), now: now)
        #expect(fresh.state == .fair)
        #expect(fresh.guardActive == true)
        #expect(fresh.brewingPaused == true)
        let stale = MacThermalReading(system: .fair, report: native, writtenAt: now.addingTimeInterval(-16), now: now)
        #expect(stale.guardActive == nil)
        #expect(stale.brewingPaused == nil)
        let mismatched = MacThermalReading(system: .critical, report: native, writtenAt: now, now: now)
        #expect(mismatched.state == .critical)
        #expect(mismatched.guardActive == nil)
        #expect(mismatched.brewingPaused == nil)
    }

    @Test func olderNativeReportLeavesGuardUnknown() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let legacy = try WireJSON.decoder.decode(NativeThermalReport.self, from: Data(#"{"isActive":true}"#.utf8))
        let reading = MacThermalReading(system: .serious, report: legacy, writtenAt: now, now: now)
        #expect(reading.state == .serious)
        #expect(reading.guardActive == nil)
    }

    @Test func observerBudgetAllowsStartupMarginWhileRemainingBounded()async throws{
        let data=try await BoundedWorker.run(executable:URL(fileURLWithPath:"/usr/bin/printf"),arguments:["ready"],timeout:12)
        XCTAssertEqual(String(data:data,encoding:.utf8),"ready")
    }
    @Test func failedRefreshKeepsTheCompletedAssessmentQualityAndVerdict(){
        var old=TriggerPreview();old.state="ready";old.checkedAt=Date(timeIntervalSince1970:100);old.combined=true
        old.rules=[.init(id:"0",label:"Agent working",satisfied:true,inGrace:false,graceRemaining:nil,details:[])]
        var failed=TriggerPreview();failed.state="error"
        failed.retainPriorAssessment(old)
        XCTAssertEqual(failed.state,"ready");XCTAssertEqual(failed.checkedAt,Date(timeIntervalSince1970:100))
        XCTAssertEqual(failed.rules.first?.label,"Agent working");XCTAssertEqual(failed.combined,true)
    }
}

extension TelemetryTests {
    @Test func successfulEmptyAssessmentReplacesPreviousRows() {
        var old=TriggerPreview();old.state="ready";old.checkedAt=Date(timeIntervalSince1970:100)
        old.rules=[.init(id:"0",label:"Agent working",satisfied:true,inGrace:false,graceRemaining:nil,details:[])]
        var empty=TriggerPreview();empty.state="ready";empty.checkedAt=Date(timeIntervalSince1970:200);empty.combined=false
        empty.retainPriorAssessment(old)
        XCTAssertTrue(empty.rules.isEmpty)
        XCTAssertEqual(empty.checkedAt,Date(timeIntervalSince1970:200))
        XCTAssertEqual(empty.combined,false)
    }
}
