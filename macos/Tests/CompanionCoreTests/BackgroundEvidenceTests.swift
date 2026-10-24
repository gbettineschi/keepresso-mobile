import Testing
@testable import CompanionCore
struct BackgroundEvidenceTests {
    @Test func onlyAnExplicitSigningFailureRequestsOwnerRegistrationRefresh(){
        #expect(BackgroundLaunchEvidence.requiresRefresh("job = {\n state = spawn scheduled\n last exit reason = OS_REASON_CODESIGNING\n}"))
        #expect(!BackgroundLaunchEvidence.requiresRefresh("job = {\n state = running\n last exit code = 0\n}"))
        #expect(!BackgroundLaunchEvidence.requiresRefresh("launchctl unavailable"))
    }
    @Test func olderRegisteredBuildWithConfigFailureOffersOwnerRefresh(){
        let stale="parent bundle version = 3\nstate = spawn scheduled\nlast exit code = 78: EX_CONFIG\njob state = spawn failed"
        #expect(BackgroundLaunchEvidence.requiresRefresh(stale,currentBuild:"5"))
        #expect(!BackgroundLaunchEvidence.requiresRefresh(stale,currentBuild:"3"))
        #expect(!BackgroundLaunchEvidence.requiresRefresh(stale.replacingOccurrences(of:"spawn failed",with:"running"),currentBuild:"5"))
        #expect(!BackgroundLaunchEvidence.requiresRefresh(stale.replacingOccurrences(of:"78: EX_CONFIG",with:"1"),currentBuild:"5"))
    }
}
