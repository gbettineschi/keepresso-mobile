import Foundation
import Testing
@testable import CompanionCore
struct WorkerTests {
    @Test func workerCapturesOutputAndRejectsTimeoutAndOutputFlood()async throws{
        let output=try await BoundedWorker.run(executable:URL(fileURLWithPath:"/usr/bin/printf"),arguments:["bounded worker"])
        XCTAssertEqual(String(data:output,encoding:.utf8),"bounded worker")
        let started=Date()
        do{_=try await BoundedWorker.run(executable:URL(fileURLWithPath:"/bin/sleep"),arguments:["2"],timeout:0.1);Issue.record("Timeout must be rejected")}catch{}
        XCTAssertTrue(Date().timeIntervalSince(started)<1.5)
        do{_=try await BoundedWorker.run(executable:URL(fileURLWithPath:"/usr/bin/yes"),arguments:[],timeout:1,outputLimit:1024);Issue.record("Output flood must be rejected")}catch{}
    }
}
extension WorkerTests {
    @Test func parentOwnedScratchIsRemovedAfterTimeout()async throws{
        var path:URL?
        do{
            _=try await ObserverScratch.withDirectory{scratch in
                path=scratch
                XCTAssertEqual(try ObserverScratch.validate(scratch.path),scratch.standardizedFileURL)
                try Data("copied hook fixture".utf8).write(to:scratch.appendingPathComponent("record.json"))
                return try await BoundedWorker.run(executable:URL(fileURLWithPath:"/bin/sleep"),arguments:["2"],timeout:0.1)
            }
            Issue.record("Expected worker timeout")
        }catch{}
        XCTAssertNotNil(path)
        XCTAssertFalse(FileManager.default.fileExists(atPath:path!.path))
        XCTAssertThrowsError(try ObserverScratch.validate(FileManager.default.temporaryDirectory.path))
    }
}
