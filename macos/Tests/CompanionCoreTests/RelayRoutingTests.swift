import Foundation
import Testing
@testable import CompanionCore

@MainActor private final class RelayFakeAPI:RelayAPI {
    var enrollments:[String]=[];var batches:[RelayBatch]=[];var commands:[RelayEnvelope]=[]
    var retryEvents:Set<String>=[];var fail=false;var duringSync:(()->Void)?
    func enroll(macId:String,deviceId:String,tokenHash:String)async throws {enrollments.append(deviceId)}
    func revoke(macId:String,deviceId:String)async throws {}
    func sync(_ batch:RelayBatch)async throws->RelaySyncResult {batches.append(batch);duringSync?();if fail{throw CompanionError.unavailable};return RelaySyncResult(commands:commands,retryEvents:retryEvents)}
}
@MainActor private final class RelayTestClock {var wall=Date(timeIntervalSince1970:1800000000);var mono:TimeInterval=100;func advance(_ seconds:TimeInterval){wall+=seconds;mono+=seconds}}

struct RelayRoutingTests {
    let mac="11111111-1111-4111-8111-111111111111",device="22222222-2222-4222-8222-222222222222"
    @MainActor @Test func nearbyDeviceHasNoRelaySnapshotAndDisconnectPublishesImmediately()async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let api=RelayFakeAPI(),clock=RelayTestClock();var nearby:Set<String>=[device];var effects=0
        let paired=AuthorizedDevice(deviceId:device,name:"Fixture",key:Data(repeating:7,count:32),approvedAt:clock.wall)
        let coordinator=try RelayCoordinator(macId:mac,api:api,outbox:RelayOutbox(url:directory.appendingPathComponent("outbox")),devices:{[paired]},nearby:{nearby},snapshot:{["capturedAt":WireJSON.iso(clock.wall)]},execute:{r,_,_,_ in effects+=1;return CommandResponse(id:r.id,status:"ok")},now:{clock.wall},monotonic:{clock.mono})
        await coordinator.tick()
        #expect(api.enrollments==[device]);#expect(api.batches.count==1);#expect(api.batches[0].states.isEmpty)
        nearby=[];coordinator.nearbyChanged();await coordinator.tick()
        #expect(api.batches.count==2);#expect(api.batches[1].states.count==1)
        clock.advance(5);await coordinator.tick();#expect(api.batches.last!.states.isEmpty)
        clock.advance(5);await coordinator.tick();#expect(api.batches.last!.states.count==1);#expect(effects==0)
    }
    @MainActor @Test func gapDuringAwaitRotatesEpochAndDiscardsReturnedMutationBeforeExecution()async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let api=RelayFakeAPI(),clock=RelayTestClock();var effects=0
        let paired=AuthorizedDevice(deviceId:device,name:"Fixture",key:Data(repeating:7,count:32),approvedAt:clock.wall)
        let coordinator=try RelayCoordinator(macId:mac,api:api,outbox:RelayOutbox(url:directory.appendingPathComponent("outbox")),devices:{[paired]},nearby:{[]},snapshot:{["capturedAt":WireJSON.iso(clock.wall)]},execute:{r,_,_,_ in effects+=1;return CommandResponse(id:r.id,status:"ok")},now:{clock.wall},monotonic:{clock.mono})
        await coordinator.tick();let epoch=coordinator.epoch
        let request=CommandRequest(id:UUID().uuidString.lowercased(),action:"stop_manual",issuedAt:clock.wall,expiresAt:clock.wall.addingTimeInterval(30))
        api.commands=[try RelayEnvelope.seal(WireJSON.encoder.encode(request),key:paired.key,macId:mac,deviceId:device,id:request.id,epoch:epoch,direction:"c2s",kind:"command",now:clock.wall,lifetime:30)]
        clock.advance(5);api.duringSync={clock.advance(16)}
        await coordinator.tick()
        #expect(coordinator.epoch != epoch);#expect(effects==0)
        api.duringSync=nil;await coordinator.tick();#expect(effects==0);#expect(api.batches.last!.epoch==coordinator.epoch)
    }
    @MainActor @Test func eventIsDurableBeforeTransmissionAndRetryRetainsExactEnvelope()async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let api=RelayFakeAPI(),clock=RelayTestClock()
        let paired=AuthorizedDevice(deviceId:device,name:"Fixture",key:Data(repeating:7,count:32),approvedAt:clock.wall)
        let url=directory.appendingPathComponent("outbox");let outbox=try RelayOutbox(url:url)
        let coordinator=try RelayCoordinator(macId:mac,api:api,outbox:outbox,devices:{[paired]},nearby:{[]},snapshot:{["capturedAt":WireJSON.iso(clock.wall)]},execute:{r,_,_,_ in CommandResponse(id:r.id,status:"ok")},now:{clock.wall},monotonic:{clock.mono})
        await coordinator.tick()
        let event=CompanionEvent(kind:"thermal",createdAt:clock.wall,title:"Fixture warning",body:"Fixture",scheduledEnd:nil,snoozedUntil:nil)
        try coordinator.enqueue(event)
        let persisted=try RelayOutbox(url:url)
        #expect(persisted.events(now:clock.wall).first?.id==event.id)
        api.fail=true;clock.advance(5);await coordinator.tick();let attempted=api.batches.last!.events.first!
        api.fail=false;clock.advance(5);await coordinator.tick()
        #expect(api.batches.last!.events.first==attempted)
        clock.advance(5);await coordinator.tick();#expect(api.batches.last!.events.isEmpty)
        #expect(try RelayOutbox(url:url).events(now:clock.wall).first?.id==event.id)
        clock.advance(301);coordinator.nearbyChanged();await coordinator.tick();#expect(outbox.events(now:clock.wall).isEmpty)
    }
    @Test func revokeTombstoneSurvivesRestartAndStaysBlockedWhenPersistenceFails()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("revoked");let tombstones=try DeviceRevocations(url:url)
        try tombstones.revoke(device);#expect(tombstones.contains(device));#expect(try DeviceRevocations(url:url).contains(device))
        try FileManager.default.removeItem(at:url);try FileManager.default.removeItem(at:directory);try Data().write(to:directory)
        let other="33333333-3333-4333-8333-333333333333"
        XCTAssertThrowsError(try tombstones.revoke(other));#expect(tombstones.contains(other))
    }
}

