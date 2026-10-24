import Foundation

/// Own the single handoff worker so normal Quit cancels pending launch work and
/// cannot receive a late UI completion from it.
@MainActor public final class ManagedStartupTask {
    private var task:Task<Void,Never>?
    private var stopped=false
    public init(){}
    public func start(operation:@escaping @MainActor ()async->Bool,completion:@escaping @MainActor (Bool)->Void){
        guard !stopped,task==nil else{return}
        task=Task{[weak self] in
            guard let self,!self.stopped,!Task.isCancelled else{return}
            let result=await operation()
            guard !self.stopped,!Task.isCancelled else{return}
            self.task=nil;completion(result)
        }
    }
    public func stop(){stopped=true;task?.cancel();task=nil}
}
