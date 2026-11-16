import Foundation
import Testing
@testable import CompanionCore

struct TriggerFolderCancellationTests {
    private let folders = [URL(fileURLWithPath: "/fixture/FolderA", isDirectory: true), URL(fileURLWithPath: "/fixture/FolderB", isDirectory: true)]

    @Test func cancellationWhileFirstProbeWaitsStopsTheNextProbeAndDropsEveryGrant() async throws {
        let prior = await approvedPolicy()
        let probe = HeldCancellationProbe()
        let operation = Task { await prior.requestingAccess(probe: probe.read) }
        await probe.waitUntilEntered()
        operation.cancel()
        await probe.finish(allowed: true)
        let result = await operation.value
        #expect(await probe.folders == [folders[0]])
        #expect(result.approvedFolders.isEmpty)
        let marker = try #require(result.consentData)
        let restored = TriggerFolderAccess(configuredFolders: folders, buildIdentity: "fixture-build", consentData: marker)
        #expect(restored.approvedFolders.isEmpty)
    }

    @Test func cancellationDropsSuccessfulEvidenceFromEarlierInTheSameRun() async {
        let prior = await approvedPolicy()
        let probe = HeldCancellationProbe(holdIndex: 2)
        let operation = Task { await prior.requestingAccess(probe: probe.read) }
        await probe.waitUntilEntered()
        operation.cancel()
        await probe.finish(allowed: true)
        let result = await operation.value
        #expect(await probe.folders == folders)
        #expect(result.approvedFolders.isEmpty)
    }

    @Test @MainActor func cancellationWhilePreparingNeverCompletesOrArmsPairing() async {
        let prior = await approvedPolicy()
        let probe = HeldCancellationProbe()
        var completed = false
        let operation = Task { @MainActor in
            await prior.prepare(probe: probe.read) { _ in completed = true }
        }
        await probe.waitUntilEntered()
        operation.cancel()
        await probe.finish(allowed: true)
        await operation.value
        #expect(!completed)
        #expect(await probe.folders == [folders[0]])
    }

    @Test @MainActor func cancellationBeforeStartDoesNotProbeKeepOldGrantsOrComplete() async {
        let prior = await approvedPolicy()
        var probed = false
        var completed = false
        // The MainActor task cannot begin until this actor yields below.
        let operation = Task { @MainActor in
            let result = await prior.requestingAccess { _ in probed = true; return true }
            await prior.prepare(probe: { _ in probed = true; return true }) { _ in completed = true }
            return result
        }
        operation.cancel()
        let result = await operation.value
        #expect(!probed)
        #expect(!completed)
        #expect(result.approvedFolders.isEmpty)
    }

    private func approvedPolicy() async -> TriggerFolderAccess {
        let policy = TriggerFolderAccess(configuredFolders: folders, buildIdentity: "fixture-build")
        return await policy.requestingAccess { _ in true }
    }
}

/// Holds one fake probe. Other probes return immediately so a bug
/// reports the unwanted request rather than hanging the test.
private actor HeldCancellationProbe {
    private(set) var folders: [URL] = []
    private let holdIndex: Int
    init(holdIndex: Int = 1) { self.holdIndex = holdIndex }
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<Bool, Never>?
    func read(_ folder: URL) async -> Bool {
        folders.append(folder)
        guard folders.count == holdIndex else { return true }
        entered = true
        waiter?.resume(); waiter = nil
        return await withCheckedContinuation { result = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(allowed: Bool) { result?.resume(returning: allowed); result = nil }
}
