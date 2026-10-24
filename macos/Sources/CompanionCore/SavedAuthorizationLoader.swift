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
    private var generation=UUID()
    public init(){}
    public func load(operation:@escaping @Sendable () throws -> SavedAuthorization,
                     ready:@escaping @MainActor (SavedAuthorization)->Void){
        guard state != .loading,state != .ready else{return}
        state = .loading;let token=generation
        Task{[weak self] in
            let result=await Task.detached(priority:.userInitiated){Result{try operation()}}.value
            guard let self,self.generation==token else{return}
            switch result {
            case .success(let saved):ready(saved);self.state = .ready
            case .failure:self.state = .unavailable
            }
        }
    }
    public func stop(){generation=UUID();state = .idle}
}
