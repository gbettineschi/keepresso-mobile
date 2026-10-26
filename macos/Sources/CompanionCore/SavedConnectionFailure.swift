import Foundation
import Security

public struct SavedConnectionFailure:Error,Equatable,Sendable {
    public enum Reason:Sendable {case locked,permissionRequired,cancelled,accessDenied,invalidData,unavailable}
    public let reason:Reason
    public let status:Int32?
    public init(reason:Reason,status:Int32?=nil){self.reason=reason;self.status=status}
    public init(status:Int32,keychainUnlocked:Bool?){
        let reason:Reason
        switch status{
        case errSecInteractionNotAllowed,errSecInteractionRequired:reason=keychainUnlocked==false ? .locked:.permissionRequired
        case errSecUserCanceled:reason = .cancelled
        case errSecAuthFailed:reason = .accessDenied
        case errSecDecode:reason = .invalidData
        default:reason = .unavailable
        }
        self.init(reason:reason,status:status)
    }
    public var canRetrySilently:Bool{[.locked,.permissionRequired,.unavailable].contains(reason)}
    public var message:String{
        switch reason{
        case .locked:return "macOS Keychain is locked. The saved connection will resume automatically when it unlocks."
        case .permissionRequired:return "This Mac build needs macOS permission to use the saved connection. Pairing has not been changed. Choose Always Allow in macOS to remember access."
        case .cancelled:return "macOS access was cancelled. Your saved connection is unchanged."
        case .accessDenied:return "macOS did not grant access to the saved connection. Your phone pairing has not been removed."
        case .invalidData:return "Saved connection data could not be read. Nothing has been reset or replaced."
        case .unavailable:return "The saved connection is temporarily unavailable. Retry without pairing again."
        }
    }
}
