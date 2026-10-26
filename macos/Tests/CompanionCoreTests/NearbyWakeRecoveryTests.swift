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
        },stop:{stops+=1},requestSleep:{sleeps+=1;return true},wait:{})
        #expect(response.status=="error");#expect(stops==0);#expect(sleeps==0)
    }
}
