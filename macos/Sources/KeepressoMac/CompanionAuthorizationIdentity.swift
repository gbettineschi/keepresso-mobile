import Foundation
import CryptoKit
import Security
import CompanionCore

/// Shared by the parent and bounded observer worker. No folders, credentials or TCC database are read.
enum CompanionAuthorizationIdentity {
    static let current: String = read() ?? ""

    private static func read() -> String? {
        var running: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return nil }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let metadata = raw as? [String: Any],
              let signerID = metadata[kSecCodeInfoIdentifier as String] as? String,
              let flags = metadata[kSecCodeInfoFlags as String] as? NSNumber,
              let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let adHoc = flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0
        let certificates = metadata[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let leaf = certificates?.first.map { SecCertificateCopyData($0) as Data }
        var legacy = ""
        if adHoc {
            guard let executable = Bundle.main.executableURL,
                  let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                  let bytes = try? Data(contentsOf: executable) else { return nil }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            // Preserve the exact existing encoding for valid ad-hoc development builds.
            legacy = "\(bundleID)|\(version)|\(build)|\(digest)"
        }
        return CompanionPrivacyIdentity.make(bundleIdentifier: bundleID, signingIdentifier: signerID, signatureValid: true,
            adHoc: adHoc, certificateDER: leaf, legacyBuildIdentity: legacy)
    }
}
