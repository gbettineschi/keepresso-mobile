import Foundation
import Security
import CompanionCore
final class CredentialStore: @unchecked Sendable {
    // Stable identity: changing it would orphan existing phone and relay keys.
    private let service="local.keespresso.companion.v1"
    private func query(_ id:String)->[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id] }
    private static let readLock=NSLock()
    func loadSaved(allowInteraction:Bool)throws->SavedAuthorization {
        // Existing installations use the file-based Keychain. Its interaction
        // policy is process-wide, so serialize reads and restore it before writes.
        Self.readLock.lock();defer{Self.readLock.unlock()}
        var wasAllowed:DarwinBoolean=false
        guard SecKeychainGetUserInteractionAllowed(&wasAllowed)==errSecSuccess else{throw CompanionError.unavailable}
        if !allowInteraction {
            guard SecKeychainSetUserInteractionAllowed(false)==errSecSuccess else{throw CompanionError.unavailable}
        }
        defer{if !allowInteraction{SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue)}}
        return SavedAuthorization(devices:try load(),relay:try loadRelay())
    }
    private func load()throws->[AuthorizedDevice] {
        var q=query("devices");q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound { return [] }
        guard status==errSecSuccess,let d=result as? Data,let records=try? WireJSON.decoder.decode([AuthorizedDevice].self,from:d),records.count<=32,records.allSatisfy({WireCrypto.validID($0.deviceId) && $0.key.count==32}) else { throw CompanionError.unavailable }
        return records
    }
    func save(_ devices:[AuthorizedDevice]) throws {
        guard devices.count<=32 else{throw CompanionError.limit};let data=try WireJSON.encoder.encode(devices)
        let q=query("devices");let values:[String:Any]=[kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status=SecItemUpdate(q as CFDictionary,values as CFDictionary)
        if status==errSecItemNotFound { var insert=q;values.forEach { insert[$0.key]=$0.value };guard SecItemAdd(insert as CFDictionary,nil)==errSecSuccess else{throw CompanionError.unavailable} } else if status != errSecSuccess { throw CompanionError.unavailable }
    }
}

extension CredentialStore {
    private func loadRelay()throws->RelayConfiguration? {
        var q=query("relay");q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?
        let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound{return nil}
        guard status==errSecSuccess,let data=result as? Data,data.count<=8192,let decoded=try? WireJSON.decoder.decode(RelayConfiguration.self,from:data) else{throw CompanionError.unavailable}
        // Codable decoding must not bypass the production HTTPS/bearer validator.
        return try RelayConfiguration(url:decoded.url,macBearer:decoded.macBearer)
    }
    func saveRelay(_ configuration:RelayConfiguration)throws {
        let data=try WireJSON.encoder.encode(configuration);let q=query("relay")
        let values:[String:Any]=[kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status=SecItemUpdate(q as CFDictionary,values as CFDictionary)
        if status==errSecItemNotFound{var insert=q;values.forEach{insert[$0.key]=$0.value};guard SecItemAdd(insert as CFDictionary,nil)==errSecSuccess else{throw CompanionError.unavailable}}
        else if status != errSecSuccess{throw CompanionError.unavailable}
    }
}
