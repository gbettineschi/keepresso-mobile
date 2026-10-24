import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins
import CompanionCore
import KeepressoCore
import Darwin

@main struct Entry {
    @MainActor static func main(){
        if CommandLine.arguments.contains("--observe-triggers"){
            // Isolated worker: no app model, Keychain, Bluetooth or power adapter.
            guard setpgid(0,0)==0 || getpgrp()==getpid(),let flag=CommandLine.arguments.firstIndex(of:"--observer-scratch"),CommandLine.arguments.indices.contains(flag+1),let scratch=try? ObserverScratch.validate(CommandLine.arguments[flag+1]) else{exit(2)}
            let workerGroup=getpgrp()
            DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+8){kill(-workerGroup,SIGKILL)}
            Task{@MainActor in
                let result=await TriggerWorker().refresh(version:Bundle(url:URL(fileURLWithPath:"/Applications/Keepresso.app"))?.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String,scratch:scratch)
                guard let data=try? WireJSON.encoder.encode(result),data.count<=65536 else{exit(2)}
                do{try FileHandle.standardOutput.write(contentsOf:data);exit(0)}catch{exit(2)}
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--read-telemetry"){
            // Read-only diagnostic, before app model, credentials or transports.
            let reading=CompanionTemperatureMonitor().reading()
            let data=try? WireJSON.data(["temperatureC":reading?.celsius as Any? ?? NSNull(),"temperatureSensor":reading?.sensor as Any? ?? NSNull()])
            if let data{try? FileHandle.standardOutput.write(contentsOf:data)}
            exit(reading==nil ? 1:0)
        }
        if CommandLine.arguments.contains("--self-check"){
            // Branch before NSApplication, Keychain, BLE, timers, native status,
            // observer or any control adapter is created.
            do{let key=Data(repeating:0,count:32);let sender=SealedChannel(sendKey:key,receiveKey:key);let receiver=SealedChannel(sendKey:key,receiveKey:key);let data=Data("self-check".utf8);guard try receiver.open(sender.seal(data))==data else{throw CompanionError.invalid};let _=TriggerRule.agentActivity(AgentRule(grace:0)).label;_ = try FrameDecoder().feed(FrameDecoder.frame(data),now:0);print("Keepresso Mobile self-check passed (crypto/framing only; no Bluetooth, permissions or power operations).");exit(0)}catch{fputs("Self-check failed.\n",stderr);exit(1)}
        }
        let background=CommandLine.arguments.contains("--background")
        if background && !BackgroundLoginSession.mayStartHidden { exit(0) }
        if !background { UserDefaults.standard.removeObject(forKey:BackgroundLoginSession.quitKey) }
        let directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Keespresso")
        let lease:CompanionInstanceLease
        do {
            guard let acquired=try CompanionInstanceLease.acquire(directory:directory) else {
                if background {
                    DistributedNotificationCenter.default().postNotificationName(BackgroundLoginSession.takeover,object:String(getuid()),userInfo:nil,deliverImmediately:true)
                    exit(75) // launchd retries after the old GUI hands over its lock.
                }
                NSRunningApplication.runningApplications(withBundleIdentifier:"local.keespresso.companion").first(where:{$0.processIdentifier != getpid()})?.activate()
                exit(0)
            }
            lease=acquired
        }catch{fputs("Keepresso Mobile runtime is already in use or unavailable.\n",stderr);exit(1)}
        let app=NSApplication.shared;let delegate=AppDelegate(background:background)
        app.delegate=delegate;app.setActivationPolicy(.accessory)
        withExtendedLifetime((delegate,lease)){app.run()}
    }
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    private let model=CompanionModel()
    private let background:Bool
    private let follow:BackgroundControl
    private var window:NSWindow?
    private var runningObservation:NSKeyValueObservation?
    private var handingOff=false
    private var terminating=false
    init(background:Bool){self.background=background;follow=BackgroundControl(managed:background);super.init()}
    func applicationDidFinishLaunching(_ notification:Notification){
        follow.onManagedHandoff={ [weak self] in
            guard let self,!self.terminating else{return}
            self.handingOff=true
            UserDefaults.standard.set(self.window?.isVisible==true,forKey:BackgroundLoginSession.reopenKey)
            UserDefaults.standard.synchronize()
            NSApp.terminate(nil)
        }
        // Workspace launch/termination notifications omit LSUIElement apps.
        // KVO of this list includes native Keepresso without process polling.
        runningObservation=NSWorkspace.shared.observe(\.runningApplications,options:[.initial,.new]){[weak self] _,_ in
            Task{@MainActor in self?.reconcileNativeApp()}
        }
        installMenus()
        let reopen=UserDefaults.standard.bool(forKey:BackgroundLoginSession.reopenKey)
        UserDefaults.standard.removeObject(forKey:BackgroundLoginSession.reopenKey)
        if !background || reopen{showSettings()}
        model.loadSavedAuthorization()
        follow.refresh()
    }
    private func reconcileNativeApp(){
        guard !terminating else{return}
        let app=NativeStatus().runningApp()
        let token=app.map{"\($0.processIdentifier)/\($0.launchDate?.timeIntervalSince1970.description ?? "unknown")"}
        model.updateNativeApplication(token:token)
    }
    private func showSettings(){
        if window==nil {
            let value=NSWindow(contentRect:NSRect(x:0,y:0,width:430,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            value.title="Keepresso Mobile";value.isReleasedWhenClosed=false;value.delegate=self
            value.minSize=NSSize(width:430,height:500)
            value.contentViewController=NSHostingController(rootView:CompanionView(model:model,follow:follow,authorization:model.authorization))
            value.center();window=value
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{showSettings();return true}
    func applicationDidBecomeActive(_ notification:Notification){follow.refresh()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func windowShouldClose(_ sender:NSWindow)->Bool{sender.orderOut(nil);NSApp.setActivationPolicy(.accessory);return false}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{
        terminating=true
        if !handingOff{BackgroundLoginSession.markExplicitQuit();UserDefaults.standard.synchronize()}
        return .terminateNow
    }
    func applicationWillTerminate(_ notification:Notification){runningObservation?.invalidate();runningObservation=nil;follow.stop();model.shutdown()}
    @objc private func quit(){NSApp.terminate(nil)}
    private func installMenus(){
        let bar=NSMenu();let appItem=NSMenuItem();bar.addItem(appItem)
        let appMenu=NSMenu();appItem.submenu=appMenu
        let quitItem=NSMenuItem(title:"Quit Keepresso Mobile",action:#selector(quit),keyEquivalent:"q");quitItem.target=self;appMenu.addItem(quitItem)
        let fileItem=NSMenuItem();fileItem.title="File";bar.addItem(fileItem)
        let fileMenu=NSMenu(title:"File");fileItem.submenu=fileMenu
        fileMenu.addItem(NSMenuItem(title:"Close Window",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w"))
        let editItem=NSMenuItem();editItem.title="Edit";bar.addItem(editItem)
        let editMenu=NSMenu(title:"Edit");editItem.submenu=editMenu
        for (title,selector,key) in [("Cut",#selector(NSText.cut(_:)),"x"),("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] {editMenu.addItem(NSMenuItem(title:title,action:selector,keyEquivalent:key))}
        NSApp.mainMenu=bar
    }
}
struct CompanionView:View{
    @ObservedObject var model:CompanionModel
    @ObservedObject var follow:BackgroundControl
    @ObservedObject var authorization:SavedAuthorizationLoader
    private var copper:Color{Color(red:0.65,green:0.29,blue:0.14)}
    private var pairingControls:PairingControls{PairingControls(savedKeysReady:model.authorizationReady,loading:authorization.state == .loading,pairedPhoneCount:model.devices.count,nativeRunning:model.nativeRunning)}
    var body:some View{
        ScrollView{VStack(alignment:.leading,spacing:16){
            HStack{if let image=NSImage(contentsOf:Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/keepresso-mobile-mac-icon.png")){Image(nsImage:image).resizable().frame(width:42,height:42)};VStack(alignment:.leading){Text("Keepresso Mobile").font(.title2.bold());Text("Unofficial Keepresso companion").font(.caption).foregroundStyle(.secondary)}}
            GroupBox("Automatic startup"){
                VStack(alignment:.leading,spacing:8){
                    HStack(alignment:.top,spacing:8){if follow.warning{Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange)};Text(follow.status).font(.callout)}
                    Button("Open Login Items…"){follow.openLoginItems()}
                    Text("Close this window to keep running quietly. Open Keepresso Mobile again to show settings. You control background permission in macOS Login Items.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            Text(model.message).font(.callout)
            GroupBox("Pairing"){
                VStack(alignment:.leading,spacing:10){
                    if !model.authorizationReady {
                        Text(authorization.state == .loading ? "Reading saved pairing…":"Unlock your saved pairing in macOS Keychain to reconnect.").font(.callout).foregroundStyle(.secondary)
                    }else if model.devices.isEmpty{Text("No paired phone").foregroundStyle(.secondary)}
                    else{ForEach(model.devices){device in Label(device.name,systemImage:"checkmark.shield").font(.callout)}}
                    HStack(spacing:12){
                        Button(pairingControls.primary == .unlock ? "Unlock saved pairing…":"Show pairing QR code"){
                            if pairingControls.primary == .unlock{model.loadSavedAuthorization(allowInteraction:true)}else{model.armPairing()}
                        }.disabled(!pairingControls.primaryEnabled)
                        Button("Delete pairing",role:.destructive){model.deletingPairing=true}.disabled(!pairingControls.deleteEnabled)
                    }
                    if let invite=model.invitation{
                        if let image=qr(invite.url.absoluteString){Image(nsImage:image).interpolation(.none).resizable().frame(width:230,height:230).padding(8).background(.white).frame(maxWidth:.infinity)}
                        Text("Expires at \(invite.expires.formatted(date:.omitted,time:.shortened)). Approve only the phone you are pairing.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let name=model.pendingName{Text("Allow \(name) to read status and control Keepresso?").font(.headline);HStack{Button("Approve"){model.approve()}.buttonStyle(.borderedProminent);Button("Deny"){model.deny()}}}
                    Divider()
                    Toggle("Nearby Bluetooth",isOn:Binding(get:{model.nearbyEnabled},set:{if $0{model.enableNearby()}else{model.disableNearby()}})).disabled(!model.authorizationReady)
                    HStack{Text(model.bluetoothState);Spacer();Text("\(model.connectionCount) connected")}.font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.alert("Delete pairing?",isPresented:$model.deletingPairing){
                Button("Cancel",role:.cancel){}
                Button("Delete pairing",role:.destructive){model.deletePairing()}
            }message:{Text(model.devices.count>1 ? "All \(model.devices.count) paired phones will lose access. Remove their old authorization in Android Settings before scanning a new QR code.":"Your phone will lose nearby and internet access. Remove its old authorization in the phone app's Settings before scanning a new QR code.")}
            Divider()
            Text("Internet fallback").font(.headline)
            Text(model.relayState).font(.caption).foregroundStyle(.secondary)
            TextField("HTTPS relay URL",text:$model.relayURLInput).textFieldStyle(.roundedBorder)
            SecureField("Independent Mac bearer (Base64)",text:$model.relayBearerInput).textFieldStyle(.roundedBorder)
            HStack{
                Button("Save and enable"){model.configureRelay()}.disabled(!model.authorizationReady || model.relayBearerInput.isEmpty)
                if model.relayEnabled{Button("Disable Internet"){model.disableRelay()}}else{Button("Enable saved relay"){model.enableStoredRelay()}.disabled(!model.authorizationReady || model.relayURLInput.isEmpty)}
            }
            Text("Your relay must already be deployed and configured. The Mac bearer is saved in Keychain. Authorized phones receive internet access through their existing nearby pairing.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Native Keepresso manages sessions and safeguards. Sleep ends the session and pauses triggers first. Manually latched closed-lid mode must be turned off on the Mac; Only while brewing releases it automatically. Temperature uses the hottest readable CPU sensor.").font(.caption).foregroundStyle(.secondary)
            Text("Reminders: \(model.reminders.settings.enabled ? "enabled":"routine off"), every \(model.reminders.settings.intervalSeconds/3600) hour(s). Phone Settings can change the interval and still-awake delay.").font(.caption)
            Text("Closing the lid while sleep is disabled plays one sound and requests trackpad feedback, plus an urgent phone warning. Trackpad feedback and phone sound depend on device settings; test phone alerts in Android Settings.").font(.caption).foregroundStyle(.secondary)
            Button("Quit Keepresso Mobile"){NSApp.terminate(nil)}
        }.padding(20)}.frame(minWidth:410,minHeight:480).tint(copper)
    }
    private func qr(_ text:String)->NSImage?{let filter=CIFilter.qrCodeGenerator();filter.message=Data(text.utf8);filter.correctionLevel="M";guard let output=filter.outputImage,let cg=CIContext().createCGImage(output,from:output.extent)else{return nil};return NSImage(cgImage:cg,size:NSSize(width:230,height:230))}
}
