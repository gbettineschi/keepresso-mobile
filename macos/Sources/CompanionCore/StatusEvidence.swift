import Foundation
public enum StatusEvidence {
    public static func consoleLock(in session: [String: Any]?, userID: UInt32) -> Bool? {
        guard let session,
              session["kCGSSessionUserIDKey"] as? UInt32 == userID,
              session["kCGSSessionOnConsoleKey"] as? Bool == true,
              session["kCGSessionLoginDoneKey"] as? Bool == true else { return nil }
        // On the active, logged-in console macOS omits the flag when unlocked.
        guard let lock = session["CGSSessionScreenIsLocked"] else { return false }
        return lock as? Bool
    }
    public static func sameLaunch(pid:Int32,launchDate:Date?,currentPID:Int32?,currentLaunchDate:Date?)->Bool {
        guard let launchDate,let currentLaunchDate else{return false}
        return pid==currentPID && launchDate==currentLaunchDate
    }
    public static func brewingActivity(appRunning:Bool,nativeActive:Bool?)->Bool? {appRunning ? nativeActive:false}
    /// Status files are written on changes and can be old while still valid.
    /// Compare with launch, never use elapsed age to infer an inactive session.
    public static func belongsToCurrentLaunch(writtenAt:Date,launchDate:Date?,now:Date)->Bool {
        guard let launchDate else{return false}
        return writtenAt.timeIntervalSince1970>=floor(launchDate.timeIntervalSince1970) && writtenAt<=now.addingTimeInterval(10)
    }
    /// The native ISO8601 writer truncates to seconds. Require the file's
    /// high-resolution modification timestamp as independent fresh-write evidence.
    public static func acknowledges(writtenAt:Date,modifiedAt:Date?,issuedAt:Date)->Bool {
        guard let modifiedAt else{return false}
        return modifiedAt>=issuedAt && writtenAt.timeIntervalSince1970>=floor(issuedAt.timeIntervalSince1970)
    }
}
