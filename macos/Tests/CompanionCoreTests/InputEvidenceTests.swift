import Testing
@testable import CompanionCore
struct InputEvidenceTests {
    @Test func collapsedMonitorFailureCannotBecomeAnInactiveRule(){
        // Core's HAL/download/async readers can collapse a failed input to false.
        // Until a complete error-bearing input adapter exists, negatives are unknown.
        XCTAssertNil(AssessmentEvidence.positiveOnly(false))
        XCTAssertEqual(AssessmentEvidence.positiveOnly(true),true)
    }
}
