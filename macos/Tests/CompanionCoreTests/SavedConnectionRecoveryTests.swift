import Foundation
import Security
import Testing
@testable import CompanionCore

private final class RecoveringReader:@unchecked Sendable {
    private let lock=NSLock()
    private var remaining:Int
    private var count=0
    let failure:SavedConnectionFailure
    init(failures:Int=1,failure:SavedConnectionFailure=SavedConnectionFailure(reason:.locked)){remaining=failures;self.failure=failure}
    var calls:Int{lock.lock();defer{lock.unlock()};return count}
    func read()throws->SavedAuthorization{
        lock.lock();defer{lock.unlock()};count+=1
        if remaining>0{remaining-=1;throw failure}
        return SavedAuthorization(devices:[AuthorizedDevice(deviceId:"11111111-1111-4111-8111-111111111111",name:"Fixture",key:Data(repeating:7,count:32),approvedAt:Date())],relay:nil)
    }
}
private final class SlowUnavailableReader:@unchecked Sendable {
    let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
    func read()throws->SavedAuthorization{entered.signal();_ = release.wait(timeout:.now()+5);throw SavedConnectionFailure(reason:.locked)}
}
@MainActor private final class RecoveryDelay {
    private var continuation:CheckedContinuation<Void,Never>?
    var waiting:Bool{continuation != nil}
    func wait()async{await withCheckedContinuation{continuation=$0}}
    func release(){let pending=continuation;continuation=nil;pending?.resume()}
}
struct SavedConnectionRecoveryTests {
    @MainActor private func settle(_ loader:SavedAuthorizationLoader)async throws{
        for _ in 0..<100 where loader.state == .loading{try await Task.sleep(for:.milliseconds(10))}
    }
    @Test func keychainErrorsDistinguishLockedApprovalDeniedAndBadData(){
        #expect(SavedConnectionFailure(status:errSecInteractionNotAllowed,keychainUnlocked:false).reason == .locked)
        #expect(SavedConnectionFailure(status:errSecInteractionNotAllowed,keychainUnlocked:true).reason == .permissionRequired)
        #expect(SavedConnectionFailure(status:errSecInteractionRequired,keychainUnlocked:nil).reason == .permissionRequired)
        #expect(SavedConnectionFailure(status:errSecUserCanceled,keychainUnlocked:true).reason == .cancelled)
        #expect(SavedConnectionFailure(status:errSecAuthFailed,keychainUnlocked:true).reason == .accessDenied)
        #expect(SavedConnectionFailure(status:errSecDecode,keychainUnlocked:true).reason == .invalidData)
        #expect(SavedConnectionFailure(status:errSecNotAvailable,keychainUnlocked:true).reason == .unavailable)
    }
    @Test @MainActor func unlockEventRecoversSavedIdentityWithoutPairingAgain()async throws{
        let reader=RecoveringReader(),loader=SavedAuthorizationLoader();var ids:[String]=[]
        loader.load(operation:{try reader.read()}){saved in ids=saved.devices.map(\.deviceId)}
        try await settle(loader)
        #expect(loader.failure == reader.failure);#expect(ids.isEmpty)
        loader.retryAfterEnvironmentChange(operation:{try reader.read()}){saved in ids=saved.devices.map(\.deviceId)}
        try await settle(loader)
        #expect(loader.state == .ready);#expect(loader.failure==nil);#expect(reader.calls==2)
        #expect(ids==["11111111-1111-4111-8111-111111111111"])
    }
    @Test @MainActor func eventStormIsCoalescedAndReadyStateNeverReloads()async throws{
        let reader=RecoveringReader(),loader=SavedAuthorizationLoader();var completions=0
        loader.load(operation:{try reader.read()}){_ in completions+=1};try await settle(loader)
        for _ in 0..<20{loader.retryAfterEnvironmentChange(operation:{try reader.read()}){_ in completions+=1}}
        try await settle(loader)
        #expect(reader.calls==2);#expect(completions==1)
        loader.retryAfterEnvironmentChange(operation:{try reader.read()}){_ in completions+=1}
        #expect(reader.calls==2)
    }
    @Test @MainActor func deniedCancelledAndInvalidDataNeverRetryAutomatically()async throws{
        for reason in [SavedConnectionFailure.Reason.accessDenied,.cancelled,.invalidData]{
            let reader=RecoveringReader(failure:SavedConnectionFailure(reason:reason)),loader=SavedAuthorizationLoader()
            loader.load(operation:{try reader.read()}){_ in Issue.record("must remain closed")};try await settle(loader)
            loader.retryAfterEnvironmentChange(operation:{try reader.read()}){_ in Issue.record("must not retry")};try await settle(loader)
            #expect(reader.calls==1);#expect(loader.state == .unavailable);#expect(loader.failure?.reason==reason)
        }
    }
    @Test @MainActor func repeatedFailuresAreRateLimitedWithoutPolling()async throws{
        var clock:TimeInterval=100
        let reader=RecoveringReader(failures:10),loader=SavedAuthorizationLoader(now:{clock})
        loader.load(operation:{try reader.read()}){_ in Issue.record("must remain closed")};try await settle(loader)
        loader.retryAfterEnvironmentChange(operation:{try reader.read()}){_ in Issue.record("must remain closed")};try await settle(loader)
        for _ in 0..<10{loader.retryAfterEnvironmentChange(operation:{try reader.read()}){_ in Issue.record("must remain closed")}}
        #expect(reader.calls==2)
        clock+=2
        loader.retryAfterEnvironmentChange(operation:{try reader.read()}){_ in Issue.record("must remain closed")};try await settle(loader)
        #expect(reader.calls==3)
    }
    @Test @MainActor func unlockDuringAnOutstandingReadSchedulesOneSilentRecovery()async throws{
        let slow=SlowUnavailableReader(),recovery=RecoveringReader(failures:0),loader=SavedAuthorizationLoader();var completions=0
        loader.load(operation:{try slow.read()}){_ in Issue.record("first read must fail")}
        for _ in 0..<100{if slow.entered.wait(timeout:.now()) == .success{break};try await Task.sleep(for:.milliseconds(10))}
        loader.retryAfterEnvironmentChange(operation:{try recovery.read()}){_ in completions+=1}
        slow.release.signal();try await settle(loader)
        #expect(loader.state == .ready);#expect(recovery.calls==1);#expect(completions==1)
    }
    @Test @MainActor func shutdownDropsAnUnlockQueuedDuringARead()async throws{
        let slow=SlowUnavailableReader(),recovery=RecoveringReader(failures:0),loader=SavedAuthorizationLoader()
        loader.load(operation:{try slow.read()}){_ in Issue.record("stopped result")}
        for _ in 0..<100{if slow.entered.wait(timeout:.now()) == .success{break};try await Task.sleep(for:.milliseconds(10))}
        loader.retryAfterEnvironmentChange(operation:{try recovery.read()}){_ in Issue.record("stopped recovery")}
        loader.stop();slow.release.signal();try await Task.sleep(for:.milliseconds(50))
        #expect(loader.state == .idle);#expect(recovery.calls==0);#expect(loader.failure==nil)
    }
    @Test @MainActor func unlockDuringAutomaticRetrySurvivesItsCooldown()async throws{
        var clock:TimeInterval=100
        let delay=RecoveryDelay(),initial=RecoveringReader(),slow=SlowUnavailableReader(),recovery=RecoveringReader(failures:0)
        let loader=SavedAuthorizationLoader(now:{clock},waitBeforeRecovery:{_ in await delay.wait()})
        loader.load(operation:{try initial.read()}){_ in Issue.record("initial failure")};try await settle(loader)
        loader.retryAfterEnvironmentChange(operation:{try slow.read()}){_ in Issue.record("stale failure")}
        for _ in 0..<100{if slow.entered.wait(timeout:.now()) == .success{break};try await Task.sleep(for:.milliseconds(10))}
        loader.retryAfterEnvironmentChange(operation:{try recovery.read()}){_ in}
        slow.release.signal();try await settle(loader)
        for _ in 0..<100 where !delay.waiting{try await Task.sleep(for:.milliseconds(10))}
        #expect(delay.waiting);#expect(recovery.calls==0)
        clock+=2;delay.release()
        for _ in 0..<100 where loader.state != .ready{try await Task.sleep(for:.milliseconds(10))}
        #expect(loader.state == .ready);#expect(recovery.calls==1)
    }
    @Test @MainActor func shutdownCancelsARecoveryWaitingForCooldown()async throws{
        var clock:TimeInterval=100
        let delay=RecoveryDelay(),reader=RecoveringReader(failures:2)
        let loader=SavedAuthorizationLoader(now:{clock},waitBeforeRecovery:{_ in await delay.wait()})
        loader.load(operation:{try reader.read()}){_ in};try await settle(loader)
        loader.retryAfterEnvironmentChange(operation:{try reader.read()}){_ in};try await settle(loader)
        loader.retryAfterEnvironmentChange(operation:{try reader.read()}){_ in}
        for _ in 0..<100 where !delay.waiting{try await Task.sleep(for:.milliseconds(10))}
        #expect(delay.waiting)
        loader.stop();clock+=2;delay.release();try await Task.sleep(for:.milliseconds(30))
        #expect(loader.state == .idle);#expect(reader.calls==2)
    }
}
