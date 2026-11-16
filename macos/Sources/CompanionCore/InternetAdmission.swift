import Foundation

/// Monotonic, bounded admission. Invalidating the gate invalidates every witness.
@MainActor public final class InternetAdmission {
    private struct Entry {var authenticated=false;var stream=false;let admitted:TimeInterval;var activity:TimeInterval;var partial:TimeInterval?}
    private var entries:[UUID:Entry]=[:]
    private let now:()->TimeInterval
    public init(now:@escaping()->TimeInterval = {ProcessInfo.processInfo.systemUptime}){self.now=now}
    public func acquire()throws->UUID {
        guard entries.values.filter({!$0.authenticated}).count<4,entries.count<12 else{throw CompanionError.limit}
        let id=UUID();entries[id]=Entry(admitted:now(),activity:now());return id
    }
    public func authenticate(_ id:UUID)throws {
        guard valid(id),var entry=entries[id],!entry.authenticated,entries.values.filter(\.authenticated).count<8 else{throw CompanionError.limit}
        entry.authenticated=true;entry.activity=now();entries[id]=entry
    }
    public func openStream(_ id:UUID)throws {
        guard valid(id),var entry=entries[id],!entry.stream else{throw CompanionError.limit}
        entry.stream=true;entries[id]=entry
    }
    public func partial(_ id:UUID){guard var entry=entries[id] else{return};entry.partial=now();entries[id]=entry}
    public func activity(_ id:UUID){guard var entry=entries[id] else{return};entry.activity=now();entry.partial=nil;entries[id]=entry}
    public func valid(_ id:UUID)->Bool {
        guard let entry=entries[id] else{return false}
        let time=now()
        guard time>=entry.admitted,entry.authenticated || time-entry.admitted<10,
              time-entry.activity<20 else{return false}
        return entry.partial.map{time-$0<10} ?? true
    }
    public func release(_ id:UUID){entries.removeValue(forKey:id)}
    public func invalidate(){entries.removeAll()}
}
