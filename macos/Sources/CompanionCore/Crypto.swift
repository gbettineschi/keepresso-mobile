import Foundation
import CryptoKit
import Security
public enum WireCrypto {
    public static let aad = Data("keepresso-mobile/v1".utf8)
    public static func random32() throws -> Data { var d=Data(count:32); let status=d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault,32,$0.baseAddress!) }; guard status==errSecSuccess else { throw CompanionError.unavailable }; return d }
    public static func validID(_ value: String) -> Bool { UUID(uuidString:value)?.uuidString.lowercased() == value }
    public static func bytes32(_ b64: String) throws -> Data { guard let b=Data(base64Encoded:b64),b.count==32,b.base64EncodedString()==b64 else { throw CompanionError.invalid }; return b }
    public static func hmac(key: Data,text: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for:Data(text.utf8),using:SymmetricKey(data:key))) }
    public static func verify(_ proof: String,key: Data,text: String) -> Bool { guard let p=try? bytes32(proof) else { return false }; return HMAC<SHA256>.isValidAuthenticationCode(p,authenticating:Data(text.utf8),using:SymmetricKey(data:key)) }
    public static func pairTranscript(mac: String,device: String,nonce: String,name: String) -> String { "keepresso-mobile/pair/v1\n\(mac)\n\(device)\n\(nonce)\n\(Data(name.utf8).base64EncodedString())" }
    public static func transcript(mac: String,device: String,client: String,server: String) -> String { "keepresso-mobile/v1\n\(mac)\n\(device)\n\(client)\n\(server)" }
    private static func hkdf(ikm: Data,salt: Data,info: String) -> Data { HKDF<SHA256>.deriveKey(inputKeyMaterial:SymmetricKey(data:ikm),salt:salt,info:Data(info.utf8),outputByteCount:32).withUnsafeBytes { Data($0) } }
    public static func deviceKey(token: Data,mac: String,device: String) -> Data { hkdf(ikm:token,salt:Data(SHA256.hash(data:Data((mac+"\n"+device).utf8))),info:"keepresso-mobile/v1/device-key") }
    public static func directionKey(deviceKey: Data,transcript: String,direction: String) -> Data { hkdf(ikm:deviceKey,salt:Data(SHA256.hash(data:Data(transcript.utf8))),info:"keepresso-mobile/v1/"+direction) }
}
public struct SealedRecord: Codable { public var type = "sealed"; public var sequence: UInt64; public var ciphertext: String }
public final class SealedChannel {
    private let sendKey: SymmetricKey; private let receiveKey: SymmetricKey
    private var sendSequence: UInt64=0; private var receiveSequence: UInt64=0
    public private(set) var closed=false
    public init(sendKey: Data,receiveKey: Data) { self.sendKey=SymmetricKey(data:sendKey);self.receiveKey=SymmetricKey(data:receiveKey) }
    private func nonce(_ seq: UInt64) throws -> AES.GCM.Nonce { var n=Data(repeating:0,count:4); for shift in stride(from:56,through:0,by:-8) { n.append(UInt8((seq>>shift)&255)) }; return try AES.GCM.Nonce(data:n) }
    public func seal(_ data: Data) throws -> SealedRecord {
        guard !closed,sendSequence<=2147483647 else { closed=true;throw CompanionError.closed }
        do { let box=try AES.GCM.seal(data,using:sendKey,nonce:nonce(sendSequence),authenticating:WireCrypto.aad); let r=SealedRecord(sequence:sendSequence,ciphertext:(box.ciphertext+box.tag).base64EncodedString());sendSequence+=1;return r } catch { closed=true;throw error }
    }
    public func open(_ record: SealedRecord) throws -> Data {
        guard !closed,record.type=="sealed",record.sequence==receiveSequence,receiveSequence<=2147483647,let bytes=Data(base64Encoded:record.ciphertext),bytes.count>=16,bytes.count<=65536,bytes.base64EncodedString()==record.ciphertext else { closed=true;throw CompanionError.invalid }
        do { let box=try AES.GCM.SealedBox(nonce:nonce(record.sequence),ciphertext:bytes.dropLast(16),tag:bytes.suffix(16));let opened=try AES.GCM.open(box,using:receiveKey,authenticating:WireCrypto.aad);receiveSequence+=1;return opened } catch { closed=true;throw error }
    }
    public func close() { closed=true }
}
