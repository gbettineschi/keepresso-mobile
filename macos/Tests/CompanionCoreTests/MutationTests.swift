import Foundation
import CryptoKit
import Testing
@testable import CompanionCore
struct MutationTests {
    @MainActor @Test func lifecycleChangeDuringIssuedCommandPersistsUncertaintyWithoutRetry() async throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:url) }
        let now=Date();let request=CommandRequest(id:UUID().uuidString.lowercased(),action:"stop_manual",issuedAt:now,expiresAt:now.addingTimeInterval(30))
        let body=try WireJSON.encoder.encode(request);let journal=try MutationJournal(url:url)
        let executor=MutationExecutor(journal:journal);var authorized=true;var effects=0
        let result=await executor.execute(request,device:"device",body:body,now:now,authorized:{authorized}) {
            effects+=1;await Task.yield();authorized=false
            return CommandResponse(id:request.id,status:"ok")
        }
        XCTAssertEqual(result.status,"uncertain")
        authorized=true
        let duplicate=await executor.execute(request,device:"device",body:body,now:now,authorized:{authorized}) {
            effects+=1;return CommandResponse(id:request.id,status:"ok")
        }
        XCTAssertEqual(duplicate.status,"uncertain");XCTAssertEqual(effects,1)
        let stored=try journal.lookup(id:request.id,device:"device",bodyDigest:Data(SHA256.hash(data:body)).base64EncodedString())
        XCTAssertEqual(stored?.status,"uncertain")
    }
    @MainActor @Test func duplicateMutationNeverInvokesAdapterTwiceAndCrashReservationNeverExecutes()async throws{
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:url)}
        let now=Date();let request=CommandRequest(id:UUID().uuidString.lowercased(),action:"stop_manual",issuedAt:now,expiresAt:now.addingTimeInterval(30));let body=try WireJSON.encoder.encode(request)
        let journal=try MutationJournal(url:url);let executor=MutationExecutor(journal:journal);var effects=0
        func fakeAction()async ->CommandResponse{effects+=1;return CommandResponse(id:request.id,status:"ok")}
        let first=await executor.execute(request,device:"device",body:body,now:now,authorized:{true},operation:fakeAction)
        let second=await executor.execute(request,device:"device",body:body,now:now,authorized:{true},operation:fakeAction)
        XCTAssertEqual(first.status,"ok");XCTAssertEqual(second.status,"ok");XCTAssertEqual(effects,1)
        let crashID=UUID().uuidString.lowercased();var crash=request;crash.id=crashID;let crashBody=try WireJSON.encoder.encode(crash)
        _=try journal.reserve(id:crashID,device:"device",body:crashBody)
        let restart=MutationExecutor(journal:try MutationJournal(url:url))
        let result=await restart.execute(crash,device:"device",body:crashBody,now:now,authorized:{true},operation:fakeAction)
        XCTAssertEqual(result.status,"uncertain");XCTAssertEqual(effects,1)
    }
    @MainActor @Test func revokedOrExpiredRequestCannotReachPowerAdapter()async throws{
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:url)}
        let now=Date();let request=CommandRequest(id:UUID().uuidString.lowercased(),action:"sleep_now",issuedAt:now,expiresAt:now.addingTimeInterval(30));let body=try WireJSON.encoder.encode(request)
        let executor=MutationExecutor(journal:try MutationJournal(url:url));var effects=0
        let r=await executor.execute(request,device:"device",body:body,now:now,authorized:{false}){effects+=1;return CommandResponse(id:request.id,status:"ok")}
        XCTAssertEqual(r.status,"error");XCTAssertEqual(effects,0)
    }
    @MainActor @Test func observedSleepSurvivesTransportLossAndIsReturnedOnlyToAnAuthorizedLookup() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        let request = CommandRequest(id: UUID().uuidString.lowercased(), action: "sleep_now", issuedAt: now,
                                     expiresAt: now.addingTimeInterval(30))
        let body = try WireJSON.encoder.encode(request)
        let executor = MutationExecutor(journal: try MutationJournal(url: url))
        var authorized = true
        var effects = 0
        let interrupted = await executor.execute(request, device: "device", body: body, now: now, authorized: { authorized }) {
            effects += 1
            authorized = false
            return CommandResponse(id: request.id, status: "ok", message: "Going to sleep", sleepOutcome: .goingToSleep)
        }
        #expect(interrupted.status == "uncertain")
        #expect(interrupted.sleepOutcome != .goingToSleep)
        let reopened = MutationExecutor(journal: try MutationJournal(url: url))
        let lookup = CommandRequest(id: UUID().uuidString.lowercased(), action: "operation_status", issuedAt: now,
                                    expiresAt: now.addingTimeInterval(30), operationId: request.id,
                                    bodyDigest: Data(SHA256.hash(data: body)).base64EncodedString())
        let lookupBody = try WireJSON.encoder.encode(lookup)
        func unexpectedAction() async -> CommandResponse {
            effects += 1
            return CommandResponse(id: lookup.id, status: "error")
        }
        let wrongDevice = await reopened.execute(lookup, device: "other", body: lookupBody, now: now,
                                                  authorized: { true }, operation: unexpectedAction)
        #expect(wrongDevice.status == "error")
        #expect(wrongDevice.sleepOutcome == nil)
        let receipt = await reopened.execute(lookup, device: "device", body: lookupBody, now: now,
                                              authorized: { true }, operation: unexpectedAction)
        #expect(receipt.operationId == request.id)
        #expect(receipt.operationStatus == "ok")
        #expect(receipt.sleepOutcome == .goingToSleep)
        let duplicate = await reopened.execute(request, device: "device", body: body, now: now,
                                                authorized: { true }, operation: unexpectedAction)
        #expect(duplicate.sleepOutcome == .goingToSleep)
        #expect(effects == 1)
    }
}
