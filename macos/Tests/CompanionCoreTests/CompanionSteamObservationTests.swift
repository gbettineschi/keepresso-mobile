import Foundation
import CryptoKit
import Testing
@testable import KeepressoCore

struct CompanionSteamObservationTests {
    @Test func absentProofAndWrongIdentityNeverReadFilesystem() {
        let fixture = SteamFixture()
        let monitor = CompanionSteamObservation(buildIdentity: "test", consentData: nil, driver: fixture.driver)
        #expect(!monitor.isDownloading)
        #expect(!monitor.hasCompleteReading)
        #expect(fixture.reads.isEmpty)
        #expect(!CompanionSteamObservation.isPrepared(nil, buildIdentity: "test"))
    }
    @Test func prepareProbesBaseBeforeConfigAndEveryExactRoot() async throws {
        let fixture = SteamFixture()
        let proof = try #require(await CompanionSteamObservation.prepareConsent(buildIdentity: "test", driver: fixture.driver) { folder in
            fixture.events.append("probe:\(folder.path)"); return true
        })
        #expect(fixture.events == ["probe:/fixture/Steam/steamapps", "read:/fixture/Steam/steamapps/libraryfolders.vdf", "probe:/fixture/Extra/steamapps"])
        let previousReads = fixture.reads
        #expect(CompanionSteamObservation.isPrepared(proof, buildIdentity: "test", driver: fixture.driver))
        #expect(!CompanionSteamObservation.isPrepared(proof, buildIdentity: "changed", driver: fixture.driver))
        #expect(fixture.reads == previousReads)
        let wrong = CompanionSteamObservation(buildIdentity: "changed", consentData: proof, driver: fixture.driver)
        #expect(!wrong.hasCompleteReading)
        #expect(fixture.reads == previousReads)
    }
    @Test func deniedBaseDoesNotReadAndDeniedLibraryProducesNoProof() async {
        let fixture = SteamFixture()
        #expect(await CompanionSteamObservation.prepareConsent(buildIdentity: "test", driver: fixture.driver, folderProbe: { _ in false }) == nil)
        #expect(fixture.reads.isEmpty)
        let denied = await CompanionSteamObservation.prepareConsent(buildIdentity: "test", driver: fixture.driver, folderProbe: { $0 == fixture.base })
        #expect(denied == nil)
        #expect(fixture.reads == [fixture.config.path])
    }
    @Test func changedConfigCannotReadAnyLibrary() async throws {
        let fixture = SteamFixture()
        let proof = try #require(await fixture.prepare())
        fixture.reads = []
        fixture.configData = Data("\"path\" \"/fixture/New\"".utf8)
        let monitor = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: fixture.driver)
        #expect(!monitor.isDownloading)
        #expect(!monitor.hasCompleteReading)
        #expect(fixture.reads == [fixture.config.path])
        #expect(fixture.listed.isEmpty)
    }
    @Test func completeInactiveAndRecentFlaggedDownloadUseNativeSemantics() async throws {
        let fixture = SteamFixture()
        let proof = try #require(await fixture.prepare())
        let inactive = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: fixture.driver)
        #expect(!inactive.isDownloading)
        #expect(inactive.hasCompleteReading)
        fixture.installManifest(flags: 1026, modified: fixture.now.addingTimeInterval(-10))
        let active = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: fixture.driver)
        #expect(active.isDownloading)
        #expect(active.hasCompleteReading)
        fixture.installManifest(flags: 1026, modified: fixture.now.addingTimeInterval(-61))
        let paused = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: fixture.driver)
        #expect(!paused.isDownloading)
        #expect(paused.hasCompleteReading)
    }
    @Test func partialPositiveSurvivesButIncompleteNegativeIsUnknown() async throws {
        let fixture = SteamFixture()
        let proof = try #require(await fixture.prepare())
        fixture.failedDirectories.insert("/fixture/Extra/steamapps")
        let unknown = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: fixture.driver)
        #expect(!unknown.isDownloading)
        #expect(!unknown.hasCompleteReading)
        fixture.installManifest(flags: 1026, modified: fixture.now)
        let positive = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: fixture.driver)
        #expect(positive.isDownloading)
        #expect(!positive.hasCompleteReading)
        #expect(fixture.reads.allSatisfy { !$0.contains("downloading") })
    }
    @Test func commentCannotCompensateForAnOmittedRealLibrary() async throws {
        let fixture = SteamFixture()
        let canonicalProof = try #require(await fixture.prepare())
        let ambiguous = """
        "libraryfolders" {
          "path" "/fixture/Steam" "path" "/fixture/Missed"
          // "path" "/fixture/Extra"
        }
        """
        // Native extraction has the right count but substitutes the comment
        // for the second real library on the preceding physical line.
        #expect(SteamDownload.libraryPaths(fromVDF: ambiguous) == ["/fixture/Steam", "/fixture/Extra"])
        fixture.configData = Data(ambiguous.utf8)
        #expect(await fixture.prepare() == nil)
        // A proof made by the previous count-only implementation must also
        // become unknown, before any recorded library is read.
        var historical = try #require(JSONSerialization.jsonObject(with: canonicalProof) as? [String: Any])
        historical["configurationSHA256"] = SHA256.hash(data: fixture.configData).map { String(format: "%02x", $0) }.joined()
        let historicalProof = try JSONSerialization.data(withJSONObject: historical)
        let monitor = CompanionSteamObservation(buildIdentity: "test", consentData: historicalProof, driver: fixture.driver)
        #expect(!monitor.isDownloading)
        #expect(!monitor.hasCompleteReading)
        #expect(fixture.listed.isEmpty)
    }
    @Test func canonicalNestedLibrariesAndEmptyMetadataKeepTheirExistingVerdicts() async throws {
        let fixture = SteamFixture()
        fixture.configData = Data("""
        "libraryfolders"
        {
          "0"
          {
            "path" "/fixture/Steam"
          }
          "1"
          {
            "path" "/fixture/Extra"
          }
        }
        """.utf8)
        let proof = try #require(await fixture.prepare())
        let emptyLibraries = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: fixture.driver)
        #expect(!emptyLibraries.isDownloading)
        #expect(emptyLibraries.hasCompleteReading)
        fixture.installManifest(flags: 1026, modified: fixture.now)
        let active = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: fixture.driver)
        #expect(active.isDownloading)
        #expect(active.hasCompleteReading)
        fixture.configData = Data("\"libraryfolders\" { }".utf8)
        #expect(await fixture.prepare() == nil)
        let missingRoots = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: fixture.driver)
        #expect(!missingRoots.hasCompleteReading)
    }
    @Test func invalidConfigurationNeverCreatesConsent() async {
        let invalid = [
            "\"path\" \"/fixture/Steam\"",
            "\"libraryfolders\" { \"path\" \"/fixture/Steam\" \"path\" \"/fixture/Missed\" }",
            "\"libraryfolders\" {\n\"path\" \"relative\"\n}",
            "\"libraryfolders\" {\n\"path\" \"/fixture/../Secret\"\n}",
            "\"libraryfolders\" {\n\"path\" \"/fixture/Steam\"",
            String(repeating: "x", count: 262_145)
        ]
        for config in invalid {
            let fixture = SteamFixture()
            fixture.configData = Data(config.utf8)
            #expect(await fixture.prepare() == nil)
        }
    }
    @Test func proofRequiresFixedBaseAndExactCurrentRootSetBeforeReadingLibraries() async throws {
        let fixture = SteamFixture()
        let proof = try #require(await fixture.prepare())
        var object = try #require(JSONSerialization.jsonObject(with: proof) as? [String: Any])
        object["base"] = "/fixture/Other/steamapps"
        object["roots"] = ["/fixture/Other/steamapps"]
        let altered = try JSONSerialization.data(withJSONObject: object)
        fixture.reads = []
        #expect(!CompanionSteamObservation.isPrepared(altered, buildIdentity: "test"))
        let monitor = CompanionSteamObservation(buildIdentity: "test", consentData: altered, driver: fixture.driver)
        #expect(!monitor.hasCompleteReading)
        #expect(fixture.reads.isEmpty)
        object = try #require(JSONSerialization.jsonObject(with: proof) as? [String: Any])
        object["roots"] = [fixture.base.path]
        let missingLibrary = try JSONSerialization.data(withJSONObject: object)
        let mismatch = CompanionSteamObservation(buildIdentity: "test", consentData: missingLibrary, driver: fixture.driver)
        #expect(!mismatch.hasCompleteReading)
        #expect(fixture.listed.isEmpty)
    }
    @Test func excessiveManifestAndWalkCountsStayIncomplete() async throws {
        let fixture = SteamFixture()
        let proof = try #require(await fixture.prepare())
        fixture.directories[fixture.base.path] = (0..<2_050).map { index in
            let name = "appmanifest_\(index).acf"
            fixture.files[fixture.base.appendingPathComponent(name).path] = Data("\"StateFlags\" \"4\"".utf8)
            return .init(name: name, kind: .regularFile)
        }
        let monitor = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: fixture.driver)
        #expect(!monitor.hasCompleteReading)
        #expect(fixture.reads.count <= 2_050)
        fixture.installManifest(flags: 1026, modified: fixture.now)
        fixture.directories[fixture.base.appendingPathComponent("downloading").path] = [.init(name: "cycle", kind: .directory)]
        var path = fixture.base.appendingPathComponent("downloading")
        for _ in 0..<40 {
            path.appendPathComponent("cycle")
            fixture.directories[path.path] = [.init(name: "cycle", kind: .directory)]
        }
        let deep = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: fixture.driver)
        #expect(!deep.isDownloading)
        #expect(!deep.hasCompleteReading)
    }
    @MainActor @Test func configurationReadDoesNotBlockMainActor() async {
        let fixture = SteamFixture()
        let original = fixture.driver
        let release = DispatchSemaphore(value: 0)
        let driver = CompanionSteamFileDriver(defaultSteamapps: fixture.base, readFile: { url, maximum in
            #expect(!Thread.isMainThread)
            #expect(release.wait(timeout: .now() + 2) == .success)
            return try original.readFile(url, maximum)
        }, contents: original.contents)
        let prepare = Task { await CompanionSteamObservation.prepareConsent(buildIdentity: "test", driver: driver, folderProbe: { _ in true }) }
        Task { @MainActor in release.signal() }
        #expect(await prepare.value != nil)
    }
    @Test func productionIORejectsOwnedFixtureSymlinksWithoutReadingDownloadedContents() async throws {
        let manager = FileManager.default
        // /tmp and Foundation's per-user temporary URL can retain symlink
        // ancestors on macOS. Use the physical system temp root for this test.
        let owned = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("keepresso-steam-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: owned) }
        let steam = owned.appendingPathComponent("Steam", isDirectory: true)
        let apps = steam.appendingPathComponent("steamapps", isDirectory: true)
        let downloading = apps.appendingPathComponent("downloading", isDirectory: true)
        try manager.createDirectory(at: downloading, withIntermediateDirectories: true)
        let config = apps.appendingPathComponent("libraryfolders.vdf")
        let contents = Data("\"libraryfolders\" {\n\"path\" \"\(steam.path)\"\n}".utf8)
        try contents.write(to: config)
        try Data("\"StateFlags\" \"1026\"".utf8).write(to: apps.appendingPathComponent("appmanifest_1.acf"))
        let chunk = downloading.appendingPathComponent("chunk")
        try Data([1]).write(to: chunk)
        let driver = CompanionSteamFileDriver.local(defaultSteamapps: apps)
        #expect(try driver.readFile(config, 262_144) == contents)
        let proof = try #require(await CompanionSteamObservation.prepareConsent(buildIdentity: "test", driver: driver, folderProbe: { _ in true }))
        let positive = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: driver)
        #expect(positive.isDownloading)
        #expect(positive.hasCompleteReading)
        try manager.removeItem(at: chunk)
        let target = owned.appendingPathComponent("other")
        try Data([2]).write(to: target)
        try manager.createSymbolicLink(at: chunk, withDestinationURL: target)
        let symlink = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: driver)
        #expect(!symlink.isDownloading)
        #expect(!symlink.hasCompleteReading)
        try manager.removeItem(at: config)
        let actualConfig = owned.appendingPathComponent("actual.vdf")
        try contents.write(to: actualConfig)
        try manager.createSymbolicLink(at: config, withDestinationURL: actualConfig)
        #expect(await CompanionSteamObservation.prepareConsent(buildIdentity: "test", driver: driver, folderProbe: { _ in true }) == nil)
    }
    @Test func malformedManifestAndSymlinkCannotCreateSafeNegative() async throws {
        let fixture = SteamFixture()
        let proof = try #require(await fixture.prepare())
        fixture.installManifest(flags: 4, modified: fixture.now)
        fixture.files[fixture.manifest.path] = Data("garbage".utf8)
        let malformed = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: fixture.driver)
        #expect(!malformed.hasCompleteReading)
        fixture.directories[fixture.base.path] = [.init(name: "appmanifest_1.acf", kind: .symbolicLink)]
        let symlink = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: fixture.driver)
        #expect(!symlink.hasCompleteReading)
    }
}

