import Foundation
public struct CompanionObserverSettings: Equatable, Encodable {
    public static let supportedVersion = "1.30.0"
    public let ruleSet: RuleSet
    public let evidenceOnlyAgentRuleIndices: [Int]

    private struct StrictRule: Decodable {
        private enum CodingKeys: String, CodingKey { case agentActivity }
        private struct AgentActivity: Decodable {
            struct Options: Decodable { let allowCPUFallback: Bool? }
            let _0: Options
        }

        let value: TriggerRule
        let evidenceOnly: Bool

        init(from decoder: Decoder) throws {
            value = try TriggerRule(from: decoder)
            if case .agentActivity = value {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let agent = try container.decode(AgentActivity.self, forKey: .agentActivity)
                evidenceOnly = agent._0.allowCPUFallback == false
            } else {
                evidenceOnly = false
            }
        }
    }
    private struct StrictRuleSet: Decodable { let combine: CombineMode; let rules: [StrictRule] }
    private struct StrictRoot: Decodable { let triggersEnabled: Bool; let ruleSet: StrictRuleSet }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw ObserverError.invalidSettings }
        // Upstream RuleSet intentionally drops unknown rules. Decode every rule
        // directly first so a newer rule cannot silently become 'no match'.
        let decoder = JSONDecoder()
        let strict = try decoder.decode(StrictRoot.self, from: data)
        let decoded = try decoder.decode(KeepressoSettings.self, from: data)
        guard strict.ruleSet.rules.map(\.value) == decoded.ruleSet.rules,
              strict.ruleSet.combine == decoded.ruleSet.combine else { throw ObserverError.invalidSettings }

        // Local builds can save a per-rule CPU override. The upstream engine
        // already supports evidence-only sessions, so retain the option here.
        let evidenceOnly = strict.ruleSet.rules.enumerated().compactMap { index, rule in
            rule.evidenceOnly ? index : nil
        }
        return Self(ruleSet: decoded.ruleSet, evidenceOnlyAgentRuleIndices: evidenceOnly)
    }
}
public enum ObserverError:Error {case invalidSettings,unavailable}
/// Upstream's reader prunes; every invocation receives disposable copies only.
/// This adapter shares a module to retain upstream's exact Codex Desktop
/// >10-minute rollout-freshness exception, without copying that algorithm.
public final class CompanionHookCopies:@unchecked Sendable {
    private let source:URL;private let root:URL;private let lock=NSLock()
    private var failedStorage=false
    public var failed:Bool { lock.lock();defer{lock.unlock()};return failedStorage }
    public init(source:URL=AgentHooks.directoryURL(),root:URL=FileManager.default.temporaryDirectory.appendingPathComponent("keepresso-hooks-"+UUID().uuidString)){self.source=source;self.root=root}
    public func read(now:Date)->[AgentHooks.HookRecord]{
        lock.lock();defer{lock.unlock()}
        let fm=FileManager.default;let directory=root.appendingPathComponent(UUID().uuidString)
        do {
            try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);defer{try? fm.removeItem(at:directory);try? fm.removeItem(at:root)}
            do {
                let values=try source.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard values.isDirectory==true,values.isSymbolicLink==false else{throw ObserverError.unavailable}
            }catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return [] // verified missing hooks is valid, not proof of no agents
            }
            let urls=try fm.contentsOfDirectory(at:source,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard urls.count<=4096 else{throw ObserverError.unavailable}
            var total=0
            for url in urls where url.pathExtension=="json" {
                let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                guard values.isRegularFile==true,values.isSymbolicLink != true,let size=values.fileSize,size<=262144 else{throw ObserverError.unavailable}
                let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
                let data=try handle.read(upToCount:262145) ?? Data()
                guard data.count<=262144 else{throw ObserverError.unavailable}
                total+=data.count;guard total<=8*1024*1024 else{throw ObserverError.unavailable}
                let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
                _ = try decoder.decode(AgentHooks.HookRecord.self,from:data)
                try data.write(to:directory.appendingPathComponent(url.lastPathComponent),options:.atomic)
            }
            return AgentHooks.readHookRecords(now:now,in:directory,hasFreshSharedHostEvidence:{session in
                guard let written=PSAgentActivityMonitor.codexRolloutWrite(forSessionId:session,now:now)else{return false}
                return written>=now.addingTimeInterval(-PSAgentActivityMonitor.evidenceWindow(for:"codex"))
            })
        }catch{failedStorage=true;return []}
    }
}
