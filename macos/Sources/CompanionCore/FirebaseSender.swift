import Foundation
import Security

public struct FirebaseSenderConfiguration: Codable {
    public let client:FirebaseClientConfiguration
    public let projectId:String
    public let clientEmail:String
    public let privateKey:String
    public let privateKeyId:String?
    public init(client:FirebaseClientConfiguration,projectId:String,clientEmail:String,privateKey:String,privateKeyId:String?=nil)throws {
        guard projectId==client.projectId,clientEmail.hasSuffix("@\(projectId).iam.gserviceaccount.com"),
              clientEmail.utf8.count<=254,clientEmail.split(separator:"@").count==2,
              clientEmail.utf8.allSatisfy({$0>32 && $0<127}),privateKey.utf8.count<=16_384,
              privateKeyId.map({ !$0.isEmpty && $0.utf8.count<=128 && $0.utf8.allSatisfy({$0>32 && $0<127}) }) ?? true else{throw CompanionError.invalid}
        self.client=client;self.projectId=projectId;self.clientEmail=clientEmail;self.privateKey=privateKey;self.privateKeyId=privateKeyId
        _=try signingKey()
    }
    enum CodingKeys:String,CodingKey{case client,projectId,clientEmail,privateKey,privateKeyId}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(client:c.decode(FirebaseClientConfiguration.self,forKey:.client),projectId:c.decode(String.self,forKey:.projectId),clientEmail:c.decode(String.self,forKey:.clientEmail),privateKey:c.decode(String.self,forKey:.privateKey),privateKeyId:c.decodeIfPresent(String.self,forKey:.privateKeyId))
    }
    public static func importServiceAccount(_ data:Data,client:FirebaseClientConfiguration)throws->Self {
        guard data.count<=65_536 else{throw CompanionError.limit}
        let json=try WireJSON.object(data)
        guard json["type"] as? String == "service_account",let project=json["project_id"] as? String,
              let email=json["client_email"] as? String,let key=json["private_key"] as? String,
              json["token_uri"] as? String == "https://oauth2.googleapis.com/token" else{throw CompanionError.invalid}
        return try Self(client:client,projectId:project,clientEmail:email,privateKey:key,privateKeyId:json["private_key_id"] as? String)
    }
    func signingKey()throws->SecKey {
        // Google's PEM is PKCS#8. Security expects the contained PKCS#1 RSA key.
        let begin="-----BEGIN PRIVATE KEY-----",end="-----END PRIVATE KEY-----"
        guard privateKey.hasPrefix(begin),privateKey.trimmingCharacters(in:.whitespacesAndNewlines).hasSuffix(end),
              let der=Data(base64Encoded:privateKey.replacingOccurrences(of:begin,with:"").replacingOccurrences(of:end,with:"").filter{!$0.isWhitespace}) else{throw CompanionError.invalid}
        struct DER {
            let bytes:[UInt8];var index=0
            mutating func value(_ tag:UInt8)throws->[UInt8]{
                guard index+2<=bytes.count,bytes[index]==tag else{throw CompanionError.invalid};index+=1
                var length=Int(bytes[index]);index+=1
                if length&128 != 0{let n=length&127;guard (1...4).contains(n),index+n<=bytes.count else{throw CompanionError.invalid};length=0;for _ in 0..<n{length=(length<<8)|Int(bytes[index]);index+=1}}
                guard length<=bytes.count-index else{throw CompanionError.invalid};defer{index+=length};return Array(bytes[index..<index+length])
            }
        }
        var outer=DER(bytes:Array(der));var sequence=DER(bytes:try outer.value(0x30))
        guard outer.index==outer.bytes.count,try sequence.value(0x02)==[0],
              try sequence.value(0x30)==[0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00] else{throw CompanionError.invalid}
        let rsa=try sequence.value(0x04)
        guard sequence.index==sequence.bytes.count,
              let key=SecKeyCreateWithData(Data(rsa) as CFData,[kSecAttrKeyType:kSecAttrKeyTypeRSA,kSecAttrKeyClass:kSecAttrKeyClassPrivate] as CFDictionary,nil),
              let attrs=SecKeyCopyAttributes(key) as? [CFString:Any],let bits=attrs[kSecAttrKeySizeInBits] as? Int,(2048...8192).contains(bits) else{throw CompanionError.invalid}
        return key
    }
    public func assertion(now:Date)throws->String {
        func base(_ data:Data)->String{data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
        var header:[String:Any]=["alg":"RS256","typ":"JWT"];if let privateKeyId{header["kid"]=privateKeyId}
        let issued=Int64(now.timeIntervalSince1970)
        let claims:[String:Any]=["iss":clientEmail,"scope":"https://www.googleapis.com/auth/firebase.messaging","aud":"https://oauth2.googleapis.com/token","iat":issued,"exp":issued+3600]
        let message=try base(WireJSON.data(header))+"."+base(WireJSON.data(claims))
        guard let signature=SecKeyCreateSignature(try signingKey(),.rsaSignatureMessagePKCS1v15SHA256,Data(message.utf8) as CFData,nil) else{throw CompanionError.unavailable}
        return message+"."+base(signature as Data)
    }
}

