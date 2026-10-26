import Foundation
/// Main-actor serialization also prevents different authorized phones racing
/// native controls during the acknowledgement window. Busy commands are rejected,
/// never queued for later execution.
@MainActor public final class MutationExecutor {
    private let journal:MutationJournal;private var busy=false
    public init(journal:MutationJournal){self.journal=journal}
    public func execute(_ request:CommandRequest,device:String,body:Data,now:Date,authorized:()->Bool,rejection:String?=nil,operation:() async ->CommandResponse)async ->CommandResponse {
        guard authorized() else{return CommandResponse(id:request.id,status:"error",message:"Device authorization was revoked.")}
        do{try request.validate(now:now)}catch{return CommandResponse(id:request.id,status:"error",message:"The request is invalid or expired.")}
        if request.action == "operation_status" {
            do {
                let result=try journal.lookup(id:request.operationId!,device:device,bodyDigest:request.bodyDigest!)
                return CommandResponse(id:request.id,status:"ok",operationId:request.operationId,operationStatus:result?.status ?? "not_found",operationMessage:result?.message)
            }catch{return CommandResponse(id:request.id,status:"error",message:"The operation lookup does not match its original authorized request.")}
        }
        guard request.isMutation else{return await operation()}
        do{
            // Reserve even a busy rejection: the same ID always has one stored
            // outcome, and a reconnect cannot turn it into a deferred effect.
            if let previous=try journal.reserve(id:request.id,device:device,body:body){return previous}
        }catch{return CommandResponse(id:request.id,status:"error",message:"The command ID cannot be durably reserved or does not match its original request.")}
        let result:CommandResponse
        if let rejection{result=CommandResponse(id:request.id,status:"error",message:rejection)}
        else if busy{result=CommandResponse(id:request.id,status:"error",message:"Another command is still awaiting native acknowledgement. This command was not executed.")}
        else if !authorized(){result=CommandResponse(id:request.id,status:"error",message:"Device authorization was revoked.")}
        else{
            busy=true;let observed=await operation();busy=false
            // The effect may already have happened. A new native lifecycle or
            // revoked device cannot confirm it; persist uncertainty, never retry.
            result=authorized() ? observed:CommandResponse(id:request.id,status:"uncertain",message:"Keepresso or device authorization changed while the request was in progress. It will not be retried automatically.")
        }
        do{try journal.finish(id:request.id,result:result);return result}catch{return CommandResponse(id:request.id,status:"uncertain",message:"The outcome could not be durably saved. Do not retry automatically.")}
    }
}
