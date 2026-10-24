import Foundation

/// Unknown credentials are never equivalent to an empty pairing slot.
public struct PairingControls {
    public enum Primary { case unlock,showQR }
    public let primary:Primary,primaryEnabled:Bool,deleteEnabled:Bool
    public init(savedKeysReady:Bool,loading:Bool,pairedPhoneCount:Int,nativeRunning:Bool){
        primary=savedKeysReady ? .showQR:.unlock
        primaryEnabled = !loading && (!savedKeysReady || (pairedPhoneCount==0 && nativeRunning))
        deleteEnabled = !loading && savedKeysReady && pairedPhoneCount>0
    }
}