extension RelayRoutingTests {
    @MainActor @Test func mutationRequiresStatusResponseRoundTripAndDuplicateTransportUsesOneJournal()async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let api=RelayFakeAPI(),clock=RelayTestClock();var effects=0
        let paired=AuthorizedDevice(deviceId:device,name:"Fixture",key:Data(repeating:7,count:32),approvedAt:clock.wall)
        let executor=MutationExecutor(journal:try MutationJournal(url:directory.appendingPathComponent("journal")))
        let coordinator=try RelayCoordinator(macId:mac,api:api,outbox:RelayOutbox(url:directory.appendingPathComponent("outbox")),devices:{[paired]},nearby:{[]},snapshot:{["capturedAt":WireJSON.iso(clock.wall)]},execute:{r,d,b,rejection in await executor.execute(r,device:d,body:b,now:clock.wall,authorized:{true},rejection:rejection){if r.isMutation{effects+=1};return CommandResponse(id:r.id,status:"ok")}},now:{clock.wall},monotonic:{clock.mono})
        await coordinator.tick()
        func command(_ action:String)throws->(CommandRequest,Data,RelayEnvelope){let r=CommandRequest(id:UUID().uuidString.lowercased(),action:action,issuedAt:clock.wall,expiresAt:clock.wall.addingTimeInterval(30));let b=try WireJSON.encoder.encode(r);return(r,b,try RelayEnvelope.seal(b,key:paired.key,macId:mac,deviceId:device,id:r.id,epoch:coordinator.epoch,direction:"c2s",kind:"command",now:clock.wall,lifetime:30))}
        let blocked=try command("stop_manual");api.commands=[blocked.2];clock.advance(5);await coordinator.tick();#expect(effects==0)
        let blockedDuplicate=await executor.execute(blocked.0,device:device,body:blocked.1,now:clock.wall,authorized:{true}){effects+=1;return CommandResponse(id:blocked.0.id,status:"ok")}
        #expect(blockedDuplicate.status=="error");#expect(effects==0)
        let status=try command("status");api.commands=[status.2];clock.advance(5);await coordinator.tick()
        api.commands=[];clock.advance(5);await coordinator.tick()
        let mutation=try command("stop_manual");api.commands=[mutation.2];clock.advance(5);await coordinator.tick();#expect(effects==1)
        // The exact same body can arrive over BLE after a relay timeout. Both
        // adapters feed this executor, so the durable reservation wins.
        let duplicate=await executor.execute(mutation.0,device:device,body:mutation.1,now:clock.wall,authorized:{true}){effects+=1;return CommandResponse(id:mutation.0.id,status:"ok")}
        #expect(duplicate.status=="ok");#expect(effects==1)
        clock.advance(5);await coordinator.tick();#expect(effects==1)
    }
    @MainActor @Test func revokedDuringSyncAndMismatchedInnerIDCannotReachExecutor()async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let api=RelayFakeAPI(),clock=RelayTestClock();var effects=0
        let paired=AuthorizedDevice(deviceId:device,name:"Fixture",key:Data(repeating:7,count:32),approvedAt:clock.wall);var devices=[paired]
        let coordinator=try RelayCoordinator(macId:mac,api:api,outbox:RelayOutbox(url:directory.appendingPathComponent("outbox")),devices:{devices},nearby:{[]},snapshot:{["capturedAt":WireJSON.iso(clock.wall)]},execute:{r,_,_,_ in effects+=1;return CommandResponse(id:r.id,status:"ok")},now:{clock.wall},monotonic:{clock.mono})
        await coordinator.tick()
        let request=CommandRequest(id:UUID().uuidString.lowercased(),action:"status",issuedAt:clock.wall,expiresAt:clock.wall.addingTimeInterval(30))
        api.commands=[try RelayEnvelope.seal(WireJSON.encoder.encode(request),key:paired.key,macId:mac,deviceId:device,id:UUID().uuidString.lowercased(),epoch:coordinator.epoch,direction:"c2s",kind:"command",now:clock.wall,lifetime:30)]
        clock.advance(5);await coordinator.tick();#expect(effects==0)
        api.commands=[try RelayEnvelope.seal(WireJSON.encoder.encode(request),key:paired.key,macId:mac,deviceId:device,id:request.id,epoch:coordinator.epoch,direction:"c2s",kind:"command",now:clock.wall,lifetime:30)]
        api.duringSync={devices=[]};clock.advance(5);await coordinator.tick();#expect(effects==0)
        api.duringSync=nil;clock.advance(5);await coordinator.tick();#expect(api.batches.last!.states.isEmpty)
    }
    @MainActor @Test func restartRetainsUnexpiredImmutableNotificationFromPreviousEpoch()async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let api=RelayFakeAPI(),clock=RelayTestClock();let paired=AuthorizedDevice(deviceId:device,name:"Fixture",key:Data(repeating:7,count:32),approvedAt:clock.wall)
        let url=directory.appendingPathComponent("outbox")
        func make()throws->RelayCoordinator {try RelayCoordinator(macId:mac,api:api,outbox:RelayOutbox(url:url),devices:{[paired]},nearby:{[]},snapshot:{["capturedAt":WireJSON.iso(clock.wall)]},execute:{r,_,_,_ in CommandResponse(id:r.id,status:"ok")},now:{clock.wall},monotonic:{clock.mono})}
        let first=try make();await first.tick()
        let event=CompanionEvent(kind:"thermal",createdAt:clock.wall,title:"Fixture warning",body:"Fixture",scheduledEnd:nil,snoozedUntil:nil)
        try first.enqueue(event);api.fail=true;clock.advance(5);await first.tick();let attempted=api.batches.last!.events.first!
        first.stop();api.fail=false;clock.advance(1);let second=try make();await second.tick()
        #expect(second.epoch != attempted.epoch);#expect(api.batches.last!.events.first==attempted)
    }
}


