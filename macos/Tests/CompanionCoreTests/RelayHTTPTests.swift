import Foundation
import Testing
@testable import CompanionCore
struct RelayHTTPTests {
    let mac="11111111-1111-4111-8111-111111111111",device="22222222-2222-4222-8222-222222222222"
    @MainActor @Test func enrollmentUploadsOnlyDerivedAccessHashAndIndependentMacBearer()async throws {
        let bearer=Data(repeating:9,count:32).base64EncodedString();let configuration=try RelayConfiguration(url:"https://relay.example",macBearer:bearer)
        let client=RelayHTTPClient(configuration:configuration){request in
            #expect(request.httpMethod=="POST");#expect(request.url==configuration.endpoint)
            #expect(request.value(forHTTPHeaderField:"Authorization")=="Bearer "+bearer)
            #expect(request.value(forHTTPHeaderField:"Content-Type")=="application/json")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            let body=try WireJSON.object(request.httpBody!)
            #expect(Set(body.keys)==Set(["op","macId","deviceId","tokenHash"]))
            #expect(body["tokenHash"] as? String==String(repeating:"a",count:64))
            return(Data("{\"enrolled\":true}".utf8),HTTPURLResponse(url:configuration.endpoint,statusCode:200,httpVersion:nil,headerFields:["Cache-Control":"no-store"])!)
        }
        try await client.enroll(macId:mac,deviceId:device,tokenHash:String(repeating:"a",count:64))
    }
    @MainActor @Test func crossOriginResponseRedirectStatusAndOversizedBatchFailClosed()async throws {
        let configuration=try RelayConfiguration(url:"https://relay.example",macBearer:Data(repeating:9,count:32).base64EncodedString())
        var code=200;var target=URL(string:"https://attacker.example/api/relay")!;var submissions=0
        let client=RelayHTTPClient(configuration:configuration){request in submissions+=1;return(Data("{\"commands\":[]}".utf8),HTTPURLResponse(url:target,statusCode:code,httpVersion:nil,headerFields:nil)!)}
        do{_=try await client.sync(RelayBatch(macId:mac,epoch:device));Issue.record("Cross-origin response was accepted")}catch{}
        target=configuration.endpoint;code=302
        do{_=try await client.sync(RelayBatch(macId:mac,epoch:device));Issue.record("Redirect response was accepted")}catch{}
        #expect(submissions==2)
        let envelope=try RelayEnvelope.seal(Data(),key:Data(repeating:1,count:32),macId:mac,deviceId:device,id:mac,epoch:device,direction:"s2c",kind:"state",now:Date(),lifetime:15)
        do{_=try await client.sync(RelayBatch(macId:mac,epoch:device,states:Array(repeating:envelope,count:17)));Issue.record("Oversized batch submitted")}catch{}
        #expect(submissions==2)
    }
}
