import Foundation
import Testing
@testable import CompanionCore

@MainActor struct InternetSessionTests {
    private let mac = "11111111-1111-4111-8111-111111111111"
    private let device = "22222222-2222-4222-8222-222222222222"
    private let key = Data(repeating:0x42,count:32)
    private let now = Date(timeIntervalSince1970:1_793_357_000)
    private func make(authorized:@escaping()->Bool = {true}, execute:@escaping InternetSession.Executor = { r,_,_,_ in CommandResponse(id:r.id,status:"ok") }, register:@escaping (String,PushRegistration)throws->PushRegistrationAck = { _,r in try PushRegistrationAck(projectId:r.projectId,revision:r.revision,tokenHash:r.tokenHash) }, monotonic:@escaping()->TimeInterval = {0}) throws -> InternetSession {
        let approved=AuthorizedDevice(deviceId:device,name:"Fixture phone",key:key,approvedAt:now)
        let firebase=try FirebaseClientConfiguration(projectId:"keepresso-test",applicationId:"1:123456:android:abcdef",apiKey:"public-fixture-api-key",senderId:"123456")
        let config=try InternetConfiguration(endpointId:Data(repeating:3,count:32).base64EncodedString(),firebase:firebase)
        return try InternetSession(macId:mac,lookupDevice:{$0==approved.deviceId ? approved:nil},authorized:{id in id==approved.deviceId && authorized()},configuration:{config},execute:execute,registerPush:register,snapshot:{["capturedAt":WireJSON.iso(self.now)]},now:{self.now},monotonic:monotonic)
    }
    private func authenticate(_ session:InternetSession,clientKey:Data? = nil) async throws ->SealedChannel {
        let nonce=Data(repeating:5,count:32).base64EncodedString(),k=clientKey ?? key
        let challenge=try WireJSON.object(await session.receive(WireJSON.data(["type":"hello","version":1,"macId":mac,"deviceId":device,"clientNonce":nonce])))
        let transcript=WireCrypto.transcript(mac:mac,device:device,client:nonce,server:challenge["serverNonce"] as! String)
        let channel=SealedChannel(sendKey:WireCrypto.directionKey(deviceKey:k,transcript:transcript,direction:"c2s"),receiveKey:WireCrypto.directionKey(deviceKey:k,transcript:transcript,direction:"s2c"))
        let ready=try await session.receive(WireJSON.data(["type":"authenticate","proof":WireCrypto.hmac(key:k,text:"client\n"+transcript).base64EncodedString()]))
        let opened=try WireJSON.object(channel.open(WireJSON.decoder.decode(SealedRecord.self,from:ready)))
        #expect(opened["type"] as? String == "ready")
        #expect(opened["internet"] != nil)
        return channel
    }
    private func raw(_ action:String,id:String=UUID().uuidString.lowercased())throws->Data {
        try WireJSON.encoder.encode(CommandRequest(id:id,action:action,issuedAt:now,expiresAt:now.addingTimeInterval(30),durationMinutes:action=="start_manual" ? 15:nil))
    }
    private func send(_ data:Data,session:InternetSession,client:SealedChannel)async throws->[String:Any] {
        let record=try WireJSON.encoder.encode(client.seal(data))
        return try WireJSON.object(client.open(WireJSON.decoder.decode(SealedRecord.self,from:await session.receive(record))))
    }

