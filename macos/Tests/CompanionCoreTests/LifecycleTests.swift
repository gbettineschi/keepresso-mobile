import Foundation
import Testing
@testable import CompanionCore

struct LifecycleTests {
    @MainActor @Test func overlappingRefreshCannotLoseCancellationOwnership() async throws {
        let owner=TriggerRefreshOwner();var cancelled=false
        let first=Task { await owner.run {
            do { try await Task.sleep(nanoseconds:3_000_000_000) } catch { cancelled=error is CancellationError }
            return TriggerPreview()
        } }
        while !owner.isRunning { await Task.yield() }
        let overlap=await owner.run { Issue.record("Overlapping refresh ran");return TriggerPreview() }
        XCTAssertNil(overlap)
        owner.cancel()
        let result=await first.value
        XCTAssertNil(result);XCTAssertTrue(cancelled);XCTAssertFalse(owner.isRunning)
        let replacement=await owner.run { TriggerPreview() }
        XCTAssertTrue(replacement != nil)
    }
    @Test func absenceAndRepeatedPresenceDoNotCreateWork() {
        var gate = NativeLifecycleGate()
        XCTAssertEqual(gate.update(applicationToken: nil), [])
        XCTAssertFalse(gate.isActive)
        XCTAssertEqual(gate.update(applicationToken: "42/1000"), [.start])
        let generation = gate.generation
        XCTAssertEqual(gate.update(applicationToken: "42/1000"), [])
        XCTAssertTrue(gate.accepts(generation: generation))
    }
    @Test func quitAndRelaunchInvalidateOutstandingWork() {
        var gate = NativeLifecycleGate()
        _ = gate.update(applicationToken: "42/1000")
        let old = gate.generation
        XCTAssertEqual(gate.update(applicationToken: nil), [.stop])
        XCTAssertFalse(gate.accepts(generation: old))
        XCTAssertEqual(gate.update(applicationToken: nil), [])
        XCTAssertEqual(gate.update(applicationToken: "42/2000"), [.start])
        XCTAssertFalse(gate.accepts(generation: old))
        XCTAssertTrue(gate.accepts(generation: gate.generation))
    }
    @Test func coalescedExitAndLaunchStopsOldRuntimeBeforeStartingReplacement() {
        var gate = NativeLifecycleGate()
        _ = gate.update(applicationToken: "42/1000")
        let old = gate.generation
        XCTAssertEqual(gate.update(applicationToken: "42/2000"), [.stop, .start])
        XCTAssertFalse(gate.accepts(generation: old))
        XCTAssertEqual(gate.update(applicationToken: "43/2000"), [.stop, .start])
    }
    @Test func cancelledWorkerStopsBeforeItsNormalTimeout() async throws {
        let began = Date()
        let task = Task { try await BoundedWorker.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import os,time; os.setpgrp(); time.sleep(3)"], timeout: 4) }
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        do { _ = try await task.value; Issue.record("Canceled worker returned a result") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(Date().timeIntervalSince(began) < 1.5)
    }
}

struct InstanceLeaseTests {
    @Test func onlyOneCompanionCanOwnTheRuntimeAndReleaseAllowsRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func holdFirstLease() throws {
            let first = try CompanionInstanceLease.acquire(directory: directory)
            XCTAssertNotNil(first)
            XCTAssertNil(try CompanionInstanceLease.acquire(directory: directory))
            withExtendedLifetime(first) {}
        }
        try holdFirstLease()
        let replacement = try CompanionInstanceLease.acquire(directory: directory)
        XCTAssertNotNil(replacement)
        withExtendedLifetime(replacement) {}
    }
    @Test func runtimeLockDoesNotFollowASymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("runtime.lock"), withDestinationURL: target)
        XCTAssertThrowsError(try CompanionInstanceLease.acquire(directory: directory))
        XCTAssertEqual(try Data(contentsOf: target), Data("unchanged".utf8))
    }
}
