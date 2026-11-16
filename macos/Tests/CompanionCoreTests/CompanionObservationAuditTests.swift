import Foundation
import Testing
@testable import KeepressoCore

struct CompanionObservationAuditTests {
    final class Locked<Value>: @unchecked Sendable {
        let lock = NSLock(); var storage: Value
        init(_ value: Value) { storage = value }
        func get() -> Value { lock.lock(); defer { lock.unlock() }; return storage }
        func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; storage = value }
    }
    @Test func asyncCompletionCannotMakeAlreadyReturnedColdProcessFalseComplete() async throws {
        let entered = Locked(false); let finish = DispatchSemaphore(value: 0)
        let cache = CompanionObservationCache<[String]>(now: Date.init) { entered.set(true); finish.wait(); return ["worker"] }
        var d = CompanionObservationDependencies(); d.processes = { cache.read().map { .init(commands: $0) } }
        let fixture = CompanionObservationInputsTests(); let input = fixture.inputs(d, steam: .init())
        let rule = TriggerRule.process("worker")
        let cold = fixture.state(rule, inputs: input)
        #expect(cold.satisfied == false); #expect(input.assessed(cold) == nil)
        for _ in 0..<100 where !entered.get() { try await Task.sleep(for: .milliseconds(1)) }
        finish.signal()
        // Observe cache commit through the public value; assessment must still
        // refer to the old consumed sample until the trigger reads again.
        var complete = false
        for _ in 0..<100 {
            if cache.read() != nil { complete = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(complete); #expect(input.assessed(cold) == nil)
        input.beginSample()
        #expect(input.assessed(fixture.state(rule, inputs: input)) == true)
    }
    @Test func cacheFailureAndExpirationCannotRetainVerifiedNegative() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000)); let value = Locked<Bool?>(false)
        let cache = CompanionObservationCache<Bool>(now: { clock.get() }, fetch: { value.get() })
        #expect(cache.read() == nil)
        var first: Bool?
        for _ in 0..<100 { first = cache.read(); if first != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(first == false)
        clock.set(clock.get().addingTimeInterval(4)); value.set(nil)
        #expect(cache.read() == nil)
        try await Task.sleep(for: .milliseconds(5)); #expect(cache.read() == nil)
    }
    @Test func scannerAuditsSafariChildrenAndErrorsWithoutReadingFileContents() {
        let folder = URL(fileURLWithPath: "/fixture/downloads"), marker = URL(fileURLWithPath: "/fixture/downloads/file.download"), child = URL(fileURLWithPath: "/fixture/downloads/file.download/body")
        let old = Date(timeIntervalSince1970: 100), fresh = Date(timeIntervalSince1970: 200)
        let scanner = CompanionObservationDownloadScanner(list: { $0 == folder ? [marker] : [child] }, metadata: { url in
            .init(modified: url == child ? fresh : old, directory: url != child)
        })
        #expect(scanner.read(in: folder)?.newestWrite == fresh)
        #expect(scanner.read(in: folder)?.complete == true)
        let failed = CompanionObservationDownloadScanner(list: { $0 == folder ? [marker] : [child] }, metadata: { url in
            if url == child { throw ObserverError.unavailable }; return .init(modified: old, directory: true)
        })
        #expect(failed.read(in: folder)?.complete == false)
        let denied = CompanionObservationDownloadScanner(list: { _ in throw ObserverError.unavailable }, metadata: { _ in .init(modified: nil, directory: true) })
        #expect(denied.read(in: folder) == nil)
        let empty = CompanionObservationDownloadScanner(list: { _ in [] }, metadata: { _ in .init(modified: nil, directory: true) })
        #expect(empty.read(in: folder)?.complete == true)
        #expect(empty.read(in: folder)?.newestWrite == nil)
    }
    @Test func unapprovedFolderIsNeverRead() {
        let fixture = CompanionObservationInputsTests(); var d = fixture.dependencies(active: false)
        d.downloads = { _ in Issue.record("unapproved directory read"); return .init(newestWrite: nil) }
        let input = CompanionObservationInputs(dependencies: d, folderApproved: { _ in false }, steam: CompanionObservationInputsTests.Steam(), steamAvailable: { true })
        #expect(input.assessed(fixture.state(.downloadInFolder(fixture.folder), inputs: input)) == nil)
    }
    @Test func agentColdBaselineCannotProveInactiveButNoCandidatesAndValidEmptyHooksCan() {
        func read(_ raw: String, available: Bool = true) -> CompanionObservationAgents? {
            CompanionObservationAgentReader.read(raw: raw, now: Date(timeIntervalSince1970: 100), hookRecords: { _ in [] }, hooksAvailable: { available }, pathOf: { _ in nil }, cwdOf: { _ in nil }, evidence: { _, _, _ in nil }, origin: { _ in nil }, codexWrite: { _ in nil })
        }
        #expect(read("42 1 0.0 ?? codex")?.negativeComplete == false)
        #expect(read("42 1 0.0 ?? /fixture/ordinary-worker")?.negativeComplete == true)
        #expect(read("42 1 0.0 ?? /fixture/ordinary-worker", available: false) == nil)
        #expect(read("malformed row") == nil)
    }
    @Test func partialMediaFailuresOnlyInvalidateAffectedRuleAndPreserveUnknown() {
        let fixture = CompanionObservationInputsTests(); var d = fixture.dependencies(active: false)
        d.media = { .init(snapshot: .init(microphoneInUse: true), cameraComplete: false, microphoneComplete: true, capturersComplete: false, audioComplete: false) }
        let input = fixture.inputs(d, steam: .init())
        #expect(input.assessed(fixture.state(.mediaInUse(.camera), inputs: input)) == nil)
        #expect(input.assessed(fixture.state(.mediaInUse(.microphone), inputs: input)) == true)
        #expect(input.assessed(fixture.state(.audioPlaying, inputs: input)) == nil)
        #expect(input.assessed(fixture.state(.micInUse(.init(apps: [.init(bundleID: "org.fixture.call")])), inputs: input)) == nil)
    }
}
extension CompanionObservationAuditTests {
    @Test func verifiedSteamPositiveSurvivesIncompleteOtherLibrariesButIncompleteNegativeDoesNot() {
        let fixture = CompanionObservationInputsTests(); let steam = CompanionObservationInputsTests.Steam()
        let input = fixture.inputs(CompanionObservationDependencies(), steam: steam, available: { false })
        let trigger = input.factory.makeTrigger(for: .steamDownload)
        steam.isDownloading = true; trigger.tick()
        #expect(input.assessed(.init(rule: .steamDownload, satisfied: trigger.isSatisfied(), inGrace: false)) == true)
        steam.isDownloading = false; input.beginSample(); trigger.tick()
        #expect(trigger.isSatisfied() == true) // The unchanged native grace still exists.
        #expect(input.assessed(.init(rule: .steamDownload, satisfied: trigger.isSatisfied(), inGrace: true)) == nil)
    }
    @Test func HALReadFailuresStayUnknownAndIdleMicDoesNotReadCapturers() {
        let failed = CompanionObservationHAL.assemble(camera: .init(active: false, complete: false), audio: .init(input: .init(active: false, complete: false), output: .init(active: false, complete: false)), capturers: { .init(values: [], complete: false) })
        #expect(failed.cameraComplete == false)
        #expect(failed.microphoneComplete == false)
        #expect(failed.capturersComplete == false)
        #expect(failed.audioComplete == false)
        let idle = CompanionObservationHAL.assemble(camera: .init(active: false, complete: true), audio: .init(input: .init(active: false, complete: true), output: .init(active: false, complete: true)), capturers: { Issue.record("capturer query for idle mic"); return .init(values: [], complete: false) })
        #expect(idle.cameraComplete && idle.microphoneComplete && idle.capturersComplete && idle.audioComplete)
        let live = CompanionObservationHAL.assemble(camera: .init(active: true, complete: true), audio: .init(input: .init(active: true, complete: true), output: .init(active: false, complete: true)), capturers: { .init(values: [], complete: false) })
        #expect(live.snapshot.cameraInUse && live.snapshot.microphoneInUse)
        #expect(live.microphoneComplete && !live.capturersComplete)
    }
}
extension CompanionObservationAuditTests {
    @Test func deniedLocationBluetoothCalendarDoNotReadGatedInputs() {
        #expect(CompanionObservationSystem.permitted(false, read: { Issue.record("denied SSID read"); return NetworkSnapshot(ssid: "private") }) == nil)
        #expect(CompanionObservationSystem.permitted(false, read: { Issue.record("denied Bluetooth read"); return BluetoothSnapshot() }) == nil)
        #expect(CompanionObservationSystem.permitted(false, read: { Issue.record("denied calendar read"); return [CalendarEventWindow]() }) == nil)
        #expect(CompanionObservationSystem.permitted(true, read: { false }) == false)
        #expect(CompanionObservationSystem.permitted(true, read: { Optional<Bool>.none }) == nil)
    }
    @Test func downloadSymlinksAndUnreadableMarkerMetadataNeverProveInactive() {
        let folder = URL(fileURLWithPath: "/fixture/downloads"), marker = folder.appendingPathComponent("a.part")
        let symlinkRoot = CompanionObservationDownloadScanner(list: { _ in Issue.record("symlink traversal"); return [] }, metadata: { _ in .init(modified: nil, directory: true, symlink: true) })
        #expect(symlinkRoot.read(in: folder) == nil)
        let failedMarker = CompanionObservationDownloadScanner(list: { _ in [marker] }, metadata: { url in
            if url == marker { throw ObserverError.unavailable }; return .init(modified: nil, directory: true)
        })
        #expect(failedMarker.read(in: folder)?.complete == false)
        let fixture = CompanionObservationInputsTests(); var d = fixture.dependencies(active: false)
        d.downloads = { _ in failedMarker.read(in: folder) }
        let input = fixture.inputs(d, steam: .init())
        #expect(input.assessed(fixture.state(.downloadInFolder(folder), inputs: input)) == nil)
    }
    @Test func sharedCacheCompletionIsLatchedForVPNAndCalendarConsumers() async throws {
        for rule in [TriggerRule.vpnConnected, .calendarEvent] {
            let cache = CompanionObservationCache<Bool>(now: Date.init, fetch: { true })
            let fixture = CompanionObservationInputsTests(); var d = CompanionObservationDependencies()
            if rule == .vpnConnected { d.vpn = { cache.read() } } else { d.calendar = { cache.read() } }
            let input = fixture.inputs(d, steam: .init())
            let cold = fixture.state(rule, inputs: input)
            #expect(input.assessed(cold) == nil)
            var complete = false
            for _ in 0..<100 {
                if cache.read() == true { complete = true; break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(complete); #expect(input.assessed(cold) == nil)
            input.beginSample()
            #expect(input.assessed(fixture.state(rule, inputs: input)) == true)
        }
    }
}
extension CompanionObservationAuditTests {
    @Test func copiedHookMalformedBytesAndWrongSchemaInvalidateEmptyEvidence() throws {
        for bytes in [Data("{".utf8), Data("{}".utf8)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let source = root.appendingPathComponent("source"), scratch = root.appendingPathComponent("scratch")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let file = source.appendingPathComponent("bad.json"); try bytes.write(to: file)
            let copies = CompanionHookCopies(source: source, root: scratch)
            #expect(copies.read(now: Date(timeIntervalSince1970: 1_800_000_000)).isEmpty)
            #expect(copies.failed)
            #expect(try Data(contentsOf: file) == bytes)
            #expect(!FileManager.default.fileExists(atPath: scratch.path))
        }
    }
    @Test func validLegacyAndStaleHookSchemaUsesNativePruningOnCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source"), scratch = root.appendingPathComponent("scratch")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        // Omit every optional later field. Old timestamp makes native liveness
        // probing unnecessary; the source record must survive copy pruning.
        let bytes = Data("{\"sessionId\":\"legacy\",\"state\":\"working\",\"updatedAt\":\"2000-01-01T00:00:00Z\"}".utf8)
        let file = source.appendingPathComponent("legacy.json"); try bytes.write(to: file)
        let copies = CompanionHookCopies(source: source, root: scratch)
        #expect(copies.read(now: Date(timeIntervalSince1970: 1_800_000_000)).isEmpty)
        #expect(!copies.failed)
        #expect(try Data(contentsOf: file) == bytes)
    }
}
extension CompanionObservationAuditTests {
    @Test func rulesSharingInputCannotBlessEarlierColdFalseWithLaterReadySample() {
        let fixture = CompanionObservationInputsTests(); var ready = false
        var d = CompanionObservationDependencies(); d.processes = { ready ? .init(commands: ["worker --compile"]) : nil }
        let input = fixture.inputs(d, steam: .init())
        let first = fixture.state(.process("worker"), inputs: input)
        ready = true
        let second = fixture.state(.process("compile"), inputs: input)
        #expect(input.assessed(first) == nil)
        #expect(input.assessed(second) == nil)
        input.beginSample()
        #expect(input.assessed(fixture.state(.process("worker"), inputs: input)) == true)
        #expect(input.assessed(fixture.state(.process("compile"), inputs: input)) == true)
    }
}
extension CompanionObservationAuditTests {
    @Test func folderApprovalAndMetadataAreOneSnapshotForRepeatedFolderRules() {
        let fixture = CompanionObservationInputsTests(); var approved = false
        let input = CompanionObservationInputs(dependencies: fixture.dependencies(active: true), folderApproved: { _ in approved }, steam: CompanionObservationInputsTests.Steam(), steamAvailable: { true }, now: { fixture.instant })
        let rule = TriggerRule.downloadInFolder(fixture.folder)
        let cold = fixture.state(rule, inputs: input)
        approved = true
        let later = fixture.state(rule, inputs: input)
        #expect(input.assessed(cold) == nil)
        #expect(input.assessed(later) == nil)
        input.beginSample()
        #expect(input.assessed(fixture.state(rule, inputs: input)) == true)
    }
    @MainActor @Test func sameRulesRebuildClearsSnapshotCacheAndRetainsNativeEMAAndGrace() {
        let fixture = CompanionObservationInputsTests(); var active = true
        var d = fixture.dependencies(active: false)
        d.cpu = { active ? 1 : 0 }
        d.media = { .init(snapshot: .init(audioPlaying: active)) }
        let input = fixture.inputs(d, steam: .init())
        let gate = TriggerGateController(factory: input.factory, now: { fixture.instant })
        let rules: [TriggerRule] = [.cpuLoad(thresholdPercent: 50), .audioPlaying]
        gate.rebuild(rules: rules, combine: .any, enabled: true)
        let engine = gate.engine
        input.beginSample(); gate.engine?.tick()
        #expect(gate.ruleStates()?.map(\.satisfied) == [true, true])
        active = false
        // Same clock intentionally: an uncleared native snapshot cache would
        // keep inGrace false. New triggers would lose both EMA and grace.
        gate.rebuild(rules: rules, combine: .any, enabled: true)
        #expect(gate.engine === engine)
        input.beginSample(); gate.engine?.tick()
        let second = gate.ruleStates()
        #expect(second?.map(\.satisfied) == [true, true])
        #expect(second?[1].inGrace == true)
        #expect(input.assessed(second![0]) == true)
        #expect(input.assessed(second![1]) == true)
    }
    @Test func nativeAgentHookMatchingAndWaitingRuleStillDecideTheVerdict() {
        let fixture = CompanionObservationInputsTests()
        for (state, detail, waiting, expected) in [(AgentHooks.HookSessionState.working, Optional<String>.none, false, true), (.idle, nil, false, false), (.waiting, nil, false, false), (.waiting, nil, true, true), (.waiting, "waiting-approval", false, true)] {
            let record = AgentHooks.HookRecord(sessionId: "fixture", state: state, detail: detail, agentPid: 42, agent: "codex", updatedAt: fixture.instant)
            let sample = CompanionObservationAgentReader.read(raw: "42 1 0.0 ?? codex", now: fixture.instant, hookRecords: { _ in [record] }, hooksAvailable: { true }, pathOf: { _ in nil }, cwdOf: { _ in nil }, evidence: { _, _, _ in nil }, origin: { _ in nil }, codexWrite: { _ in nil })
            var d = CompanionObservationDependencies(); d.agents = { sample }
            let input = fixture.inputs(d, steam: .init())
            #expect(input.assessed(fixture.state(.agentActivity(.init(grace: 0, countWaitingAsWorking: waiting)), inputs: input)) == expected)
        }
    }

