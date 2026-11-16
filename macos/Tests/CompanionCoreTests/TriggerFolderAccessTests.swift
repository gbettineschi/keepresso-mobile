import Foundation
import Testing
@testable import CompanionCore
import KeepressoCore

struct TriggerFolderAccessTests {
    private let downloads = URL(fileURLWithPath: "/fixture/Downloads", isDirectory: true)
    private let other = URL(fileURLWithPath: "/fixture/Other", isDirectory: true)

    @Test func scannerDefaultsToNoFolderAccess() {
        let scanner = CountingDownloadScanner()
        let gated = PermissionGatedDownloadScanner(scanner: scanner)
        #expect(gated.newestPartialDownloadWrite(in: downloads) == nil)
        #expect(scanner.folders.isEmpty)
    }

    @Test func noProbeOrFolderReadBeforeExplicitLocalSetup() {
        let setup = TriggerFolderAccess(configuredFolders: [downloads], buildIdentity: "build-a")
        let scanner = CountingDownloadScanner()
        let gated = PermissionGatedDownloadScanner(scanner: scanner, isApproved: setup.isApproved)
        #expect(gated.newestPartialDownloadWrite(in: downloads) == nil)
        #expect(scanner.folders.isEmpty)
        #expect(setup.approvedFolders.isEmpty)
    }

    @Test func denialStaysUnknownAndRetryApprovesOnlyTheConfiguredFolder() async {
        var setup = TriggerFolderAccess(configuredFolders: [downloads], buildIdentity: "build-a")
        var probes: [URL] = []
        setup = await setup.requestingAccess { probes.append($0); return false }
        #expect(!setup.isApproved(downloads))
        setup = await setup.requestingAccess { probes.append($0); return true }
        #expect(probes == [downloads, downloads])
        let scanner = CountingDownloadScanner()
        let gated = PermissionGatedDownloadScanner(scanner: scanner, isApproved: setup.isApproved)
        #expect(gated.newestPartialDownloadWrite(in: downloads) == Date(timeIntervalSince1970: 42))
        #expect(gated.newestPartialDownloadWrite(in: other) == nil)
        #expect(scanner.folders == [downloads])
        let denied = DownloadInFolderTrigger(folder: other, scanner: gated)
        denied.tick()
        #expect(AssessmentEvidence.positiveOnly(denied.isSatisfied()) == nil)
        // A skipped folder must not suppress another independent trigger.
        let allowed = DownloadInFolderTrigger(folder: downloads, scanner: gated, now: { Date(timeIntervalSince1970: 42) })
        allowed.tick()
        #expect(allowed.isSatisfied())
    }

    @Test func deniedLocalRecheckRevokesPersistedGrantAndBlocksTheRealScanner() async throws {
        var setup = TriggerFolderAccess(configuredFolders: [downloads], buildIdentity: "build-a")
        setup = await setup.requestingAccess { _ in true }
        #expect(setup.isApproved(downloads))
        #expect(setup.canRequestAccess)
        var probes: [URL] = []
        setup = await setup.requestingAccess { probes.append($0); return false }
        #expect(probes == [downloads])
        #expect(!setup.isApproved(downloads))
        let persisted = try #require(setup.consentData)
        let workerPolicy = TriggerFolderAccess(configuredFolders: [downloads], buildIdentity: "build-a", consentData: persisted)
        let scanner = CountingDownloadScanner()
        let gated = PermissionGatedDownloadScanner(scanner: scanner, isApproved: workerPolicy.isApproved)
        #expect(gated.newestPartialDownloadWrite(in: downloads) == nil)
        #expect(scanner.folders.isEmpty)
        #expect(workerPolicy.approvedFolders.isEmpty)
        #expect(setup.canRequestAccess)
    }

    @Test func successfulSameBuildLocalRecheckActuallyProbesAndKeepsAccess() async {
        var setup = TriggerFolderAccess(configuredFolders: [downloads], buildIdentity: "build-a")
        setup = await setup.requestingAccess { _ in true }
        setup = TriggerFolderAccess(configuredFolders: [downloads], buildIdentity: "build-a", consentData: setup.consentData)
        var probes: [URL] = []
        setup = await setup.requestingAccess { probes.append($0); return true }
        #expect(probes == [downloads])
        #expect(setup.isApproved(downloads))
        #expect(setup.canRequestAccess)
        let empty = TriggerFolderAccess(configuredFolders: [], buildIdentity: "build-a")
        #expect(!empty.canRequestAccess)
    }

    @Test func exactFolderAndBuildAreRequiredAndRemovedFoldersCannotRegainApproval() async throws {
        var setup = TriggerFolderAccess(configuredFolders: [downloads], buildIdentity: "build-a")
        setup = await setup.requestingAccess { _ in true }
        let marker = try #require(setup.consentData)
        let changedBuild = TriggerFolderAccess(configuredFolders: [downloads], buildIdentity: "build-b", consentData: marker)
        #expect(!changedBuild.isApproved(downloads))
        let changedFolder = TriggerFolderAccess(configuredFolders: [other], buildIdentity: "build-a", consentData: marker)
        #expect(!changedFolder.isApproved(other))
        #expect(!changedFolder.isApproved(downloads))
        let child = downloads.appendingPathComponent("child", isDirectory: true)
        #expect(!setup.isApproved(child))
        #expect(!setup.isApproved(URL(fileURLWithPath: "/fixture/Downloads-other")))
        let canonicalAlias = URL(fileURLWithPath: "/fixture/temp/../Downloads/")
        #expect(setup.isApproved(canonicalAlias))
        let restored = TriggerFolderAccess(configuredFolders: [downloads], buildIdentity: "build-a", consentData: changedFolder.consentData)
        #expect(!restored.isApproved(downloads))
    }

