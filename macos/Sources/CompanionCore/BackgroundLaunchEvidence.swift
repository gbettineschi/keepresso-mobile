import Foundation
public enum BackgroundLaunchEvidence {
    /// Only the fixed companion job's read-only launchctl output is accepted here.
    public static func requiresRefresh(_ dump:String)->Bool {
        dump.split(separator:"\n").contains{$0.trimmingCharacters(in:.whitespaces)=="last exit reason = OS_REASON_CODESIGNING"}
    }
}
