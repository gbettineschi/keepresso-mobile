import Foundation
import CryptoKit
import Security

/// Names local preparation evidence; it neither grants nor proves current OS access.
public enum CompanionPrivacyIdentity {
    public static let companionIdentifier = "local.keespresso.companion"

    /// The caller must validate the actual running code before supplying its metadata.
    public static func make(bundleIdentifier: String, signingIdentifier: String, signatureValid: Bool,
                            adHoc: Bool, certificateDER: Data?, legacyBuildIdentity: String) -> String? {
        guard signatureValid, bundleIdentifier == companionIdentifier, signingIdentifier == companionIdentifier else { return nil }
        if adHoc {
            guard certificateDER == nil, !legacyBuildIdentity.isEmpty, legacyBuildIdentity.utf8.count <= 512,
                  !legacyBuildIdentity.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return legacyBuildIdentity
        }
        guard let certificateDER, !certificateDER.isEmpty, certificateDER.count <= 65_536,
              SecCertificateCreateWithData(nil, certificateDER as CFData) != nil else { return nil }
        let digest = SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
        return "certificate-v1|\(companionIdentifier)|\(digest)"
    }
}
