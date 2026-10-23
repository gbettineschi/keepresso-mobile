import Foundation
public struct PairRequest: Codable {
    public var type = "pair"; public var version: Int; public var macId: String; public var deviceId: String; public var deviceName: String; public var clientNonce: String; public var proof: String
    public init(version: Int,macId: String,deviceId: String,deviceName: String,clientNonce: String,proof: String) { self.version=version;self.macId=macId;self.deviceId=deviceId;self.deviceName=deviceName;self.clientNonce=clientNonce;self.proof=proof }
}
public struct AuthorizedDevice: Codable, Identifiable { public var id: String { deviceId }; public var deviceId: String; public var name: String; public var key: Data; public var approvedAt: Date }
public struct PairInvitation {
    public let token: Data; public let expires: Date; public let url: URL
}
public final class PairingManager {
    public struct Pending { public let request: PairRequest; public let peer: String; public let expires: Date }
    public let macId: String; public private(set) var invitation: PairInvitation?; public private(set) var pending: Pending?
    public init(macId: String) { self.macId=macId }
    @discardableResult public func arm(name: String,now: Date) throws -> PairInvitation {
        let token=try WireCrypto.random32(); let expiry=Date(timeIntervalSince1970:floor(now.timeIntervalSince1970)+300)
        var u=URLComponents();u.scheme="keespresso";u.host="pair";u.queryItems=[URLQueryItem(name:"v",value:"1"),URLQueryItem(name:"mac",value:macId),URLQueryItem(name:"token",value:token.base64EncodedString()),URLQueryItem(name:"expires",value:String(Int(expiry.timeIntervalSince1970))),URLQueryItem(name:"name",value:String(name.prefix(80)))]
        // '+' is legal in RFC3986 but form parsers often decode it as space.
        let url=URL(string:u.url!.absoluteString.replacingOccurrences(of:"+",with:"%2B"))!
        let i=PairInvitation(token:token,expires:expiry,url:url); invitation=i;pending=nil;return i
    }
    public func request(_ r: PairRequest,peer: String,now: Date) throws {
        guard let i=invitation,now<i.expires,pending==nil,r.type=="pair",r.version==1,r.macId==macId,WireCrypto.validID(r.deviceId),!r.deviceName.isEmpty,r.deviceName.utf8.count<=80,!r.deviceName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CompanionError.unauthorized }
        _ = try WireCrypto.bytes32(r.clientNonce)
        guard WireCrypto.verify(r.proof,key:i.token,text:WireCrypto.pairTranscript(mac:macId,device:r.deviceId,nonce:r.clientNonce,name:r.deviceName)) else { throw CompanionError.unauthorized }
        pending=Pending(request:r,peer:peer,expires:min(i.expires,now.addingTimeInterval(60)))
    }
    public func approve(now: Date) throws -> AuthorizedDevice {
        guard let p=pending,let i=invitation,now<p.expires,now<i.expires else { deny();throw CompanionError.expired }
        let d=AuthorizedDevice(deviceId:p.request.deviceId,name:p.request.deviceName,key:WireCrypto.deviceKey(token:i.token,mac:macId,device:p.request.deviceId),approvedAt:now)
        invitation=nil;pending=nil;return d
    }
    public func deny() { invitation=nil;pending=nil }
    public func expire(now: Date) { if invitation.map({now >= $0.expires}) == true || pending.map({now >= $0.expires}) == true { deny() } }
}