extension RelayRoutingTests {
    @MainActor @Test func transientPushFailureRetainsImmutableEventWhileCommandPollingContinues()async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let api=RelayFakeAPI(),clock=RelayTestClock();var reads=0
        let paired=AuthorizedDevice(deviceId:device,name:"Fixture",key:Data(repeating:7,count:32),approvedAt:clock.wall)
        let coordinator=try RelayCoordinator(macId:mac,api:api,outbox:RelayOutbox(url:directory.appendingPathComponent("outbox")),devices:{[paired]},nearby:{[]},snapshot:{["capturedAt":WireJSON.iso(clock.wall)]},execute:{r,_,_,_ in reads+=1;return CommandResponse(id:r.id,status:"ok")},now:{clock.wall},monotonic:{clock.mono})
        await coordinator.tick()
        let event=CompanionEvent(kind:"thermal",createdAt:clock.wall,title:"Fixture warning",body:"Fixture",scheduledEnd:nil,snoozedUntil:nil)
        try coordinator.enqueue(event);api.retryEvents=[event.id]
        let request=CommandRequest(id:UUID().uuidString.lowercased(),action:"status",issuedAt:clock.wall,expiresAt:clock.wall.addingTimeInterval(30))
        api.commands=[try RelayEnvelope.seal(WireJSON.encoder.encode(request),key:paired.key,macId:mac,deviceId:device,id:request.id,epoch:coordinator.epoch,direction:"c2s",kind:"command",now:clock.wall,lifetime:30)]
        clock.advance(5);await coordinator.tick();let attempted=api.batches.last!.events.first!
        #expect(reads==1)
        api.commands=[];clock.advance(5);await coordinator.tick();#expect(api.batches.last!.events.first==attempted)
        api.retryEvents=[];clock.advance(5);await coordinator.tick();#expect(api.batches.last!.events.first==attempted)
        clock.advance(5);await coordinator.tick();#expect(api.batches.last!.events.isEmpty)
    }
}