    @MainActor @Test func agentRulesWithDifferentCPUPoliciesUseOneSampleAndKeepDirectEvidence() {
        let fixture = CompanionObservationInputsTests()
        var session = AgentSession(pid: 42, agent: "codex", tty: nil, cpuPercent: 95)
        var reads = 0
        var dependencies = CompanionObservationDependencies()
        dependencies.agents = {
            reads += 1
            return .init(snapshot: .init(sessions: [session]), negativeComplete: true)
        }
        let input = fixture.inputs(dependencies, steam: .init())
        let rule = TriggerRule.agentActivity(.init(grace: 0, countWaitingAsWorking: false))
        let standard = TriggerGateController(factory: input.factory)
        let evidenceOnly = TriggerGateController(factory: input.evidenceOnlyFactory)

        func sample() -> [Bool?] {
            input.beginSample()
            return [standard, evidenceOnly].map { gate in
                gate.rebuild(rules: [rule], combine: .any, enabled: true)
                gate.engine?.tick()
                return gate.ruleStates()?.first.flatMap(input.assessed)
            }
        }
        #expect(sample() == [true, false])
        #expect(reads == 1)
        session.hasFreshEvidence = true
        #expect(sample() == [true, true])
        session.hasFreshEvidence = false
        session.hookState = .working
        #expect(sample() == [true, true])
        #expect(reads == 3)
    }
}
extension CompanionObservationAuditTests {
    @Test func copiedHooksRejectSymbolicLinkSourceAndAcceptVerifiedMissingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("target"), link = root.appendingPathComponent("link")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let copies = CompanionHookCopies(source: link, root: root.appendingPathComponent("scratch"))
        #expect(copies.read(now: Date(timeIntervalSince1970: 1_800_000_000)).isEmpty)
        #expect(copies.failed)
        let missing = CompanionHookCopies(source: root.appendingPathComponent("missing"), root: root.appendingPathComponent("missing-scratch"))
        #expect(missing.read(now: Date(timeIntervalSince1970: 1_800_000_000)).isEmpty)
        #expect(!missing.failed)
        let file = root.appendingPathComponent("file"); try Data().write(to: file)
        let nonDirectory = CompanionHookCopies(source: file, root: root.appendingPathComponent("file-scratch"))
        #expect(nonDirectory.read(now: Date(timeIntervalSince1970: 1_800_000_000)).isEmpty)
        #expect(nonDirectory.failed)
    }
}
