import Foundation

/// Physical readiness never grants application authority. Each connection owns
/// a fresh generation, and invalidation is permanent even after a reconnect.
public final class NearbyCentralSession {
    public enum Stage:Int { case connecting, services, characteristics, subscribing, ready, closed }
    public let generation=UUID()
    public private(set) var stage:Stage = .connecting
    public private(set) var authorized=false
    private var bufferedRecords:[Data]=[]
    private var bufferedBytes=0
    private var deadline:TimeInterval
    public init(now:TimeInterval){deadline=now+15}
    public var ready:Bool{stage == .ready}
    public func accepts(_ generation:UUID)->Bool{stage != .closed && self.generation==generation}
    public func advance(to next:Stage,now:TimeInterval)throws {
        guard stage != .closed,next != .closed,next.rawValue==stage.rawValue+1,!expired(now:now) else{throw CompanionError.closed}
        stage=next;deadline=now+15
    }
    public func expired(now:TimeInterval)->Bool{stage != .closed && stage != .ready && now>=deadline}
    public func authenticate()throws{guard ready else{throw CompanionError.closed};authorized=true}
    /// Android may deliver hello immediately after CCCD enable, before the
    /// central receives notification-state confirmation. Preserve it, bounded,
    /// but do not run the handshake or send any writes during subscription.
    public func receiveRecord(_ record:Data)throws->[Data]{
        guard stage == .subscribing || ready else{throw CompanionError.closed}
        if ready{return [record]}
        guard bufferedRecords.count<8,bufferedBytes+record.count<=131072 else{throw CompanionError.limit}
        bufferedRecords.append(record);bufferedBytes+=record.count;return []
    }
    public func takeBufferedRecords()->[Data]{
        guard ready else{return []}
        let records=bufferedRecords;bufferedRecords=[];bufferedBytes=0;return records
    }
    public func invalidate(){authorized=false;stage = .closed;bufferedRecords=[];bufferedBytes=0}
}

/// CoreBluetooth accepts a write immediately but completes it asynchronously.
/// Keep the current chunk until ACK and never expose a second write in flight.
/// Failure/timeout is terminal: ciphertext cannot be replayed on a new session.
public final class NearbyAcknowledgedWrites {
    private var queue=NotificationQueue()
    private var sentAt:TimeInterval?
    private var closed=false
    public init(){}
    public var bytes:Int{queue.bytes}
    /// A with-response value can use ATT prepared writes. Our framing peer
    /// accepts ordinary writes only, so also respect the single-packet limit.
    public func enqueue(record:Data,maximumWithResponse:Int,maximumWithoutResponse:Int)throws {
        guard maximumWithResponse>0,maximumWithoutResponse>0 else{throw CompanionError.invalid}
        try enqueue(record:record,mtu:min(512,min(maximumWithResponse,maximumWithoutResponse)))
    }
    public func enqueue(record:Data,mtu:Int)throws {
        guard !closed else{throw CompanionError.closed}
        try queue.enqueue(record:record,mtu:mtu)
    }
    public func take(now:TimeInterval)->Data?{
        guard !closed,sentAt==nil,let next=queue.next else{return nil}
        sentAt=now;return next
    }
    public func acknowledge(success:Bool,now:TimeInterval)throws{
        guard !closed,sentAt != nil else{throw CompanionError.closed}
        guard success,!expired(now:now) else{invalidate();throw CompanionError.unavailable}
        queue.accepted();sentAt=nil
    }
    public func expired(now:TimeInterval)->Bool{sentAt.map{now-$0>=10} ?? false}
    public func invalidate(){closed=true;queue=NotificationQueue();sentAt=nil}
}

/// Identity of the active manager, independent of platform Bluetooth classes.
public final class NearbyCentralLifetime {
    private var generation=UUID()
    private var active=false
    public init(){}
    public func begin()->UUID{generation=UUID();active=true;return generation}
    public func end(){active=false}
    public func accepts(_ candidate:UUID)->Bool{active && candidate==generation}
}