extension RelayRoutingTests {
    @MainActor @Test func foregroundStatusChecksSpeedSnapshotsWithoutPermanentFasterWrites()async throws{
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let api=RelayFakeAPI(),clock=RelayTestClock()
        let paired=AuthorizedDevice(deviceId:device,name:"Fixture",key:Data(repeating:7,count:32),approvedAt:clock.wall)
        let coordinator=try RelayCoordinator(macId:mac,api:api,outbox:RelayOutbox(url:directory.appendingPathComponent("outbox")),devices:{[paired]},nearby:{[]},snapshot:{["capturedAt":WireJSON.iso(clock.wall)]},execute:{r,_,_,_ in CommandResponse(id:r.id,status:"ok")},now:{clock.wall},monotonic:{clock.mono})
        await coordinator.tick()
        let request=CommandRequest(id:UUID().uuidString.lowercased(),action:"status",issuedAt:clock.wall,expiresAt:clock.wall.addingTimeInterval(30))
        api.commands=[try RelayEnvelope.seal(WireJSON.encoder.encode(request),key:paired.key,macId:mac,deviceId:device,id:request.id,epoch:coordinator.epoch,direction:"c2s",kind:"command",now:clock.wall,lifetime:30)]
        clock.advance(5);await coordinator.tick();api.commands=[]
        clock.advance(1);await coordinator.tick();#expect(api.batches.last!.states.count==1)
        for _ in 0..<12{clock.advance(5);await coordinator.tick();#expect(api.batches.last!.states.count==1)}
        clock.advance(5);await coordinator.tick();#expect(api.batches.last!.states.isEmpty)
        clock.advance(5);await coordinator.tick();#expect(api.batches.last!.states.count==1)
    }
    @MainActor @Test func persistedCommandResponseUploadsOnNextTimerTickBeforeFiveSecondPoll()async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let api=RelayFakeAPI(),clock=RelayTestClock();var reads=0
        let paired=AuthorizedDevice(deviceId:device,name:"Fixture",key:Data(repeating:7,count:32),approvedAt:clock.wall)
        let coordinator=try RelayCoordinator(macId:mac,api:api,outbox:RelayOutbox(url:directory.appendingPathComponent("outbox")),devices:{[paired]},nearby:{[]},snapshot:{["capturedAt":WireJSON.iso(clock.wall)]},execute:{r,_,_,_ in reads+=1;return CommandResponse(id:r.id,status:"ok")},now:{clock.wall},monotonic:{clock.mono})
        await coordinator.tick()
        let request=CommandRequest(id:UUID().uuidString.lowercased(),action:"status",issuedAt:clock.wall,expiresAt:clock.wall.addingTimeInterval(30))
        api.commands=[try RelayEnvelope.seal(WireJSON.encoder.encode(request),key:paired.key,macId:mac,deviceId:device,id:request.id,epoch:coordinator.epoch,direction:"c2s",kind:"command",now:clock.wall,lifetime:30)]
        clock.advance(5);await coordinator.tick();#expect(reads==1);#expect(api.batches.count==2)
        api.commands=[];clock.advance(1);await coordinator.tick()
        #expect(api.batches.count==3);#expect(api.batches.last!.responses.first?.id==request.id);#expect(reads==1)
    }
}

