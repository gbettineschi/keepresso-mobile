import Foundation
import Testing
@testable import CompanionCore
struct StatusEvidenceTests {
    @Test func sameSecondNativeWriteUsesPreciseModificationTimeAndRejectsOldFile(){
        let issued=Date(timeIntervalSince1970:1000.81)
        XCTAssertTrue(StatusEvidence.acknowledges(writtenAt:Date(timeIntervalSince1970:1000),modifiedAt:Date(timeIntervalSince1970:1000.85),issuedAt:issued))
        XCTAssertFalse(StatusEvidence.acknowledges(writtenAt:Date(timeIntervalSince1970:1000),modifiedAt:Date(timeIntervalSince1970:1000.1),issuedAt:issued))
    }
    @Test func staleReusedPIDCannotIdentifyCurrentLaunch(){
        XCTAssertFalse(StatusEvidence.belongsToCurrentLaunch(writtenAt:Date(timeIntervalSince1970:1000),launchDate:Date(timeIntervalSince1970:2000.8),now:Date(timeIntervalSince1970:2100)))
        XCTAssertTrue(StatusEvidence.belongsToCurrentLaunch(writtenAt:Date(timeIntervalSince1970:2000),launchDate:Date(timeIntervalSince1970:2000.8),now:Date(timeIntervalSince1970:5000)))
    }
}
extension StatusEvidenceTests {
    @Test func exitedAppIsKnownInactiveButRunningUnreadableSourceStaysUnknown(){
        XCTAssertEqual(StatusEvidence.brewingActivity(appRunning:false,nativeActive:nil),false)
        XCTAssertNil(StatusEvidence.brewingActivity(appRunning:true,nativeActive:nil))
        XCTAssertEqual(StatusEvidence.brewingActivity(appRunning:true,nativeActive:true),true)
    }
}
