import Foundation
import Security
import CompanionCore
import OSLog
private let credentialLog=Logger(subsystem:"local.keespresso.companion",category:"saved-connection")
final class CredentialStore: @unchecked Sendable {
    private let repository: CredentialRepository
    init() {
        let legacy = LegacyCredentialReader()
        repository = CredentialRepository(file: PrivateCredentialFile(), legacyReader: { try legacy.loadSaved(allowInteraction: $0) })
    }
    func loadSaved(allowInteraction: Bool) throws -> SavedAuthorization { try repository.loadSaved(allowInteraction: allowInteraction) }
    func save(_ devices: [AuthorizedDevice]) throws { try repository.save(devices) }
    func saveRelay(_ configuration: RelayConfiguration) throws { try repository.saveRelay(configuration) }
}

/// Retained solely for migration. Constructing this reader performs no Keychain
/// API calls; a valid private file bypasses even the interaction-policy queries.
private final class LegacyCredentialReader: @unchecked Sendable {
    // Stable identity: changing it would orphan existing phone and relay keys.
    private let service="local.keespresso.companion.v1"
    private func query(_ id:String)->[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id] }
    private static let readLock=NSLock()
    private func readFailure(_ status:OSStatus,account:String)->SavedConnectionFailure{
        var keychain:SecKeychain?;var flags:SecKeychainStatus=0
        let unlocked:Bool? = SecKeychainCopyDefault(&keychain)==errSecSuccess && keychain != nil && SecKeychainGetStatus(keychain!,&flags)==errSecSuccess ? flags & 1 != 0:nil
        let failure=SavedConnectionFailure(status:status,keychainUnlocked:unlocked)
        credentialLog.error("Saved connection read failed: item=\(account,privacy:.public) status=\(status,privacy:.public) reason=\(String(describing:failure.reason),privacy:.public)")
        return failure
    }
    func loadSaved(allowInteraction:Bool)throws->SavedAuthorization {
        // Existing installations use the file-based Keychain. Its interaction
        // policy is process-wide, so serialize reads and restore it before returning.
        Self.readLock.lock();defer{Self.readLock.unlock()}
        var wasAllowed:DarwinBoolean=false
        let policyStatus=SecKeychainGetUserInteractionAllowed(&wasAllowed)
        guard policyStatus==errSecSuccess else{throw readFailure(policyStatus,account:"interaction-policy")}
        if !allowInteraction {
            let status=SecKeychainSetUserInteractionAllowed(false)
            guard status==errSecSuccess else{throw readFailure(status,account:"interaction-policy")}
        }
        defer{if !allowInteraction{SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue)}}
        return SavedAuthorization(devices:try load(),relay:try loadRelay())
    }
    private func load()throws->[AuthorizedDevice] {
        var q=query("devices");q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound { return [] }
        guard status==errSecSuccess else{throw readFailure(status,account:"devices")}
        guard let d=result as? Data,let records=try? WireJSON.decoder.decode([AuthorizedDevice].self,from:d),records.count<=32,records.allSatisfy({WireCrypto.validID($0.deviceId) && $0.key.count==32}) else {throw SavedConnectionFailure(reason:.invalidData)}
        return records
    }
}

private extension LegacyCredentialReader {
    private func loadRelay()throws->RelayConfiguration? {
        var q=query("relay");q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?
        let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound{return nil}
        guard status==errSecSuccess else{throw readFailure(status,account:"relay")}
        guard let data=result as? Data,data.count<=8192,let decoded=try? WireJSON.decoder.decode(RelayConfiguration.self,from:data) else{throw SavedConnectionFailure(reason:.invalidData)}
        // Codable decoding must not bypass the production HTTPS/bearer validator.
        guard let validated=try? RelayConfiguration(url:decoded.url,macBearer:decoded.macBearer) else{throw SavedConnectionFailure(reason:.invalidData)}
        return validated
    }
}
