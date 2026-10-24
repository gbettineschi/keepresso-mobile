import Foundation
public struct ReminderMachine: Codable {
    public var settings = ReminderSettings(); public private(set) var snoozedUntil: Date?
    private var activeIncidents:Set<String>=[]
    // Optional so 0.3.x persisted reminders decode without migration/reset.
    private var lidWarning:LidWarningState?
    private struct LidWarningState:Codable{var lastClosed:Bool?;var pendingSince:Date?;var warned=false}
    private var suppressNextTransition = false
    private var wasActive: Bool?; private var nextHourly: Date?; private var endedDue: Date?; private var endedWarned = false
    public init() {}
    public func needsLidCheck(now:Date)->Bool{
        guard let lid=lidWarning,lid.lastClosed==true,!lid.warned,let since=lid.pendingSince else{return false}
        return now>=since && now.timeIntervalSince(since)<=5
    }
    public mutating func observeLid(closed:Bool?,sleepDisabled:Bool?,now:Date)->CompanionEvent?{
        guard let closed else{lidWarning=nil;return nil}
        var lid=lidWarning ?? LidWarningState();defer{lidWarning=lid}
        if !closed{lid.pendingSince=nil;lid.warned=false}
        else if lid.lastClosed==false{lid.pendingSince=now;lid.warned=false}
        lid.lastClosed=closed
        guard closed,!lid.warned,let since=lid.pendingSince else{return nil}
        guard now>=since,now.timeIntervalSince(since)<=5 else{lid.pendingSince=nil;return nil}
        guard sleepDisabled==true else{return nil}
        lid.warned=true;lid.pendingSince=nil
        return CompanionEvent(kind:"lid_awake",createdAt:now,title:"Mac awake with lid closed",body:"Sleep is disabled. Check your Mac before putting it away.",scheduledEnd:nil,snoozedUntil:nil)
    }
    public mutating func observeSafety(kind:String,active:Bool,now:Date)->CompanionEvent? {
        guard ["battery","thermal","sleep_failed"].contains(kind) else{return nil}
        if !active{activeIncidents.remove(kind);return nil}
        guard activeIncidents.insert(kind).inserted else{return nil}
        return warning(kind:kind,now:now)
    }
    public mutating func acknowledge() {} // OK intentionally leaves cadence unchanged.
    public mutating func snooze(now: Date) { snoozedUntil=now.addingTimeInterval(21600) }
    public mutating func resume() { snoozedUntil=nil }
    public mutating func observedSleep() { endedDue=nil; endedWarned=true; suppressNextTransition=true;lidWarning=nil;activeIncidents.remove("sleep_failed") }
    public mutating func update(settings: ReminderSettings, now: Date) throws { try settings.validate(); self.settings=settings; if wasActive==true { nextHourly=now.addingTimeInterval(Double(settings.intervalSeconds)) } }
    public func warning(kind: String, now: Date) -> CompanionEvent {
        let title:String,body:String
        switch kind{
        case "session_ended_awake":title="Mac is still awake";body="The brewing session ended, but your Mac hasn't slept."
        case "thermal":title="Mac is getting hot";body="Check your Mac's temperature and ventilation."
        case "sleep_failed":title="Mac couldn't sleep";body="Open Keepresso Mobile to check what blocked sleep."
        default:title="Keepresso warning";body="Check your Mac."
        }
        return CompanionEvent(kind:kind,createdAt:now,title:title,body:body,scheduledEnd:nil,snoozedUntil:snoozedUntil)
    }
    public mutating func observe(active: Bool?, now: Date, scheduledEnd: Date? = nil) -> [CompanionEvent] {
        guard let active else { return [] } // unknown never becomes inactive
        let canScheduleEnd = !suppressNextTransition; suppressNextTransition=false
        var events:[CompanionEvent]=[]
        if active {
            endedDue=nil; endedWarned=false
            if wasActive != true { nextHourly=now.addingTimeInterval(Double(settings.intervalSeconds)) }
            if let next=nextHourly,now>=next {
                let interval=Double(settings.intervalSeconds)
                nextHourly=next.addingTimeInterval((floor(now.timeIntervalSince(next)/interval)+1)*interval)
                if settings.enabled && (snoozedUntil == nil || now>=snoozedUntil!) { events.append(CompanionEvent(kind:"hourly",createdAt:now,title:"Your Mac is still brewing",body:scheduledEnd.map { "Scheduled end: \(WireJSON.iso($0))." } ?? "There is no automatic end time.",scheduledEnd:scheduledEnd,snoozedUntil:snoozedUntil)) }
            }
        } else {
            if wasActive==true && canScheduleEnd { endedDue=now.addingTimeInterval(Double(settings.endedAwakeDelaySeconds)); endedWarned=false }
            nextHourly=nil
            if let due=endedDue,now>=due,!endedWarned { events.append(warning(kind:"session_ended_awake",now:now)); endedWarned=true; endedDue=nil }
        }
        wasActive=active; return events
    }
    /// A restart cannot prove continuous wakefulness in an offline interval.
    public mutating func resumedAfterUnknownInterval() { endedDue=nil; endedWarned=true; suppressNextTransition=true;lidWarning=nil }
}
