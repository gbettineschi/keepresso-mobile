import Foundation
public enum BackgroundLaunchEvidence {
    /// Only the fixed companion job's read-only launchctl output is accepted here.
    public static func requiresRefresh(_ dump:String,currentBuild:String?=nil)->Bool {
        let lines=dump.split(separator:"\n").map{$0.trimmingCharacters(in:.whitespaces)}
        if lines.contains("last exit reason = OS_REASON_CODESIGNING"){return true}
        guard let currentBuild,!currentBuild.isEmpty,
              lines.contains("last exit code = 78: EX_CONFIG"),lines.contains("job state = spawn failed"),
              let parent=lines.first(where:{$0.hasPrefix("parent bundle version = ")}) else{return false}
        return String(parent.dropFirst("parent bundle version = ".count)) != currentBuild
    }
}
