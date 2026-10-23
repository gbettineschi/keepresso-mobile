import Foundation
public enum CompanionObserverSettings {
    private struct StrictRuleSet:Decodable { let combine:CombineMode;let rules:[TriggerRule] }
    private struct StrictRoot:Decodable {let triggersEnabled:Bool;let ruleSet:StrictRuleSet}
    public static func decode(_ data:Data)throws -> KeepressoSettings {
        guard data.count<=1048576 else{throw ObserverError.invalidSettings}
        // Upstream RuleSet intentionally drops unknown rules. Decode every rule
        // directly first so a newer rule cannot silently become 'no match'.
        let strict=try JSONDecoder().decode(StrictRoot.self,from:data)
        let decoded=try JSONDecoder().decode(KeepressoSettings.self,from:data)
        guard strict.ruleSet.rules==decoded.ruleSet.rules,strict.ruleSet.combine==decoded.ruleSet.combine else{throw ObserverError.invalidSettings}
        return decoded
    }
}
public enum ObserverError:Error {case invalidSettings,unavailable}
/// Upstream's reader prunes; every invocation receives disposable copies only.
/// This adapter shares a module to retain upstream's exact Codex Desktop
/// >10-minute rollout-freshness exception, without copying that algorithm.
public final class CompanionHookCopies:@unchecked Sendable {
    private let source:URL;private let root:URL;private let lock=NSLock()
    public private(set) var failed=false
    public init(source:URL=AgentHooks.directoryURL(),root:URL=FileManager.default.temporaryDirectory.appendingPathComponent("keepresso-hooks-"+UUID().uuidString)){self.source=source;self.root=root}
    public func read(now:Date)->[AgentHooks.HookRecord]{
        lock.lock();defer{lock.unlock()}
        let fm=FileManager.default;let directory=root.appendingPathComponent(UUID().uuidString)
        do {
            try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);defer{try? fm.removeItem(at:directory);try? fm.removeItem(at:root)}
            if !fm.fileExists(atPath:source.path){return []} // no hooks configured is valid, not evidence of no agents
            let urls=try fm.contentsOfDirectory(at:source,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard urls.count<=4096 else{throw ObserverError.unavailable}
            var total=0
            for url in urls where url.pathExtension=="json" {
                let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                guard values.isRegularFile==true,values.isSymbolicLink != true,let size=values.fileSize,size<=262144 else{throw ObserverError.unavailable}
                total+=size;guard total<=8*1024*1024 else{throw ObserverError.unavailable}
                try Data(contentsOf:url).write(to:directory.appendingPathComponent(url.lastPathComponent),options:.atomic)
            }
            return AgentHooks.readHookRecords(now:now,in:directory,hasFreshSharedHostEvidence:{session in
                guard let written=PSAgentActivityMonitor.codexRolloutWrite(forSessionId:session,now:now)else{return false}
                return written>=now.addingTimeInterval(-PSAgentActivityMonitor.evidenceWindow(for:"codex"))
            })
        }catch{failed=true;return []}
    }
}
