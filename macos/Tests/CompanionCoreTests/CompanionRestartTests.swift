import Foundation
import Testing
@testable import CompanionCore

struct CompanionRestartTests {
    @Test func onlyCanonicalHelperWithItsActualParentAcceptsThePID() {
        func parse(_ args: [String], bundle: String = "/Applications/Keepresso Mobile.app", executable: String = "/Applications/Keepresso Mobile.app/Contents/MacOS/KeepressoMac", parent: Int32 = 42, parentExecutable: String? = "/Applications/Keepresso Mobile.app/Contents/MacOS/KeepressoMac") -> Int32? {
            CompanionRelaunch.parent(arguments: args, bundlePath: bundle, executablePath: executable, actualParent: parent, ownPID: 43, parentExecutablePath: parentExecutable)
        }
        let valid = ["/Applications/Keepresso Mobile.app/Contents/MacOS/KeepressoMac", "--relaunch-companion", "42"]
        #expect(parse(valid) == 42)
        #expect(parse(valid, bundle: "/fixture/Keepresso Mobile.app") == nil)
        #expect(parse(valid, executable: "/fixture/KeepressoMac") == nil)
        #expect(parse(valid, parent: 1) == nil)
        #expect(parse(valid, parentExecutable: "/fixture/arbitrary-parent") == nil)
        #expect(parse(valid, parentExecutable: nil) == nil)
        #expect(parse(valid + ["https://example.invalid"]) == nil)
        for pid in ["0", "1", "-1", "43", "invalid", "2147483648", " 42", "042"] {
            #expect(parse([valid[0], valid[1], pid]) == nil)
        }
        #expect(parse([valid[0], "--other", "42"]) == nil)
    }

    @Test @MainActor func helperOpensOnceOnlyAfterParentExitAndNeverAfterTimeoutOrCancellation() async {
        var alive = true, instant: TimeInterval = 0, opens = 0, sleeps = 0
        let result = await CompanionRelaunch.waitForParentExit(parentPID: 42, ownPID: 43, now: { instant }, isAlive: { pid in
            #expect(pid == 42); return alive
        }, pause: {
            sleeps += 1; instant += 0.1; if sleeps == 3 { alive = false }
        }, open: { opens += 1; return true })
        #expect(result && opens == 1 && sleeps == 3)
        opens = 0; instant = 0
        let timeout = await CompanionRelaunch.waitForParentExit(parentPID: 42, ownPID: 43, now: { instant }, isAlive: { _ in true }, pause: { instant += 1 }, open: { opens += 1; return true })
        #expect(!timeout && instant == 10 && opens == 0)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await CompanionRelaunch.waitForParentExit(parentPID: 42, ownPID: 43, now: { 0 }, isAlive: { _ in false }, pause: {}, open: { opens += 1; return true })
        }
        #expect(await cancelled.value == false && opens == 0)
        for pid: Int32 in [0, 1, -1, 43] {
            #expect(await CompanionRelaunch.waitForParentExit(parentPID: pid, ownPID: 43, now: { 0 }, isAlive: { _ in false }, pause: {}, open: { opens += 1; return true }) == false)
        }
        #expect(opens == 0)
    }

    @Test @MainActor func launchFailureNeverCheckpointsOrQuitsAndAcknowledgementPrecedesBoth() async {
        let restart = CompanionRestartRequest()
        var events: [String] = []
        #expect(await restart.perform(launch: { events.append("launch-failed"); return false }, checkpoint: { events.append("checkpoint"); return true }, quit: { events.append("quit") }) == false)
        #expect(events == ["launch-failed"])
        events = []
        #expect(await restart.perform(launch: { events.append("helper-ready"); return true }, checkpoint: { events.append("checkpoint"); return true }, quit: { events.append("quit") }))
        #expect(events == ["helper-ready", "checkpoint", "quit"])
        events = []
        #expect(await restart.perform(launch: { true }, checkpoint: { false }, cancelHelper: { events.append("cancel-helper") }, quit: { events.append("quit") }) == false)
        #expect(events == ["cancel-helper"])
    }
}

extension CompanionRestartTests {
    @Test @MainActor func checkpointPrecedesSheetDismissalAndQuitCannotRunWithModalSetup() async {
        let restart=CompanionRestartRequest()
        var checkpointed=false,modalOpen=true,quit=false
        let accepted=await restart.perform(launch:{true},checkpoint:{checkpointed=true;return true},dismissSetup:{
            #expect(checkpointed);modalOpen=false
        },quit:{#expect(!modalOpen);quit=true})
        #expect(accepted && quit)
        var dismissed=false
        let rejected=await restart.perform(launch:{true},checkpoint:{false},dismissSetup:{dismissed=true},quit:{Issue.record("Failed checkpoint must not quit")})
        #expect(!rejected)
        #expect(!dismissed)
    }

    @Test @MainActor func cancelledWaitAndOpenFailureNeverReportRelaunchSuccess() async {
        var opens = 0
        #expect(await CompanionRelaunch.waitForParentExit(parentPID: 42, ownPID: 43, now: { 0 }, isAlive: { _ in true }, pause: { throw CancellationError() }, open: { opens += 1; return true }) == false)
        #expect(opens == 0)
        #expect(await CompanionRelaunch.waitForParentExit(parentPID: 42, ownPID: 43, now: { 0 }, isAlive: { _ in false }, pause: {}, open: { opens += 1; return false }) == false)
        #expect(opens == 1)
    }

    @Test @MainActor func pendingRestartRejectsDuplicateClicksAndCancellationDoesNotQuit() async {
        let restart = CompanionRestartRequest()
        var acknowledgement: CheckedContinuation<Bool, Never>?
        var quitCount = 0, launches = 0, helperCancellations = 0
        let first = Task { @MainActor in
            await restart.perform(launch: { launches += 1; return await withCheckedContinuation { acknowledgement = $0 } }, checkpoint: { true }, cancelHelper: { helperCancellations += 1 }, quit: { quitCount += 1 })
        }
        for _ in 0..<200 where acknowledgement == nil { await Task.yield() }
        #expect(acknowledgement != nil)
        #expect(await restart.perform(launch: { launches += 1; return true }, checkpoint: { true }, quit: { quitCount += 1 }) == false)
        first.cancel(); acknowledgement?.resume(returning: true)
        #expect(await first.value == false && launches == 1 && quitCount == 0 && helperCancellations == 1)
    }
}


extension CompanionRestartTests {
    @Test @MainActor func nativeOpenCompletionRequiresFreshLiveProcessInsteadOfHelperOrParent() async {
        let cases: [(pid: Int32?, terminated: Bool, error: Bool, accepted: Bool)] = [
            (44, false, false, true),
            (43, false, false, false), // Same-bundle relaunch helper.
            (42, false, false, false), // Retired parent's Launch Services entry.
            (nil, false, false, false),
            (0, false, false, false),
            (1, false, false, false),
            (-1, false, false, false),
            (44, true, false, false),
            (44, false, true, false)
        ]
        for sample in cases {
            var opens = 0
            let result = await CompanionRelaunch.waitForParentExit(parentPID: 42, ownPID: 43,
                now: { 0 }, isAlive: { _ in false }, pause: {}, open: {
                    opens += 1
                    return CompanionRelaunch.acceptsOpenedApplication(processIdentifier: sample.pid,
                        terminated: sample.terminated, errorOccurred: sample.error,
                        parentPID: 42, helperPID: 43)
                })
            #expect(result == sample.accepted)
            #expect(opens == 1) // No retry or fallback instance on a reused/bad callback.
        }
    }
}
