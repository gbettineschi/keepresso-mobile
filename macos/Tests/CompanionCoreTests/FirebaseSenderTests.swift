import Foundation
import Testing
import Security
@testable import CompanionCore

@MainActor struct FirebaseSenderTests {
    let date=Date(timeIntervalSince1970:1_793_357_000)
    func config()throws->FirebaseSenderConfiguration {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let key=try String(contentsOf:root.appendingPathComponent("shared/fixtures/fcm-test-only-private.pem"),encoding:.utf8)
        return try FirebaseSenderConfiguration(client:FirebaseClientConfiguration(projectId:"keepresso-test",applicationId:"1:123456:android:abcdef",apiKey:"public-fixture",senderId:"123456"),projectId:"keepresso-test",clientEmail:"fixture@keepresso-test.iam.gserviceaccount.com",privateKey:key,privateKeyId:"fixture")
    }
    func envelope(body:String="Hello")throws->RelayEnvelope {
        try RelayEnvelope.seal(Data(body.utf8),key:Data(repeating:1,count:32),macId:"11111111-1111-4111-8111-111111111111",deviceId:"22222222-2222-4222-8222-222222222222",id:UUID().uuidString.lowercased(),epoch:"33333333-3333-4333-8333-333333333333",direction:"s2c",kind:"event",now:date,lifetime:300)
    }
    @Test func jwtIsRS256WithFixedAudienceAndScope()throws {
        let c=try config(),jwt=try c.assertion(now:date),parts=jwt.split(separator:".").map(String.init)
        #expect(parts.count==3)
        func unbase(_ s:String)->Data{Data(base64Encoded:s.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")+String(repeating:"=",count:(4-s.count%4)%4))!}
        let claims=try WireJSON.object(unbase(parts[1])),header=try WireJSON.object(unbase(parts[0]))
        #expect(header["alg"] as? String == "RS256")
        #expect(claims["aud"] as? String == "https://oauth2.googleapis.com/token")
        #expect(claims["scope"] as? String == "https://www.googleapis.com/auth/firebase.messaging")
        #expect((claims["exp"] as? Int64)==Int64(date.timeIntervalSince1970)+3600)
        let publicKey=try #require(SecKeyCopyPublicKey(c.signingKey()))
        #expect(SecKeyVerifySignature(publicKey,.rsaSignatureMessagePKCS1v15SHA256,Data((parts[0]+"."+parts[1]).utf8) as CFData,unbase(parts[2]) as CFData,nil))
        let encoded=try JSONEncoder().encode(c)
        var bad=try WireJSON.object(encoded);bad["projectId"]="wrong-project"
        #expect(throws:Error.self){try JSONDecoder().decode(FirebaseSenderConfiguration.self,from:WireJSON.data(bad))}
        let service=try WireJSON.data(["type":"service_account","project_id":c.projectId,"client_email":c.clientEmail,"private_key":c.privateKey,"token_uri":"https://attacker.example/token"])
        #expect(throws:Error.self){try FirebaseSenderConfiguration.importServiceAccount(service,client:c.client)}
    }
    @Test func tokenCacheFixedDestinationAndResponseClassification()async throws {
        var tokenCalls=0,sendCalls=0,status=200,clock=date
        let sender=FirebaseSender(configuration:try config(),now:{clock},http:{url,headers,body in
            if url.absoluteString == "https://oauth2.googleapis.com/token" {
                tokenCalls+=1
                return FCMHTTPResponse(status:200,data:Data("{\"access_token\":\"fixture-access\",\"expires_in\":3600,\"token_type\":\"Bearer\"}".utf8))
            }
            #expect(url.absoluteString == "https://fcm.googleapis.com/v1/projects/keepresso-test/messages:send")
            #expect(headers["Authorization"]=="Bearer fixture-access")
            let json=try WireJSON.object(body),message=json["message"] as! [String:Any]
            #expect((message["data"] as? [String:String])?["relayEnvelope"] != nil)
            #expect(body.count<=4096);sendCalls+=1
            return FCMHTTPResponse(status:status,data:status==404 ? Data( "{\"error\":{\"details\":[{\"errorCode\":\"UNREGISTERED\"}]}}".utf8):Data())
        })
        let e=try envelope()
        #expect(await sender.send(e,token:"fixture-token") == .accepted)
        #expect(await sender.send(e,token:"fixture-token") == .accepted)
        #expect(tokenCalls==1 && sendCalls==2)
        status=503;#expect(await sender.send(e,token:"fixture-token") == .transient)
        status=404;#expect(await sender.send(e,token:"fixture-token") == .unregistered)
        clock=date.addingTimeInterval(3601)
        #expect(try await sender.send(envelopeAt(clock),token:"fixture-token") == .unregistered)
        #expect(tokenCalls==2)
    }
    func envelopeAt(_ now:Date)throws->RelayEnvelope {
        var e=try envelope();e.createdAt=Int64(now.timeIntervalSince1970);e.expiresAt=e.createdAt+300;return e
    }
    @Test func byteBudgetsAndOriginalExpiryAreEnforcedBeforeHTTP()async throws {
        var calls=0
        let sender=FirebaseSender(configuration:try config(),now:{date},http:{_,_,_ in calls+=1;return FCMHTTPResponse(status:500,data:Data())})
        #expect(try await sender.send(envelope(body:String(repeating:"☕",count:1100)),token:"fixture") == .rejected)
        #expect(try await sender.send(envelope(),token:String(repeating:"x",count:4096)) == .rejected)
        var expired=try envelope();expired.expiresAt=Int64(date.timeIntervalSince1970)
        #expect(await sender.send(expired,token:"fixture") == .expired)
        #expect(calls==0)
    }
    @Test func temporaryOAuthFailureRetainsDeliveryForRetry()async throws {
        let sender=FirebaseSender(configuration:try config(),now:{date},http:{_,_,_ in FCMHTTPResponse(status:503,data:Data())})
        #expect(try await sender.send(envelope(),token:"fixture-token") == .transient)
    }
    @Test func independentSenderAndTokenStoragePersistAndRejectCorruption()throws {
        let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=FirebaseSenderStorage(url:root.appendingPathComponent("push/sender.json"))
        try store.save(config())
        #expect(try store.load()?.projectId=="keepresso-test")
        let device="22222222-2222-4222-8222-222222222222",url=root.appendingPathComponent("push/tokens.json")
        let registry=try PushTokenStorage(url:url),registration=try PushRegistration(projectId:"keepresso-test",token:"fixture",revision:2)
        #expect(try registry.register(registration,device:device).matches(registration))
        #expect(try PushTokenStorage(url:url).registration(device)==registration)
        #expect(throws:Error.self){try registry.register(PushRegistration(projectId:"keepresso-test",token:"older",revision:1),device:device)}
        try Data("invalid".utf8).write(to:url)
        #expect(throws:Error.self){try PushTokenStorage(url:url)}
        #expect(try store.load()?.client==config().client)
    }
}

@MainActor struct NotificationOutboxTests {
    @Test func persistenceRetriesKeepCiphertextAndNeverExtendExpiry()throws {
        let directory=URL(fileURLWithPath:"/private/tmp").appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let fixture=FirebaseSenderTests(),now=fixture.date,e=try fixture.envelope()
        let url=directory.appendingPathComponent("notifications/outbox.json")
        let queue=try NotificationOutbox(url:url)
        try queue.enqueue(e,kind:"hourly",now:now)
        #expect(queue.existing(event:e.id,device:e.deviceId,now:now)==e)
        #expect(try NotificationOutbox(url:url).due(devices:[e.deviceId],now:now).first==e)
        try queue.completed(e,result:.transient,now:now)
        #expect(queue.due(devices:[e.deviceId],now:now).isEmpty)
        #expect(queue.due(devices:[e.deviceId],now:now.addingTimeInterval(60)).first==e)
        try queue.completed(e,result:.unregistered,now:now.addingTimeInterval(60))
        #expect(queue.due(devices:[e.deviceId],now:now.addingTimeInterval(120)).isEmpty)
        try queue.tokenChanged(e.deviceId,now:now.addingTimeInterval(120))
        #expect(queue.due(devices:[e.deviceId],now:now.addingTimeInterval(121)).first==e)
        #expect(queue.due(devices:[e.deviceId],now:now.addingTimeInterval(301)).isEmpty)
        try queue.resolve(kinds:["hourly"],now:now)
        #expect(queue.due(devices:[e.deviceId],now:now).isEmpty)
    }
    @Test func capacityRevocationAndDuplicateOverlap()throws {
        let directory=URL(fileURLWithPath:"/private/tmp").appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let f=FirebaseSenderTests(),e=try f.envelope(),queue=try NotificationOutbox(url:directory.appendingPathComponent("outbox/data.json"))
        try queue.enqueue(e,kind:"hourly",now:f.date);try queue.enqueue(e,kind:"hourly",now:f.date)
        #expect(queue.due(devices:[e.deviceId],now:f.date).count==1)
        for _ in 1..<256{try queue.enqueue(f.envelope(),kind:"hourly",now:f.date)}
        #expect(throws:Error.self){try queue.enqueue(f.envelope(),kind:"hourly",now:f.date)}
        try queue.revoke(e.deviceId,now:f.date)
        #expect(queue.due(devices:[e.deviceId],now:f.date).isEmpty)
    }
}
