import Foundation
import Testing
import CryptoKit
@testable import CompanionCore

struct RelayTests {
    let mac="11111111-1111-4111-8111-111111111111"
    let device="22222222-2222-4222-8222-222222222222"
    let epoch="33333333-3333-4333-8333-333333333333"
    let id="44444444-4444-4444-8444-444444444444"
    let now=Date(timeIntervalSince1970:1800000000)
    let key=Data(repeating:7,count:32)
    func envelope(kind:String="command",direction:String="c2s",expiry:Int=30)throws->RelayEnvelope {
        try RelayEnvelope.seal(Data("secret request bytes".utf8),key:key,macId:mac,deviceId:device,id:id,epoch:epoch,direction:direction,kind:kind,now:now,lifetime:expiry,nonce:Data(repeating:1,count:12))
    }
    @Test func independentNodeRelayVectorMatchesKeysAADAndCiphertext()throws {
        let path=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/relay-vectors.json")
        let fixture=try WireJSON.object(Data(contentsOf:path));let fixtureKey=Data(base64Encoded:fixture["deviceKey"] as! String)!
        let raw=try WireJSON.data(fixture["envelope"] as! [String:Any]);let expected=try RelayEnvelope.decode(raw)
        let time=Date(timeIntervalSince1970:Double(expected.createdAt))
        #expect(try RelayEnvelope.directionKey(deviceKey:fixtureKey,macId:mac,deviceId:device,direction:"c2s").base64EncodedString()==fixture["c2s"] as? String)
        #expect(try RelayEnvelope.directionKey(deviceKey:fixtureKey,macId:mac,deviceId:device,direction:"s2c").base64EncodedString()==fixture["s2c"] as? String)
        #expect(try RelayEnvelope.phoneBearer(deviceKey:fixtureKey,macId:mac,deviceId:device)==fixture["phoneBearer"] as? String)
        #expect(try RelayEnvelope.phoneTokenHash(deviceKey:fixtureKey,macId:mac,deviceId:device)==fixture["phoneTokenHash"] as? String)
        #expect(try RelayEnvelope.accessTicket(macBearer:fixture["macBearer"] as! String,deviceKey:fixtureKey,macId:mac,deviceId:device)==fixture["authTicket"] as? String)
        #expect(String(data:expected.aad,encoding:.utf8)==fixture["aad"] as? String)
        #expect(try expected.open(key:fixtureKey,macId:mac,deviceId:device,epoch:expected.epoch,direction:"c2s",kinds:["command"],now:time)==Data((fixture["plaintext"] as! String).utf8))
        #expect(try RelayEnvelope.seal(Data((fixture["plaintext"] as! String).utf8),key:fixtureKey,macId:mac,deviceId:device,id:expected.id,epoch:expected.epoch,direction:"c2s",kind:"command",now:time,lifetime:30,nonce:Data(base64Encoded:expected.nonce))==expected)
    }
    @Test func relayAADTamperWrongRoutingAndEpochNeverDecrypt()throws {
        let original=try envelope()
        #expect(try original.open(key:key,macId:mac,deviceId:device,epoch:epoch,direction:"c2s",kinds:["command"],now:now)==Data("secret request bytes".utf8))
        var tampered=original;tampered.id="55555555-5555-4555-8555-555555555555"
        XCTAssertThrowsError(try tampered.open(key:key,macId:mac,deviceId:device,epoch:epoch,direction:"c2s",kinds:["command"],now:now))
        XCTAssertThrowsError(try original.open(key:key,macId:device,deviceId:device,epoch:epoch,direction:"c2s",kinds:["command"],now:now))
        XCTAssertThrowsError(try original.open(key:key,macId:mac,deviceId:device,epoch:id,direction:"c2s",kinds:["command"],now:now))
        XCTAssertThrowsError(try original.open(key:Data(repeating:8,count:32),macId:mac,deviceId:device,epoch:epoch,direction:"c2s",kinds:["command"],now:now))
        XCTAssertThrowsError(try original.open(key:key,macId:mac,deviceId:device,epoch:epoch,direction:"s2c",kinds:["response"],now:now))
    }
    @Test func relayFreshnessSizeAndCanonicalEncodingAreStrict()throws {
        let original=try envelope()
        XCTAssertThrowsError(try original.open(key:key,macId:mac,deviceId:device,epoch:epoch,direction:"c2s",kinds:["command"],now:now.addingTimeInterval(30)))
        XCTAssertThrowsError(try original.open(key:key,macId:mac,deviceId:device,epoch:epoch,direction:"c2s",kinds:["command"],now:now.addingTimeInterval(-11)))
        XCTAssertThrowsError(try envelope(expiry:31))
        var malformed=original;malformed.nonce += "\n"
        XCTAssertThrowsError(try malformed.open(key:key,macId:mac,deviceId:device,epoch:epoch,direction:"c2s",kinds:["command"],now:now))
        var upper=original;upper.macId="AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        XCTAssertThrowsError(try upper.validate(now:now))
        XCTAssertThrowsError(try RelayEnvelope.decode(Data(repeating:32,count:65537)))
        var object=try WireJSON.object(WireJSON.encoder.encode(original));object["createdAt"]=1800000000.5
        XCTAssertThrowsError(try RelayEnvelope.decode(WireJSON.data(object)))
        object["createdAt"]=true
        XCTAssertThrowsError(try RelayEnvelope.decode(WireJSON.data(object)))
    }
    @Test func configurationRequiresHTTPSAndAnIndependentCanonicalBearer()throws {
        #expect(try RelayConfiguration(url:"https://relay.example/path/",macBearer:Data(repeating:9,count:32).base64EncodedString()).endpoint.absoluteString=="https://relay.example/path/api/relay")
        XCTAssertThrowsError(try RelayConfiguration(url:"http://relay.example",macBearer:Data(repeating:9,count:32).base64EncodedString()))
        XCTAssertThrowsError(try RelayConfiguration(url:"https://user:password@relay.example",macBearer:Data(repeating:9,count:32).base64EncodedString()))
        XCTAssertThrowsError(try RelayConfiguration(url:"https://relay.example?secret=x",macBearer:Data(repeating:9,count:32).base64EncodedString()))
        XCTAssertThrowsError(try RelayConfiguration(url:"https://relay.example",macBearer:"bad"))
    }
    @MainActor @Test func freshOperationLookupIsDeviceAndDigestBoundAndCannotExecuteMutation()async throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:url)}
        let request=CommandRequest(id:id,action:"stop_manual",issuedAt:now,expiresAt:now.addingTimeInterval(30));let body=try WireJSON.encoder.encode(request)
        let journal=try MutationJournal(url:url);let executor=MutationExecutor(journal:journal);var effects=0
        let initial=await executor.execute(request,device:device,body:body,now:now,authorized:{true}){effects+=1;return CommandResponse(id:request.id,status:"ok")}
        #expect(initial.status=="ok", "initial: \(initial.message ?? initial.status)")
        var lookup=CommandRequest(id:UUID().uuidString.lowercased(),action:"operation_status",issuedAt:now,expiresAt:now.addingTimeInterval(30),operationId:id,bodyDigest:Data(SHA256.hash(data:body)).base64EncodedString())
        try lookup.validate(now:now)
        #expect(!lookup.isMutation)
        let result=await executor.execute(lookup,device:device,body:try WireJSON.encoder.encode(lookup),now:now,authorized:{true}){effects+=1;return CommandResponse(id:lookup.id,status:"error")}
        #expect(result.id==lookup.id);#expect(result.operationId==id);#expect(result.operationStatus=="ok");#expect(effects==1)
        let stolen=await executor.execute(lookup,device:mac,body:try WireJSON.encoder.encode(lookup),now:now,authorized:{true}){effects+=1;return CommandResponse(id:lookup.id,status:"ok")}
        #expect(stolen.status=="error");#expect(effects==1)
        lookup.bodyDigest=Data(repeating:0,count:32).base64EncodedString()
        let mismatch=await executor.execute(lookup,device:device,body:try WireJSON.encoder.encode(lookup),now:now,authorized:{true}){effects+=1;return CommandResponse(id:lookup.id,status:"ok")}
        #expect(mismatch.status=="error");#expect(effects==1)
        lookup.operationId=UUID().uuidString.lowercased()
        let missing=await executor.execute(lookup,device:device,body:try WireJSON.encoder.encode(lookup),now:now,authorized:{true}){effects+=1;return CommandResponse(id:lookup.id,status:"ok")}
        #expect(missing.operationStatus=="not_found");#expect(effects==1)
        lookup.bodyDigest="not a digest";XCTAssertThrowsError(try lookup.validate(now:now))
        var ordinary=request;ordinary.operationId=id;ordinary.bodyDigest=Data(repeating:0,count:32).base64EncodedString();XCTAssertThrowsError(try ordinary.validate(now:now))
    }
}
