import Foundation
/// One ephemeral handshake per peer, ten-second authentication deadline.
public final class ServerHandshake {
    public let deviceId:String;public let transcript:String;private let key:Data;public let expires:Date;private var consumed=false
    public let challenge:[String:String]
    public init(mac:String,device:String,clientNonce:String,key:Data,now:Date) throws {
        guard WireCrypto.validID(mac),WireCrypto.validID(device),key.count==32 else{throw CompanionError.invalid}
        _=try WireCrypto.bytes32(clientNonce);let server=try WireCrypto.random32().base64EncodedString()
        deviceId=device;self.key=key;expires=now.addingTimeInterval(10)
        transcript=WireCrypto.transcript(mac:mac,device:device,client:clientNonce,server:server)
        challenge=["type":"challenge","serverNonce":server,"proof":WireCrypto.hmac(key:key,text:"server\n"+transcript).base64EncodedString()]
    }
    public func authenticate(proof:String,now:Date) throws -> SealedChannel {
        guard !consumed else{throw CompanionError.closed};consumed=true
        guard now<expires,WireCrypto.verify(proof,key:key,text:"client\n"+transcript) else{throw CompanionError.unauthorized}
        return SealedChannel(sendKey:WireCrypto.directionKey(deviceKey:key,transcript:transcript,direction:"s2c"),receiveKey:WireCrypto.directionKey(deviceKey:key,transcript:transcript,direction:"c2s"))
    }
}
