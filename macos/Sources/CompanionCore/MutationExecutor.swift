import Foundation
/// Main-actor serialization also prevents different authorized phones racing
/// native controls during the acknowledgement window. Busy commands are rejected,
/// never queued for later execution.
@MainActor public final class MutationExecutor {
    private let journal:MutationJournal;private var busy=false
    public init(journal:MutationJournal){self.journal=journal}
    public func execute(_ request:CommandRequest,device:String,body:Data,now:Date,authorized:()->Bool,rejection:String?=nil,operation:() async ->CommandResponse)async ->CommandResponse {
        func rejected(_ message: String, status: String = "error") -> CommandResponse {
            if request.action == "sleep_now" {
                return .sleep(id: request.id, outcome: .couldNotRequestSleep, status: status)
            }
            return CommandResponse(id: request.id, status: status, message: message)
        }
        guard authorized() else { return rejected("Device authorization was revoked.") }
        do { try request.validate(now: now) }
        catch { return rejected("The request is invalid or expired.") }
        if request.action == "operation_status" {
            do {
                let result=try journal.lookup(id:request.operationId!,device:device,bodyDigest:request.bodyDigest!)
                return CommandResponse(id:request.id,status:"ok",operationId:request.operationId,operationStatus:result?.status ?? "not_found",operationMessage:result?.message,sleepOutcome:result?.sleepOutcome)
            }catch{return CommandResponse(id:request.id,status:"error",message:"The operation lookup does not match its original authorized request.")}
        }
        guard request.isMutation else{return await operation()}
        do{
            // Reserve even a busy rejection: the same ID always has one stored
            // outcome, and a reconnect cannot turn it into a deferred effect.
            if let previous=try journal.reserve(id:request.id,device:device,body:body){return previous}
        } catch { return rejected("The command ID cannot be durably reserved or does not match its original request.") }
        let result:CommandResponse
        var replyAfterInvalidation: CommandResponse?
        if let rejection { result = rejected(rejection) }
        else if busy { result = rejected("Another command is still awaiting native acknowledgement. This command was not executed.") }
        else if !authorized() { result = rejected("Device authorization was revoked.") }
        else{
            busy=true;let observed=await operation();busy=false
            // The effect may already have happened. Losing authorization
            // can make its outcome uncertain, but must never allow a retry.
            if authorized() {
                result = observed
            } else {
                let interrupted = rejected(
                    "Keepresso or device authorization changed while the request was in progress. It will not be retried automatically.",
                    status: "uncertain"
                )
                // A system sleep transition can itself close the authorized
                // route. Only the original device may retrieve this receipt
                // in a later authenticated, read-only operation lookup.
                let verifiedSleep = request.action == "sleep_now" && observed.id == request.id
                    && observed.status == "ok" && observed.sleepOutcome == .goingToSleep
                result = verifiedSleep ? observed : interrupted
                replyAfterInvalidation = interrupted
            }
        }
        do { try journal.finish(id: request.id, result: result); return replyAfterInvalidation ?? result }
        catch { return rejected("The outcome could not be durably saved. Do not retry automatically.", status: "uncertain") }
    }
}
