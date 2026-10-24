import Foundation

public struct SleepPreparationState {
    /// Nil when the native process/state acknowledgement cannot be verified.
    public var stopped:Bool?
    public var sleepDisabled:Bool?
    public init(stopped:Bool?,sleepDisabled:Bool?){self.stopped=stopped;self.sleepDisabled=sleepDisabled}
}

/// Authorization and observed native state gate every step. The production
/// adapter supplies one fixed sleep request; tests inject all power effects.
@MainActor public enum SafeSleep {
    public static func perform(id:String,authorized:()->Bool,state:()async->SleepPreparationState?,stop:()async throws->Void,requestSleep:()->Bool,wait:()async->Void={try? await Task.sleep(nanoseconds:250_000_000)})async->CommandResponse{
        guard authorized(),!Task.isCancelled else{return CommandResponse(id:id,status:"error",message:"Phone authorization changed. Sleep wasn't requested.")}
        guard let initial=await state(),initial.sleepDisabled != nil,authorized(),!Task.isCancelled else{return CommandResponse(id:id,status:"error",message:"Couldn't verify this Mac's sleep settings. Sleep wasn't requested.")}
        do{try await stop()}catch{return CommandResponse(id:id,status:"uncertain",message:"Couldn't confirm Keepresso stopped. Sleep wasn't requested.")}
        var last:SleepPreparationState?
        let deadline=ProcessInfo.processInfo.systemUptime+8
        for _ in 0..<32{
            guard authorized(),!Task.isCancelled else{return CommandResponse(id:id,status:"uncertain",message:"Keepresso or phone authorization changed. Sleep wasn't requested.")}
            last=await state()
            guard authorized(),!Task.isCancelled else{return CommandResponse(id:id,status:"uncertain",message:"Keepresso or phone authorization changed. Sleep wasn't requested.")}
            if last?.stopped==true,last?.sleepDisabled==false{
                return requestSleep() ? CommandResponse(id:id,status:"ok",message:"Sleep requested."):CommandResponse(id:id,status:"error",message:"macOS rejected the sleep request.")
            }
            if ProcessInfo.processInfo.systemUptime>=deadline{break}
            await wait()
        }
        if last?.stopped==true,last?.sleepDisabled==true{return CommandResponse(id:id,status:"error",message:"Keepresso stopped, but closed-lid mode still blocks sleep. Turn it off on the Mac or use Only while brewing.")}
        return CommandResponse(id:id,status:"uncertain",message:"Couldn't verify that Keepresso released its hold. Sleep wasn't requested.")
    }
}
