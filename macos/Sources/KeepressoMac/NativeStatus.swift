import AppKit
import ApplicationServices
import CompanionCore
import KeepressoCore
import CoreGraphics
import IOKit
import IOKit.pwr_mgt
import os.lock

fileprivate struct NativeAlertReport: Decodable {
    let wakeState: MacAlertWakeState?
    let brewingStartedAt: Date?
    let brewingMode: MacBrewReading.Mode?
    let returnsToAutomatic: Bool?
    let lastUserInputAt: Date?
}

fileprivate struct NativeTriggerModeReport: Decodable {
    let supportsTriggerModeControl: Bool?
    let lastTriggerModeRequestID: UUID?
}

private struct NativeTriggerModeRequest: Encodable {
    let id: UUID
    let pid: Int32
    let paused: Bool
    let validUntil: Date

    var file: URL {
        StatusFile.defaultURL().deletingLastPathComponent().appendingPathComponent(".trigger-mode-\(id.uuidString).json")
    }

    var doorbell: URL {
        URL(string: "keepresso://apply-trigger-mode?id=\(id.uuidString)")!
    }
}

@MainActor final class NativeStatus {
    let network=MacNetworkStatus()
    private let modelIdentifier = MachineIdentity.currentModelIdentifier()
    static let appURL=URL(fileURLWithPath:"/Applications/Keepresso.app")
    func runningApp() -> NSRunningApplication? { NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == Self.appURL.standardizedFileURL } }
    var installedVersion: String? { Bundle(url:Self.appURL)?.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String }
    fileprivate func nativeRecord(for app: NSRunningApplication?, now: Date)
    -> (status: StatusSnapshot, thermal: NativeThermalReport?, triggerMode: NativeTriggerModeReport?, alerts: NativeAlertReport?)? {
        let url = StatusFile.defaultURL()
        guard let app,
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 65536,
              let data = try? Data(contentsOf: url), data.count <= 65536,
              let status = try? WireJSON.decoder.decode(StatusSnapshot.self, from: data),
              status.pid == app.processIdentifier,
              StatusEvidence.belongsToCurrentLaunch(writtenAt: status.writtenAt, launchDate: app.launchDate, now: now)
        else { return nil }
        let thermal = try? WireJSON.decoder.decode(NativeThermalReport.self, from: data)
        let triggerMode = try? WireJSON.decoder.decode(NativeTriggerModeReport.self, from: data)
        let alerts = try? WireJSON.decoder.decode(NativeAlertReport.self, from: data)
        return (status, thermal, triggerMode, alerts)
    }

    func native() -> StatusSnapshot? {
        nativeRecord(for: runningApp(), now: Date())?.status
    }

    var supportsDirectTriggerMode: Bool {
        nativeRecord(for: runningApp(), now: Date())?.triggerMode?.supportsTriggerModeControl == true
    }

    func thermalReading(now: Date) -> MacThermalReading {
        let record = nativeRecord(for: runningApp(), now: now)
        return MacThermalReading(system: .current, report: record?.thermal, writtenAt: record?.status.writtenAt, now: now)
    }

    var fullWake: Bool {
        let reported = nativeRecord(for: runningApp(), now: Date())?.alerts?.wakeState ?? .unknown
        return verifiedWake(reported) == .full
    }

    func alertReadings(now: Date) -> (awake: MacAwakeReading, thermal: MacThermalReading) {
        let record = nativeRecord(for: runningApp(), now: now)
        let wake = verifiedWake(record?.alerts?.wakeState ?? .unknown)
        let lid = IORegistryLidState().isClosed()
        let brew = record.flatMap { reading -> MacBrewReading? in
            guard reading.status.isActive else { return nil }
            return MacBrewReading(startedAt: reading.alerts?.brewingStartedAt, mode: reading.alerts?.brewingMode ?? .unknown,
                                  endsAt: reading.status.endsAt, returnsToAutomatic: reading.alerts?.returnsToAutomatic == true)
        }
        let awake = MacAwakeReading(wake: wake, lidClosed: lid, isBrewing: record?.status.isActive, brew: brew,
                                    lastUserInputAt: record?.alerts?.lastUserInputAt)
        let thermal = MacThermalReading(system: .current, report: record?.thermal, writtenAt: record?.status.writtenAt, now: now)
        return (awake, thermal)
    }

    fileprivate func verifiedWake(_ reported: MacAlertWakeState) -> MacAlertWakeState {
        // A same-process status file can predate a short wake. Check the
        // kernel's current capabilities before treating it as proof.
        guard reported == .full else { return reported }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return .unknown }
        defer { IOObjectRelease(root) }
        let capabilities = IORegistryEntryCreateCFProperty(root, "System Capabilities" as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        return reported.corroborated(by: .init(systemCapabilities: capabilities?.uint64Value))
    }

    func snapshot(triggers: TriggerPreview,reminders: ReminderMachine,ax: AccessibilityControl) -> [String: Any] {
        let source=IOKitPowerSourceMonitor().current
        let session=CGSessionCopyCurrentDictionary() as? [String: Any]
        let lock=StatusEvidence.consoleLock(in:session,userID:getuid()).map { $0 ? "locked":"unlocked" } ?? "unknown"
        let lid=IORegistryLidState().isClosed().map { $0 ? "closed":"open" } ?? "unknown"
        var count:UInt32=0;var display="unknown"
        if CGGetOnlineDisplayList(0,nil,&count) == .success,count>0 {
            var ids=[CGDirectDisplayID](repeating:0,count:Int(count))
            if CGGetOnlineDisplayList(count,&ids,&count) == .success { display=ids.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 } ? "off":"on" }
        } // Public APIs cannot distinguish dimmed reliably. Never fabricate it.
        let now = Date()
        let app = runningApp()
        let record = nativeRecord(for: app, now: now)
        let status = record?.status
        let running = app != nil
        let kind = sessionKind(status, reported: record?.alerts?.brewingMode)
        let thermal = MacThermalReading(system: .current, report: record?.thermal, writtenAt: status?.writtenAt, now: now)
        let sleepPort=running && status != nil ? IOPMFindPowerManagement(mach_task_self_):0
        if sleepPort != 0{IOServiceClose(sleepPort)}
        let brewingAvailable = thermal.state != .critical && thermal.brewingPaused != true
        let directModeControl = record?.triggerMode?.supportsTriggerModeControl == true
        let canSwitchMode = status?.triggersEnabled == true
        let canPause = directModeControl
            ? canSwitchMode && status?.triggersPaused == false : ax.canPerform("Pause Triggers")
        let canResume = directModeControl
            ? canSwitchMode && status?.triggersPaused == true : ax.canPerform("Resume Triggers")
        let capabilities:[String:Any]=["startManual":brewingAvailable && FileManager.default.fileExists(atPath:Self.appURL.path),"stopManual":kind=="manual","pauseTriggers":canPause,"resumeTriggers":canResume,"sleepNow":sleepPort != 0,"refreshTriggers":installedVersion==CompanionObserverSettings.supportedVersion]
        let safetyPause = thermal.brewingPaused == true ? "thermal" : "unknown"
        let k:[String:Any]=["appRunning":running,"version":installedVersion as Any? ?? NSNull(),"isActive":StatusEvidence.brewingActivity(appRunning:running,nativeActive:status?.isActive) as Any? ?? NSNull(),"endsAt":status?.endsAt.map(WireJSON.iso) as Any? ?? NSNull(),"triggersEnabled":status?.triggersEnabled as Any? ?? NSNull(),"triggersPaused":status?.triggersPaused as Any? ?? NSNull(),"sessionKind":kind,"safetyPause":safetyPause]
        var mac:[String:Any]=["lock":lock,"display":display,"lid":lid,"batteryPercent":source.percentage as Any? ?? NSNull(),"powerSource":source.provider.rawValue,"isCharging":source.hasBattery ? source.isCharging as Any:NSNull(),"temperatureC":NSNull(),"temperatureSensor":NSNull(),"thermal":thermal.state.legacyStatus,"thermalSeverity":thermal.state.rawValue]
        if let wake = record?.alerts?.wakeState { mac["wakeState"] = verifiedWake(wake).rawValue }
        if let guardActive = thermal.guardActive { mac["thermalGuardActive"] = guardActive }
        if let modelIdentifier { mac["modelIdentifier"] = modelIdentifier }
        mac.merge(network.snapshot()){_,new in new}
        let reminder:[String:Any]=["enabled":reminders.settings.enabled,"intervalSeconds":reminders.settings.intervalSeconds,"endedAwakeDelaySeconds":reminders.settings.endedAwakeDelaySeconds,"snoozedUntil":reminders.snoozedUntil.map(WireJSON.iso) as Any? ?? NSNull()]
        return ["capturedAt":WireJSON.iso(Date()),"macName":Host.current().localizedName ?? "Mac","mac":mac,"keepresso":k,"capabilities":capabilities,"triggers":(try? WireJSON.object(WireJSON.encoder.encode(triggers))) ?? [:],"reminders":reminder]
    }
    func sessionKind(_ s: StatusSnapshot?, reported: MacBrewReading.Mode?) -> String {
        guard let s, s.isActive else { return "unknown" }
        if let reported { return reported.rawValue }
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
        let issued = Date()
        guard let original = status.runningApp(), let originalLaunch = original.launchDate else {
            if r.action == "sleep_now" { return .sleep(id: r.id, outcome: .couldNotRequestSleep, status: "error") }
            return CommandResponse(id: r.id, status: "error", message: "The current Keepresso process could not be verified.")
        }
        let initial = status.nativeRecord(for: original, now: issued)
        let before = initial?.status
        func stillAuthorized()->Bool{
            let current=status.runningApp()
            return authorized() && Date()<r.expiresAt && StatusEvidence.sameLaunch(pid:original.processIdentifier,launchDate:originalLaunch,currentPID:current?.processIdentifier,currentLaunchDate:current?.launchDate)
        }
        if r.action=="sleep_now"{
            guard status.verifiedWake(initial?.alerts?.wakeState ?? .unknown) == .full else {
                return .sleep(id: r.id, outcome: .couldNotRequestSleep, status: "error")
            }
            let initiallyStopped=before.map{!$0.isActive && (!$0.triggersEnabled || $0.triggersPaused)}==true
            let transition = SystemSleepObservation()
            defer { transition.end() }
            return await SafeSleep.perform(id:r.id,authorized:stillAuthorized,state:{
                let sleepDisabled=await SystemSleepSettings.readDisabled()
                guard let current=self.status.native() else{return nil}
                // An already verified idle/paused state need not rewrite its
                // snapshot in response to an idempotent Stop URL.
                let acknowledged=initiallyStopped || StatusEvidence.acknowledges(writtenAt:current.writtenAt,modifiedAt:(try? FileManager.default.attributesOfItem(atPath:StatusFile.defaultURL().path)[.modificationDate]) as? Date,issuedAt:issued)
                return SleepPreparationState(stopped:acknowledged ? (!current.isActive && (!current.triggersEnabled || current.triggersPaused)):nil,sleepDisabled:sleepDisabled)
            }, stop: {
                guard stillAuthorized(), !Task.isCancelled, self.status.fullWake else { throw CompanionError.unavailable }
                // Stopping a closed-lid brew can itself let macOS begin sleep.
                transition.begin()
                try await self.open(URL(string: "keepresso://stop")!)
            }, observedWillSleep: {
                transition.observed
            }, requestSleep: {
                await self.requestSystemSleep(authorized: stillAuthorized, transition: transition)
            })
        }
        guard stillAuthorized() else{return CommandResponse(id:r.id,status:"error",message:"Phone authorization changed or the command expired.")}
        var modeRequest: NativeTriggerModeRequest?
        defer { if let modeRequest { try? FileManager.default.removeItem(at: modeRequest.file) } }
        do {
            switch r.action {
            case "start_manual":
                let thermal = status.thermalReading(now: Date())
                if thermal.state == .critical || thermal.brewingPaused == true {
                    return CommandResponse(id: r.id, status: "error", message: "Keepresso is paused while your Mac cools down.")
                }
                guard let minutes=r.durationMinutes,FileManager.default.fileExists(atPath:NativeStatus.appURL.path) else { throw CompanionError.unavailable }
                let url=URL(string:"keepresso://start?duration=\(minutes)")!
                try await open(url)
            case "stop_manual":
                guard status.sessionKind(before, reported: initial?.alerts?.brewingMode)=="manual" else { throw CompanionError.unavailable };try await open(URL(string:"keepresso://stop")!)
            case "pause_triggers", "resume_triggers":
                let paused = r.action == "pause_triggers"
                if initial?.triggerMode?.supportsTriggerModeControl == true {
                    guard before?.triggersEnabled == true else { throw CompanionError.unavailable }
                    let ticket = NativeTriggerModeRequest(
                        id: UUID(), pid: original.processIdentifier, paused: paused,
                        validUntil: min(r.expiresAt, Date().addingTimeInterval(5))
                    )
                    try WireJSON.encoder.encode(ticket).write(to: ticket.file, options: .atomic)
                    modeRequest = ticket
                    guard stillAuthorized() else { throw CompanionError.unauthorized }
                    try await open(ticket.doorbell)
                } else {
                    try ax.perform(paused ? "Pause Triggers" : "Resume Triggers")
                }
            default: throw CompanionError.invalid
            }
        } catch { return CommandResponse(id:r.id,status:"error",message:"Control unavailable. Check that Keepresso is running and supports this action.") }
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds:250_000_000)
            let current=status.runningApp()
            guard !Task.isCancelled,authorized(),StatusEvidence.sameLaunch(pid:original.processIdentifier,launchDate:originalLaunch,currentPID:current?.processIdentifier,currentLaunchDate:current?.launchDate) else{return CommandResponse(id:r.id,status:"uncertain",message:"Keepresso or phone authorization changed while the request was in progress. It will not be retried automatically.")}
            guard let reply = status.nativeRecord(for: current, now: Date()),
                  StatusEvidence.acknowledges(writtenAt: reply.status.writtenAt, modifiedAt: (try? FileManager.default.attributesOfItem(atPath: StatusFile.defaultURL().path)[.modificationDate]) as? Date, issuedAt: issued)
            else { continue }
            if let modeRequest, reply.triggerMode?.lastTriggerModeRequestID != modeRequest.id { continue }
            let after = reply.status
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
    private func requestSystemSleep(
        authorized: () -> Bool, transition: SystemSleepObservation
    ) async -> SystemSleepEvidence {
        if transition.observed { return .willSleep }
        guard authorized(), !Task.isCancelled, status.fullWake else {
            return transition.observed ? .willSleep : .unconfirmed
        }
        let port = IOPMFindPowerManagement(mach_task_self_)
        guard port != 0 else { return transition.observed ? .willSleep : .rejected }

        let accepted: Bool = {
            defer { IOServiceClose(port) }
            return authorized() && !Task.isCancelled && !transition.observed
                && IOPMSleepSystem(port) == kIOReturnSuccess
        }()
        if transition.observed { return .willSleep }
        guard accepted else { return .rejected }

        await transition.wait()
        if transition.observed { return .willSleep }
        return authorized() && !Task.isCancelled && status.fullWake ? .stillAwake : .unconfirmed
    }

    private func open(_ url:URL) async throws {
        // Pin the destination app instead of trusting the user's scheme handler.
        let config=NSWorkspace.OpenConfiguration();config.activates=false
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            NSWorkspace.shared.open([url],withApplicationAt:NativeStatus.appURL,configuration:config) { _,error in if let error { continuation.resume(throwing:error) } else { continuation.resume() } }
        }
    }
}

