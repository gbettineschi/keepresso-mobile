import Foundation
import Testing
@testable import CompanionCore

@MainActor struct NotificationDeliveryTests {
    @Test func resolvingLaterQueuedEventDuringFirstSendPreventsItsHTTP() async throws {
        let f=FirebaseSenderTests(),first=try f.envelope(),second=try f.envelope()
        let directory=URL(fileURLWithPath:"/private/tmp").appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let queue=try NotificationOutbox(url:directory.appendingPathComponent("queue/data.json"))
        try queue.enqueue(first,kind:"hourly",now:f.date);try queue.enqueue(second,kind:"lid_awake",now:f.date)
        let pending=queue.due(devices:[first.deviceId],now:f.date)
        let registration=try PushRegistration(projectId:"keepresso-test",token:"fixture",revision:1)
        var release:CheckedContinuation<Void,Never>?,sent=0
        let sender=FirebaseSender(configuration:try f.config(),now:{f.date},http:{url,_,_ in
            if url.host=="oauth2.googleapis.com"{return FCMHTTPResponse(status:200,data:Data("{\"access_token\":\"fixture\",\"expires_in\":3600,\"token_type\":\"Bearer\"}".utf8))}
            sent+=1;await withCheckedContinuation{release=$0}
            return FCMHTTPResponse(status:200,data:Data())
        })
        let delivery=Task{try await NotificationDelivery.drain(pending,sender:sender,registration:{e in
            queue.existing(event:e.id,device:e.deviceId,now:f.date)==e ? registration:nil
        },completed:{e,_,result in try queue.completed(e,result:result,now:f.date)})}
        while release==nil{await Task.yield()}
        try queue.resolve(kinds:["lid_awake"],now:f.date)
        release?.resume();try await delivery.value
        #expect(sent==1);#expect(queue.due(devices:[first.deviceId],now:f.date).isEmpty)
    }
    @Test func resolvedDuringOAuthNeverReachesFCM() async throws {
        let f=FirebaseSenderTests(),event=try f.envelope()
        var current=true,posts=0,release:CheckedContinuation<Void,Never>?
        let sender=FirebaseSender(configuration:try f.config(),now:{f.date},http:{url,_,_ in
            if url.host=="oauth2.googleapis.com"{
                await withCheckedContinuation{release=$0}
                return FCMHTTPResponse(status:200,data:Data("{\"access_token\":\"fixture\",\"expires_in\":3600,\"token_type\":\"Bearer\"}".utf8))
            }
            posts+=1;return FCMHTTPResponse(status:200,data:Data())
        })
        let send=Task{await sender.send(event,token:"fixture",stillCurrent:{current})}
        while release==nil{await Task.yield()}
        current=false;release?.resume()
        #expect(await send.value == .cancelled);#expect(posts==0)
    }
    @Test(arguments:[CompanionError.unavailable,CompanionError.limit])
    func optionalPushStorageFailureDoesNotSuppressLiveDelivery(_ failure:CompanionError) {
        var bluetooth=0,internet=0,failures=0
        NotificationDelivery.live(enqueuePush:{throw failure},broadcast:{bluetooth+=1;internet+=1},pushFailed:{failures+=1})
        #expect(bluetooth==1 && internet==1 && failures==1)
    }
}
