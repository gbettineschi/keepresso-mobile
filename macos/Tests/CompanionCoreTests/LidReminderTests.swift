import Foundation
import Testing
@testable import CompanionCore

struct LidReminderTests {
    let t=Date(timeIntervalSince1970:1800000000)
    @Test func oldSavedReminderConfigurationStillDecodesWithoutLidState()throws{
        var r=ReminderMachine();r.settings.intervalSeconds=7200;r.snooze(now:t)
        var object=try WireJSON.object(WireJSON.encoder.encode(r));object.removeValue(forKey:"awakeAlerts")
        var restored=try WireJSON.decoder.decode(ReminderMachine.self,from:WireJSON.data(object))
        XCTAssertEqual(restored.settings.intervalSeconds,7200);XCTAssertEqual(restored.snoozedUntil,t+21600)
        let reading = MacAwakeReading(wake: .full, lidClosed: true, displayAvailability: .unavailable, isBrewing: false, brew: nil, lastUserInputAt: nil)
        XCTAssertTrue(restored.observeAwake(reading, now: t + 1).isEmpty)
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

    @Test func replacingNoncriticalHeatPreservesTheCriticalResolution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = try RelayOutbox(url: directory.appendingPathComponent("events"))
        let mac = "11111111-1111-4111-8111-111111111111"
        let epoch = "22222222-2222-4222-8222-222222222222"
        let critical = CompanionEvent(kind: "thermal", createdAt: t, title: "Recovered", body: "Now at Fair",
                                      scheduledEnd: nil, snoozedUntil: nil, thermalSeverity: .critical,
                                      thermalState: .fair, incidentId: UUID().uuidString.lowercased(), alertPhase: .resolved)
        let warm = CompanionEvent(kind: "thermal", createdAt: t, title: "Guard active", body: "Fair",
                                  scheduledEnd: nil, snoozedUntil: nil, thermalSeverity: .serious, thermalState: .fair)
        for event in [critical, warm] { try box.enqueue(event, devices: [], macId: mac, epoch: epoch, now: t) }
        try box.resolve(kinds: ["thermal"], now: t + 1)
        #expect(box.events(now: t + 1).map(\.id) == [critical.id])
    }

}
