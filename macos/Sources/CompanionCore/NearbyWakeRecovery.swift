import Foundation

/// Separates machine sleep from the lifetime of native Keepresso. Callbacks own
/// only the companion transport; this coordinator never requests or prevents sleep.
@MainActor public final class NearbyWakeRecovery {
    public private(set) var sleeping=false
    public private(set) var generation:UInt64=0
    private let stop:()->Void
    private let start:()->Void
    public init(stop:@escaping()->Void,start:@escaping()->Void){self.stop=stop;self.start=start}
    public func willSleep(){guard !sleeping else{return};generation &+= 1;sleeping=true;stop()}
    public func didWake(enabled:Bool){guard sleeping else{return};sleeping=false;if enabled{start()}}
    /// A metadata refresh may resume a previously enabled connection; it never
    /// enables Nearby, requests consent or constructs a pairing invitation.
    public func permissionRefreshed(enabled:Bool,nativeRunning:Bool,authorizationReady:Bool,permissionGranted:Bool,alreadyStarted:Bool) {
        guard enabled,nativeRunning,authorizationReady,permissionGranted,!sleeping,!alreadyStarted else{return}
        start()
    }
    public func reset(){generation &+= 1;sleeping=false}
    public func accepts(generation candidate:UInt64)->Bool{!sleeping && candidate==generation}
}
