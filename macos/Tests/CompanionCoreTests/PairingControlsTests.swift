import Testing
@testable import CompanionCore
struct PairingControlsTests {
    @Test func unavailableKeysNeverOfferNewPairingOrDeletion(){
        let controls=PairingControls(savedKeysReady:false,loading:false,pairedPhoneCount:0,nativeRunning:true)
        #expect(controls.primary == .unlock);#expect(controls.primaryEnabled);#expect(!controls.deleteEnabled)
        let reading=PairingControls(savedKeysReady:false,loading:true,pairedPhoneCount:1,nativeRunning:true)
        #expect(!reading.primaryEnabled);#expect(!reading.deleteEnabled)
    }
    @Test func onlyOnePairingActionIsEnabledAcrossLoadedStates(){
        for count in [0,1,8]{
            let controls=PairingControls(savedKeysReady:true,loading:false,pairedPhoneCount:count,nativeRunning:true)
            #expect(controls.primary == .showQR)
            #expect(controls.primaryEnabled == (count==0));#expect(controls.deleteEnabled == (count>0))
            #expect(!(controls.primaryEnabled && controls.deleteEnabled))
        }
    }
    @Test func nativeKeepressoIsNeededForQRCodeButNotForRevocation(){
        let unpaired=PairingControls(savedKeysReady:true,loading:false,pairedPhoneCount:0,nativeRunning:false)
        #expect(!unpaired.primaryEnabled);#expect(!unpaired.deleteEnabled)
        let paired=PairingControls(savedKeysReady:true,loading:false,pairedPhoneCount:1,nativeRunning:false)
        #expect(!paired.primaryEnabled);#expect(paired.deleteEnabled)
    }
}