// The fake replaces only the bounded observer operation; routing, encryption,
// durable responses and snapshot capture use the real coordinator/outbox.
@MainActor private final class SuspendedRelayRead {
    var started:[String]=[];var cancelled:[String]=[]
    private var pending:[String:CheckedContinuation<Void,Never>]=[:]
    func run(_ request:CommandRequest)async->CommandResponse {
        started.append(request.id)
        await withCheckedContinuation{pending[request.id]=$0}
        if Task.isCancelled{cancelled.append(request.id)}
        return CommandResponse(id:request.id,status:"ok")
    }
    func release(){let waits=Array(pending.values);pending=[:];for wait in waits{wait.resume()}}
}
@MainActor private func settleRelayTasks()async {for _ in 0..<40{await Task.yield()}}

extension RelayRoutingTests {
    @MainActor @Test func suspendedTriggerReadAllowsFreshTelemetryAndDuplicateDoesNotExecuteTwice()async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let api=RelayFakeAPI(),clock=RelayTestClock(),read=SuspendedRelayRead()
        let paired=AuthorizedDevice(deviceId:device,name:"Fixture",key:Data(repeating:7,count:32),approvedAt:clock.wall)
        let outbox=try RelayOutbox(url:directory.appendingPathComponent("outbox"))
        let coordinator=try RelayCoordinator(macId:mac,api:api,outbox:outbox,devices:{[paired]},nearby:{[]},snapshot:{["capturedAt":WireJSON.iso(clock.wall)]},execute:{r,_,_,_ in await read.run(r)},now:{clock.wall},monotonic:{clock.mono})
        await coordinator.tick()
        let request=CommandRequest(id:UUID().uuidString.lowercased(),action:"refresh_triggers",issuedAt:clock.wall,expiresAt:clock.wall.addingTimeInterval(30))
        let body=try WireJSON.encoder.encode(request)
        api.commands=[try RelayEnvelope.seal(body,key:paired.key,macId:mac,deviceId:device,id:request.id,epoch:coordinator.epoch,direction:"c2s",kind:"command",now:clock.wall,lifetime:30)]
        clock.advance(5);let accepting=Task{await coordinator.tick()};await settleRelayTasks()
        #expect(read.started==[request.id])
        clock.advance(5);await coordinator.tick()
        #expect(api.batches.count==3,"A suspended explicit check must not hold the polling busy flag")
        if api.batches.count==3 {
            #expect(api.batches[2].states.count==1)
            let state=try api.batches[2].states[0].open(key:paired.key,macId:mac,deviceId:device,epoch:coordinator.epoch,direction:"s2c",kinds:["state"],now:clock.wall)
            let snapshot=try WireJSON.object(state)["snapshot"] as? [String:Any]
            #expect(snapshot?["capturedAt"] as? String==WireJSON.iso(clock.wall))
        }
        #expect(read.started==[request.id])
        api.commands=[];read.release();await accepting.value;await settleRelayTasks()
        clock.advance(1);await coordinator.tick()
        #expect(api.batches.last?.responses.first?.id==request.id)
        #expect(read.started==[request.id])
        coordinator.stop()
    }

    @MainActor @Test(arguments:["stop","wake","revoke","authorization_removed"])
    func suspendedTriggerReadIsCancelledAndLateOutputRejected(_ lifecycle:String)async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let api=RelayFakeAPI(),clock=RelayTestClock(),read=SuspendedRelayRead()
        let paired=AuthorizedDevice(deviceId:device,name:"Fixture",key:Data(repeating:7,count:32),approvedAt:clock.wall);var approved=[paired]
        let outbox=try RelayOutbox(url:directory.appendingPathComponent("outbox"))
        let coordinator=try RelayCoordinator(macId:mac,api:api,outbox:outbox,devices:{approved},nearby:{[]},snapshot:{[:]},execute:{r,_,_,_ in await read.run(r)},now:{clock.wall},monotonic:{clock.mono})
        await coordinator.tick()
        let request=CommandRequest(id:UUID().uuidString.lowercased(),action:"refresh_triggers",issuedAt:clock.wall,expiresAt:clock.wall.addingTimeInterval(30));let epoch=coordinator.epoch
        api.commands=[try RelayEnvelope.seal(WireJSON.encoder.encode(request),key:paired.key,macId:mac,deviceId:device,id:request.id,epoch:epoch,direction:"c2s",kind:"command",now:clock.wall,lifetime:30)]
        clock.advance(5);let accepting=Task{await coordinator.tick()};await settleRelayTasks()
        #expect(read.started==[request.id]);api.commands=[]
        switch lifecycle {
        case "stop":coordinator.stop()
        case "wake":coordinator.wake()
        case "revoke":approved=[];await coordinator.revoke(device)
        default:approved=[];clock.advance(5);await coordinator.tick()
        }
        read.release();await accepting.value;await settleRelayTasks()
        #expect(read.cancelled==[request.id])
        #expect(try outbox.response(id:request.id,deviceId:device,epoch:epoch,body:WireJSON.encoder.encode(request),now:clock.wall)==nil)
        coordinator.stop()
    }
}

