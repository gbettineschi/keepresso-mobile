import Foundation

public enum StartupServiceStatus { case notRegistered,enabled,requiresApproval,notFound }
public enum StartupLaunchHealth { case running,failed,unavailable }
@MainActor public protocol StartupService:AnyObject {
    var status:StartupServiceStatus{get}
    func register()throws
    func unregister()async throws
}

/// Registration is app setup, never consent. A disabled service has the same
/// requiresApproval status as one awaiting first approval: leave both untouched.
@MainActor public final class AutomaticStartupRegistration {
    public enum State { case enabled,requiresApproval,unavailable }
    private let service:StartupService,managed:Bool
    private let staleEvidence:()async->Bool
    private let verifyLaunch:(()async->StartupLaunchHealth)?
    private var busy=false,attempted=false,stopped=false,failed=false
    public private(set) var state:State = .unavailable
    public init(service:StartupService,managed:Bool,staleEvidence:@escaping()async->Bool,verifyLaunch:(()async->StartupLaunchHealth)?=nil){self.service=service;self.managed=managed;self.staleEvidence=staleEvidence;self.verifyLaunch=verifyLaunch}
    private func observed()->State {
        if service.status == .requiresApproval{return .requiresApproval}
        return service.status == .enabled && !failed ? .enabled:.unavailable
    }
    public func reconcile()async->State {
        guard !stopped,!busy else{return state}
        busy=true;defer{busy=false}
        if service.status == .requiresApproval || service.status == .notFound || managed {state=observed();return state}
        let stale=await staleEvidence()
        guard !stopped else{return state}
        // Consent may have changed while the read-only launchctl probe waited.
        if service.status == .requiresApproval || service.status == .notFound{state=observed();return state}
        if !attempted && (service.status == .notRegistered || stale) {
            attempted=true
            // A replaced ad-hoc binary can leave BTM's old hash constraint in
            // place after unregister/register. Allow one further repair only
            // after a settled, positively observed failed launch.
            for round in 0..<2 {
                do {
                    if stale || round>0{try await service.unregister()}
                    guard !stopped else{return state}
                    guard service.status != .requiresApproval else{state = .requiresApproval;return state}
                    try service.register()
                    guard service.status != .requiresApproval else{state = .requiresApproval;return state}
                    guard let verifyLaunch else{break}
                    let health=await verifyLaunch()
                    guard !stopped else{return state}
                    guard service.status != .requiresApproval else{state = .requiresApproval;return state}
                    if health == .running{break}
                    if health != .failed || round==1{failed=true;break}
                }catch{failed=true;break}
            }
        }
        state=observed();return state
    }
    public func stop(){stopped=true}
}