public struct FCMHTTPResponse {
    public let status:Int;public let data:Data
    public init(status:Int,data:Data){self.status=status;self.data=data}
}
public enum FirebaseSendResult:String,Codable {case accepted,transient,unregistered,rejected,expired,cancelled}
public typealias FCMHTTP = (URL,[String:String],Data)async throws->FCMHTTPResponse

private final class FCMNetwork:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    static let shared=FCMNetwork()
    private lazy var session:URLSession = {
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=10;config.timeoutIntervalForResource=15
        config.httpShouldSetCookies=false;config.urlCache=nil
        return URLSession(configuration:config,delegate:self,delegateQueue:nil)
    }()
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
    func post(_ url:URL,_ headers:[String:String],_ body:Data)async throws->FCMHTTPResponse {
        guard url.scheme=="https",["oauth2.googleapis.com","fcm.googleapis.com"].contains(url.host ?? "") else{throw CompanionError.invalid}
        var request=URLRequest(url:url);request.httpMethod="POST";request.httpBody=body;request.allHTTPHeaderFields=headers
        let (data,response)=try await session.data(for:request)
        guard let response=response as? HTTPURLResponse,data.count<=65_536 else{throw CompanionError.limit}
        return FCMHTTPResponse(status:response.statusCode,data:data)
    }
}

@MainActor public final class FirebaseSender {
    private let configuration:FirebaseSenderConfiguration;private let http:FCMHTTP;private let now:()->Date
    private var access:(value:String,expires:Date)?
    private var fetching:Task<(String,Date),Error>?
    public init(configuration:FirebaseSenderConfiguration,now:@escaping()->Date = Date.init,http:FCMHTTP?=nil){
        self.configuration=configuration;self.now=now;self.http=http ?? {url,headers,body in try await FCMNetwork.shared.post(url,headers,body)}
    }
    private func token()async throws->String {
        if let access,access.expires.timeIntervalSince(now())>60{return access.value}
        if let fetching{return try await fetching.value.0}
        let issued=now(),http=self.http,configuration=self.configuration
        let task=Task<(String,Date),Error>{
            let assertion=try configuration.assertion(now:issued)
            let body=Data(("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion="+assertion).utf8)
            let reply=try await http(URL(string:"https://oauth2.googleapis.com/token")!,["Content-Type":"application/x-www-form-urlencoded"],body)
            guard reply.status==200,reply.data.count<=65_536 else{throw CompanionError.unavailable}
            let json=try WireJSON.object(reply.data)
            guard let token=json["access_token"] as? String,!token.isEmpty,token.utf8.count<=16_384,token.utf8.allSatisfy({$0>32 && $0<127}),
                  json["token_type"] as? String == "Bearer",let seconds=json["expires_in"] as? Int,(1...3600).contains(seconds) else{throw CompanionError.invalid}
            return (token,issued.addingTimeInterval(Double(seconds)))
        }
        fetching=task
        defer{fetching=nil}
        let fetched=try await task.value;access=(fetched.0,fetched.1);return fetched.0
    }
    public func send(_ envelope:RelayEnvelope,token registration:String,stillCurrent:()->Bool = {true})async->FirebaseSendResult {
        do {
            guard !Task.isCancelled,stillCurrent() else{return .cancelled}
            let current=now()
            guard Double(envelope.expiresAt)>current.timeIntervalSince1970 else{return .expired}
            try envelope.validate(now:current)
            guard envelope.kind=="event",envelope.direction=="s2c",!registration.isEmpty,registration.utf8.count<=4096,registration.utf8.allSatisfy({$0>32 && $0<127}) else{return .rejected}
            let encoded=try WireJSON.encoder.encode(envelope)
            guard encoded.count<=3000,let envelopeString=String(data:encoded,encoding:.utf8) else{return .rejected}
            let body=try WireJSON.data(["message":["token":registration,"data":["relayEnvelope":envelopeString],"android":["priority":"high","ttl":"\(max(1,Int(Double(envelope.expiresAt)-current.timeIntervalSince1970)))s"]]])
            guard body.count<=4096 else{return .rejected}
            let access=try await token()
            guard !Task.isCancelled,stillCurrent() else{return .cancelled}
            guard Double(envelope.expiresAt)>now().timeIntervalSince1970 else{return .expired}
            let reply=try await http(URL(string:"https://fcm.googleapis.com/v1/projects/\(configuration.projectId)/messages:send")!,["Authorization":"Bearer "+access,"Content-Type":"application/json"],body)
            if (200...299).contains(reply.status){return .accepted}
            if reply.status==401{self.access=nil;return .transient}
            if reply.status==429 || reply.status>=500{return .transient}
            if let json=try? WireJSON.object(reply.data),let error=json["error"] as? [String:Any],let details=error["details"] as? [[String:Any]],details.contains(where:{$0["errorCode"] as? String == "UNREGISTERED"}){return .unregistered}
            return .rejected
        }catch is CancellationError{return .transient}
        catch let error as CompanionError {
            switch error {case .expired:return .expired;case .unavailable,.closed:return .transient;default:return .rejected}
        }
        catch{return .transient}
    }
}
