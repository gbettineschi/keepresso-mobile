import Foundation

/// Only exact already sealed event/device deliveries enter this durable queue.
/// Token rotation may retry a delivery, but may never renew its original expiry.
@MainActor public final class NotificationOutbox {
    private struct Record:Codable {let envelope:RelayEnvelope;let kind:String;var attempts=0;var next:Date;var blocked=false}
    private let file:PrivateStateFile
    private var records:[Record]
    public init(url:URL)throws {
        file=PrivateStateFile(url:url,maximumBytes:1_048_576)
        if let data=try file.read(){records=try WireJSON.decoder.decode([Record].self,from:data)}else{records=[]}
        guard records.count<=256,Set(records.map{$0.envelope.deviceId+"/"+$0.envelope.id}).count==records.count else{throw CompanionError.invalid}
        for record in records {
            try record.envelope.validate(now:Date(timeIntervalSince1970:Double(record.envelope.createdAt)))
            guard record.envelope.kind=="event",record.envelope.direction=="s2c",try WireJSON.encoder.encode(record.envelope).count<=3000,
                  record.kind.utf8.count<=64,record.attempts>=0,record.attempts<=32,record.next.timeIntervalSince1970.isFinite else{throw CompanionError.invalid}
        }
    }
    private func persist(_ updated:[Record])throws{try file.write(WireJSON.encoder.encode(updated));records=updated}
    private func pruned(_ now:Date)->[Record]{records.filter{Double($0.envelope.expiresAt)>now.timeIntervalSince1970}}
    public func enqueue(_ envelope:RelayEnvelope,kind:String,now:Date)throws {
        try envelope.validate(now:now)
        guard envelope.kind=="event",envelope.direction=="s2c",kind.utf8.count<=64,try WireJSON.encoder.encode(envelope).count<=3000 else{throw CompanionError.limit}
        var updated=pruned(now)
        if let prior=updated.first(where:{$0.envelope.deviceId==envelope.deviceId && $0.envelope.id==envelope.id}){
            guard prior.envelope==envelope,prior.kind==kind else{throw CompanionError.mismatch};return
        }
        guard updated.count<256 else{throw CompanionError.limit}
        updated.append(Record(envelope:envelope,kind:kind,next:now));try persist(updated)
    }
    public func due(devices:Set<String>,now:Date)->[RelayEnvelope] {
        pruned(now).filter{devices.contains($0.envelope.deviceId) && !$0.blocked && $0.next<=now}.map(\.envelope)
    }
    public func existing(event:String,device:String,now:Date)->RelayEnvelope? {
        pruned(now).first{$0.envelope.id==event && $0.envelope.deviceId==device}?.envelope
    }
    public func completed(_ envelope:RelayEnvelope,result:FirebaseSendResult,now:Date)throws {
        var updated=pruned(now)
        guard let index=updated.firstIndex(where:{$0.envelope==envelope}) else{return}
        switch result {
        case .accepted,.rejected,.expired,.cancelled:updated.remove(at:index)
        case .unregistered:updated[index].blocked=true
        case .transient:
            updated[index].attempts=min(32,updated[index].attempts+1)
            let delay=min(240,60*pow(2,Double(min(2,updated[index].attempts-1))))
            updated[index].next=now.addingTimeInterval(delay)
        }
        try persist(updated)
    }
    public func tokenChanged(_ device:String,now:Date)throws {
        var updated=pruned(now)
        for index in updated.indices where updated[index].envelope.deviceId==device{updated[index].blocked=false;updated[index].next=now}
        try persist(updated)
    }
    public func revoke(_ device:String,now:Date)throws{try persist(pruned(now).filter{$0.envelope.deviceId != device})}
    public func resolve(kinds:Set<String>,now:Date)throws{try persist(pruned(now).filter{!kinds.contains($0.kind)})}
}
