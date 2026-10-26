import AppKit
import Security
import OSLog

private let savedConnectionSignal=Notification.Name("KeepressoSavedConnectionEnvironmentChanged")
private let savedConnectionCallback:SecKeychainCallback={_,_,_ in
    // No credential/item contents, process identity or callback context is read.
    NotificationCenter.default.post(name:savedConnectionSignal,object:nil)
    return errSecSuccess
}

/// Event-driven recovery for the existing file-based Keychain. Registration is
/// on AppKit's active run loop; callbacks only request a coalesced silent read.
@MainActor final class SavedConnectionEvents {
    private var keychainRegistered=false
    private var observers:[(NotificationCenter,NSObjectProtocol)]=[]
    private var generation=UUID()
    private let changed:()->Void
    init(changed:@escaping()->Void){self.changed=changed}
    func start(){
        guard observers.isEmpty else{return}
        let token=generation
        func observe(_ center:NotificationCenter,_ name:Notification.Name){
            let observer=center.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in
                Task{@MainActor in guard let self,self.generation==token,!self.observers.isEmpty else{return};self.changed()}
            }
            observers.append((center,observer))
        }
        observe(.default,savedConnectionSignal)
        observe(NSWorkspace.shared.notificationCenter,NSWorkspace.didWakeNotification)
        observe(NSWorkspace.shared.notificationCenter,NSWorkspace.sessionDidBecomeActiveNotification)
        let status=SecKeychainAddCallback(savedConnectionCallback,.unlockEventMask,nil)
        keychainRegistered=status==errSecSuccess
        if !keychainRegistered{Logger(subsystem:"local.keespresso.companion",category:"saved-connection").error("Keychain unlock observer unavailable: \(status,privacy:.public)")}
    }
    func stop(){
        generation=UUID()
        if keychainRegistered{SecKeychainRemoveCallback(savedConnectionCallback);keychainRegistered=false}
        for (center,observer) in observers{center.removeObserver(observer)}
        observers=[]
    }
}
