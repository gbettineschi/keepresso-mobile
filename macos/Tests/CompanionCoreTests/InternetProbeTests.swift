import Foundation
import Testing
@testable import CompanionCore

private final class ConnectivityURLProtocol:URLProtocol,@unchecked Sendable {
    private static let lock=NSLock()
    nonisolated(unsafe) private static var codes:[Int]=[]
    nonisolated(unsafe) private static var requests:[URLRequest]=[]
    static func prepare(_ responses:[Int]){lock.lock();defer{lock.unlock()};codes=responses;requests=[]}
    static var sent:[URLRequest]{lock.lock();defer{lock.unlock()};return requests}
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        Self.lock.lock();Self.requests.append(request);let code=Self.codes.isEmpty ? 503:Self.codes.removeFirst();Self.lock.unlock()
        let response=HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:"HTTP/1.1",headerFields:["Location":"https://portal.invalid/login"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}

@Suite(.serialized) struct InternetProbeTests {
    private func probe()->HTTPSInternetProbe{
        let configuration=URLSessionConfiguration.ephemeral
        configuration.protocolClasses=[ConnectivityURLProtocol.self]
        return HTTPSInternetProbe(configuration:configuration)
    }
    @Test func validProofUsesNoCredentialsOrBodyAndSkipsFallback()async{
        ConnectivityURLProtocol.prepare([204])
        #expect(await probe().check())
        let requests=ConnectivityURLProtocol.sent
        #expect(requests.count==1)
        #expect(requests.first?.url?.scheme=="https")
        #expect(requests.first?.httpMethod=="HEAD")
        #expect(requests.first?.httpBody==nil)
        #expect(requests.first?.value(forHTTPHeaderField:"Authorization")==nil)
        #expect(requests.first?.httpShouldHandleCookies==false)
    }
    @Test func blockedPrimaryCanUseIndependentFallback()async{
        ConnectivityURLProtocol.prepare([503,204])
        #expect(await probe().check())
        #expect(Set(ConnectivityURLProtocol.sent.compactMap{$0.url?.host}).count==2)
    }
    @Test func captivePortalRedirectAndUnexpectedSuccessAreNotInternetProof()async{
        ConnectivityURLProtocol.prepare([302,200])
        #expect(await probe().check()==false)
        #expect(ConnectivityURLProtocol.sent.count==2)
    }
}
