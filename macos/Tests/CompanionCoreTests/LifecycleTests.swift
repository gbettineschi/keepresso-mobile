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
            // Pass only a Boolean into test diagnostics: retaining the lease in
            // a recorded expectation can outlive this scope and keep its lock.
            XCTAssertTrue(first != nil)
            XCTAssertNil(try CompanionInstanceLease.acquire(directory: directory))
            withExtendedLifetime(first) {}
        }
        try holdFirstLease()
        let replacement = try CompanionInstanceLease.acquire(directory: directory)
        XCTAssertTrue(replacement != nil)
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

extension LifecycleTests {
    @MainActor @Test func cancellingRefreshCallerCancelsOwnedWorker() async throws {
        let owner=TriggerRefreshOwner();var childStarted=false;var childCancelled=false
        let caller=Task { await owner.run {
            childStarted=true
            do { try await Task.sleep(nanoseconds:2_000_000_000) }
            catch { childCancelled=error is CancellationError }
            return TriggerPreview()
        } }
        while !childStarted { await Task.yield() }
        caller.cancel()
        let result=await caller.value
        XCTAssertNil(result)
        XCTAssertTrue(childCancelled)
        XCTAssertFalse(owner.isRunning)
    }
}
extension LifecycleTests {
    @MainActor @Test(arguments: ["ready", "unknown"])
    func cancelledRefreshOwnsItsCleanupBeforeNativeResumeCanStartAnotherCheck(state:String) async {
        let owner=TriggerRefreshOwner()
        var history=ManualTriggerHistory()
        var completed=TriggerPreview();completed.state=state;completed.checkedAt=Date(timeIntervalSince1970:100)
        completed.combined=state == "ready" ? true:nil
        completed.rules=[.init(id:"0",label:"Microphone",satisfied:completed.combined,inGrace:false,graceRemaining:nil,details:[])]
        history.complete(completed)
        var lifecycle=NativeLifecycleGate();_=lifecycle.update(applicationToken:"native/1")
        let previousGeneration=lifecycle.generation
        var releaseWorker:CheckedContinuation<Void,Never>?
        let first=Task { await owner.run {
            history.begin()
            // A cancelled process may need time to unwind. Hold that exact
            // window without timing sleeps, subprocesses or native app state.
            await withCheckedContinuation { releaseWorker=$0 }
            history.cancel()
            return history.preview
        } }
        while releaseWorker == nil { await Task.yield() }
        owner.cancel()
        _=lifecycle.update(applicationToken:nil);history.invalidate();history.cancel()
        _=lifecycle.update(applicationToken:"native/2")
        XCTAssertFalse(lifecycle.accepts(generation:previousGeneration))
        XCTAssertEqual(history.preview.state,state)
        XCTAssertEqual(history.preview.checkedAt,Date(timeIntervalSince1970:100))
        XCTAssertEqual(history.preview.rules.first?.satisfied,completed.combined)
        XCTAssertEqual(history.preview.checking,false);XCTAssertEqual(history.preview.outdated,true)
        XCTAssertTrue(owner.isRunning)
        let duringCleanup=await owner.run { history.preview }
        XCTAssertNil(duringCleanup) // Retained history must never be a new check.
        releaseWorker?.resume()
        let cancelled=await first.value
        XCTAssertNil(cancelled)
        XCTAssertFalse(owner.isRunning)
        let afterCleanup=await owner.run {
            history.begin();var fresh=completed;fresh.checkedAt=Date(timeIntervalSince1970:200)
            history.complete(fresh);return history.preview
        }
        XCTAssertEqual(afterCleanup?.checkedAt,Date(timeIntervalSince1970:200))
        XCTAssertEqual(afterCleanup?.outdated,false)
    }
}
