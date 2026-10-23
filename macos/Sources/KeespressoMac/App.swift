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
            DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+5){kill(-workerGroup,SIGKILL)}
            Task{@MainActor in
                let result=await TriggerWorker().refresh(version:Bundle(url:URL(fileURLWithPath:"/Applications/Keepresso.app"))?.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String,scratch:scratch)
                guard let data=try? WireJSON.encoder.encode(result),data.count<=65536 else{exit(2)}
                do{try FileHandle.standardOutput.write(contentsOf:data);exit(0)}catch{exit(2)}
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--self-check"){
            // Branch before NSApplication, Keychain, BLE, timers, native status,
            // observer or any control adapter is created.
            do{let key=Data(repeating:0,count:32);let sender=SealedChannel(sendKey:key,receiveKey:key);let receiver=SealedChannel(sendKey:key,receiveKey:key);let data=Data("self-check".utf8);guard try receiver.open(sender.seal(data))==data else{throw CompanionError.invalid};let _=TriggerRule.agentActivity(AgentRule(grace:0)).label;_ = try FrameDecoder().feed(FrameDecoder.frame(data),now:0);print("Keespresso Mac self-check passed (crypto/framing only; no Bluetooth, permissions or power operations).");exit(0)}catch{fputs("Self-check failed.\n",stderr);exit(1)}
        }
        let app=NSApplication.shared;let delegate=AppDelegate();app.delegate=delegate;app.setActivationPolicy(.accessory);app.run();withExtendedLifetime(delegate){}
    }
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate{
    private var statusItem:NSStatusItem!;private var panel:NSPopover!;private var model:CompanionModel!
    func applicationDidFinishLaunching(_ notification:Notification){
        model=CompanionModel();statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        if let image=NSImage(contentsOf:Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/keepresso-menu-idle.png")){image.size=NSSize(width:20,height:20);image.isTemplate=true;statusItem.button?.image=image}else{statusItem.button?.title="K"}
        statusItem.button?.target=self;statusItem.button?.action=#selector(toggle)
        panel=NSPopover();panel.behavior = .transient;panel.contentSize=NSSize(width:410,height:640);panel.contentViewController=NSHostingController(rootView:CompanionView(model:model))
    }
    @objc private func toggle(){if panel.isShown{panel.performClose(nil)}else if let button=statusItem.button{panel.show(relativeTo:button.bounds,of:button,preferredEdge:.minY);NSApp.activate(ignoringOtherApps:true)}}
}
struct CompanionView:View{
    @ObservedObject var model:CompanionModel
    private var copper:Color{Color(red:0.65,green:0.29,blue:0.14)}
    var body:some View{
        ScrollView{VStack(alignment:.leading,spacing:16){
            HStack{if let image=NSImage(contentsOf:Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/keepresso-installed-icon.png")){Image(nsImage:image).resizable().frame(width:42,height:42)};VStack(alignment:.leading){Text("Keespresso Mac").font(.title2.bold());Text("Unofficial Keepresso companion").font(.caption).foregroundStyle(.secondary)}}
            Text(model.message).font(.callout)
            HStack{Text("Nearby: \(model.bluetoothState)");Spacer();Text("\(model.connectionCount) connected").foregroundStyle(.secondary)}.font(.caption)
            if model.nearbyEnabled{Button("Disable Nearby"){model.disableNearby()}}else{Button("Enable Nearby Bluetooth"){model.enableNearby()}.buttonStyle(.borderedProminent)}
            Divider()
            Text("Authorize a phone").font(.headline)
            Button("Show pairing QR code"){model.armPairing()}.disabled(!model.nearbyEnabled)
            if let invite=model.invitation{
                if let image=qr(invite.url.absoluteString){Image(nsImage:image).interpolation(.none).resizable().frame(width:230,height:230).padding(8).background(.white).frame(maxWidth:.infinity)}
                Text("Expires at \(invite.expires.formatted(date:.omitted,time:.shortened)). Approve only the phone you are pairing.").font(.caption).foregroundStyle(.secondary)
            }
            if let name=model.pendingName{Text("Allow \(name) to read status and control Keepresso?").font(.headline);HStack{Button("Approve"){model.approve()}.buttonStyle(.borderedProminent);Button("Deny"){model.deny()}}}
            Divider();Text("Authorized phones").font(.headline)
            if model.devices.isEmpty{Text("No authorized phones").foregroundStyle(.secondary)}
            ForEach(model.devices){device in HStack{Text(device.name);Spacer();Button("Revoke"){model.revoke(device)}}}
            Divider()
            Text("Keepresso must be installed in Applications. Start/Stop require an observed native acknowledgement. Pause/Resume additionally need Accessibility access and a uniquely exposed native control; otherwise they are unavailable. Safe remote sleep is unavailable. Temperature readings are unsupported; thermal pressure remains available.").font(.caption).foregroundStyle(.secondary)
            Text("Reminders: \(model.reminders.settings.enabled ? "enabled":"routine off"), every \(model.reminders.settings.intervalSeconds/3600) hour(s). Phone Settings can change the interval and still-awake delay.").font(.caption)
            Button("Quit Keespresso Mac"){NSApp.terminate(nil)}
        }.padding(20)}.frame(width:410,height:640).tint(copper)
    }
    private func qr(_ text:String)->NSImage?{let filter=CIFilter.qrCodeGenerator();filter.message=Data(text.utf8);filter.correctionLevel="M";guard let output=filter.outputImage,let cg=CIContext().createCGImage(output,from:output.extent)else{return nil};return NSImage(cgImage:cg,size:NSSize(width:230,height:230))}
}
