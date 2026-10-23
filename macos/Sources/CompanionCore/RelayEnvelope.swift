import Foundation
import CryptoKit
import CoreFoundation

/// Transport-independent authenticated envelope. Metadata is authenticated along
/// with the exact request bytes; routing/freshness are checked before decryption.
public struct RelayEnvelope: Codable, Equatable {
    public var version:Int = 1
    public var macId:String; public var deviceId:String; public var id:String; public var epoch:String
    public var direction:String; public var kind:String
    public var createdAt:Int64; public var expiresAt:Int64
    public var nonce:String; public var ciphertext:String
    private static let domain="keepresso-mobile/relay/v1"
    public var aad:Data { Data([Self.domain,macId,deviceId,id,epoch,direction,kind,String(createdAt),String(expiresAt)].joined(separator:"\n").utf8) }
    public static func directionKey(deviceKey:Data,macId:String,deviceId:String,direction:String)throws->Data {
        guard deviceKey.count==32,WireCrypto.validID(macId),WireCrypto.validID(deviceId),["c2s","s2c","phone-access"].contains(direction) else{throw CompanionError.invalid}
        let salt=Data(SHA256.hash(data:Data((macId+"\n"+deviceId).utf8)))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial:SymmetricKey(data:deviceKey),salt:salt,info:Data((domain+"/"+direction).utf8),outputByteCount:32).withUnsafeBytes{Data($0)}
    }
    public static func phoneBearer(deviceKey:Data,macId:String,deviceId:String)throws->String {try directionKey(deviceKey:deviceKey,macId:macId,deviceId:deviceId,direction:"phone-access").base64EncodedString()}
    public static func phoneTokenHash(deviceKey:Data,macId:String,deviceId:String)throws->String {Data(SHA256.hash(data:Data(try phoneBearer(deviceKey:deviceKey,macId:macId,deviceId:deviceId).utf8))).map{String(format:"%02x",$0)}.joined()}
    public static func accessTicket(macBearer:String,deviceKey:Data,macId:String,deviceId:String)throws->String {
        _=try WireCrypto.bytes32(macBearer)
        let macHash=Data(SHA256.hash(data:Data(macBearer.utf8))).map{String(format:"%02x",$0)}.joined()
        let phoneHash=try phoneTokenHash(deviceKey:deviceKey,macId:macId,deviceId:deviceId)
        let transcript="keepresso-mobile/relay/v1/access-ticket\n"+macId+"\n"+deviceId+"\n"+phoneHash
        return WireCrypto.hmac(key:Data(macHash.utf8),text:transcript).base64EncodedString()
    }
    public static func decode(_ data:Data)throws->RelayEnvelope {
        guard data.count<=65536 else{throw CompanionError.limit}
        let object=try WireJSON.object(data)
        guard Set(object.keys)==Set(["version","macId","deviceId","id","epoch","direction","kind","createdAt","expiresAt","nonce","ciphertext"]) else{throw CompanionError.invalid}
        for field in ["version","createdAt","expiresAt"] {
            guard let number=object[field] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite,number.doubleValue.rounded(.towardZero)==number.doubleValue else{throw CompanionError.invalid}
        }
        return try WireJSON.decoder.decode(Self.self,from:data)
    }
    public func validate(now:Date)throws {
        guard version==1,WireCrypto.validID(macId),WireCrypto.validID(deviceId),WireCrypto.validID(id),WireCrypto.validID(epoch),["c2s","s2c"].contains(direction),["command","response","state","event"].contains(kind),direction == (kind == "command" ? "c2s":"s2c") else{throw CompanionError.invalid}
        let lifetimes:[String:Int64]=["command":30,"response":120,"state":15,"event":300]
        guard createdAt>=0,expiresAt>createdAt,expiresAt-createdAt<=lifetimes[kind]!,Double(createdAt)<=now.timeIntervalSince1970+10,Double(expiresAt)>now.timeIntervalSince1970 else{throw CompanionError.expired}
        guard let n=Data(base64Encoded:nonce),n.count==12,n.base64EncodedString()==nonce,let c=Data(base64Encoded:ciphertext),c.count>=16,c.base64EncodedString()==ciphertext else{throw CompanionError.invalid}
        guard try WireJSON.encoder.encode(self).count<=65536 else{throw CompanionError.limit}
    }
    public static func seal(_ plaintext:Data,key:Data,macId:String,deviceId:String,id:String,epoch:String,direction:String,kind:String,now:Date,lifetime:Int,nonce:Data?=nil)throws->RelayEnvelope {
        let n:Data
        if let nonce{n=nonce}else{n=try WireCrypto.random32().prefix(12)}
        var envelope=RelayEnvelope(macId:macId,deviceId:deviceId,id:id,epoch:epoch,direction:direction,kind:kind,createdAt:Int64(floor(now.timeIntervalSince1970)),expiresAt:Int64(floor(now.timeIntervalSince1970))+Int64(lifetime),nonce:n.base64EncodedString(),ciphertext:Data(repeating:0,count:16).base64EncodedString())
        try envelope.validate(now:now)
        let directionKey=try directionKey(deviceKey:key,macId:macId,deviceId:deviceId,direction:direction)
        let box=try AES.GCM.seal(plaintext,using:SymmetricKey(data:directionKey),nonce:AES.GCM.Nonce(data:n),authenticating:envelope.aad)
        envelope.ciphertext=(box.ciphertext+box.tag).base64EncodedString()
        try envelope.validate(now:now)
        return envelope
    }
    public func open(key:Data,macId:String,deviceId:String,epoch:String,direction:String,kinds:Set<String>,now:Date)throws->Data {
        try validate(now:now)
        guard self.macId==macId,self.deviceId==deviceId,self.epoch==epoch,self.direction==direction,kinds.contains(kind) else{throw CompanionError.mismatch}
        let bytes=Data(base64Encoded:ciphertext)!
        let box=try AES.GCM.SealedBox(nonce:AES.GCM.Nonce(data:Data(base64Encoded:nonce)!),ciphertext:bytes.dropLast(16),tag:bytes.suffix(16))
        return try AES.GCM.open(box,using:SymmetricKey(data:Self.directionKey(deviceKey:key,macId:macId,deviceId:deviceId,direction:direction)),authenticating:aad)
    }
}

public struct RelayConfiguration:Codable,Equatable {
    public let url:String; public let macBearer:String
    public var endpoint:URL {URL(string:url)!.appendingPathComponent("api/relay")}
    public init(url:String,macBearer:String,allowLocalhost:Bool=false)throws {
        guard url.utf8.count<=4096,let components=URLComponents(string:url),let parsed=components.url,let host=components.host,!host.isEmpty,components.user==nil,components.password==nil,components.query==nil,components.fragment==nil,(components.scheme=="https" || (allowLocalhost && components.scheme=="http" && ["127.0.0.1","localhost","::1"].contains(host))),!url.unicodeScalars.contains(where:{CharacterSet.whitespacesAndNewlines.contains($0)}) else{throw CompanionError.invalid}
        _=try WireCrypto.bytes32(macBearer)
        self.url=parsed.absoluteString.trimmingCharacters(in:CharacterSet(charactersIn:"/"));self.macBearer=macBearer
    }
}
