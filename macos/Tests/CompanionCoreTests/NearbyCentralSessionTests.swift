import Foundation
import Testing
@testable import CompanionCore

struct NearbyCentralSessionTests {
    // Premature readiness would let protocol bytes bypass subscription setup.
    @Test func discoveryMustFinishAndNotificationMustBeConfirmed() throws {
        let session=NearbyCentralSession(now:0)
        #expect(!session.ready)
        #expect(throws: (any Error).self) { try session.advance(to:.ready,now:1) }
        try session.advance(to:.services,now:1)
        try session.advance(to:.characteristics,now:2)
        try session.advance(to:.subscribing,now:3)
        #expect(!session.ready)
        try session.advance(to:.ready,now:4)
        #expect(session.ready)
        #expect(!session.authorized)
        try session.authenticate()
        #expect(session.authorized)
    }
    // Removing generation checks revives authority after disconnect/revoke/sleep.
    @Test func invalidationClosesAuthorityAndRejectsOldCallbacks() throws {
        for _ in ["disconnect","revoke","stop","sleep"] {
            let session=try readySession()
            let token=session.generation
            try session.authenticate()
            session.invalidate()
            #expect(!session.accepts(token))
            #expect(!session.authorized)
            #expect(throws: (any Error).self) { try session.authenticate() }
            #expect(throws: (any Error).self) { try session.advance(to:.ready,now:5) }
            let replacement=try readySession()
            #expect(!replacement.accepts(token))
        }
    }
    @Test func stalledDiscoveryExpiresButReadySessionHasNoSetupDeadline() throws {
        let connecting=NearbyCentralSession(now:0)
        #expect(!connecting.expired(now:14))
        #expect(connecting.expired(now:15))
        try connecting.advance(to:.services,now:14)
        #expect(!connecting.expired(now:28))
        #expect(connecting.expired(now:29))
        #expect(try !readySession().expired(now:1000))
    }
    // A second take before ACK would violate write-with-response ordering.
    @Test func writesAdvanceOnlyAfterAcknowledgement() throws {
        let queue=NearbyAcknowledgedWrites()
        try queue.enqueue(record:Data("abc".utf8),mtu:4)
        #expect(queue.take(now:0)==Data([0,0,0,3]))
        #expect(queue.take(now:1)==nil)
        #expect(queue.bytes==7)
        try queue.acknowledge(success:true,now:2)
        #expect(queue.bytes==3)
        #expect(queue.take(now:2)==Data("abc".utf8))
        try queue.acknowledge(success:true,now:2)
        #expect(queue.take(now:3)==nil)
    }
    @Test func failedOrTimedOutWriteNeverReplaysQueuedData() throws {
        for timeout in [false,true] {
            let queue=NearbyAcknowledgedWrites()
            try queue.enqueue(record:Data("abc".utf8),mtu:4)
            _=queue.take(now:0)
            if timeout {
                #expect(!queue.expired(now:9))
                #expect(queue.expired(now:10))
                queue.invalidate()
            } else {
                #expect(throws: (any Error).self) { try queue.acknowledge(success:false,now:2) }
            }
            #expect(queue.bytes==0)
            #expect(queue.take(now:11)==nil)
            #expect(throws: (any Error).self) { try queue.enqueue(record:Data("x".utf8),mtu:4) }
        }
    }
    @Test func boundedQueueRejectsExcessWithoutDroppingAcceptedBytes() throws {
        let queue=NearbyAcknowledgedWrites()
        let record=Data(repeating:65,count:65536)
        for _ in 0..<3 { try queue.enqueue(record:record,mtu:512) }
        #expect(queue.bytes==196620)
        #expect(throws: (any Error).self) { try queue.enqueue(record:record,mtu:512) }
        #expect(queue.bytes==196620)
        #expect(queue.take(now:0)?.count==512)
    }
    @Test func lateAcknowledgementCannotReviveTimedOutWrites() throws {
        let queue=NearbyAcknowledgedWrites()
        try queue.enqueue(record:Data("abc".utf8),mtu:4)
        _=queue.take(now:0)
        #expect(throws: (any Error).self) { try queue.acknowledge(success:true,now:10) }
        #expect(queue.bytes==0)
        #expect(queue.take(now:11)==nil)
    }
    @Test func oldManagerCallbacksCannotReenterAfterStopOrRestart() {
        let lifetime=NearbyCentralLifetime()
        let original=lifetime.begin()
        #expect(lifetime.accepts(original))
        lifetime.end()
        #expect(!lifetime.accepts(original))
        let replacement=lifetime.begin()
        #expect(!lifetime.accepts(original))
        #expect(lifetime.accepts(replacement))
    }
    @MainActor @Test func disconnectedPeerCannotCompleteSleepOrReplayUncertainMutation() async throws {
        let peer=try readySession();try peer.authenticate()
        var stops=0,sleeps=0
        let result=await SafeSleep.perform(id:"fixture",authorized:{peer.authorized},state:{
            peer.invalidate();return SleepPreparationState(stopped:true,sleepDisabled:false)
        },stop:{stops+=1},requestSleep:{sleeps+=1;return .willSleep},wait:{})
        #expect(result.status=="error");#expect(stops==0);#expect(sleeps==0)

        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:url)}
        let journal=try MutationJournal(url:url),executor=MutationExecutor(journal:journal)
        let now=Date()
        let request=CommandRequest(id:UUID().uuidString.lowercased(),action:"stop_manual",issuedAt:now,expiresAt:now.addingTimeInterval(30))
        let body=try WireJSON.encoder.encode(request)
        let connection=try readySession();try connection.authenticate()
        var effects=0
        let first=await executor.execute(request,device:"fixture",body:body,now:now,authorized:{connection.authorized}){
            effects+=1;await Task.yield();connection.invalidate()
            return CommandResponse(id:request.id,status:"ok")
        }
        #expect(first.status=="uncertain", "\(first.message ?? "no response message")")
        let replacement=try readySession();try replacement.authenticate()
        let duplicate=await executor.execute(request,device:"fixture",body:body,now:now,authorized:{replacement.authorized}){
            effects+=1;return CommandResponse(id:request.id,status:"ok")
        }
        #expect(duplicate.status=="uncertain");#expect(effects==1)
    }
    @Test func earlyHelloWaitsForNotificationConfirmation() throws {
        let session=NearbyCentralSession(now:0)
        for stage in [NearbyCentralSession.Stage.services,.characteristics,.subscribing]{try session.advance(to:stage,now:1)}
        let hello=Data("{\"type\":\"hello\"}".utf8)
        #expect(try session.receiveRecord(hello).isEmpty)
        #expect(session.takeBufferedRecords().isEmpty)
        #expect(!session.authorized)
        #expect(throws: (any Error).self){try session.authenticate()}
        try session.advance(to:.ready,now:2)
        #expect(session.takeBufferedRecords()==[hello])
        #expect(session.takeBufferedRecords().isEmpty)
        #expect(try session.receiveRecord(Data("next".utf8))==[Data("next".utf8)])
    }
    @Test func earlyInputIsBoundedAndInvalidationDiscardsIt() throws {
        let session=NearbyCentralSession(now:0)
        #expect(throws: (any Error).self){try session.receiveRecord(Data("early".utf8))}
        for stage in [NearbyCentralSession.Stage.services,.characteristics,.subscribing]{try session.advance(to:stage,now:1)}
        for _ in 0..<8{_ = try session.receiveRecord(Data("hello".utf8))}
        #expect(throws: (any Error).self){try session.receiveRecord(Data("overflow".utf8))}
        session.invalidate()
        #expect(session.takeBufferedRecords().isEmpty)
        #expect(throws: (any Error).self){try session.receiveRecord(Data("late".utf8))}
    }
    private func readySession() throws -> NearbyCentralSession {
        let session=NearbyCentralSession(now:0)
        for stage in [NearbyCentralSession.Stage.services,.characteristics,.subscribing,.ready] { try session.advance(to:stage,now:1) }
        return session
    }
}
