import Foundation
import Testing
@testable import CompanionCore

@MainActor private final class FakeStartupService:StartupService {
    var status:StartupServiceStatus = .notRegistered
    var registrations=0,removals=0,failRegister=false,failUnregister=false
    var duringUnregister:(()async->Void)?
    func register()throws{registrations+=1;if failRegister{throw CompanionError.unavailable};status = .enabled}
    func unregister()async throws{removals+=1;await duringUnregister?();if failUnregister{throw CompanionError.unavailable};status = .notRegistered}
}
struct AutomaticStartupTests {
    @Test @MainActor func initialRegistrationHappensOnceAndHealthyStartupIsUntouched()async{
        let service=FakeStartupService();let registration=AutomaticStartupRegistration(service:service,managed:false,staleEvidence:{false})
        #expect(await registration.reconcile() == .enabled)
        #expect(await registration.reconcile() == .enabled)
        #expect(service.registrations==1);#expect(service.removals==0)
        let healthy=FakeStartupService();healthy.status = .enabled
        let existing=AutomaticStartupRegistration(service:healthy,managed:false,staleEvidence:{false})
        #expect(await existing.reconcile() == .enabled);#expect(healthy.registrations==0)
    }
    @Test @MainActor func revokedConsentIsNeverRemovedOrRegisteredAgain()async{
        let service=FakeStartupService();service.status = .requiresApproval
        let registration=AutomaticStartupRegistration(service:service,managed:false,staleEvidence:{true})
        #expect(await registration.reconcile() == .requiresApproval)
        #expect(service.registrations==0);#expect(service.removals==0)
    }
    @Test @MainActor func consentIsCheckedAgainAfterTheAsyncProbe()async{
        let service=FakeStartupService();service.status = .enabled
        let registration=AutomaticStartupRegistration(service:service,managed:false,staleEvidence:{service.status = .requiresApproval;return true})
        #expect(await registration.reconcile() == .requiresApproval)
        #expect(service.registrations==0);#expect(service.removals==0)
    }
    @Test @MainActor func confirmedStaleRegistrationIsRepairedOnce()async{
        let service=FakeStartupService();service.status = .enabled
        let registration=AutomaticStartupRegistration(service:service,managed:false,staleEvidence:{true})
        #expect(await registration.reconcile() == .enabled)
        _=await registration.reconcile()
        #expect(service.removals==1);#expect(service.registrations==1)
    }
    @Test @MainActor func failedRepairDoesNotRegisterOrLoop()async{
        let service=FakeStartupService();service.status = .enabled;service.failUnregister=true
        let registration=AutomaticStartupRegistration(service:service,managed:false,staleEvidence:{true})
        #expect(await registration.reconcile() == .unavailable)
        #expect(await registration.reconcile() == .unavailable)
        #expect(service.removals==1);#expect(service.registrations==0)
    }
    @Test @MainActor func deniedRegistrationDoesNotLoopAndShowsApprovalStatus()async{
        let service=FakeStartupService();service.failRegister=true
        let registration=AutomaticStartupRegistration(service:service,managed:false,staleEvidence:{false})
        #expect(await registration.reconcile() == .unavailable)
        service.status = .requiresApproval
        #expect(await registration.reconcile() == .requiresApproval)
        #expect(service.registrations==1)
    }
    @Test @MainActor func duplicateActivationAndShutdownCannotAddAnotherRegistration()async{
        let service=FakeStartupService();service.status = .enabled
        var release:CheckedContinuation<Bool,Never>?
        let registration=AutomaticStartupRegistration(service:service,managed:false,staleEvidence:{await withCheckedContinuation{release=$0}})
        let first=Task{await registration.reconcile()}
        for _ in 0..<100 where release==nil{await Task.yield()}
        #expect(release != nil)
        _=await registration.reconcile()
        registration.stop();release?.resume(returning:true)
        _=await first.value
        #expect(service.registrations==0);#expect(service.removals==0)
    }
    @Test @MainActor func shutdownDuringUnregisterPreventsReregistration()async{
        let service=FakeStartupService();service.status = .enabled
        let registration=AutomaticStartupRegistration(service:service,managed:false,staleEvidence:{true})
        service.duringUnregister={registration.stop()}
        _=await registration.reconcile()
        #expect(service.removals==1);#expect(service.registrations==0)
    }
    @Test @MainActor func managedAgentNeverUnregistersItself()async{
        let service=FakeStartupService();service.status = .enabled
        let registration=AutomaticStartupRegistration(service:service,managed:true,staleEvidence:{true})
        #expect(await registration.reconcile() == .enabled)
        #expect(service.removals==0);#expect(service.registrations==0)
    }
    @Test @MainActor func registrationMustActuallyLaunchAndGetsOneSettledRepair()async{
        let service=FakeStartupService();var checks=0
        let registration=AutomaticStartupRegistration(service:service,managed:false,staleEvidence:{false},verifyLaunch:{checks+=1;return checks==1 ? .failed:.running})
        #expect(await registration.reconcile() == .enabled)
        #expect(service.registrations==2);#expect(service.removals==1);#expect(checks==2)
    }
    @Test @MainActor func persistentLaunchFailureStaysUnavailableWithoutARepairLoop()async{
        let service=FakeStartupService()
        let registration=AutomaticStartupRegistration(service:service,managed:false,staleEvidence:{false},verifyLaunch:{.failed})
        #expect(await registration.reconcile() == .unavailable)
        #expect(await registration.reconcile() == .unavailable)
        #expect(service.registrations==2);#expect(service.removals==1)
    }
    @Test @MainActor func consentChangedDuringLaunchVerificationStopsRepair()async{
        let service=FakeStartupService()
        let registration=AutomaticStartupRegistration(service:service,managed:false,staleEvidence:{false},verifyLaunch:{service.status = .requiresApproval;return .failed})
        #expect(await registration.reconcile() == .requiresApproval)
        #expect(service.registrations==1);#expect(service.removals==0)
    }
    @Test @MainActor func shutdownDuringLaunchVerificationStopsRepair()async{
        let service=FakeStartupService();var registration:AutomaticStartupRegistration!
        registration=AutomaticStartupRegistration(service:service,managed:false,staleEvidence:{false},verifyLaunch:{registration.stop();return .failed})
        _=await registration.reconcile()
        #expect(service.registrations==1);#expect(service.removals==0)
    }
}
