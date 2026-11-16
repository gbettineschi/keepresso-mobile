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
}
extension SafetyTests {
    @Test func configuredGuardWarnsAtFairWithoutAnotherDwellAndRepeatsEveryFiveMinutes() {
        var machine = ReminderMachine()
        let start = Date(timeIntervalSince1970: 1_000)
        machine.snooze(now: start)
        let state = MacThermalReading(state: .fair, guardActive: true)
        let first = machine.observeHeat(state, now: start)
        #expect(first?.thermalSeverity == .serious)
        #expect(first?.thermalState == .fair)
        #expect(first?.body.contains("Fair") == true)
        #expect(machine.observeHeat(state, now: start.addingTimeInterval(299)) == nil)
        let repeatWarning = machine.observeHeat(state, now: start.addingTimeInterval(300))
        #expect(repeatWarning?.thermalSeverity == .serious)
        #expect(repeatWarning?.id != first?.id)
    }

    @Test func seriousOnlyWarnsWhenNativeGuardReportsAnAction() {
        var machine = ReminderMachine()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(machine.observeHeat(MacThermalReading(state: .serious), now: start) == nil)
        #expect(machine.observeHeat(MacThermalReading(state: .serious, guardActive: false), now: start) == nil)
        #expect(machine.observeHeat(MacThermalReading(state: .serious, guardActive: true), now: start)?.thermalState == .serious)
    }

    @Test func noncriticalCooldownSurvivesCoolingAndRestartWithoutDelayingCritical() throws {
        var machine = ReminderMachine()
        let start = Date(timeIntervalSince1970: 1_000)
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        let serious = MacThermalReading(state: .serious, guardActive: true)
        let fair = MacThermalReading(state: .fair, guardActive: true)

        #expect(machine.observeHeat(fair, now: at(0))?.thermalState == .fair)
        #expect(machine.observeHeat(MacThermalReading(state: .nominal, guardActive: false), now: at(1)) == nil)
        #expect(machine.observeHeat(serious, now: at(2)) == nil)
        #expect(machine.observeHeat(MacThermalReading(state: .critical, guardActive: false), now: at(3))?.thermalSeverity == .critical)

        let saved = try JSONEncoder().encode(machine)
        machine = try JSONDecoder().decode(ReminderMachine.self, from: saved)
        machine.resumedAfterUnknownInterval()
        #expect(machine.observeHeat(serious, now: at(90))?.alertPhase == .resolved)
        #expect(machine.observeHeat(serious, now: at(299)) == nil)
        #expect(machine.observeHeat(serious, now: at(300))?.thermalState == .serious)
    }

    @Test func sleepAndUnknownIntervalResetHeatEvidence() {
        var machine = ReminderMachine()
        let start = Date(timeIntervalSince1970: 1_000)
        let serious = MacThermalReading(state: .serious, guardActive: true)
        _ = machine.observeHeat(serious, now: start)
        machine.observedSleep()
        #expect(!machine.noncriticalHeatActive)
        #expect(machine.observeHeat(serious, now: start.addingTimeInterval(31)) == nil)
        machine.resumedAfterUnknownInterval()
        #expect(!machine.noncriticalHeatActive)
        #expect(machine.observeHeat(serious, now: start.addingTimeInterval(62)) == nil)
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
    @Test func backgroundDurableRecordsCanBeReopenedAndAtomicallyReplaced() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("background-record")
        let first=Data("first fixture".utf8),second=Data("second fixture".utf8)
        try PrivateDurableFile.save(first,to:url)
        XCTAssertEqual(try Data(contentsOf:url),first)
        try PrivateDurableFile.save(second,to:url)
        XCTAssertEqual(try Data(contentsOf:url),second)
        let mode=try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue,0o600)
    }
}
