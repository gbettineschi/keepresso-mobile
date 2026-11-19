import Foundation
import Testing
@testable import CompanionCore

/// Public certificate fixtures only. Their generated test private keys were discarded.
enum PrivacyCertificateFixtures {
    static let a = Data(base64Encoded: "MIICbzCCAhWgAwIBAgIJAKlqqR/+C2DyMAoGCCqGSM49BAMCMCYxJDAiBgNVBAMMG0tlZXByZXNzbyBUZXN0IEZpeHR1cmUgT25seTAeFw0yNjExMTkxMTMxNTNaFw0zNjExMTYxMTMxNTNaMCYxJDAiBgNVBAMMG0tlZXByZXNzbyBUZXN0IEZpeHR1cmUgT25seTCCAUswggEDBgcqhkjOPQIBMIH3AgEBMCwGByqGSM49AQECIQD/////AAAAAQAAAAAAAAAAAAAAAP///////////////zBbBCD/////AAAAAQAAAAAAAAAAAAAAAP///////////////AQgWsY12Ko6k+ez671VdpiGvGUdBrDMU7D2O848PifSYEsDFQDEnTYIhucEk2pmeOETnSa3gZ9+kARBBGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfUCIQD/////AAAAAP//////////vOb6racXnoTzucrC/GMlUQIBAQNCAAT18yCwVCryQSBj18vhPr2wiTigjIUYhm6SaapSUQ7jWe5RHj6RM9Cy+zT+nAZF731pDkVEAAb1s2iiS69q3YG9ozgwNjAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDAzAKBggqhkjOPQQDAgNIADBFAiAMGp0SrrnGPtb/+9k3lmtPQapSTrP+rC93g1X9x1p0/QIhAK81Em0iNRMKEaXlbOZgUA5Qh1zn+JM2uOyFrK0HO1A6")!
    static let b = Data(base64Encoded: "MIICcDCCAhWgAwIBAgIJAMQvcWBTXcZuMAoGCCqGSM49BAMCMCYxJDAiBgNVBAMMG0tlZXByZXNzbyBUZXN0IEZpeHR1cmUgT25seTAeFw0yNjExMTkxMTMxNTNaFw0zNjExMTYxMTMxNTNaMCYxJDAiBgNVBAMMG0tlZXByZXNzbyBUZXN0IEZpeHR1cmUgT25seTCCAUswggEDBgcqhkjOPQIBMIH3AgEBMCwGByqGSM49AQECIQD/////AAAAAQAAAAAAAAAAAAAAAP///////////////zBbBCD/////AAAAAQAAAAAAAAAAAAAAAP///////////////AQgWsY12Ko6k+ez671VdpiGvGUdBrDMU7D2O848PifSYEsDFQDEnTYIhucEk2pmeOETnSa3gZ9+kARBBGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfUCIQD/////AAAAAP//////////vOb6racXnoTzucrC/GMlUQIBAQNCAATrzoDte+Yn7r6ycVpfLSnp5lIN6gQc3uVeHWe5DeGNaKRXVW9MwXcab+vp9NyueA5oYOaUumd3/cAAEyiO0RNIozgwNjAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDAzAKBggqhkjOPQQDAgNJADBGAiEAuktLNmTcGJ1a7NGBLnl3Yije3+S0qxNNxkbfSQdiY/kCIQCl+g74jK9jB2bWrVgDD+X23PRbvNjMD8/Fx6AVDd9zJQ==")!
    static func authority(_ legacy: String, certificate: Data = a) -> String {
        CompanionPrivacyIdentity.make(bundleIdentifier: "local.keespresso.companion", signingIdentifier: "local.keespresso.companion",
            signatureValid: true, adHoc: false, certificateDER: certificate, legacyBuildIdentity: legacy)!
    }
    static let aSHA256 = "b89fecff16d5f478a6d3f79fd672b27662d3d0934b8cb5db8c168d71b3b26d39"
}

struct CompanionPrivacyIdentityTests {
    private let identifier = "local.keespresso.companion"
    private func identity(_ legacy: String = "local.keespresso.companion|0.6.12|6012|old-hash", certificate: Data? = PrivacyCertificateFixtures.a,
                          valid: Bool = true, adHoc: Bool = false, bundle: String = "local.keespresso.companion", signerID: String = "local.keespresso.companion") -> String? {
        CompanionPrivacyIdentity.make(bundleIdentifier: bundle, signingIdentifier: signerID, signatureValid: valid, adHoc: adHoc,
                                      certificateDER: certificate, legacyBuildIdentity: legacy)
    }
    @Test func certificateUpdatesIgnoreVersionAndBytesButNotSigningIdentity() throws {
        let expected = "certificate-v1|local.keespresso.companion|b89fecff16d5f478a6d3f79fd672b27662d3d0934b8cb5db8c168d71b3b26d39"
        #expect(identity() == expected)
        #expect(identity("local.keespresso.companion|0.6.13|6013|new-hash") == expected)
        #expect(identity(certificate: PrivacyCertificateFixtures.b) != expected)
        #expect(identity(bundle: "different.app") == nil)
        #expect(identity(signerID: "different.app") == nil)
    }
    @Test func invalidOrMalformedSigningEvidenceCannotReuseAuthorization() {
        #expect(identity(valid: false) == nil)
        #expect(identity(certificate: nil) == nil)
        #expect(identity(certificate: Data()) == nil)
        #expect(identity(certificate: Data("a certificate name is not a certificate".utf8)) == nil)
        #expect(identity(certificate: PrivacyCertificateFixtures.a, adHoc: true) == nil)
    }
    @Test func validAdHocRetainsOnlyItsLegacyBuildProof() {
        #expect(identity("build-A", certificate: nil, adHoc: true) == "build-A")
        #expect(identity("build-B", certificate: nil, adHoc: true) == "build-B")
        #expect(identity("", certificate: nil, adHoc: true) == nil)
        #expect(identity("build-A", certificate: nil, valid: false, adHoc: true) == nil)
    }
    @Test func folderProofSurvivesASignedUpdateButKeepsExactScope() async throws {
        let folder = URL(fileURLWithPath: "/fixture/Downloads", isDirectory: true)
        let old = try #require(identity())
        let new = try #require(identity("new-build"))
        let approved = await TriggerFolderAccess(configuredFolders: [folder], buildIdentity: old).requestingAccess { _ in true }
        #expect(TriggerFolderAccess(configuredFolders: [folder], buildIdentity: new, consentData: approved.consentData).allConfiguredApproved)
        let changed = URL(fileURLWithPath: "/fixture/Other", isDirectory: true)
        #expect(!TriggerFolderAccess(configuredFolders: [changed], buildIdentity: new, consentData: approved.consentData).allConfiguredApproved)
        #expect(!TriggerFolderAccess(configuredFolders: [folder], buildIdentity: "old-ad-hoc-proof", consentData: approved.consentData).allConfiguredApproved)
        let denied = await TriggerFolderAccess(configuredFolders: [folder], buildIdentity: old).requestingAccess { _ in false }
        #expect(!TriggerFolderAccess(configuredFolders: [folder], buildIdentity: new, consentData: denied.consentData).allConfiguredApproved)
    }
}
