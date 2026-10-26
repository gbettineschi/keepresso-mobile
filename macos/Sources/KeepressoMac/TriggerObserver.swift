import Foundation
import CompanionCore
import KeepressoCore
import OSLog

private let triggerLog=Logger(subsystem:"local.keespresso.companion",category:"trigger-check")

@MainActor final class TriggerWorker {
    private(set) var preview=TriggerPreview();private var running=false
    func markStale(){if preview.checkedAt != nil{preview.state="stale";preview.message="Native session or settings changed. Refresh conditions."}}
    func refresh(version:String?,scratch:URL) async -> TriggerPreview {
        guard !running else{return preview};running=true;defer{running=false}
        preview.state="checking"
        guard version=="1.27.0",let defaults=UserDefaults(suiteName:"sh.gyorgy.keepresso"),let blob=defaults.data(forKey:UserDefaultsSettingsStore.defaultKey),let settings=try? CompanionObserverSettings.decode(blob) else{return fail("Saved rules are unavailable or incompatible with the bundled Keepresso 1.27.0 engine.")}
        // Preserve positive results from the pinned engine. HAL, directory-stat
        // and initial async-agent failures are swallowed by upstream monitors;
        // their negative results remain unknown until audited error-bearing
        // input adapters can establish complete reads.
        let copies=CompanionHookCopies(root:scratch.appendingPathComponent("hooks"))
        let monitor=PSAgentActivityMonitor(ttl:1,hookRecords:{copies.read(now:$0)})
        let gate=TriggerGateController(factory:TriggerFactory(agents:monitor))
        gate.rebuild(rules:settings.ruleSet.rules,combine:settings.ruleSet.combine,enabled:true)
        defer{gate.rebuild(rules:[],combine:.any,enabled:false);monitor.evidenceEnabled=false}
        // Only explicit refresh runs these ticks. No SessionController or power
        // assertion is constructed; nothing remains scheduled after this loop.
        var states:[RuleState]=[]
        for i in 0..<5 {
            if Task.isCancelled{return fail("Refresh canceled.")}
            gate.engine?.tick();states=gate.ruleStates() ?? []
            if i<4{try? await Task.sleep(nanoseconds:850_000_000)}
        }
        guard defaults.data(forKey:UserDefaultsSettingsStore.defaultKey)==blob,states.count==settings.ruleSet.rules.count else{return fail("Saved settings changed during refresh.")}
        var rows:[TriggerPreview.Rule]=[]
        for (index,state) in states.enumerated(){
            var satisfied:Bool?
            switch state.rule {
            case .agentActivity,.micInUse,.mediaInUse,.downloadInFolder:
                satisfied=AssessmentEvidence.positiveOnly(state.satisfied)
            default:satisfied=nil
            }
            rows.append(.init(id:String(index),label:state.rule.label,satisfied:satisfied,inGrace:state.inGrace,graceRemaining:state.graceRemaining,details:[]))
        }
        preview.rules=rows
        preview.checkedAt=Date()
        let values=rows.map(\.satisfied)
        if settings.ruleSet.combine == .any {preview.combined=values.contains(true) ? true:(values.contains(where:{$0==nil}) ? nil:false)}
        else {preview.combined=values.contains(false) ? false:(values.contains(where:{$0==nil}) ? nil:!values.isEmpty)}
        if values.contains(where:{$0==nil}) {preview.state="unknown";preview.message=nil}
        else {preview.state="ready";preview.checkedAt=Date();preview.message=nil}
        return preview
    }
    private func fail(_ message:String)->TriggerPreview{triggerLog.error("Worker input check failed: \(message,privacy:.public)");preview.state="error";preview.combined=nil;preview.message="Couldn't check triggers. Try again.";return preview}
}

/// Parent process owns only the last preview; all engine work is in the bounded
/// child. Private async caches/subprocesses cannot outlive the worker group.
@MainActor final class TriggerObserver {
    private(set) var preview=TriggerPreview();private var running=false
    private var generation=0
    private var configuredBlob:Data?
    @discardableResult func syncRules(version:String?)->Bool{
        guard version=="1.27.0",let defaults=UserDefaults(suiteName:"sh.gyorgy.keepresso"),let data=defaults.data(forKey:UserDefaultsSettingsStore.defaultKey) else{return false}
        guard data != configuredBlob else{return true}
        do{
            let settings=try CompanionObserverSettings.decode(data)
            configuredBlob=data;preview=TriggerPreview()
            preview.rules=settings.ruleSet.rules.enumerated().map{.init(id:String($0.offset),label:$0.element.label,satisfied:nil,inGrace:false,graceRemaining:nil,details:[])}
            return true
        }catch{_=fail("Saved settings are incompatible with the pinned observer.");return false}
    }
    func invalidate(){generation+=1;preview.state=preview.checkedAt==nil ? "unknown":"stale";preview.combined=nil;preview.message="Waiting for a fresh check after Keepresso restarts."}
    func markStale(){if preview.checkedAt != nil{preview.state="stale";preview.combined=nil;preview.message=nil}}
    func refresh(version:String?)async ->TriggerPreview{
        guard !running else{return preview}
        guard syncRules(version:version) else{return fail("Saved rules are unavailable or incompatible.")}
        running=true;preview.state="checking";defer{running=false}
        let began=generation
        let settingsAtStart=configuredBlob
        guard version=="1.27.0",let executable=Bundle.main.executableURL else{return fail("The installed Keepresso version is incompatible with the bundled observer.")}
        do{
            let started=ProcessInfo.processInfo.systemUptime
            let data=try await ObserverScratch.withDirectory{scratch in try await BoundedWorker.run(executable:executable,arguments:["--observe-triggers","--observer-scratch",scratch.path],timeout:8,outputLimit:65536)}
            guard began==generation,!Task.isCancelled else{return preview}
            guard UserDefaults(suiteName:"sh.gyorgy.keepresso")?.data(forKey:UserDefaultsSettingsStore.defaultKey)==settingsAtStart else{syncRules(version:version);return fail("Settings changed during the bounded check.")}
            var result=try WireJSON.decoder.decode(TriggerPreview.self,from:data)
            result.retainPriorAssessment(preview)
            if result.state=="error"{result.message="Couldn't check triggers. Try again."}
            triggerLog.info("Trigger check completed in \(ProcessInfo.processInfo.systemUptime-started,privacy:.public)s")
            preview=result;return preview
        }catch{guard began==generation,!Task.isCancelled else{return preview};return fail("Bounded worker failed: \(String(describing:error)); previous assessment retained.")}
    }
    private func fail(_ message:String)->TriggerPreview{triggerLog.error("Trigger check failed: \(message,privacy:.public)");preview.state="error";preview.combined=nil;preview.message="Couldn't check triggers. Try again.";return preview}
}