extension RelayRoutingTests {
    @MainActor @Test func inFlightTriggerIdentityMismatchIsDroppedAndCompetingCheckRejectedWithoutQueue()async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let api=RelayFakeAPI(),clock=RelayTestClock(),read=SuspendedRelayRead();var statusReads=0
        let paired=AuthorizedDevice(deviceId:device,name:"Fixture",key:Data(repeating:7,count:32),approvedAt:clock.wall)
        let outbox=try RelayOutbox(url:directory.appendingPathComponent("outbox"))
        let coordinator=try RelayCoordinator(macId:mac,api:api,outbox:outbox,devices:{[paired]},nearby:{[]},snapshot:{[:]},execute:{r,_,_,_ in if r.action=="refresh_triggers"{return await read.run(r)};statusReads+=1;return CommandResponse(id:r.id,status:"ok")},now:{clock.wall},monotonic:{clock.mono})
        await coordinator.tick()
        func seal(_ request:CommandRequest)throws->RelayEnvelope {try RelayEnvelope.seal(WireJSON.encoder.encode(request),key:paired.key,macId:mac,deviceId:device,id:request.id,epoch:coordinator.epoch,direction:"c2s",kind:"command",now:clock.wall,lifetime:30)}
        let original=CommandRequest(id:UUID().uuidString.lowercased(),action:"refresh_triggers",issuedAt:clock.wall,expiresAt:clock.wall.addingTimeInterval(30))
        api.commands=[try seal(original)];clock.advance(5);let accepting=Task{await coordinator.tick()};await settleRelayTasks()
        let mismatched=CommandRequest(id:original.id,action:"status",issuedAt:original.issuedAt,expiresAt:original.expiresAt)
        let competing=CommandRequest(id:UUID().uuidString.lowercased(),action:"refresh_triggers",issuedAt:clock.wall,expiresAt:clock.wall.addingTimeInterval(30))
        let status=CommandRequest(id:UUID().uuidString.lowercased(),action:"status",issuedAt:clock.wall,expiresAt:clock.wall.addingTimeInterval(30))
        api.commands=[try seal(mismatched),try seal(competing),try seal(status)];clock.advance(5);await coordinator.tick()
        #expect(read.started==[original.id]);#expect(statusReads==1)
        let rejected=try outbox.response(id:competing.id,deviceId:device,epoch:coordinator.epoch,body:WireJSON.encoder.encode(competing),now:clock.wall)
        #expect(rejected != nil)
        if let rejected {
            let object=try WireJSON.object(rejected.open(key:paired.key,macId:mac,deviceId:device,epoch:coordinator.epoch,direction:"s2c",kinds:["response"],now:clock.wall))
            #expect(object["status"] as? String=="error")
        }
        api.commands=[];read.release();await accepting.value;await settleRelayTasks();coordinator.stop()
        #expect(read.started==[original.id])
    }

    @MainActor @Test(arguments:[14.0,3.0])
    func triggerReadDeadlineCancelsUncooperativeWorkAndRejectsLateSuccess(_ validity:TimeInterval)async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let api=RelayFakeAPI(),clock=RelayTestClock(),read=SuspendedRelayRead()
        let paired=AuthorizedDevice(deviceId:device,name:"Fixture",key:Data(repeating:7,count:32),approvedAt:clock.wall)
        let outbox=try RelayOutbox(url:directory.appendingPathComponent("outbox"))
        let coordinator=try RelayCoordinator(macId:mac,api:api,outbox:outbox,devices:{[paired]},nearby:{[]},snapshot:{[:]},execute:{r,_,_,_ in await read.run(r)},now:{clock.wall},monotonic:{clock.mono})
        await coordinator.tick();clock.advance(5)
        let request=CommandRequest(id:UUID().uuidString.lowercased(),action:"refresh_triggers",issuedAt:clock.wall,expiresAt:clock.wall.addingTimeInterval(validity==14 ? 30:validity))
        api.commands=[try RelayEnvelope.seal(WireJSON.encoder.encode(request),key:paired.key,macId:mac,deviceId:device,id:request.id,epoch:coordinator.epoch,direction:"c2s",kind:"command",now:clock.wall,lifetime:30)]
        let accepting=Task{await coordinator.tick()};await settleRelayTasks();#expect(read.started==[request.id]);api.commands=[]
        clock.advance(validity);await coordinator.tick();read.release();await accepting.value;await settleRelayTasks()
        #expect(read.cancelled==[request.id])
        if let result=try outbox.response(id:request.id,deviceId:device,epoch:coordinator.epoch,body:WireJSON.encoder.encode(request),now:clock.wall) {
            let object=try WireJSON.object(result.open(key:paired.key,macId:mac,deviceId:device,epoch:coordinator.epoch,direction:"s2c",kinds:["response"],now:clock.wall))
            #expect(object["status"] as? String=="error")
        }
        coordinator.stop()
    }
}

