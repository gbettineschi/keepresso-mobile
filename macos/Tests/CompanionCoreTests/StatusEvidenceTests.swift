import Foundation
import Testing
@testable import CompanionCore
struct StatusEvidenceTests {
    @Test func absentLockFlagMeansUnlockedOnlyInCurrentConsoleSession() {
        let current: [String: Any] = [
            "kCGSSessionUserIDKey": NSNumber(value: 501),
            "kCGSSessionOnConsoleKey": true,
            "kCGSessionLoginDoneKey": true,
        ]
        #expect(StatusEvidence.consoleLock(in: current, userID: 501) == false)
        #expect(StatusEvidence.consoleLock(in: current.merging(["CGSSessionScreenIsLocked": true]) { _, new in new }, userID: 501) == true)
        #expect(StatusEvidence.consoleLock(in: current, userID: 502) == nil)
        var background = current
        background["kCGSSessionOnConsoleKey"] = false
        #expect(StatusEvidence.consoleLock(in: background, userID: 501) == nil)
        var loginWindow = current
        loginWindow["kCGSessionLoginDoneKey"] = false
        #expect(StatusEvidence.consoleLock(in: loginWindow, userID: 501) == nil)
        #expect(StatusEvidence.consoleLock(in: ["kCGSessionLoginDoneKey": true], userID: 501) == nil)
        #expect(StatusEvidence.consoleLock(in: nil, userID: 501) == nil)
    }
    @Test func replacementNativeLaunchCannotAcknowledgeAnEarlierCommand() {
        let launch=Date(timeIntervalSince1970:1000)
        XCTAssertTrue(StatusEvidence.sameLaunch(pid:42,launchDate:launch,currentPID:42,currentLaunchDate:launch))
        XCTAssertFalse(StatusEvidence.sameLaunch(pid:42,launchDate:launch,currentPID:42,currentLaunchDate:launch.addingTimeInterval(1)))
        XCTAssertFalse(StatusEvidence.sameLaunch(pid:42,launchDate:launch,currentPID:43,currentLaunchDate:launch))
        XCTAssertFalse(StatusEvidence.sameLaunch(pid:42,launchDate:launch,currentPID:nil,currentLaunchDate:nil))
        XCTAssertFalse(StatusEvidence.sameLaunch(pid:42,launchDate:nil,currentPID:42,currentLaunchDate:nil))
    }
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
