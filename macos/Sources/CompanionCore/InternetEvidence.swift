import Foundation

/// A route is not internet proof. Only a fresh check for that route can be Online.
public struct InternetEvidence {
    public private(set) var checkedAt:Date?
    private var available:Bool?
    private var identity:String?
    private var pending:UUID?
    private var result="unknown"
    public init(){}
    @discardableResult public mutating func updatePath(available:Bool,identity:String,now:Date)->Bool{
        if !available{checkedAt=now}
        guard self.available != available || self.identity != identity else{return false}
        self.available=available;self.identity=identity;pending=nil
        result=available ? "checking":"offline";checkedAt=available ? nil:now
        return true
    }
    public mutating func beginCheck(now:Date)->UUID?{
        guard available==true,pending==nil else{return nil}
        if let checkedAt,(0..<15).contains(now.timeIntervalSince(checkedAt)){return nil}
        let token=UUID();pending=token;return token
    }
    public mutating func complete(_ token:UUID,success:Bool,now:Date){
        guard pending==token,available==true else{return}
        pending=nil;checkedAt=now;result=success ? "online":"check_failed"
    }
    public func status(at now:Date)->String{
        if let checkedAt,!(0...45).contains(now.timeIntervalSince(checkedAt)){return "unknown"}
        return result
    }
    public mutating func reset(){self=Self()}
}

/// Two independent, small HTTPS checks. No redirects, cookies, credentials or cache.
public final class HTTPSInternetProbe:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    private let configuration:URLSessionConfiguration
    public init(configuration:URLSessionConfiguration = .ephemeral){
        self.configuration=configuration.copy() as! URLSessionConfiguration
        self.configuration.timeoutIntervalForRequest=3
        self.configuration.timeoutIntervalForResource=3
        self.configuration.waitsForConnectivity=false
        self.configuration.httpCookieStorage=nil
        self.configuration.httpShouldSetCookies=false
        self.configuration.urlCredentialStorage=nil
        self.configuration.urlCache=nil
        super.init()
    }
    public func check()async->Bool{
        let session=URLSession(configuration:configuration,delegate:self,delegateQueue:nil)
        defer{session.invalidateAndCancel()}
        for address in ["https://www.gstatic.com/generate_204","https://cp.cloudflare.com/generate_204"]{
            guard !Task.isCancelled else{return false}
            let url=URL(string:address)!
            var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:3)
            request.httpMethod="HEAD";request.httpShouldHandleCookies=false
            request.setValue("no-cache, no-store",forHTTPHeaderField:"Cache-Control")
            do{
                let (data,response)=try await session.data(for:request)
                if !Task.isCancelled,let http=response as? HTTPURLResponse,http.statusCode==204,http.url==url,data.isEmpty{return true}
            }catch{}
        }
        return false
    }
    public func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
}