extension RelayRoutingTests {
    @MainActor @Test(arguments:[8,9])
    func triggerReadsRunPerDeviceWithinEightPhoneLimit(_ count:Int)async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let api=RelayFakeAPI(),clock=RelayTestClock(),read=SuspendedRelayRead()
        let paired=(0..<count).map{index in AuthorizedDevice(deviceId:String(format:"22222222-2222-4222-8222-%012d",index),name:"Fixture",key:Data(repeating:7,count:32),approvedAt:clock.wall)}
        let coordinator=try RelayCoordinator(macId:mac,api:api,outbox:RelayOutbox(url:directory.appendingPathComponent("outbox")),devices:{paired},nearby:{[]},snapshot:{[:]},execute:{r,_,_,_ in await read.run(r)},now:{clock.wall},monotonic:{clock.mono})
        await coordinator.tick()
        api.commands=try paired.map{phone in
            let request=CommandRequest(id:UUID().uuidString.lowercased(),action:"refresh_triggers",issuedAt:clock.wall,expiresAt:clock.wall.addingTimeInterval(30))
            return try RelayEnvelope.seal(WireJSON.encoder.encode(request),key:phone.key,macId:mac,deviceId:phone.deviceId,id:request.id,epoch:coordinator.epoch,direction:"c2s",kind:"command",now:clock.wall,lifetime:30)
        }
        clock.advance(5);let accepting=Task{await coordinator.tick()};await settleRelayTasks()
        #expect(read.started.count==(count==8 ? 8:0))
        coordinator.stop();read.release();await accepting.value;await settleRelayTasks()
        #expect(read.cancelled.count==read.started.count)
    }
}
