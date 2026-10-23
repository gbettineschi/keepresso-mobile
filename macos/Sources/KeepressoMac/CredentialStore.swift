import Foundation
import Security
import CompanionCore
final class CredentialStore {
    // Stable identity: changing it would orphan existing phone and relay keys.
    private let service="local.keespresso.companion.v1"
    private func query(_ id:String)->[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id] }
    func load()->[AuthorizedDevice] {
        var q=query("devices");q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound { return [] }
        guard status==errSecSuccess,let d=result as? Data,let records=try? WireJSON.decoder.decode([AuthorizedDevice].self,from:d),records.count<=32,records.allSatisfy({WireCrypto.validID($0.deviceId) && $0.key.count==32}) else { return [] } // no fallback credential authorization
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
    func loadRelay()->RelayConfiguration? {
        var q=query("relay");q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&result)==errSecSuccess,let data=result as? Data,data.count<=8192,let decoded=try? WireJSON.decoder.decode(RelayConfiguration.self,from:data) else{return nil}
        // Codable decoding must not bypass the production HTTPS/bearer validator.
        return try? RelayConfiguration(url:decoded.url,macBearer:decoded.macBearer)
    }
    func saveRelay(_ configuration:RelayConfiguration)throws {
        let data=try WireJSON.encoder.encode(configuration);let q=query("relay")
        let values:[String:Any]=[kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status=SecItemUpdate(q as CFDictionary,values as CFDictionary)
        if status==errSecItemNotFound{var insert=q;values.forEach{insert[$0.key]=$0.value};guard SecItemAdd(insert as CFDictionary,nil)==errSecSuccess else{throw CompanionError.unavailable}}
        else if status != errSecSuccess{throw CompanionError.unavailable}
    }
}
