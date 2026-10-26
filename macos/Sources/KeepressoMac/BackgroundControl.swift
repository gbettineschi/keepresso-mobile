import AppKit
import ServiceManagement
import Security
import Darwin
import CompanionCore
import OSLog
import CryptoKit

@MainActor private final class MacStartupService:StartupService {
    private let logger=Logger(subsystem:"local.keespresso.companion",category:"AutomaticStartup")
    let service:SMAppService
    init(_ service:SMAppService){self.service=service}
    var status:StartupServiceStatus {
        switch service.status {
        case .enabled:return .enabled
        case .requiresApproval:return .requiresApproval
        case .notRegistered:return .notRegistered
        case .notFound:return FileManager.default.fileExists(atPath:Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/local.keepresso.mobile.follow.plist").path) ? .notRegistered:.notFound
        default:return .notFound
        }
    }
    func register()throws{
        do{try service.register()}catch{
            if (error as NSError).code==kSMErrorAlreadyRegistered,service.status == .enabled{return}
            logger.error("Startup registration failed: \((error as NSError).code,privacy:.public)");throw error
        }
    }
    func unregister()async throws{
        do{try await service.unregister()}
        catch{
            let error=error as NSError
            var expectedDomain=error.domain==(kSMErrorDomainFramework as String)
            if #available(macOS 15.0,*){expectedDomain = expectedDomain || error.domain==SMAppServiceErrorDomain}
            guard expectedDomain,error.code==kSMErrorJobNotFound else{logger.error("Startup removal failed: \(error.code,privacy:.public)");throw error}
        }
        // The callback can precede BTM's status update. Do not race register
        // against an item still being removed; never clear revoked consent.
        for _ in 0..<20 {
            if service.status != .enabled{return}
            try await Task.sleep(for:.milliseconds(250))
        }
        throw CompanionError.unavailable
    }
}

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
    private let service:SMAppService
    private let registration:AutomaticStartupRegistration
    let managed: Bool
    @Published private(set) var status = "Checking automatic startup…"
    @Published private(set) var enabled = false
    @Published private(set) var approvalRequired = false
    @Published private(set) var warning = false
    private var refreshing=false,stopped=false
    private var takeoverToken: NSObjectProtocol?
    private let managedStart=ManagedStartupTask()
    var onManagedHandoff: (() -> Void)?
    init(managed: Bool) {
        self.managed = managed
        let service=SMAppService.agent(plistName:"local.keepresso.mobile.follow.plist")
        self.service=service
        // Record only a binary that has actually entered the managed role.
        // Version strings cannot distinguish two locally rebuilt trial bundles.
        let executableDigest=Bundle.main.executableURL.flatMap{try? Data(contentsOf:$0,options:.mappedIfSafe)}.map{Data(SHA256.hash(data:$0)).base64EncodedString()}
        let digestKey="registeredCompanionExecutableSHA256"
        if managed,let executableDigest{UserDefaults.standard.set(executableDigest,forKey:digestKey)}
        registration=AutomaticStartupRegistration(service:MacStartupService(service),managed:managed,staleEvidence:{
            if let executableDigest,UserDefaults.standard.string(forKey:digestKey) != executableDigest{return true}
            guard let data=try? await BoundedWorker.run(executable:URL(fileURLWithPath:"/bin/launchctl"),arguments:["print","gui/\(getuid())/\(Self.label)"],timeout:2,outputLimit:16384),let text=String(data:data,encoding:.utf8) else{return false}
            return BackgroundLaunchEvidence.requiresRefresh(text,currentBuild:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String)
        },verifyLaunch:{
            // launchd's failed-spawn constraint repair is throttled by ten
            // seconds. Leave it time to invalidate the old pin before rebinding.
            try? await Task.sleep(for:.seconds(12))
            guard !Task.isCancelled,let data=try? await BoundedWorker.run(executable:URL(fileURLWithPath:"/bin/launchctl"),arguments:["print","gui/\(getuid())/\(Self.label)"],timeout:2,outputLimit:16384),let text=String(data:data,encoding:.utf8) else{return .unavailable}
            return BackgroundLaunchEvidence.launchHealth(text)
        })
        takeoverToken = DistributedNotificationCenter.default().addObserver(forName: BackgroundLoginSession.takeover, object: String(getuid()), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.managed, self.service.status == .enabled else { return }
                self.onManagedHandoff?()
            }
        }
        refresh()
    }
    func stop() {
        stopped=true;registration.stop();managedStart.stop()
        if let takeoverToken { DistributedNotificationCenter.default().removeObserver(takeoverToken) }
        takeoverToken = nil
    }
    func refresh() {
        guard !stopped,!refreshing else{return}
        refreshing=true
        Task{
            defer{refreshing=false}
            let state=await registration.reconcile()
            guard !stopped else{return}
            enabled=state == .enabled;approvalRequired=state == .requiresApproval;warning = !enabled
            switch state {
            case .enabled:status=managed ? "Automatic startup is on. Connections follow native Keepresso.":"Automatic startup is registered. Starting the background app…";requestManagedStart()
            case .requiresApproval:status="Automatic startup is not allowed. Enable Keepresso Mobile in Login Items."
            case .unavailable:status="Automatic startup is unavailable. Check Login Items or reopen Keepresso Mobile."
            }
        }
    }
    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    func requestManagedStart() {
        guard !stopped,!managed,enabled,BackgroundLoginSession.identifier != nil else { return }
        let job = "gui/\(getuid())/\(Self.label)"
        // Start only this already-approved per-user job. No shell or user input.
        // A lifetime lock keeps its initial launch from running a second server.
        managedStart.start(operation:{
            guard (try? await BoundedWorker.run(executable:URL(fileURLWithPath:"/bin/launchctl"),arguments:["kickstart",job],timeout:2,outputLimit:1024)) != nil else{return false}
            try? await Task.sleep(for:.seconds(1))
            guard !Task.isCancelled,let data=try? await BoundedWorker.run(executable:URL(fileURLWithPath:"/bin/launchctl"),arguments:["print",job],timeout:2,outputLimit:16384),let text=String(data:data,encoding:.utf8) else{return false}
            return BackgroundLaunchEvidence.launchHealth(text) == .running
        },completion:{[weak self] ok in
            guard let self,!self.stopped else{return}
            if !ok { self.warning=true;self.status = "Automatic startup could not start. This session is running manually." }
        })
    }
}