/// Read-only observation scoped to one authorized sleep operation. Begin
/// before stopping Keepresso, and never wait on or delay the OS transition.
@MainActor private final class SystemSleepObservation {
    private let center = NSWorkspace.shared.notificationCenter
    private let sawWillSleep = OSAllocatedUnfairLock(initialState: false)
    private let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var token: NSObjectProtocol?

    var observed: Bool { sawWillSleep.withLock { $0 } }

    func begin() {
        let flag = sawWillSleep
        let continuation = signal.continuation
        token = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
            // Preserve the proof if the same notification invalidates its route.
            flag.withLock { $0 = true }
            continuation.yield(())
        }
    }

    func wait() async {
        let continuation = signal.continuation
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(6)) }
            catch { return }
            continuation.finish()
        }
        defer { timeout.cancel() }
        var events = signal.stream.makeAsyncIterator()
        _ = await events.next()
    }

    func end() {
        if let token { center.removeObserver(token) }
        token = nil
        signal.continuation.finish()
    }
}

enum SystemSleepSettings {
    /// Fixed read-only process off the main actor, bounded if powerd stalls.
    static func readDisabled()async->Bool?{
        guard let data=try? await BoundedWorker.run(executable:URL(fileURLWithPath:"/usr/bin/pmset"),arguments:["-g"],timeout:1.5,outputLimit:16384),let text=String(data:data,encoding:.utf8),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return nil}
        return PMSetSleepControl.parseSleepDisabled(from:text)
    }
}
