import Foundation
import CompanionCore
import KeepressoCore
import OSLog

private let triggerLog=Logger(subsystem:"local.keespresso.companion",category:"trigger-check")

@MainActor final class TriggerWorker {
    private(set) var preview=TriggerPreview();private var running=false
    func markStale(){if preview.checkedAt != nil{preview.state="stale";preview.message="Native session or settings changed. Refresh conditions."}}
    func refresh(version:String?,scratch:URL,folderConsent:Data?=nil) async -> TriggerPreview {
        guard !running else{return preview};running=true;defer{running=false}
        preview.state="checking"
        guard version == CompanionObserverSettings.supportedVersion,
              let defaults = UserDefaults(suiteName: "sh.gyorgy.keepresso"),
              let blob = defaults.data(forKey: UserDefaultsSettingsStore.defaultKey),
              let settings = try? CompanionObserverSettings.decode(blob)
        else { return fail("Saved rules are unavailable or incompatible with the bundled Keepresso engine.") }
        // The unchanged pinned engine matches rules. Audited lazy inputs keep
        // unavailable/partial/cold data separate from a verified inactive result.
        let copies=CompanionHookCopies(root:scratch.appendingPathComponent("hooks"))
        let consent=CompanionObservationConsent.decode(folderConsent)
        let folderPolicy=TriggerFolderAccess(configuredFolders:settings.ruleSet.rules.compactMap { rule in
            if case .downloadInFolder(let folder)=rule { return folder };return nil
        },buildIdentity:CompanionAuthorizationIdentity.current,consentData:consent?.folders)
        let steam=CompanionSteamObservation(buildIdentity:CompanionAuthorizationIdentity.current,consentData:consent?.steam)
        let inputs=CompanionObservationInputs(hookRecords:{copies.read(now:$0)},hooksAvailable:{!copies.failed},folderApproved:folderPolicy.isApproved,steam:steam,steamAvailable:{steam.hasCompleteReading})
        let cpuDisabled = Set(settings.evidenceOnlyAgentRuleIndices)
        let rules = Array(settings.ruleSet.rules.enumerated())
        let standardRules = rules.filter { !cpuDisabled.contains($0.offset) }
        let evidenceOnlyRules = rules.filter { cpuDisabled.contains($0.offset) }
        let groups = [
            (standardRules, standardRules.isEmpty ? nil : TriggerGateController(factory: inputs.factory)),
            (evidenceOnlyRules, evidenceOnlyRules.isEmpty ? nil : TriggerGateController(factory: inputs.evidenceOnlyFactory)),
        ]
        defer {
            for (_, gate) in groups { gate?.rebuild(rules: [], combine: .any, enabled: false) }
        }
        // Only explicit refresh runs these ticks. No SessionController or power
        // assertion is constructed; nothing remains scheduled after this loop.
        var states: [Int: RuleState] = [:]
        for i in 0..<6 {
            if Task.isCancelled{return fail("Refresh canceled.")}
            inputs.beginSample()
            states.removeAll(keepingCapacity: true)
            for (indexedRules, gate) in groups {
                guard let gate else { continue }
                // Same-rule rebuild clears the native UI cache but keeps
                // trigger instances, EMA and grace. Both groups share one read.
                gate.rebuild(rules: indexedRules.map(\.element), combine: settings.ruleSet.combine, enabled: true)
                gate.engine?.tick()
                for (rule, state) in zip(indexedRules, gate.ruleStates() ?? []) {
                    states[rule.offset] = state
                }
            }
            if i<5{try? await Task.sleep(nanoseconds:850_000_000)}
        }
        guard let latest = defaults.data(forKey: UserDefaultsSettingsStore.defaultKey),
              let latestSettings = try? CompanionObserverSettings.decode(latest),
              latestSettings == settings, states.count == rules.count
        else { return fail("Saved settings changed during refresh.") }
        var rows:[TriggerPreview.Rule]=[]
        for index in states.keys.sorted() {
            guard let state = states[index] else { continue }
            let satisfied=inputs.assessed(state)
            rows.append(.init(id:String(index),label:state.rule.label,satisfied:satisfied,inGrace:state.inGrace,graceRemaining:state.graceRemaining,details:[]))
        }
        preview.rules=rows
        preview.checkedAt=Date()
        let values=rows.map(\.satisfied)
        if settings.ruleSet.combine == .any {preview.combined=values.contains(true) ? true:(values.contains(where:{$0==nil}) ? nil:false)}
        else {preview.combined=values.contains(false) ? false:(values.contains(where:{$0==nil}) ? nil:!values.isEmpty)}
        if values.contains(where:{$0==nil}) {preview.state="unknown";preview.message="Some trigger inputs are unavailable."}
        else {preview.state="ready";preview.checkedAt=Date();preview.message=nil}
        return preview
    }
    private func fail(_ message:String)->TriggerPreview{triggerLog.error("Worker input check failed: \(message,privacy:.public)");preview.state="error";preview.combined=nil;preview.message="Couldn't check triggers. Try again.";return preview}
}

