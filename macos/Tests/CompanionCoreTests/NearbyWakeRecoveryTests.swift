import Foundation
import Testing
@testable import CompanionCore

struct NearbyWakeRecoveryTests {
    @MainActor @Test func sleepDiscardsOldPeerAndWakeRequiresFreshAuthentication(){
        var resource:UUID?=UUID(),authenticated=true,starts=0,stops=0
        let original=resource
        let recovery=NearbyWakeRecovery(stop:{stops+=1;resource=nil;authenticated=false},start:{starts+=1;resource=UUID()})
        recovery.willSleep()
        #expect(resource==nil);#expect(!authenticated);#expect(recovery.sleeping)
        recovery.willSleep();#expect(stops==1)
        recovery.didWake(enabled:true)
        #expect(!recovery.sleeping);#expect(resource != nil);#expect(resource != original);#expect(!authenticated);#expect(starts==1)
        recovery.didWake(enabled:true);#expect(starts==1)
    }
    @MainActor @Test func disablingNearbyDuringSleepDoesNotRestartItOnWake(){
        var starts=0,stops=0
        let recovery=NearbyWakeRecovery(stop:{stops+=1},start:{starts+=1})
        recovery.willSleep();recovery.didWake(enabled:false)
        #expect(stops==1);#expect(starts==0);#expect(!recovery.sleeping)
    }
    @MainActor @Test func nativeQuitResetCannotRestartOldTransportOnALateWake(){
        var starts=0
        let recovery=NearbyWakeRecovery(stop:{},start:{starts+=1})
        recovery.willSleep();recovery.reset();recovery.didWake(enabled:true)
        #expect(starts==0)
    }
    @MainActor @Test func shortSleepWakeCannotReviveAnInFlightPowerCommand()async{
        var stops=0,sleeps=0
        let recovery=NearbyWakeRecovery(stop:{},start:{})
        let generation=recovery.generation
        let response=await SafeSleep.perform(id:UUID().uuidString.lowercased(),authorized:{!recovery.sleeping && recovery.generation==generation},state:{
            recovery.willSleep();recovery.didWake(enabled:true)
            return SleepPreparationState(stopped:true,sleepDisabled:false)
        },stop:{stops+=1},requestSleep:{sleeps+=1;return .willSleep},wait:{})
        #expect(response.status=="error");#expect(stops==0);#expect(sleeps==0)
    }
}

extension NearbyWakeRecoveryTests {
    @MainActor @Test func manuallyGrantedBluetoothResumesOnlyAnEligibleSavedTransportOnce() {
        var starts = 0, alreadyStarted = false
        let recovery = NearbyWakeRecovery(stop: {}, start: { starts += 1; alreadyStarted = true })
        for (enabled, nativeRunning, authorizationReady, permissionGranted, existing) in [
            (false, true, true, true, false),
            (true, false, true, true, false),
            (true, true, false, true, false),
            (true, true, true, false, false),
            (true, true, true, true, true)
        ] {
            recovery.permissionRefreshed(enabled: enabled, nativeRunning: nativeRunning,
                authorizationReady: authorizationReady, permissionGranted: permissionGranted, alreadyStarted: existing)
        }
        #expect(starts == 0)
        recovery.willSleep()
        recovery.permissionRefreshed(enabled: true, nativeRunning: true, authorizationReady: true,
            permissionGranted: true, alreadyStarted: false)
        #expect(starts == 0)
        recovery.reset()
        recovery.permissionRefreshed(enabled: true, nativeRunning: true, authorizationReady: true,
            permissionGranted: true, alreadyStarted: alreadyStarted)
        #expect(starts == 1)
        recovery.permissionRefreshed(enabled: true, nativeRunning: true, authorizationReady: true,
            permissionGranted: true, alreadyStarted: alreadyStarted)
        #expect(starts == 1)
    }
}
