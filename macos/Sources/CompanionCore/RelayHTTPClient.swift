import Foundation

public struct RelayBatch:Encodable {
    public var op="sync";public let macId:String;public let epoch:String
    public var states:[RelayEnvelope];public var responses:[RelayEnvelope];public var events:[RelayEnvelope]
    public init(macId:String,epoch:String,states:[RelayEnvelope]=[],responses:[RelayEnvelope]=[],events:[RelayEnvelope]=[]){self.macId=macId;self.epoch=epoch;self.states=states;self.responses=responses;self.events=events}
}
public struct RelaySyncResult {
    public let commands:[RelayEnvelope];public let retryEvents:Set<String>
    public init(commands:[RelayEnvelope],retryEvents:Set<String>=[]){self.commands=commands;self.retryEvents=retryEvents}
}
@MainActor public protocol RelayAPI:AnyObject {
    func enroll(macId:String,deviceId:String,tokenHash:String)async throws
    func revoke(macId:String,deviceId:String)async throws
    func sync(_ batch:RelayBatch)async throws->RelaySyncResult
}
private final class RefuseRelayRedirects:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
}
@MainActor public final class RelayHTTPClient:RelayAPI {
    public typealias Transport=(URLRequest)async throws->(Data,HTTPURLResponse)
    private let configuration:RelayConfiguration;private let transport:Transport
    public init(configuration:RelayConfiguration,transport:Transport?=nil) {
        self.configuration=configuration
        if let transport{self.transport=transport}else{
            let options=URLSessionConfiguration.ephemeral;options.urlCache=nil;options.httpCookieStorage=nil;options.urlCredentialStorage=nil;options.timeoutIntervalForRequest=8;options.timeoutIntervalForResource=12
            let session=URLSession(configuration:options,delegate:RefuseRelayRedirects(),delegateQueue:nil)
            self.transport={request in
                let (bytes,response)=try await session.bytes(for:request)
                guard let http=response as? HTTPURLResponse else{throw CompanionError.unavailable}
                if response.expectedContentLength>256*1024{throw CompanionError.limit}
                var data=Data();for try await byte in bytes{guard data.count<256*1024 else{throw CompanionError.limit};data.append(byte)}
                return (data,http)
            }
        }
    }
    private func post(_ body:Data)async throws->[String:Any] {
        guard body.count<=256*1024 else{throw CompanionError.limit}
        var request=URLRequest(url:configuration.endpoint,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:8)
        request.httpMethod="POST";request.httpBody=body;request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("Bearer "+configuration.macBearer,forHTTPHeaderField:"Authorization");request.setValue("no-store",forHTTPHeaderField:"Cache-Control")
        let (data,response)=try await transport(request)
        guard response.url==configuration.endpoint,(200...299).contains(response.statusCode),data.count<=256*1024 else{throw CompanionError.unavailable}
        return try WireJSON.object(data)
    }
    public func enroll(macId:String,deviceId:String,tokenHash:String)async throws {
        guard WireCrypto.validID(macId),WireCrypto.validID(deviceId),tokenHash.count==64,tokenHash.allSatisfy({$0.isHexDigit && !$0.isUppercase}) else{throw CompanionError.invalid}
        let result=try await post(WireJSON.data(["op":"enroll","macId":macId,"deviceId":deviceId,"tokenHash":tokenHash]))
        guard result["enrolled"] as? Bool==true else{throw CompanionError.invalid}
    }
    public func revoke(macId:String,deviceId:String)async throws {
        guard WireCrypto.validID(macId),WireCrypto.validID(deviceId) else{throw CompanionError.invalid}
        let result=try await post(WireJSON.data(["op":"revoke","macId":macId,"deviceId":deviceId]))
        guard result["revoked"] as? Bool==true else{throw CompanionError.invalid}
    }
    public func sync(_ batch:RelayBatch)async throws->RelaySyncResult {
        guard WireCrypto.validID(batch.macId),WireCrypto.validID(batch.epoch),batch.states.count+batch.responses.count+batch.events.count<=16 else{throw CompanionError.invalid}
        let result=try await post(WireJSON.encoder.encode(batch))
        guard let commands=result["commands"] as? [[String:Any]],commands.count<=16 else{throw CompanionError.invalid}
        let retries:Set<String>
        if let raw=result["retryEvents"] {
            guard let ids=raw as? [String],ids.count<=16,ids.allSatisfy(WireCrypto.validID),Set(ids).isSubset(of:Set(batch.events.map(\.id))) else{throw CompanionError.invalid};retries=Set(ids)
        }else{retries=[]}
        return RelaySyncResult(commands:try commands.map{try RelayEnvelope.decode(WireJSON.data($0))},retryEvents:retries)
    }
}
