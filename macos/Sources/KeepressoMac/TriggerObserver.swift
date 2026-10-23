import Foundation
import CompanionCore
import KeepressoCore

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
            let detail=state.details.map{TriggerPreview.Detail(label:$0.label,active:$0.active,agent:$0.agent)}
            rows.append(.init(id:String(index),label:state.rule.label,satisfied:satisfied,inGrace:state.inGrace,graceRemaining:state.graceRemaining,details:detail))
        }
        preview.rules=rows
        preview.checkedAt=Date()
        let values=rows.map(\.satisfied)
        if settings.ruleSet.combine == .any {preview.combined=values.contains(true) ? true:(values.contains(where:{$0==nil}) ? nil:false)}
        else {preview.combined=values.contains(false) ? false:(values.contains(where:{$0==nil}) ? nil:!values.isEmpty)}
        if values.contains(where:{$0==nil}) {preview.state="unknown";preview.message="Some inputs or the initial asynchronous agent assessment are unconfirmed. Grace in this preview may differ from Keepresso; Resume can allow sleep."}
        else {preview.state="ready";preview.checkedAt=Date();preview.message="Condition snapshot from Keepresso 1.27.0. Grace history is independent; Resume can allow sleep."}
        return preview
    }
    private func fail(_ message:String)->TriggerPreview{preview.state=preview.checkedAt==nil ? "unknown":"stale";preview.combined=nil;preview.message=message;return preview}
}

/// Parent process owns only the last preview; all engine work is in the bounded
/// child. Private async caches/subprocesses cannot outlive the worker group.
@MainActor final class TriggerObserver {
    private(set) var preview=TriggerPreview();private var running=false
    private var generation=0
    func invalidate(){generation+=1;preview.state=preview.checkedAt==nil ? "unknown":"stale";preview.combined=nil;preview.message="Waiting for a fresh check after Keepresso restarts."}
    func markStale(){if preview.checkedAt != nil{preview.state="stale";preview.message="Native session or settings changed. Refresh conditions."}}
    func refresh(version:String?)async ->TriggerPreview{
        guard !running else{return preview};running=true;preview.state="checking";defer{running=false}
        let began=generation
        guard version=="1.27.0",let executable=Bundle.main.executableURL else{return fail("The installed Keepresso version is incompatible with the bundled observer.")}
        do{
            let data=try await ObserverScratch.withDirectory{scratch in try await BoundedWorker.run(executable:executable,arguments:["--observe-triggers","--observer-scratch",scratch.path],timeout:5,outputLimit:65536)}
            guard began==generation,!Task.isCancelled else{return preview}
            var result=try WireJSON.decoder.decode(TriggerPreview.self,from:data)
            if result.checkedAt==nil{result.checkedAt=preview.checkedAt;if preview.checkedAt != nil{result.state="stale"}}
            preview=result;return preview
        }catch{guard began==generation,!Task.isCancelled else{return preview};return fail("Trigger refresh exceeded its five-second budget or its input/output was unavailable. Worker stopped; previous assessment time preserved.")}
    }
    private func fail(_ message:String)->TriggerPreview{preview.state=preview.checkedAt==nil ? "unknown":"stale";preview.combined=nil;preview.message=message;return preview}
}