    @Test func statusProofGatesMutationsAndExpiresWithoutLosingPairing()async throws {
        var clock=0.0,mutations=0
        let s=try make(execute:{r,_,_,_ in if r.isMutation{mutations+=1};return CommandResponse(id:r.id,status:"ok")},monotonic:{clock})
        let c=try await authenticate(s)
        #expect(try await send(raw("start_manual"),session:s,client:c)["status"] as? String == "error")
        #expect(mutations==0)
        #expect(try await send(raw("status"),session:s,client:c)["status"] as? String == "ok")
        #expect(try await send(raw("start_manual"),session:s,client:c)["status"] as? String == "ok")
        clock=16
        #expect(try await send(raw("start_manual"),session:s,client:c)["status"] as? String == "error")
        #expect(mutations==1 && s.ready)
    }
    @Test func unknownWrongKeyReplayAndOversizedRecordsCloseTheSession()async throws {
        let unknown=try make()
        do{_=try await unknown.receive(WireJSON.data(["type":"hello","version":1,"macId":mac,"deviceId":mac,"clientNonce":Data(repeating:1,count:32).base64EncodedString()]));Issue.record("unknown phone accepted")}catch{}
        let wrong=try make()
        do{_=try await authenticate(wrong,clientKey:Data(repeating:7,count:32));Issue.record("wrong key accepted")}catch{}
        #expect(!wrong.ready)
        let s=try make(),c=try await authenticate(s)
        let packet=try WireJSON.encoder.encode(c.seal(raw("status")))
        _=try await s.receive(packet)
        do{_=try await s.receive(packet);Issue.record("encrypted replay accepted")}catch{}
        #expect(!s.ready)
        do{_=try await make().receive(Data(count:65_537));Issue.record("oversized record accepted")}catch{}
    }
    @Test func simultaneousTransportsUseTheSameDurableMutationReservation()async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let executor=MutationExecutor(journal:try MutationJournal(url:directory.appendingPathComponent("journal.json")))
        var count=0
        let execute:InternetSession.Executor={r,d,b,valid in
            await executor.execute(r,device:d,body:b,now:self.now,authorized:valid){if r.isMutation{count+=1;await Task.yield()};return CommandResponse(id:r.id,status:"ok")}
        }
        let a=try make(execute:execute),b=try make(execute:execute)
        let ca=try await authenticate(a),cb=try await authenticate(b)
        _=try await send(raw("status"),session:a,client:ca);_=try await send(raw("status"),session:b,client:cb)
        let request=try raw("start_manual")
        let pa=try WireJSON.encoder.encode(ca.seal(request)),pb=try WireJSON.encoder.encode(cb.seal(request))
        async let ra=a.receive(pa);async let rb=b.receive(pb)
        _=try await (ra,rb)
        #expect(count==1)
    }
    @Test func revocationWhileAnActionIsSuspendedCannotReturnALateSuccess()async throws {
        var live=true,entered=false
        var release:CheckedContinuation<Void,Never>?
        let s=try make(authorized:{live},execute:{r,_,_,_ in
            if r.isMutation{entered=true;await withCheckedContinuation{release=$0}}
            return CommandResponse(id:r.id,status:"ok")
        })
        let c=try await authenticate(s);_=try await send(raw("status"),session:s,client:c)
        let packet=try WireJSON.encoder.encode(c.seal(raw("start_manual")))
        let task=Task{try await s.receive(packet)}
        while !entered{await Task.yield()}
        live=false;s.close();release?.resume()
        do{_=try await task.value;Issue.record("late revoked success returned")}catch{}
        #expect(!s.ready)
    }
    @Test func registrationIsAuthenticatedMaintenanceAndNeverANativeCommand()async throws {
        var nativeCalls=0,registered=0
        let s=try make(execute:{r,_,_,_ in nativeCalls+=1;return CommandResponse(id:r.id,status:"ok")},register:{d,r in
            #expect(d==device);registered+=1;return try PushRegistrationAck(projectId:r.projectId,revision:r.revision,tokenHash:r.tokenHash)
        })
        let c=try await authenticate(s),r=try PushRegistration(projectId:"keepresso-test",token:"fixture-token",revision:1)
        let reply=try await send(r.encoded(),session:s,client:c)
        #expect(reply["type"] as? String == "push_registered")
        #expect(registered==1 && nativeCalls==0)
        let wrong=try PushRegistration(projectId:"other-project",token:"fixture-token",revision:2)
        #expect(try await send(wrong.encoded(),session:s,client:c)["type"] as? String == "push_registration_error")
        #expect(registered==1 && nativeCalls==0)
    }
    @Test func foregroundEventsUseTheSameOrderedCipherWithoutBecomingCommands()async throws {
        let s=try make(),c=try await authenticate(s)
        let event=CompanionEvent(kind:"hourly",createdAt:now,title:"Fixture",body:"Synthetic notification")
        let record=try s.eventRecord(event)
        let object=try WireJSON.object(c.open(WireJSON.decoder.decode(SealedRecord.self,from:record)))
        #expect(object["type"] as? String == "event")
        #expect((object["event"] as? [String:Any])?["id"] as? String == event.id)
        #expect(try await send(raw("status"),session:s,client:c)["status"] as? String == "ok")
        s.close();#expect(throws:Error.self){try s.eventRecord(event)}
    }
}
