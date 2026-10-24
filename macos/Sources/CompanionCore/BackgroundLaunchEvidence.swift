import Foundation
public enum BackgroundLaunchEvidence {
    /// Only the fixed companion job's read-only launchctl output is accepted here.
    public static func requiresRefresh(_ dump:String,currentBuild:String?=nil)->Bool {
        let lines=dump.split(separator:"\n").map{$0.trimmingCharacters(in:.whitespaces)}
        if lines.contains("last exit reason = OS_REASON_CODESIGNING"){return true}
        // BTM can invalidate an ad-hoc pin ten seconds after a failed launch,
        // leaving EX_CONFIG even for the same version/build. Version alone
        // cannot prove that the registered executable can run.
        return lines.contains("last exit code = 78: EX_CONFIG") && lines.contains("job state = spawn failed")
    }
    public static func launchHealth(_ dump:String)->StartupLaunchHealth {
        let lines=dump.split(separator:"\n").map{$0.trimmingCharacters(in:.whitespaces)}
        if lines.contains("state = running"),let pid=lines.first(where:{$0.hasPrefix("pid = ")}),let number=Int(pid.dropFirst(6)),number>0{return .running}
        return requiresRefresh(dump) ? .failed:.unavailable
    }
}
