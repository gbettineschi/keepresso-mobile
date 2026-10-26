import Foundation
import Combine

public struct SavedAuthorization: Sendable {
    public let devices:[AuthorizedDevice]
    public let relay:RelayConfiguration?
    public init(devices:[AuthorizedDevice],relay:RelayConfiguration?){self.devices=devices;self.relay=relay}
}

/// Keychain IPC may wait for system UI indefinitely. Never run it on AppKit's
/// actor, authorize an empty fallback, or start another read while one is pending.
@MainActor public final class SavedAuthorizationLoader:ObservableObject {
    public enum State { case idle,loading,ready,unavailable }
    @Published public private(set) var state:State = .idle
    @Published public private(set) var failure:SavedConnectionFailure?
    private var generation=UUID()
    private let now:()->TimeInterval
    private let waitBeforeRecovery:@MainActor (TimeInterval) async throws->Void
    private typealias Recovery=(operation:@Sendable ()throws->SavedAuthorization,ready:@MainActor (SavedAuthorization)->Void)
    private var pendingRecovery:Recovery?
    private var lastRecoveryAt:TimeInterval?
    private var recoveryTask:Task<Void,Never>?
    public init(now:@escaping()->TimeInterval={ProcessInfo.processInfo.systemUptime},waitBeforeRecovery:@escaping @MainActor (TimeInterval) async throws->Void={try await Task.sleep(for:.seconds($0))}){self.now=now;self.waitBeforeRecovery=waitBeforeRecovery}
    /// The caller supplies a silent reader, never the earlier interactive read.
    public func retryAfterEnvironmentChange(operation:@escaping @Sendable () throws -> SavedAuthorization,ready:@escaping @MainActor (SavedAuthorization)->Void){
        if state == .loading{pendingRecovery=(operation,ready);return}
        guard state == .unavailable,failure?.canRetrySilently==true else{return}
        pendingRecovery=(operation,ready)
        let remaining=lastRecoveryAt.map{max(0,2-(now()-$0))} ?? 0
        if remaining==0{startPendingRecovery();return}
        guard recoveryTask==nil else{return}
        let token=generation,wait=waitBeforeRecovery
        recoveryTask=Task{[weak self] in
            do{try await wait(remaining)}catch{return}
            guard !Task.isCancelled,let self,self.generation==token else{return}
            self.recoveryTask=nil
            self.startPendingRecovery()
        }
    }
    private func startPendingRecovery(){
        guard state == .unavailable,failure?.canRetrySilently==true,let pending=pendingRecovery else{return}
        pendingRecovery=nil;lastRecoveryAt=now()
        load(operation:pending.operation,ready:pending.ready)
    }
    public func load(operation:@escaping @Sendable () throws -> SavedAuthorization,
                     ready:@escaping @MainActor (SavedAuthorization)->Void){
        guard state != .loading,state != .ready else{return}
        recoveryTask?.cancel();recoveryTask=nil;pendingRecovery=nil
        state = .loading;failure=nil;let token=generation
        Task{[weak self] in
            let result=await Task.detached(priority:.userInitiated){Result{try operation()}}.value
            guard let self,self.generation==token else{return}
            switch result {
            case .success(let saved):self.state = .ready;self.pendingRecovery=nil;ready(saved)
            case .failure(let error):
                self.failure=(error as? SavedConnectionFailure) ?? SavedConnectionFailure(reason:.unavailable)
                self.state = .unavailable
                let pending=self.pendingRecovery;self.pendingRecovery=nil
                if let pending{self.retryAfterEnvironmentChange(operation:pending.operation,ready:pending.ready)}
            }
        }
    }
    public func stop(){generation=UUID();recoveryTask?.cancel();recoveryTask=nil;state = .idle;failure=nil;pendingRecovery=nil;lastRecoveryAt=nil}
}