/// Parent process owns only the last preview; all engine work is in the bounded
/// child. Private async caches/subprocesses cannot outlive the worker group.
@MainActor final class TriggerObserver {
    private var history=ManualTriggerHistory()
    var preview:TriggerPreview { history.preview }
    private var running=false
    private var generation=0
    private var configuredRuleSet:Data?
    @discardableResult func syncRules(version:String?)->Bool {
        guard version==CompanionObserverSettings.supportedVersion,let defaults=UserDefaults(suiteName:"sh.gyorgy.keepresso"),let data=defaults.data(forKey:UserDefaultsSettingsStore.defaultKey) else {
            history.invalidate();return false
        }
        do {
            let settings=try CompanionObserverSettings.decode(data)
            let canonical=try WireJSON.encoder.encode(settings)
            configuredRuleSet=canonical
            history.configure(ruleSet:canonical,rules:settings.ruleSet.rules.enumerated().map{.init(id:String($0.offset),label:$0.element.label,satisfied:nil,inGrace:false,graceRemaining:nil,details:[])})
            return true
        } catch { history.invalidate();return false }
    }
    func invalidate() { generation+=1;history.invalidate();history.cancel() }
    func markStale() { history.invalidate() }
    func refresh(version:String?,folderConsent:Data?=nil)async ->TriggerPreview {
        guard !running else { return preview }
        guard syncRules(version:version) else { return fail("Saved rules are unavailable or incompatible.") }
        guard !Task.isCancelled else { history.cancel();return preview }
        running=true;history.begin();defer { running=false;history.cancel() }
        let began=generation
        let settingsAtStart=configuredRuleSet
        guard let executable=Bundle.main.executableURL else { return fail("The bundled observer could not be located.") }
        do {
            let started=ProcessInfo.processInfo.systemUptime
            // Includes process startup; the isolated child retains its 8s engine watchdog.
            let data=try await ObserverScratch.withDirectory{scratch in
                try TriggerFolderWorkerConsent.write(folderConsent,to:scratch)
                return try await BoundedWorker.run(executable:executable,arguments:["--observe-triggers","--observer-scratch",scratch.path],timeout:12,outputLimit:65536)
            }
            guard began==generation,!Task.isCancelled else { return preview }
            guard syncRules(version:version),configuredRuleSet==settingsAtStart else { return fail("Rules changed during the bounded check.") }
            let result=try WireJSON.decoder.decode(TriggerPreview.self,from:data)
            history.complete(result)
            triggerLog.info("Trigger check completed in \(ProcessInfo.processInfo.systemUptime-started,privacy:.public)s")
            return preview
        } catch {
            guard began==generation,!Task.isCancelled else { return preview }
            return fail("Bounded worker failed: \(String(describing:error)); previous assessment retained.")
        }
    }
    private func fail(_ message:String)->TriggerPreview {
        triggerLog.error("Trigger check failed: \(message,privacy:.public)")
        history.fail("Couldn't check triggers. Try again.");return preview
    }
}
