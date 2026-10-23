import Foundation
import Testing
@testable import CompanionCore
struct MutationTests {
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
}
