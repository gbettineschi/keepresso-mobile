import Foundation

/// Only names and metadata are inspected, never downloaded file contents.
/// The caller must establish approval before invoking this scanner.
final class CompanionObservationDownloadScanner {
    struct Metadata { var modified: Date?; var directory: Bool; var symlink: Bool = false }
    private let list: (URL) throws -> [URL]
    private let metadata: (URL) throws -> Metadata
    init(list: @escaping (URL) throws -> [URL] = { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]) }, metadata: @escaping (URL) throws -> Metadata = {
        let values = try $0.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard let directory = values.isDirectory, let symlink = values.isSymbolicLink else { throw ObserverError.unavailable }
        return Metadata(modified: values.contentModificationDate, directory: directory, symlink: symlink)
    }) { self.list = list; self.metadata = metadata }
    func read(in folder: URL) -> CompanionObservationDownload? {
        do {
            let root = try metadata(folder)
            guard root.directory, !root.symlink else { return nil }
            let entries = try list(folder)
            var newest: Date?; var complete = entries.count <= 4096
            var inspected = min(entries.count, 4096)
            for entry in entries.prefix(4096) where FileManagerDownloadScanner.isPartialDownload(entry.lastPathComponent) {
                do {
                    let values = try metadata(entry)
                    guard !values.symlink, let modified = values.modified else { complete = false; continue }
                    newest = max(newest ?? .distantPast, modified)
                    if values.directory {
                        let children = try list(entry)
                        // A bounded scan can still retain an already proved
                        // positive. Uninspected entries only defeat negatives.
                        guard children.count <= 8192 - inspected else { complete = false; continue }
                        inspected += children.count
                        for child in children {
                            do {
                                let value = try metadata(child)
                                guard !value.symlink, let date = value.modified else { complete = false; continue }
                                newest = max(newest ?? .distantPast, date)
                            } catch { complete = false }
                        }
                    }
                } catch { complete = false }
            }
            return .init(newestWrite: newest, complete: complete)
        } catch { return nil }
    }
}

/// Uses the native parse/session/hook matching helpers and delegates the final
/// work decision to the native AgentActivityTrigger. CPU-only cold negatives
/// lack a learned baseline and therefore cannot establish inactivity here.
enum CompanionObservationAgentReader {
    static func read(raw: String, now: Date,
                     hookRecords: (Date) -> [AgentHooks.HookRecord], hooksAvailable: () -> Bool,
                     pathOf: (Int32) -> String? = AgentHooks.defaultPathOf,
                     cwdOf: (Int32) -> String? = PSAgentActivityMonitor.processCwd,
                     evidence: (String, String?, Int32) -> Date? = { PSAgentActivityMonitor.transcriptActivity(agent: $0, cwd: $1, pid: $2) },
                     origin: (Int32) -> AgentHooks.HookSessionOrigin? = { AgentHooks.classifyOrigin(abovePid: $0) },
                     codexWrite: (String) -> Date? = { PSAgentActivityMonitor.codexRolloutWrite(forSessionId: $0) }) -> CompanionObservationAgents? {
        guard CompanionObservationSystem.validPS(raw) else { return nil }
        var sessions = PSAgentActivityMonitor.sessions(from: PSAgentActivityMonitor.parse(raw), pathOf: pathOf)
        var cwds: [Int32: String] = [:]; var dates: [Int32: Date] = [:]
        for index in sessions.indices {
            let session = sessions[index]; let cwd = cwdOf(session.pid); cwds[session.pid] = cwd
            if let written = evidence(session.agent, cwd, session.pid) {
                dates[session.pid] = written
                sessions[index].hasFreshEvidence = written >= now.addingTimeInterval(-PSAgentActivityMonitor.evidenceWindow(for: session.agent))
            }
            if let classified = origin(session.pid) { sessions[index].origin = classified }
        }
        let records = hookRecords(now)
        guard hooksAvailable() else { return nil }
        let joined = PSAgentActivityMonitor.applyHookRecords(records, to: sessions, cwdOf: { cwds[$0] })
        sessions = joined.sessions
        // Same native precedence: a later transcript write defeats an older
        // idle/plain waiting edge, while waiting-approval remains authoritative.
        for index in sessions.indices {
            let session = sessions[index]
            let overridable = session.hookState == .idle || (session.hookState == .waiting && session.hookDetail != "waiting-approval")
            if overridable, session.hasFreshEvidence, let stamped = session.hookUpdatedAt,
               let written = dates[session.pid], written > stamped {
                sessions[index].hookState = nil; sessions[index].hookDetail = nil
            }
        }
        sessions = PSAgentActivityMonitor.suppressingHookCoveredEvidenceHosts(sessions, hookRecords: records)
        let unclaimed = HermesHooks.withoutCoveredPresence(joined.unclaimed)
        sessions.append(contentsOf: unclaimed.compactMap { record in
            guard var session = PSAgentActivityMonitor.hookOnlySession(from: record) else { return nil }
            if record.agent == "codex", let written = codexWrite(record.sessionId) {
                session.hasFreshEvidence = written >= now.addingTimeInterval(-PSAgentActivityMonitor.evidenceWindow(for: "codex"))
            }
            return session
        })
        let negativeComplete = unclaimed.allSatisfy { $0.ownerPid != nil } && sessions.allSatisfy { $0.hookState != nil }
        return .init(snapshot: .init(sessions: sessions), negativeComplete: negativeComplete)
    }
}
