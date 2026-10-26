import AppKit
import ApplicationServices
import CompanionCore
import KeepressoCore
import CoreGraphics
import IOKit.pwr_mgt

@MainActor final class NativeStatus {
    let network=MacNetworkStatus()
    private lazy var temperature=CompanionTemperatureMonitor()
    static let appURL=URL(fileURLWithPath:"/Applications/Keepresso.app")
    func runningApp() -> NSRunningApplication? { NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == Self.appURL.standardizedFileURL } }
    var installedVersion: String? { Bundle(url:Self.appURL)?.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String }
    func native() -> StatusSnapshot? {
        guard let app=runningApp(),let size=(try? StatusFile.defaultURL().resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size<=65536,let s=StatusFile.read(),s.pid==app.processIdentifier,StatusEvidence.belongsToCurrentLaunch(writtenAt:s.writtenAt,launchDate:app.launchDate,now:Date()) else { return nil }
        return s
    }
    func snapshot(triggers: TriggerPreview,reminders: ReminderMachine,ax: AccessibilityControl) -> [String: Any] {
        let source=IOKitPowerSourceMonitor().current
        let session=CGSessionCopyCurrentDictionary() as? [String: Any]
        let lock=(session?["CGSSessionScreenIsLocked"] as? Bool).map { $0 ? "locked":"unlocked" } ?? "unknown"
        let lid=IORegistryLidState().isClosed().map { $0 ? "closed":"open" } ?? "unknown"
        var count:UInt32=0;var display="unknown"
        if CGGetOnlineDisplayList(0,nil,&count) == .success,count>0 {
            var ids=[CGDirectDisplayID](repeating:0,count:Int(count))
            if CGGetOnlineDisplayList(count,&ids,&count) == .success { display=ids.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 } ? "off":"on" }
        } // Public APIs cannot distinguish dimmed reliably. Never fabricate it.
        let thermal:String
        switch ProcessInfo.processInfo.thermalState { case .nominal: thermal="normal";case .fair:thermal="warm";case .serious,.critical:thermal="hot";@unknown default:thermal="unknown" }
        let running=runningApp() != nil;let status=running ? native():nil;let kind=sessionKind(status)
        let sleepPort=running && status != nil ? IOPMFindPowerManagement(mach_task_self_):0
        if sleepPort != 0{IOServiceClose(sleepPort)}
        let capabilities:[String:Any]=["startManual":FileManager.default.fileExists(atPath:Self.appURL.path),"stopManual":kind=="manual","pauseTriggers":ax.canPerform("Pause Triggers"),"resumeTriggers":ax.canPerform("Resume Triggers"),"sleepNow":sleepPort != 0,"refreshTriggers":installedVersion=="1.27.0"]
        let k:[String:Any]=["appRunning":running,"version":installedVersion as Any? ?? NSNull(),"isActive":StatusEvidence.brewingActivity(appRunning:running,nativeActive:status?.isActive) as Any? ?? NSNull(),"endsAt":status?.endsAt.map(WireJSON.iso) as Any? ?? NSNull(),"triggersEnabled":status?.triggersEnabled as Any? ?? NSNull(),"triggersPaused":status?.triggersPaused as Any? ?? NSNull(),"sessionKind":kind,"safetyPause":"unknown"]
        let reading=temperature.reading()
        var mac:[String:Any]=["lock":lock,"display":display,"lid":lid,"batteryPercent":source.percentage as Any? ?? NSNull(),"powerSource":source.provider.rawValue,"isCharging":source.hasBattery ? source.isCharging as Any:NSNull(),"temperatureC":reading?.celsius as Any? ?? NSNull(),"temperatureSensor":reading?.sensor as Any? ?? NSNull(),"thermal":thermal]
        mac.merge(network.snapshot()){_,new in new}
        let reminder:[String:Any]=["enabled":reminders.settings.enabled,"intervalSeconds":reminders.settings.intervalSeconds,"endedAwakeDelaySeconds":reminders.settings.endedAwakeDelaySeconds,"snoozedUntil":reminders.snoozedUntil.map(WireJSON.iso) as Any? ?? NSNull()]
        return ["capturedAt":WireJSON.iso(Date()),"macName":Host.current().localizedName ?? "Mac","mac":mac,"keepresso":k,"capabilities":capabilities,"triggers":(try? WireJSON.object(WireJSON.encoder.encode(triggers))) ?? [:],"reminders":reminder]
    }
    func sessionKind(_ s: StatusSnapshot?) -> String {
        guard let s,s.isActive else { return "unknown" }
        if s.leaseIDs?.isEmpty == false { return "lease" }
        if s.triggersEnabled && !s.triggersPaused { return "automatic" }
        // An indefinite public snapshot does not reliably identify ownership.
        if s.endsAt != nil && (!s.triggersEnabled || s.triggersPaused) { return "manual" }
        return "unknown"
    }
}
/// Only presses an already exposed, enabled, uniquely matching native action.
/// It never opens an inferred status item or clicks coordinates to find a control.
@MainActor final class AccessibilityControl {
    private let status:NativeStatus
    init(status:NativeStatus) { self.status=status }
    func controls(_ title:String) -> [AXUIElement] {
        guard AXIsProcessTrusted(),let app=status.runningApp(),["Pause Triggers","Resume Triggers"].contains(title),status.installedVersion=="1.27.0" else { return [] }
        var found:[AXUIElement]=[];var remaining=128;let deadline=ProcessInfo.processInfo.systemUptime+0.075
        func attr(_ e:AXUIElement,_ key:CFString)->CFTypeRef? { var value:CFTypeRef?; guard AXUIElementCopyAttributeValue(e,key,&value) == .success else{return nil};return value }
        func walk(_ e:AXUIElement,_ depth:Int) {
            guard depth<10,remaining>0,ProcessInfo.processInfo.systemUptime<deadline else{return};remaining-=1
            let t=attr(e,kAXTitleAttribute as CFString) as? String
            let role=attr(e,kAXRoleAttribute as CFString) as? String
            let enabled=attr(e,kAXEnabledAttribute as CFString) as? Bool
            if t==title,enabled==true,[kAXButtonRole,kAXMenuItemRole].contains(role ?? "") { var actions:CFArray?;if AXUIElementCopyActionNames(e,&actions) == .success,(actions as? [String])?.contains(kAXPressAction)==true { found.append(e) } }
            for c in (attr(e,kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? [] { walk(c,depth+1) }
        }
        let root=AXUIElementCreateApplication(app.processIdentifier);AXUIElementSetMessagingTimeout(root,0.01);walk(root,0);return found
    }
    func canPerform(_ title:String)->Bool { controls(title).count==1 }
    func perform(_ title:String)throws { let c=controls(title);guard c.count==1,AXUIElementPerformAction(c[0],kAXPressAction as CFString) == .success else {throw CompanionError.unavailable} }
}
@MainActor final class NativeCommands {
    let status:NativeStatus;let ax:AccessibilityControl
    init(status:NativeStatus,ax:AccessibilityControl) { self.status=status;self.ax=ax }
    func execute(_ r:CommandRequest,authorized:@escaping()->Bool={true}) async -> CommandResponse {
        let issued=Date();let before=status.native()
        guard let original=status.runningApp(),let originalLaunch=original.launchDate else{return CommandResponse(id:r.id,status:"error",message:"The current Keepresso process could not be verified.")}
        func stillAuthorized()->Bool{
            let current=status.runningApp()
            return authorized() && Date()<r.expiresAt && StatusEvidence.sameLaunch(pid:original.processIdentifier,launchDate:originalLaunch,currentPID:current?.processIdentifier,currentLaunchDate:current?.launchDate)
        }
        if r.action=="sleep_now"{
            let initiallyStopped=before.map{!$0.isActive && (!$0.triggersEnabled || $0.triggersPaused)}==true
            return await SafeSleep.perform(id:r.id,authorized:stillAuthorized,state:{
                let sleepDisabled=await SystemSleepSettings.readDisabled()
                guard let current=self.status.native() else{return nil}
                // An already verified idle/paused state need not rewrite its
                // snapshot in response to an idempotent Stop URL.
                let acknowledged=initiallyStopped || StatusEvidence.acknowledges(writtenAt:current.writtenAt,modifiedAt:(try? FileManager.default.attributesOfItem(atPath:StatusFile.defaultURL().path)[.modificationDate]) as? Date,issuedAt:issued)
                return SleepPreparationState(stopped:acknowledged ? (!current.isActive && (!current.triggersEnabled || current.triggersPaused)):nil,sleepDisabled:sleepDisabled)
            },stop:{try await self.open(URL(string:"keepresso://stop")!)},requestSleep:{
                let port=IOPMFindPowerManagement(mach_task_self_)
                guard port != 0 else{return false};defer{IOServiceClose(port)}
                return IOPMSleepSystem(port)==kIOReturnSuccess
            })
        }
        guard stillAuthorized() else{return CommandResponse(id:r.id,status:"error",message:"Phone authorization changed or the command expired.")}
        do {
            switch r.action {
            case "start_manual":
                guard let minutes=r.durationMinutes,FileManager.default.fileExists(atPath:NativeStatus.appURL.path) else { throw CompanionError.unavailable }
                let url=URL(string:"keepresso://start?duration=\(minutes)")!
                try await open(url)
            case "stop_manual":
                guard status.sessionKind(before)=="manual" else { throw CompanionError.unavailable };try await open(URL(string:"keepresso://stop")!)
            case "pause_triggers": try ax.perform("Pause Triggers")
            case "resume_triggers": try ax.perform("Resume Triggers")
            default: throw CompanionError.invalid
            }
        } catch { return CommandResponse(id:r.id,status:"error",message:"Control unavailable. Keepresso must be installed and its native control must be unambiguous. Pause/Resume additionally needs Accessibility permission and an exposed native control.") }
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds:250_000_000)
            let current=status.runningApp()
            guard !Task.isCancelled,authorized(),StatusEvidence.sameLaunch(pid:original.processIdentifier,launchDate:originalLaunch,currentPID:current?.processIdentifier,currentLaunchDate:current?.launchDate) else{return CommandResponse(id:r.id,status:"uncertain",message:"Keepresso or phone authorization changed while the request was in progress. It will not be retried automatically.")}
            guard let after=status.native(),StatusEvidence.acknowledges(writtenAt:after.writtenAt,modifiedAt:(try? FileManager.default.attributesOfItem(atPath:StatusFile.defaultURL().path)[.modificationDate]) as? Date,issuedAt:issued) else {continue}
            let confirmed:Bool
            switch r.action {
            case "start_manual": confirmed=after.isActive && (!after.triggersEnabled || after.triggersPaused) && after.endsAt.map { abs($0.timeIntervalSince(issued)-Double(r.durationMinutes!*60))<10 } == true
            case "stop_manual": confirmed = !after.isActive && (!after.triggersEnabled || after.triggersPaused)
            case "pause_triggers":confirmed=after.triggersPaused
            case "resume_triggers":confirmed=after.triggersEnabled && !after.triggersPaused
            default:confirmed=false
            }
            if confirmed { return CommandResponse(id:r.id,status:"ok",message:"Observed the requested Keepresso state.") }
        }
        return CommandResponse(id:r.id,status:"uncertain",message:"The request was delivered, but Keepresso did not confirm the requested state. It will not be retried automatically.")
    }
    private func open(_ url:URL) async throws {
        // Pin the destination app instead of trusting the user's scheme handler.
        let config=NSWorkspace.OpenConfiguration();config.activates=false
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            NSWorkspace.shared.open([url],withApplicationAt:NativeStatus.appURL,configuration:config) { _,error in if let error { continuation.resume(throwing:error) } else { continuation.resume() } }
        }
    }
}

enum SystemSleepSettings {
    /// Fixed read-only process off the main actor, bounded if powerd stalls.
    static func readDisabled()async->Bool?{
        guard let data=try? await BoundedWorker.run(executable:URL(fileURLWithPath:"/usr/bin/pmset"),arguments:["-g"],timeout:1.5,outputLimit:16384),let text=String(data:data,encoding:.utf8),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return nil}
        return PMSetSleepControl.parseSleepDisabled(from:text)
    }
}