    @Test func malformedUnboundedAndUnconfiguredWorkerConsentFailsClosed() async throws {
        let invalidInputs: [Data?] = [nil, Data("{}".utf8), Data(repeating: 0, count: 32_769), Data(#"{"buildIdentity":"build-a","folders":["file:///fixture/Other/"]}"#.utf8), Data(#"{"buildIdentity":"build-a","folders":["https://example.com/"]}"#.utf8), Data(#"{"buildIdentity":"build-a","folders":["file://remote/fixture/Downloads/"]}"#.utf8), Data(#"{"buildIdentity":"build-a","folders":["file:///fixture/Downloads/child/"]}"#.utf8)]
        for input in invalidInputs {
            let setup = TriggerFolderAccess(configuredFolders: [downloads], buildIdentity: "build-a", consentData: input)
            #expect(setup.approvedFolders.isEmpty)
        }
        var setup = TriggerFolderAccess(configuredFolders: [downloads], buildIdentity: "build-a")
        setup = await setup.requestingAccess { _ in true }
        let restored = TriggerFolderAccess(configuredFolders: [downloads], buildIdentity: "build-a", consentData: setup.consentData)
        #expect(restored.isApproved(downloads))
        let huge = (0..<33).map { URL(fileURLWithPath: "/fixture/\($0)") }
        var unbounded = TriggerFolderAccess(configuredFolders: huge, buildIdentity: "build-a")
        var probed = false
        unbounded = await unbounded.requestingAccess { _ in probed = true; return true }
        #expect(!probed)
        #expect(unbounded.approvedFolders.isEmpty)
    }

    @Test @MainActor func pairingPreparesLocallyBeforeArmingAndContinuesAfterDenial() async {
        var setup = TriggerFolderAccess(configuredFolders: [downloads], buildIdentity: "build-a")
        var events: [String] = []
        await setup.prepare(probe: { _ in events.append("local-probe"); return false }, complete: { setup = $0; events.append("arm") })
        #expect(events == ["local-probe", "arm"])
        #expect(!setup.isApproved(downloads))
        await setup.prepare(probe: { _ in events.append("retry"); return true }, complete: { setup = $0; events.append("arm") })
        #expect(events == ["local-probe", "arm", "retry", "arm"])
        #expect(setup.isApproved(downloads))
        await setup.prepare(probe: { _ in events.append("recheck"); return false }, complete: { setup = $0; events.append("arm") })
        #expect(events.last == "arm")
        #expect(events == ["local-probe", "arm", "retry", "arm", "recheck", "arm"])
        #expect(!setup.isApproved(downloads))
    }
}

private final class CountingDownloadScanner: DownloadFolderScanning {
    var folders: [URL] = []
    func newestPartialDownloadWrite(in folder: URL) -> Date? {
        folders.append(folder)
        return Date(timeIntervalSince1970: 42)
    }
}

struct TriggerFolderWorkerConsentTests {
    @Test func missingAndOversizedGrantsNeverReachTheWorker() throws {
        let scratch = try ObserverScratch.create()
        defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(TriggerFolderWorkerConsent.read(from: scratch) == nil)
        try TriggerFolderWorkerConsent.write(nil, to: scratch)
        #expect(TriggerFolderWorkerConsent.read(from: scratch) == nil)
        #expect(throws: (any Error).self) {
            try TriggerFolderWorkerConsent.write(Data(repeating: 0, count: 32_769), to: scratch)
        }
        #expect(TriggerFolderWorkerConsent.read(from: scratch) == nil)
    }

    @Test func privateScratchGrantRoundTripsAndRejectsSymbolicLinks() throws {
        let scratch = try ObserverScratch.create()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let data = Data(#"{"buildIdentity":"build-a","folders":["file:///fixture/Downloads/"]}"#.utf8)
        try TriggerFolderWorkerConsent.write(data, to: scratch)
        #expect(TriggerFolderWorkerConsent.read(from: scratch) == data)
        let grant = scratch.appendingPathComponent("folder-consent.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: grant.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let target = scratch.appendingPathComponent("target.json")
        try FileManager.default.moveItem(at: grant, to: target)
        try FileManager.default.createSymbolicLink(at: grant, withDestinationURL: target)
        #expect(TriggerFolderWorkerConsent.read(from: scratch) == nil)
    }
}


extension TriggerFolderAccessTests {
    @Test @MainActor func suspendedFolderSetupKeepsMainActorResponsiveAndDelaysPairing() async {
        let setup = TriggerFolderAccess(configuredFolders: [URL(fileURLWithPath: "/fixture/Downloads", isDirectory: true)], buildIdentity: "build-a")
        let probe = SuspendedFolderProbe()
        var events: [String] = []
        let preparation = Task { @MainActor in
            await setup.prepare(probe: { await probe.read($0) }, complete: { result in
                #expect(result.approvedFolders.isEmpty)
                events.append("arm")
            })
        }
        await probe.waitUntilEntered()
        // Represents a status/transport heartbeat while the owner is deciding
        // on a privacy prompt. It must run before that prompt completes.
        let heartbeat = Task { @MainActor in events.append("heartbeat") }
        await heartbeat.value
        #expect(events == ["heartbeat"])
        await probe.finish(allowed: false)
        await preparation.value
        #expect(events == ["heartbeat", "arm"])
    }
}

private actor SuspendedFolderProbe {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<Bool, Never>?
    func read(_ folder: URL) async -> Bool {
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