private final class SteamFixture: @unchecked Sendable {
    let base = URL(fileURLWithPath: "/fixture/Steam/steamapps", isDirectory: true)
    var config: URL { base.appendingPathComponent("libraryfolders.vdf") }
    var manifest: URL { base.appendingPathComponent("appmanifest_1.acf") }
    let now = Date(timeIntervalSince1970: 1_000)
    var configData = Data("\"libraryfolders\"\n{\n\"path\" \"/fixture/Steam\"\n\"path\" \"/fixture/Extra\"\n}\n".utf8)
    var events: [String] = []
    var reads: [String] = []
    var listed: [String] = []
    var files: [String: Data] = [:]
    var directories: [String: [CompanionSteamFileDriver.Entry]] = [:]
    var failedDirectories: Set<String> = []
    var driver: CompanionSteamFileDriver {
        .init(defaultSteamapps: base, now: { self.now }, readFile: { url, maximum in
            self.reads.append(url.path); self.events.append("read:\(url.path)")
            let data = url == self.config ? self.configData : self.files[url.path]
            guard let data, data.count <= maximum else { throw FixtureError.unreadable }
            return data
        }, contents: { url, maximum in
            self.listed.append(url.path)
            guard !self.failedDirectories.contains(url.path) else { throw FixtureError.unreadable }
            let result = self.directories[url.path] ?? []
            guard result.count <= maximum else { throw FixtureError.unreadable }
            return .init(entries: result)
        })
    }
    func prepare() async -> Data? {
        await CompanionSteamObservation.prepareConsent(buildIdentity: "test", driver: driver, folderProbe: { _ in true })
    }
    func installManifest(flags: Int, modified: Date) {
        directories[base.path] = [.init(name: "appmanifest_1.acf", kind: .regularFile)]
        files[manifest.path] = Data("\"StateFlags\" \"\(flags)\"".utf8)
        directories[base.appendingPathComponent("downloading").path] = [.init(name: "chunk", kind: .regularFile, modified: modified)]
    }
    enum FixtureError: Error { case unreadable }
}
extension CompanionSteamObservationTests {
    @Test func concreteEnumerationPreservesManifestAndRecentFileAcrossStatIterationAndBoundFailures() async throws {
        let fixture = SteamFixture()
        let proof = try #require(await fixture.prepare())
        fixture.installManifest(flags: 1026, modified: fixture.now)
        for rootPartial in [true, false] {
            for failure in ["stat-before", "stat-after", "iteration", "bound"] {
                let name = rootPartial ? "appmanifest_1.acf" : "chunk"
                var names = failure == "stat-before" ? ["broken", name] : [name, "broken"]
                var metadataReads = 0
                let partial = SteamMetadataIO.enumerate(maximum: failure == "bound" ? 1 : 4, next: {
                    if failure == "iteration", names.first == "broken" { throw SteamFixture.FixtureError.unreadable }
                    return names.isEmpty ? nil : names.removeFirst()
                }, metadata: { entry in
                    metadataReads += 1
                    if entry == "broken" { throw SteamFixture.FixtureError.unreadable }
                    return .init(name: entry, kind: .regularFile, modified: fixture.now)
                })
                #expect(partial.entries.map(\.name) == [name])
                #expect(!partial.complete)
                if failure == "bound" { #expect(metadataReads == 1) }
                let original = fixture.driver
                let driver = CompanionSteamFileDriver(defaultSteamapps: fixture.base, now: { fixture.now }, readFile: original.readFile, contents: { url, maximum in
                    if url.path == (rootPartial ? fixture.base : fixture.base.appendingPathComponent("downloading")).path { return partial }
                    return try original.contents(url, maximum)
                })
                let monitor = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: driver)
                #expect(monitor.isDownloading)
                #expect(!monitor.hasCompleteReading)
            }
        }
    }
    @Test func partialEnumerationWithoutRecentFileCannotProveNegativeAndCountsFailedEntriesTowardBound() async throws {
        let fixture = SteamFixture()
        let proof = try #require(await fixture.prepare())
        fixture.installManifest(flags: 1026, modified: fixture.now)
        var calls = 0
        let partial = SteamMetadataIO.enumerate(maximum: 2, next: { calls += 1; return "broken-\(calls)" }, metadata: { _ in throw SteamFixture.FixtureError.unreadable })
        #expect(partial.entries.isEmpty && !partial.complete)
        #expect(calls == 3)
        let original = fixture.driver
        let driver = CompanionSteamFileDriver(defaultSteamapps: fixture.base, now: { fixture.now }, readFile: original.readFile, contents: { url, maximum in
            if url.lastPathComponent == "downloading" { return partial }
            return try original.contents(url, maximum)
        })
        let monitor = CompanionSteamObservation(buildIdentity: "test", consentData: proof, driver: driver)
        #expect(!monitor.isDownloading && !monitor.hasCompleteReading)
    }
}
