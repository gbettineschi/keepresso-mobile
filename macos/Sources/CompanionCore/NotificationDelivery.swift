import Foundation

/// Notification preparation is revocable until its actual network submission.
@MainActor public enum NotificationDelivery {
    public static func drain(_ pending:[RelayEnvelope],sender:FirebaseSender,
                             registration:(RelayEnvelope)->PushRegistration?,
                             completed:(RelayEnvelope,PushRegistration,FirebaseSendResult)throws->Void)async throws {
        for envelope in pending {
            guard !Task.isCancelled,let current=registration(envelope) else{continue}
            let result=await sender.send(envelope,token:current.token,stillCurrent:{
                !Task.isCancelled && registration(envelope)==current
            })
            guard !Task.isCancelled,registration(envelope)==current else{continue}
            try completed(envelope,current,result)
        }
    }
    /// The caller has already persisted the authoritative event/reminder state.
    public static func live(enqueuePush:()throws->Void,broadcast:()->Void,pushFailed:()->Void) {
        do{try enqueuePush()}catch{pushFailed()}
        broadcast()
    }
}
