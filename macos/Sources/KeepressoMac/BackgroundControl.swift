import AppKit
import ServiceManagement
import Security
import Darwin
import CompanionCore

enum BackgroundLoginSession {
    static let quitKey = "backgroundExplicitQuitSession"
    static let reopenKey = "backgroundReopenSettings"
    static let takeover = Notification.Name("local.keepresso.mobile.managed-start")
    static var identifier: String? {
        var session: SecuritySessionId = 0
        var boot = timeval(); var size = MemoryLayout<timeval>.size
        guard SessionGetInfo(callerSecuritySession, &session, nil) == errSecSuccess,
              sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return "\(boot.tv_sec)/\(session)"
    }
    static func markExplicitQuit() {
        if let identifier { UserDefaults.standard.set(identifier, forKey: quitKey) }
    }
    static var mayStartHidden: Bool {
        guard let identifier else { return false }
        return UserDefaults.standard.string(forKey: quitKey) != identifier
    }
}

@MainActor final class BackgroundControl: ObservableObject {
    static let label = "local.keepresso.mobile.follow"
    private let service = SMAppService.agent(plistName: "local.keepresso.mobile.follow.plist")
    let managed: Bool
    @Published private(set) var status = "Automatic startup is off."
    @Published private(set) var enabled = false
    @Published private(set) var approvalRequired = false
    @Published private(set) var requiresRefresh = false
    private var checkingLaunch = false
    private var takeoverToken: NSObjectProtocol?
    private var starting = false
    var onManagedHandoff: (() -> Void)?
    init(managed: Bool) {
        self.managed = managed
        takeoverToken = DistributedNotificationCenter.default().addObserver(forName: BackgroundLoginSession.takeover, object: String(getuid()), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.managed, self.service.status == .enabled else { return }
                self.onManagedHandoff?()
            }
        }
        refresh()
    }
    func stop() {
        if let takeoverToken { DistributedNotificationCenter.default().removeObserver(takeoverToken) }
        takeoverToken = nil
    }
    func refresh() {
        enabled = service.status == .enabled
        approvalRequired = service.status == .requiresApproval
        switch service.status {
        case .enabled: status = managed ? "Follow Keepresso is on. Restarts after a crash or forced kill." : "Follow Keepresso is enabled. Completing background startup…"
        case .requiresApproval: status = "Allow Keepresso Mobile in macOS Login Items to finish setup."
        case .notRegistered: status = "Follow Keepresso is off. This app stays open until you quit it."
        case .notFound: status = "Background startup is unavailable. Reinstall the complete app bundle."
        @unknown default: status = "Background startup status is unavailable."
        }
        guard !managed,!checkingLaunch else{return}
        checkingLaunch=true
        Task{
            defer{checkingLaunch=false}
            if let data=try? await BoundedWorker.run(executable:URL(fileURLWithPath:"/bin/launchctl"),arguments:["print","gui/\(getuid())/\(Self.label)"],timeout:2,outputLimit:16384),let text=String(data:data,encoding:.utf8),BackgroundLaunchEvidence.requiresRefresh(text,currentBuild:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String){
                requiresRefresh=true
                status="This local update needs automatic startup refreshed. Pairing is retained; this app is running normally."
            }
        }
    }
    /// Explicit owner action only: replace the old build's registered signing requirement.
    func refreshRegistration(){
        guard !managed else{return}
        Task{
            // A new ad-hoc identity may report notRegistered for the old registration.
            // Still attempt its cleanup, then let macOS apply approval to the new one.
            try? await service.unregister()
            do{try service.register();requiresRefresh=false;refresh();requestManagedStart()}
            catch{status="Automatic startup could not be refreshed. Check macOS Login Items and try again."}
        }
    }
    func enable() {
        guard BackgroundLoginSession.identifier != nil else { status = "Your login session could not be verified. Automatic startup was not enabled."; return }
        do { try service.register(); refresh(); requestManagedStart() }
        catch { refresh(); if !enabled && !approvalRequired { status = "Automatic startup could not be enabled. Move the app to Applications and try again." } }
    }
    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    func requestManagedStart() {
        guard !managed, enabled, !starting else { return }
        starting = true
        let job = "gui/\(getuid())/\(Self.label)"
        // Start only this already-approved per-user job. No shell or user input.
        // A lifetime lock keeps its initial launch from running a second server.
        Task {
            let ok = (try? await BoundedWorker.run(executable:URL(fileURLWithPath:"/bin/launchctl"),arguments:["kickstart",job],timeout:2,outputLimit:1024)) != nil
            starting = false
            if !ok { status = "Automatic startup is enabled for your next login. This session is running manually." }
        }
    }
}
