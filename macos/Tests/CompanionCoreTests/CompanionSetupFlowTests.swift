import Foundation
import Testing
@testable import CompanionCore
import KeepressoCore

@MainActor private final class SetupMemory: CompanionSetupStorage {
    var data: Data?
    var dropWrites = false
    func load() -> Data? { data }
    func save(_ data: Data) { if !dropWrites { self.data = data } }
}

@MainActor private final class SetupDriver: CompanionSetupPermissionDriving, CompanionSetupStatusNotifying {
    var onStatusChange: (() -> Void)?
    var onStatusRead: (() -> Void)?
    var states: [CompanionSetupKind: CompanionSetupStatus] = [:]
    var statusReads: [CompanionSetupKind] = []
    var requests: [CompanionSetupKind] = []
    var pending: [CompanionSetupKind: CheckedContinuation<CompanionSetupStatus, Never>] = [:]
    func status(for kind: CompanionSetupKind) -> CompanionSetupStatus { statusReads.append(kind); onStatusRead?(); return states[kind] ?? .undetermined }
    func request(_ kind: CompanionSetupKind) async -> CompanionSetupStatus {
        requests.append(kind)
        return await withCheckedContinuation { pending[kind] = $0 }
    }
    func answer(_ kind: CompanionSetupKind, _ status: CompanionSetupStatus) {
        states[kind] = status
        pending.removeValue(forKey: kind)?.resume(returning: status)
    }
    func cancel() {} // Deliberately simulate an OS callback which ignores cancellation.
}

