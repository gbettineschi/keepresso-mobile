import Foundation
import Testing
@testable import CompanionCore

struct LidReminderTests {
    let t=Date(timeIntervalSince1970:1800000000)
    @Test func closedAtStartupIsNotANewClosureAndOneObservedClosureWarnsOnce(){
        var r=ReminderMachine()
        XCTAssertNil(r.observeLid(closed:true,sleepDisabled:true,now:t))
        XCTAssertNil(r.observeLid(closed:true,sleepDisabled:true,now:t+1))
        XCTAssertNil(r.observeLid(closed:false,sleepDisabled:true,now:t+2))
        XCTAssertNil(r.observeLid(closed:true,sleepDisabled:nil,now:t+3))
        XCTAssertEqual(r.observeLid(closed:true,sleepDisabled:true,now:t+4)?.kind,"lid_awake")
        XCTAssertNil(r.observeLid(closed:true,sleepDisabled:true,now:t+5))
    }
    @Test func unknownHoldAndExpiredClosureNeverBecomeAnAlarm(){
        var r=ReminderMachine();_=r.observeLid(closed:false,sleepDisabled:nil,now:t)
        XCTAssertNil(r.observeLid(closed:true,sleepDisabled:nil,now:t+1))
        XCTAssertNil(r.observeLid(closed:true,sleepDisabled:false,now:t+2))
        XCTAssertNil(r.observeLid(closed:true,sleepDisabled:true,now:t+7))
        XCTAssertFalse(r.needsLidCheck(now:t+7))
    }
    @Test func unknownLidSampleInvalidatesBothOpenBaselineAndPendingClosure(){
        var r=ReminderMachine();_=r.observeLid(closed:false,sleepDisabled:nil,now:t)
        _=r.observeLid(closed:nil,sleepDisabled:nil,now:t+1)
        XCTAssertNil(r.observeLid(closed:true,sleepDisabled:true,now:t+120))
        _=r.observeLid(closed:false,sleepDisabled:nil,now:t+121)
        _=r.observeLid(closed:true,sleepDisabled:nil,now:t+122)
        _=r.observeLid(closed:nil,sleepDisabled:nil,now:t+123)
        XCTAssertFalse(r.needsLidCheck(now:t+124))
        XCTAssertNil(r.observeLid(closed:true,sleepDisabled:true,now:t+124))
        _=r.observeLid(closed:false,sleepDisabled:nil,now:t+125)
        XCTAssertNotNil(r.observeLid(closed:true,sleepDisabled:true,now:t+126))
    }
    @Test func reopeningCancelsPendingCueAndSnoozeDoesNotSuppressNextRealClosure(){
        var r=ReminderMachine();r.settings.enabled=false;r.snooze(now:t)
        _=r.observeLid(closed:false,sleepDisabled:nil,now:t)
        _=r.observeLid(closed:true,sleepDisabled:nil,now:t+1)
        _=r.observeLid(closed:false,sleepDisabled:true,now:t+2)
        XCTAssertFalse(r.needsLidCheck(now:t+2))
        XCTAssertEqual(r.observeLid(closed:true,sleepDisabled:true,now:t+3)?.kind,"lid_awake")
    }
    @Test func restartAndObservedSleepCannotReplayAnOldLidWarning()throws{
        var r=ReminderMachine();_=r.observeLid(closed:false,sleepDisabled:nil,now:t)
        XCTAssertNotNil(r.observeLid(closed:true,sleepDisabled:true,now:t+1))
        var restored=try WireJSON.decoder.decode(ReminderMachine.self,from:WireJSON.encoder.encode(r))
        XCTAssertNil(restored.observeLid(closed:true,sleepDisabled:true,now:t+2))
        restored.resumedAfterUnknownInterval()
        XCTAssertNil(restored.observeLid(closed:true,sleepDisabled:true,now:t+3))
        _=restored.observeLid(closed:false,sleepDisabled:nil,now:t+4);restored.observedSleep()
        XCTAssertNil(restored.observeLid(closed:true,sleepDisabled:true,now:t+5))
    }
    @Test func oldSavedReminderConfigurationStillDecodesWithoutLidState()throws{
        var r=ReminderMachine();r.settings.intervalSeconds=7200;r.snooze(now:t)
        var object=try WireJSON.object(WireJSON.encoder.encode(r));object.removeValue(forKey:"lidWarning")
        var restored=try WireJSON.decoder.decode(ReminderMachine.self,from:WireJSON.data(object))
        XCTAssertEqual(restored.settings.intervalSeconds,7200);XCTAssertEqual(restored.snoozedUntil,t+21600)
        XCTAssertNil(restored.observeLid(closed:true,sleepDisabled:true,now:t+1))
    }
    @Test func resolvedLidEventCannotBeDeliveredLateWhileOtherWarningsSurvive()throws{
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let outbox=try RelayOutbox(url:directory.appendingPathComponent("events"))
        let mac="11111111-1111-4111-8111-111111111111",epoch="22222222-2222-4222-8222-222222222222"
        let device=AuthorizedDevice(deviceId:"33333333-3333-4333-8333-333333333333",name:"Fixture",key:Data(repeating:0,count:32),approvedAt:t)
        for kind in ["lid_awake","thermal"]{try outbox.enqueue(CompanionEvent(kind:kind,createdAt:t,title:"Fixture",body:"Fixture",scheduledEnd:nil,snoozedUntil:nil),devices:[device],macId:mac,epoch:epoch,now:t)}
        try outbox.resolve(kinds:["lid_awake"],now:t+1)
        XCTAssertEqual(outbox.events(now:t+1).map(\.kind),["thermal"])
        XCTAssertEqual(outbox.pending(epoch:epoch,devices:[device.deviceId],nearby:[],now:t+1).count,1)
    }
}
