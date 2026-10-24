import Testing
@testable import CompanionCore
struct BackgroundEvidenceTests {
    @Test func onlyAnExplicitSigningFailureRequestsOwnerRegistrationRefresh(){
        #expect(BackgroundLaunchEvidence.requiresRefresh("job = {\n state = spawn scheduled\n last exit reason = OS_REASON_CODESIGNING\n}"))
        #expect(!BackgroundLaunchEvidence.requiresRefresh("job = {\n state = running\n last exit code = 0\n}"))
        #expect(!BackgroundLaunchEvidence.requiresRefresh("launchctl unavailable"))
    }
}