struct CompanionSetupFlowTests {
    @Test @MainActor func missingValidatedIdentityNeverPersistsOrReusesSetup() async {
        let memory = SetupMemory(), driver = SetupDriver()
        driver.states[.bluetooth] = .authorized
        let invalid = scope(build: "")
        let flow = CompanionSetupFlow(scope: { invalid }, driver: driver, storage: memory)
        flow.presentIfNeeded(); await flow.start()
        #expect(!flow.checkpointForRestart())
        flow.finish()
        #expect(memory.data == nil)
        memory.data = Data(#"{"version":1,"scope":{"buildIdentity":"","requirements":["nearby"],"steps":["bluetooth"]},"deferred":false,"outcomes":[],"resumeSummary":false}"#.utf8)
        let next = CompanionSetupFlow(scope: { invalid }, driver: driver, storage: memory)
        next.presentIfNeeded()
        #expect(next.presented)
    }

    @Test @MainActor func certificateUpdateDoesNotRestartCompletedOrDeferredSetup() async {
        let memory = SetupMemory(), driver = SetupDriver()
        driver.states[.bluetooth] = .authorized
        let first = PrivacyCertificateFixtures.authority("build-A")
        var required = scope(build: first)
        let flow = CompanionSetupFlow(scope: { required }, driver: driver, storage: memory)
        flow.presentIfNeeded(); await flow.start(); flow.finish()
        required = scope(build: PrivacyCertificateFixtures.authority("build-B"))
        let updated = CompanionSetupFlow(scope: { required }, driver: driver, storage: memory)
        updated.presentIfNeeded()
        #expect(!updated.presented)
        driver.states[.bluetooth] = .denied
        updated.review(); await updated.start(); updated.deferSetup()
        let deferred = CompanionSetupFlow(scope: { required }, driver: driver, storage: memory)
        deferred.presentIfNeeded()
        #expect(!deferred.presented)
        #expect(driver.requests.isEmpty)
        required = scope(build: PrivacyCertificateFixtures.authority("build-C", certificate: PrivacyCertificateFixtures.b))
        deferred.presentIfNeeded()
        #expect(deferred.presented)
    }

    @MainActor private func settle(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
        #expect(condition())
    }
    @MainActor private func scope(_ needs: [String] = ["nearby"], _ steps: [CompanionSetupKind] = [.bluetooth], build: String = "fixture-code") -> CompanionSetupScope {
        CompanionSetupScope(buildIdentity: build, requirements: needs, steps: steps)
    }

    @Test @MainActor func foregroundEvaluationPresentsWithoutRequestingAndOneContinueSerializesChoices() async {
        let driver = SetupDriver(), memory = SetupMemory()
        let flow = CompanionSetupFlow(scope: { scope(["nearby", "ssid", "calendar"], [.bluetooth, .location, .calendar]) }, driver: driver, storage: memory)
        #expect(!flow.presented)
        flow.presentIfNeeded()
        #expect(flow.presented)
        #expect(driver.requests.isEmpty)
        let task = Task { await flow.start() }
        await settle { driver.requests == [.bluetooth] }
        #expect(flow.current == .bluetooth)
        let duplicate = Task { await flow.start() }
        await duplicate.value
        #expect(driver.requests == [.bluetooth])
        driver.answer(.bluetooth, .denied)
        await settle { driver.requests == [.bluetooth, .location] }
        driver.answer(.location, .authorized)
        await settle { driver.requests == [.bluetooth, .location, .calendar] }
        driver.answer(.calendar, .authorized)
        await task.value
        #expect(flow.phase == .summary)
        #expect(!flow.running)
        #expect(flow.outcomes[.bluetooth] == .denied)
        #expect(flow.outcomes[.location] == .authorized)
        #expect(memory.data == nil) // Summary still needs explicit Finish.
    }

    @Test @MainActor func alreadyGrantedAndDeniedRestrictedStepsNeverReprompt() async {
        let driver = SetupDriver()
        driver.states = [.bluetooth: .authorized, .location: .denied, .calendar: .restricted]
        let flow = CompanionSetupFlow(scope: { scope(["nearby", "ssid", "calendar"], [.bluetooth, .location, .calendar]) }, driver: driver, storage: SetupMemory())
        flow.presentIfNeeded()
        await flow.start()
        #expect(driver.requests.isEmpty)
        #expect(flow.outcomes == [.bluetooth: .authorized, .location: .denied, .calendar: .restricted])
        #expect(flow.phase == .summary)
    }

    @Test @MainActor func finishedAndDeferredScopesDoNotNagButNewNeedsAndNewCodeReopen() async {
        let memory = SetupMemory(), driver = SetupDriver()
        driver.states[.bluetooth] = .authorized
        var required = scope()
        let flow = CompanionSetupFlow(scope: { required }, driver: driver, storage: memory)
        flow.presentIfNeeded()
        await flow.start()
        flow.finish()
        #expect(!flow.presented)
        flow.presentIfNeeded()
        #expect(!flow.presented)
        required = scope(["nearby", "calendar"], [.bluetooth, .calendar])
        flow.presentIfNeeded()
        #expect(flow.presented)
        flow.deferSetup()
        let reopened = CompanionSetupFlow(scope: { required }, driver: driver, storage: memory)
        reopened.presentIfNeeded()
        #expect(!reopened.presented)
        reopened.review()
        #expect(reopened.presented)
        reopened.deferSetup()
        required = scope([], [], build: "new-code")
        reopened.presentIfNeeded()
        #expect(reopened.presented)
    }

    @Test @MainActor func removingRequirementsDoesNotNagAndChangesDuringRunAreNotSilentlyCompleted() async {
        let memory = SetupMemory(), driver = SetupDriver()
        var required = scope(["nearby", "folder:/fixture/A"], [.bluetooth, .folders])
        driver.states = [.bluetooth: .authorized, .folders: .authorized]
        let flow = CompanionSetupFlow(scope: { required }, driver: driver, storage: memory)
        flow.review()
        await flow.start()
        required = scope(["nearby", "folder:/fixture/B"], [.bluetooth, .folders])
        flow.finish()
        flow.presentIfNeeded()
        #expect(flow.presented)
        flow.deferSetup()
        required = scope()
        flow.presentIfNeeded()
        #expect(!flow.presented)
    }

    @Test @MainActor func lifecycleCancellationRejectsLateResultsWithoutDeferringAndAllowsRestart() async {
        let memory = SetupMemory(), driver = SetupDriver()
        let flow = CompanionSetupFlow(scope: { scope(["nearby", "ssid"], [.bluetooth, .location]) }, driver: driver, storage: memory)
        flow.review()
        let oldRun = Task { await flow.start() }
        await settle { driver.pending[.bluetooth] != nil }
        flow.cancelForLifecycleChange()
        await oldRun.value
        #expect(!flow.running)
        #expect(!flow.presented)
        #expect(memory.data == nil)
        driver.answer(.bluetooth, .authorized)
        await Task.yield()
        #expect(flow.outcomes.isEmpty)
        #expect(driver.requests == [.bluetooth])
        flow.presentIfNeeded()
        #expect(flow.presented)
        flow.deferSetup()
    }

    @Test @MainActor func skipCurrentAdvancesEvenIfExternalOperationIgnoresCancellation() async {
        let driver = SetupDriver()
        driver.states[.accessibility] = .authorized
        let flow = CompanionSetupFlow(scope: { scope(["steam", "remote"], [.steam, .accessibility]) }, driver: driver, storage: SetupMemory())
        flow.review()
        let task = Task { await flow.start() }
        await settle { driver.pending[.steam] != nil }
        flow.skipCurrent()
        await task.value
        #expect(flow.outcomes[.steam] == .skipped)
        #expect(flow.outcomes[.accessibility] == .authorized)
        #expect(flow.phase == .summary)
        driver.answer(.steam, .authorized)
        await Task.yield()
        #expect(flow.outcomes[.steam] == .skipped)
    }

    @Test @MainActor func cancelledCallerReleasesRunAndNeverAdvancesToAnotherPermission() async {
        let driver = SetupDriver(), memory = SetupMemory()
        let flow = CompanionSetupFlow(scope: { scope(["nearby", "ssid"], [.bluetooth, .location]) }, driver: driver, storage: memory)
        flow.review()
        let task = Task { await flow.start() }
        await settle { driver.pending[.bluetooth] != nil }
        task.cancel()
        await task.value
        #expect(!flow.running)
        #expect(memory.data == nil)
        driver.answer(.bluetooth, .authorized)
        await Task.yield()
        #expect(driver.requests == [.bluetooth])
    }

    @Test @MainActor func finishBeforeSummaryCannotPersistACompletionAndMalformedStorageDefaultsToSetup() {
        let driver = SetupDriver(), memory = SetupMemory()
        memory.data = Data("not a record".utf8)
        let flow = CompanionSetupFlow(scope: { scope() }, driver: driver, storage: memory)
        flow.presentIfNeeded()
        flow.finish()
        #expect(flow.presented)
        #expect(memory.data == Data("not a record".utf8))
    }

    @Test @MainActor func lateCallbackFromCancelledRunCannotResolveAReplacementRun() async {
        let driver = SetupDriver()
        let flow = CompanionSetupFlow(scope: { scope() }, driver: driver, storage: SetupMemory())
        flow.review()
        let first = Task { await flow.start() }
        await settle { driver.pending[.bluetooth] != nil }
        let oldAnswer = driver.pending.removeValue(forKey: .bluetooth)
        flow.cancelForLifecycleChange()
        await first.value
        flow.review()
        let second = Task { await flow.start() }
        await settle { driver.requests.count == 2 && driver.pending[.bluetooth] != nil }
        oldAnswer?.resume(returning: .denied)
        for _ in 0..<10 { await Task.yield() }
        #expect(flow.running)
        #expect(flow.current == .bluetooth)
        #expect(flow.outcomes.isEmpty)
        driver.answer(.bluetooth, .authorized)
        await second.value
        #expect(flow.outcomes[.bluetooth] == .authorized)
        #expect(flow.phase == .summary)
    }

    @Test @MainActor func explicitDeferralDuringARequestStopsTheSequenceAndSurvivesNewController() async {
        let driver = SetupDriver(), memory = SetupMemory()
        let requirements = scope(["nearby", "ssid"], [.bluetooth, .location])
        let flow = CompanionSetupFlow(scope: { requirements }, driver: driver, storage: memory)
        // start is not itself a presentation action, including on hidden startup.
        await flow.start()
        #expect(driver.requests.isEmpty)
        flow.presentIfNeeded()
        let task = Task { await flow.start() }
        await settle { driver.pending[.bluetooth] != nil }
        flow.deferSetup()
        await task.value
        driver.answer(.bluetooth, .authorized)
        for _ in 0..<10 { await Task.yield() }
        #expect(driver.requests == [.bluetooth])
        let next = CompanionSetupFlow(scope: { requirements }, driver: driver, storage: memory)
        next.presentIfNeeded()
        #expect(!next.presented)
        next.review()
        #expect(next.presented)
    }


    @Test(arguments: [false, true]) @MainActor
    func observerCancellationBeforeWaiterCreationCannotStartConsentOrCompleteScope(deferExplicitly: Bool) async throws {
        let driver = SetupDriver(), memory = SetupMemory()
        let requirements = scope(["nearby", "ssid"], [.bluetooth, .location])
        let flow = CompanionSetupFlow(scope: { requirements }, driver: driver, storage: memory)
        flow.review()
        var interrupted = false, returned = false
        flow.onChange = {
            guard flow.current != nil, !interrupted else { return }
            interrupted = true
            if deferExplicitly { flow.deferSetup() }
            else { flow.cancelForLifecycleChange() }
        }
        let task = Task { await flow.start(); returned = true }
        for _ in 0..<200 where !returned { await Task.yield() }
        #expect(interrupted)
        #expect(returned) // No owner/OS answer may be necessary to release start.
        #expect(driver.requests.isEmpty)
        #expect(!flow.presented)
        #expect(!flow.running)
        #expect(flow.outcomes.isEmpty)
        let saved = memory.data
        if deferExplicitly {
            let record = try JSONSerialization.jsonObject(with: #require(saved)) as? [String: Any]
            #expect(record?["deferred"] as? Bool == true)
        } else {
            #expect(saved == nil)
        }
        // Release a request only if the regression occurred, so RED terminates
        // while still proving no completion/continuation may revive the flow.
        driver.answer(.bluetooth, .authorized)
        await task.value
        flow.finish()
        #expect(memory.data == saved)
        #expect(flow.outcomes.isEmpty)
        #expect(!flow.presented)
        #expect(driver.requests.filter { $0 == .location }.isEmpty)
        flow.onChange = nil
        flow.presentIfNeeded()
        #expect(flow.presented == !deferExplicitly)
    }

}
extension CompanionSetupFlowTests {
    @Test @MainActor func unpairedShowQRWaitsForSettledForegroundOwnership() async {
        let driver = SetupDriver(), memory = SetupMemory()
        var managed = false, manualFallback = false, visible = true
        let flow = CompanionSetupFlow(scope: { scope() }, driver: driver, storage: memory,
            eligible: { visible && (managed || manualFallback) })
        driver.states[.bluetooth] = .authorized
        // This is the same pairing/setup boundary used by the Mac model.
        #expect(!flow.preparePairing(bluetoothAuthorized: false))
        flow.review(); flow.presentIfNeeded(); await flow.start()
        #expect(!flow.presented && driver.requests.isEmpty && memory.data == nil)
        flow.cancelForLifecycleChange(); driver.states = [:]
        for useManaged in [true, false] {
            managed = useManaged; manualFallback = !useManaged
            #expect(!flow.preparePairing(bluetoothAuthorized: false))
            #expect(flow.presented)
            let run = Task { await flow.start() }
            await settle { driver.pending[.bluetooth] != nil }
            driver.answer(.bluetooth, .authorized)
            await run.value
            flow.finish()
            #expect(!flow.presented)
            driver.states = [:]
        }
        driver.states[.bluetooth] = .authorized
        visible = false
        #expect(!flow.preparePairing(bluetoothAuthorized: true))
        flow.review(); await flow.start()
        #expect(!flow.presented)
        visible = true; managed = false; manualFallback = false
        #expect(!flow.preparePairing(bluetoothAuthorized: true))
        manualFallback = true
        #expect(flow.preparePairing(bluetoothAuthorized: true))
    }
    @Test @MainActor func unsettledForegroundCannotStartPreviouslyPresentedSetup() async {
        let driver = SetupDriver()
        var eligible = true
        let flow = CompanionSetupFlow(scope: { scope() }, driver: driver, storage: SetupMemory(), eligible: { eligible })
        flow.review(); #expect(flow.presented)
        eligible = false; driver.states[.bluetooth] = .authorized
        await flow.start()
        #expect(driver.requests.isEmpty && !flow.running && flow.phase == .welcome)
        flow.cancelForLifecycleChange()
    }
}

extension CompanionSetupFlowTests {
    @Test @MainActor func visibleSummaryRefreshesGrantsAndRevocationsWithoutRepeatingLocalReads() async {
        let driver = SetupDriver(), memory = SetupMemory()
        let required = scope(["nearby", "folder:/fixture/A", "steam"], [.bluetooth, .folders, .steam])
        driver.states = [.bluetooth: .denied, .folders: .authorized, .steam: .authorized]
        let flow = CompanionSetupFlow(scope: { required }, driver: driver, storage: memory)
        flow.review(); await flow.start()
        driver.statusReads = []
        var publications = 0
        flow.onChange = { publications += 1 }
        driver.states = [.bluetooth: .authorized, .folders: .undetermined, .steam: .undetermined]
        flow.presentIfNeeded()
        #expect(flow.outcomes == [.bluetooth: .authorized, .folders: .authorized, .steam: .authorized])
        #expect(driver.statusReads == [.bluetooth])
        #expect(publications == 1)
        driver.states[.bluetooth] = .denied
        flow.presentIfNeeded()
        #expect(flow.outcomes[.bluetooth] == .denied)
        #expect(publications == 2)
        #expect(driver.requests.isEmpty && memory.data == nil)
    }
}

extension CompanionSetupFlowTests {
    @Test @MainActor func passiveRefreshKeepsVisibilityRunningEligibilityAndCancellationGates() async {
        let driver = SetupDriver()
        var eligible = true
        let flow = CompanionSetupFlow(scope: { scope() }, driver: driver, storage: SetupMemory(), eligible: { eligible })
        flow.refreshFrameworkStatuses(); #expect(driver.statusReads.isEmpty)
        flow.review(); flow.refreshFrameworkStatuses(); #expect(driver.statusReads.isEmpty)
        let task = Task { await flow.start() }
        await settle { driver.pending[.bluetooth] != nil }
        driver.statusReads = []
        driver.onStatusChange?(); flow.presentIfNeeded()
        #expect(driver.statusReads.isEmpty && flow.running)
        driver.answer(.bluetooth, .denied); await task.value
        driver.statusReads = []
        eligible = false; driver.onStatusChange?()
        #expect(driver.statusReads.isEmpty && flow.outcomes[.bluetooth] == .denied)
        eligible = true
        driver.states[.bluetooth] = .authorized
        driver.onStatusChange?()
        #expect(flow.outcomes[.bluetooth] == .authorized)
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; flow.refreshFrameworkStatuses() }
        driver.statusReads = []; await cancelled.value
        #expect(driver.statusReads.isEmpty)
        driver.onStatusRead = { flow.cancelForLifecycleChange() }
        flow.refreshFrameworkStatuses()
        #expect(!flow.presented && flow.outcomes.isEmpty)
        driver.statusReads = []; driver.onStatusRead = nil
        driver.onStatusChange?()
        #expect(driver.statusReads.isEmpty)
    }

    @Test @MainActor func manualSummaryRecheckExplicitlyRevalidatesLocalAccessWithoutRepromptingDeniedFrameworks() async {
        let driver = SetupDriver()
        var required = scope(["nearby", "folder:/fixture/A", "steam"], [.bluetooth, .folders, .steam])
        let original = required
        driver.states = [.bluetooth: .denied, .folders: .authorized, .steam: .authorized]
        let flow = CompanionSetupFlow(scope: { required }, driver: driver, storage: SetupMemory())
        await flow.manualRecheck(); #expect(!flow.presented && driver.requests.isEmpty)
        flow.review(); await flow.start()
        required = scope(["nearby", "folder:/fixture/B", "calendar"], [.bluetooth, .folders, .calendar])
        driver.states[.folders] = .undetermined; driver.states[.steam] = .undetermined
        driver.onStatusChange?()
        #expect(driver.requests.isEmpty)
        let run = Task { await flow.manualRecheck() }
        await settle { driver.pending[.folders] != nil }
        #expect(driver.requests == [.folders])
        await flow.manualRecheck()
        driver.answer(.folders, .denied)
        await settle { driver.pending[.steam] != nil }
        driver.answer(.steam, .authorized); await run.value
        #expect(flow.phase == .summary && flow.activeScope == original)
        #expect(flow.outcomes == [.bluetooth: .denied, .folders: .denied, .steam: .authorized])
        #expect(driver.requests == [.folders, .steam])
    }

    @Test @MainActor func restartGuidanceRequiresExplicitSettingsReturnAndClearsOnGrant() async {
        let driver = SetupDriver()
        driver.states = [.bluetooth: .denied, .folders: .denied]
        let flow = CompanionSetupFlow(scope: { scope(["nearby", "folder:/fixture/A"], [.bluetooth, .folders]) }, driver: driver, storage: SetupMemory())
        flow.review(); await flow.start()
        flow.refreshFrameworkStatuses(returningFromSettings: true)
        #expect(!flow.restartSuggested)
        flow.settingsOpened(for: .folders)
        flow.refreshFrameworkStatuses(returningFromSettings: true)
        #expect(!flow.restartSuggested)
        flow.settingsOpened(for: .bluetooth)
        driver.onStatusChange?(); #expect(!flow.restartSuggested)
        flow.refreshFrameworkStatuses(returningFromSettings: true)
        #expect(flow.restartSuggested)
        driver.states[.bluetooth] = .authorized; driver.onStatusChange?()
        #expect(!flow.restartSuggested && driver.requests.isEmpty)
        driver.states[.bluetooth] = .denied; driver.onStatusChange?()
        #expect(!flow.restartSuggested) // A later revocation is not a failed Settings return.
        flow.settingsOpened(for: .bluetooth)
        flow.presentIfNeeded(returningFromSettings: true)
        #expect(flow.restartSuggested)
        flow.finish(); #expect(!flow.presented)
    }

    @Test @MainActor func explicitRestartRestoresOnlyExactBuildAndScopeAndNeverStartsLocalReads() async {
        let driver = SetupDriver(), memory = SetupMemory()
        let required = scope(["nearby", "folder:/fixture/A", "steam"], [.bluetooth, .folders, .steam])
        driver.states = [.bluetooth: .denied, .folders: .authorized, .steam: .authorized]
        let flow = CompanionSetupFlow(scope: { required }, driver: driver, storage: memory)
        #expect(!flow.checkpointForRestart())
        flow.review(); await flow.start()
        #expect(flow.checkpointForRestart())
        let saved = memory.data
        flow.cancelForLifecycleChange()
        driver.statusReads = []
        driver.states = [.bluetooth: .authorized, .folders: .undetermined, .steam: .undetermined]
        let restored = CompanionSetupFlow(scope: { required }, driver: driver, storage: memory)
        restored.presentIfNeeded()
        #expect(restored.presented && restored.phase == .summary)
        #expect(restored.outcomes == [.bluetooth: .authorized, .folders: .authorized, .steam: .authorized])
        #expect(driver.statusReads == [.bluetooth] && driver.requests.isEmpty)
        restored.cancelForLifecycleChange()
        restored.presentIfNeeded(); #expect(!restored.presented) // Checkpoint consumed once.
        for changed in [scope(["nearby"], [.bluetooth]), scope(required.requirements + ["calendar"], required.steps + [.calendar]), scope(required.requirements, required.steps, build: "different-code"), scope(required.requirements, [.bluetooth, .steam, .folders])] {
            memory.data = saved
            let replacement = CompanionSetupFlow(scope: { changed }, driver: driver, storage: memory)
            replacement.presentIfNeeded()
            #expect(replacement.presented && replacement.phase == .welcome && replacement.outcomes.isEmpty)
        }
        memory.data = saved
        var visible = false
        let hidden = CompanionSetupFlow(scope: { required }, driver: driver, storage: memory, eligible: { visible })
        hidden.presentIfNeeded(); #expect(!hidden.presented && memory.data == saved)
        visible = true; hidden.presentIfNeeded(); #expect(hidden.phase == .summary)
        hidden.deferSetup()
        let deferred = CompanionSetupFlow(scope: { required }, driver: driver, storage: memory)
        deferred.presentIfNeeded(); #expect(!deferred.presented)
    }
}

extension CompanionSetupFlowTests {
    @Test @MainActor func checkpointRequiresAcknowledgedStorageAndCancellationLeavesNoRefresh() async {
        let driver = SetupDriver(), memory = SetupMemory()
        driver.states[.bluetooth] = .denied
        let flow = CompanionSetupFlow(scope: { scope() }, driver: driver, storage: memory)
        flow.review(); await flow.start()
        memory.dropWrites = true
        #expect(!flow.checkpointForRestart() && memory.data == nil)
        memory.dropWrites = false
        #expect(flow.checkpointForRestart())
        flow.finish()
        let reopened = CompanionSetupFlow(scope: { scope() }, driver: driver, storage: memory)
        reopened.presentIfNeeded()
        #expect(!reopened.presented) // Finish overwrites a pending checkpoint.
    }
}

extension CompanionSetupFlowTests {
    @Test @MainActor func manualRecheckRetainsSettingsRecoveryUntilGrantAndCannotReviveItAfterCancellation() async {
        let driver = SetupDriver()
        let required = scope(["nearby", "folder:/fixture/A"], [.bluetooth, .folders])
        driver.states = [.bluetooth: .denied, .folders: .authorized]
        let flow = CompanionSetupFlow(scope: { required }, driver: driver, storage: SetupMemory())
        flow.review(); await flow.start()
        flow.settingsOpened(for: .bluetooth)
        flow.presentIfNeeded(returningFromSettings: true)
        #expect(flow.restartSuggested)
        await flow.manualRecheck()
        #expect(flow.restartSuggested && flow.outcomes[.bluetooth] == .denied)
        #expect(driver.requests.isEmpty)
        driver.states[.bluetooth] = .authorized
        await flow.manualRecheck()
        #expect(!flow.restartSuggested)
        driver.states[.bluetooth] = .denied
        flow.refreshFrameworkStatuses()
        #expect(!flow.restartSuggested) // Grant consumed the old Settings return.

        flow.settingsOpened(for: .bluetooth)
        flow.presentIfNeeded(returningFromSettings: true)
        driver.states[.folders] = .undetermined
        let run = Task { await flow.manualRecheck() }
        await settle { driver.pending[.folders] != nil }
        flow.cancelForLifecycleChange()
        await run.value
        driver.answer(.folders, .authorized)
        await Task.yield()
        #expect(!flow.restartSuggested && !flow.presented)
        flow.review(); await flow.start()
        #expect(!flow.restartSuggested && flow.outcomes[.bluetooth] == .denied)
    }
}
