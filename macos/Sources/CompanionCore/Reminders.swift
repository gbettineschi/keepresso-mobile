import Foundation
public struct ReminderMachine: Codable {
    public var settings = ReminderSettings(); public private(set) var snoozedUntil: Date?
    private var activeIncidents:Set<String>=[]
    private var suppressNextTransition = false
    private var wasActive: Bool?; private var nextHourly: Date?; private var endedDue: Date?; private var endedWarned = false
    public init() {}
    public mutating func observeSafety(kind:String,active:Bool,now:Date)->CompanionEvent? {
        guard ["battery","thermal","sleep_failed"].contains(kind) else{return nil}
        if !active{activeIncidents.remove(kind);return nil}
        guard activeIncidents.insert(kind).inserted else{return nil}
        return warning(kind:kind,now:now)
    }
    public mutating func acknowledge() {} // OK intentionally leaves cadence unchanged.
    public mutating func snooze(now: Date) { snoozedUntil=now.addingTimeInterval(21600) }
    public mutating func resume() { snoozedUntil=nil }
    public mutating func observedSleep() { endedDue=nil; endedWarned=true; suppressNextTransition=true }
    public mutating func update(settings: ReminderSettings, now: Date) throws { try settings.validate(); self.settings=settings; if wasActive==true { nextHourly=now.addingTimeInterval(Double(settings.intervalSeconds)) } }
    public func warning(kind: String, now: Date) -> CompanionEvent {
        CompanionEvent(kind:kind,createdAt:now,title:"Keepresso warning",body:kind == "session_ended_awake" ? "The brewing session ended, but this Mac has stayed awake." : "Check the Mac: \(kind.replacingOccurrences(of:"_",with:" ")).",scheduledEnd:nil,snoozedUntil:snoozedUntil)
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
    public mutating func resumedAfterUnknownInterval() { endedDue=nil; endedWarned=true; suppressNextTransition=true }
}
