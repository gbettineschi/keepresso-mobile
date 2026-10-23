import Testing
import Foundation
@testable import CompanionCore
struct SafetyTests {
    @Test func testFramingEverySplitAndOversizeAndPartialTimeout() throws {
        let record = try FrameDecoder.frame(Data("{\"type\":\"hello\"}".utf8))
        for split in 0...record.count {
            let d = FrameDecoder()
            var result = try d.feed(Data(record.prefix(split)), now: 0)
            result += try d.feed(Data(record.dropFirst(split)), now: 1)
            XCTAssertEqual(result, [Data("{\"type\":\"hello\"}".utf8)])
        }
        XCTAssertThrowsError(try FrameDecoder().feed(Data([0, 1, 0, 1]), now: 0))
        let d = FrameDecoder(); _ = try d.feed(Data([0]), now: 0)
        XCTAssertThrowsError(try d.feed(Data([0]), now: 11))
    }
    @Test func testPairProofRequiresLocalApprovalAndInvitationIsSingleUse() throws {
        let now = Date(timeIntervalSince1970: 100)
        let mac = "11111111-1111-4111-8111-111111111111", device = "22222222-2222-4222-8222-222222222222"
        let p = PairingManager(macId: mac)
        let invite = try p.arm(name: "Mac", now: now)
        let nonce = Data(repeating: 9, count: 32).base64EncodedString()
        let proof = WireCrypto.hmac(key: invite.token, text: WireCrypto.pairTranscript(mac: mac, device: device, nonce: nonce, name: "Phone")).base64EncodedString()
        let request = PairRequest(version: 1, macId: mac, deviceId: device, deviceName: "Phone", clientNonce: nonce, proof: proof)
        try p.request(request, peer: "central", now: now)
        XCTAssertNotNil(p.pending)
        let approved = try p.approve(now: now)
        XCTAssertEqual(approved.deviceId, device)
        XCTAssertThrowsError(try p.request(request, peer: "central", now: now))
        _ = try p.arm(name: "Mac", now: now)
        XCTAssertThrowsError(try p.request(request, peer: "central", now: now.addingTimeInterval(301)))
    }
    @Test func testFreshnessAndDurationBounds() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var r = CommandRequest(id: UUID().uuidString.lowercased(), action: "start_manual", issuedAt: now, expiresAt: now.addingTimeInterval(30), durationMinutes: 90)
        XCTAssertNoThrow(try r.validate(now: now))
        r.durationMinutes = 16; XCTAssertThrowsError(try r.validate(now: now))
        r.durationMinutes = 90; r.expiresAt = now.addingTimeInterval(31); XCTAssertThrowsError(try r.validate(now: now))
        r.expiresAt = now.addingTimeInterval(-1); XCTAssertThrowsError(try r.validate(now: now))
    }
    @Test func testDurableJournalReturnsUncertainAfterCrashAndRejectsOwnerOrBodyMismatch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let j = try MutationJournal(url: url)
        XCTAssertNil(try j.reserve(id: "command", device: "a", body: Data("stop".utf8)))
        let restarted = try MutationJournal(url: url)
        XCTAssertEqual(try restarted.reserve(id: "command", device: "a", body: Data("stop".utf8))?.status, "uncertain")
        XCTAssertThrowsError(try restarted.reserve(id: "command", device: "b", body: Data("stop".utf8)))
        XCTAssertThrowsError(try restarted.reserve(id: "command", device: "a", body: Data("sleep".utf8)))
        try restarted.finish(id: "command", result: CommandResponse(id: "command", status: "ok"))
        XCTAssertEqual(try MutationJournal(url: url).reserve(id: "command", device: "a", body: Data("stop".utf8))?.status, "ok")
    }
    @Test func testReminderOKKeepsCadenceSnoozeOnlyRoutineAndNewSessionCancelsWarning() throws {
        var r = ReminderMachine(); let start = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(r.observe(active: true, now: start).isEmpty)
        XCTAssertEqual(r.observe(active: true, now: start.addingTimeInterval(3600)).map(\.kind), ["hourly"])
        r.acknowledge() // no schedule reset
        r.snooze(now: start.addingTimeInterval(3610))
        XCTAssertTrue(r.observe(active: true, now: start.addingTimeInterval(7200)).isEmpty)
        XCTAssertEqual(r.warning(kind: "thermal", now: start).kind, "thermal")
        _ = r.observe(active: false, now: start.addingTimeInterval(7300))
        _ = r.observe(active: true, now: start.addingTimeInterval(7400))
        XCTAssertFalse(r.observe(active: true, now: start.addingTimeInterval(7700)).contains { $0.kind == "session_ended_awake" })
    }
    @Test func testObservedSleepCancelsEndedWarningAcrossRestart() throws {
        var r = ReminderMachine(); let t = Date(timeIntervalSince1970: 100)
        _ = r.observe(active: true, now: t); _ = r.observe(active: false, now: t.addingTimeInterval(10)); r.observedSleep()
        var restored = try JSONDecoder().decode(ReminderMachine.self, from: JSONEncoder().encode(r))
        XCTAssertTrue(restored.observe(active: false, now: t.addingTimeInterval(1000)).isEmpty)
    }
}
extension SafetyTests {
    @Test func restartPreservesOriginalHourlyCadence() throws {
        var r=ReminderMachine();let t=Date(timeIntervalSince1970:100)
        _=r.observe(active:true,now:t)
        var restart=try JSONDecoder().decode(ReminderMachine.self,from:JSONEncoder().encode(r));restart.resumedAfterUnknownInterval()
        XCTAssertEqual(restart.observe(active:true,now:t.addingTimeInterval(3600)).map(\.kind),["hourly"])
    }
}
extension SafetyTests {
    @Test func helperGapCannotCreateEndedWarningFromLastActiveState() throws {
        var state=ReminderMachine();let now=Date(timeIntervalSince1970:100)
        _=state.observe(active:true,now:now)
        state.resumedAfterUnknownInterval()
        _=state.observe(active:false,now:now.addingTimeInterval(1000))
        XCTAssertTrue(state.observe(active:false,now:now.addingTimeInterval(1400)).isEmpty)
    }
}
extension SafetyTests {
    @Test func sleepBeforeInactiveSampleCannotRearmEndedWarning() {
        var state=ReminderMachine();let now=Date(timeIntervalSince1970:100)
        _=state.observe(active:true,now:now);state.observedSleep()
        _=state.observe(active:false,now:now.addingTimeInterval(1000))
        XCTAssertTrue(state.observe(active:false,now:now.addingTimeInterval(1400)).isEmpty)
    }
}
extension SafetyTests {
    @Test func safetyIncidentBypassesSnoozeButDoesNotDuplicateAcrossRestart()throws{
        var state=ReminderMachine();let now=Date();state.snooze(now:now)
        XCTAssertNotNil(state.observeSafety(kind:"thermal",active:true,now:now))
        var restored=try JSONDecoder().decode(ReminderMachine.self,from:JSONEncoder().encode(state))
        XCTAssertNil(restored.observeSafety(kind:"thermal",active:true,now:now))
        XCTAssertNil(restored.observeSafety(kind:"thermal",active:false,now:now))
        XCTAssertNotNil(restored.observeSafety(kind:"thermal",active:true,now:now))
    }
    @Test func journalSaveFailureDoesNotConvertUncertainMemoryToOK()throws{
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);let parent=base.appendingPathComponent("state");let moved=base.appendingPathComponent("previous");defer{try? FileManager.default.removeItem(at:base)}
        let j=try MutationJournal(url:parent.appendingPathComponent("journal.json"));let data=Data("stop".utf8)
        _=try j.reserve(id:"a",device:"phone",body:data)
        try FileManager.default.moveItem(at:parent,to:moved);try Data().write(to:parent)
        XCTAssertThrowsError(try j.finish(id:"a",result:CommandResponse(id:"a",status:"ok")))
        XCTAssertEqual(try j.reserve(id:"a",device:"phone",body:data)?.status,"uncertain")
    }
    @Test func notificationBackpressureNeverConsumesUnacceptedChunkAndBoundsQueue()throws{
        let q=NotificationQueue();let payload=Data(repeating:65,count:1000)
        try q.enqueue(record:payload,mtu:20);let first=q.next
        XCTAssertEqual(q.next,first);XCTAssertEqual(q.bytes,1004)
        let decoder=FrameDecoder();var output:[Data]=[]
        while let chunk=q.next{output+=try decoder.feed(chunk,now:0);q.accepted()}
        XCTAssertEqual(output,[payload]);XCTAssertEqual(q.bytes,0)
        XCTAssertThrowsError(try q.enqueue(record:Data(repeating:0,count:65536),mtu:1))
    }
}
extension SafetyTests {
    @Test func quittingKeepressoAfterKnownActiveSessionSchedulesAwakeWarning(){
        var state=ReminderMachine();let now=Date(timeIntervalSince1970:100)
        _=state.observe(active:true,now:now)
        _=state.observe(active:StatusEvidence.brewingActivity(appRunning:false,nativeActive:nil),now:now.addingTimeInterval(10))
        XCTAssertEqual(state.observe(active:false,now:now.addingTimeInterval(311)).map(\.kind),["session_ended_awake"])
    }
}
