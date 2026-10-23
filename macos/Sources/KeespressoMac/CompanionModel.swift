import Foundation
import AppKit
import CompanionCore
import KeepressoCore

@MainActor final class CompanionModel:ObservableObject {
    @Published var invitation:PairInvitation?;@Published var pendingName:String?;@Published var devices:[AuthorizedDevice]=[]
    @Published var message="Unofficial Keepresso companion. Enable Nearby when you are ready to connect.";@Published var bluetoothState="Off";@Published var connectionCount=0
    @Published var reminders=ReminderMachine();@Published var nearbyEnabled=false
    let macId:String;let pairing:PairingManager
    private let credentials=CredentialStore();private let native=NativeStatus();private let observer=TriggerObserver()
    private lazy var ax=AccessibilityControl(status:native);private lazy var commands=NativeCommands(status:native,ax:ax)
    lazy var bluetooth=BluetoothServer(model:self)
    private let directory:URL;private var executor:MutationExecutor?;private var timer:Timer?;private var sleepToken:NSObjectProtocol?;private var lastSignature:String?;private var persistedReminderData:Data?
    init(){
        let defaults=UserDefaults.standard
        if let saved=defaults.string(forKey:"macUUID"),WireCrypto.validID(saved){macId=saved}else{let id=UUID().uuidString.lowercased();macId=id;defaults.set(id,forKey:"macUUID")}
        pairing=PairingManager(macId:macId)
        directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Keespresso")
        devices=credentials.load()
        if let journal=try? MutationJournal(url:directory.appendingPathComponent("mutations.json")){executor=MutationExecutor(journal:journal)}
        let reminderURL=directory.appendingPathComponent("reminders.json")
        if FileManager.default.fileExists(atPath:reminderURL.path){
            if let data=try? Data(contentsOf:reminderURL),let state=try? WireJSON.decoder.decode(ReminderMachine.self,from:data),(try? state.settings.validate()) != nil{persistedReminderData=data;reminders=state;reminders.resumedAfterUnknownInterval()}
            else{message="Saved reminder state could not be read. Routine reminders are disabled until settings are saved.";reminders.settings.enabled=false}
        }
        sleepToken=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.observedSleep()}}
        if defaults.bool(forKey:"nearbyEnabled"){enableNearby()}
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in Task{@MainActor in self?.tick()}}
    }
    func enableNearby(){UserDefaults.standard.set(true,forKey:"nearbyEnabled");nearbyEnabled=true;bluetooth.start();message="Nearby Bluetooth is enabled. Authorize a phone using the QR code on this Mac."}
    func disableNearby(){UserDefaults.standard.set(false,forKey:"nearbyEnabled");bluetooth.stop();nearbyEnabled=false;bluetoothState="Off";pairing.deny();pairingChanged()}
    func armPairing(){do{invitation=try pairing.arm(name:Host.current().localizedName ?? "Mac",now:Date());message="Scan this five-minute invitation on your phone, then approve its name here."}catch{message="Could not create a secure invitation."}}
    func pairingChanged(){invitation=pairing.invitation;pendingName=pairing.pending?.request.deviceName}
    func approve(){do{try bluetooth.approvePending();message="Phone authorized. It must now complete the encrypted handshake."}catch{pairing.deny();pairingChanged();message="Approval could not be saved securely. Pair again."}}
    func deny(){bluetooth.denyPending()}
    func addDevice(_ device:AuthorizedDevice)throws{guard !devices.contains(where:{$0.deviceId==device.deviceId})else{throw CompanionError.invalid};let updated=devices+[device];try credentials.save(updated);devices=updated}
    func revoke(_ device:AuthorizedDevice){
        // Drop active sessions even if Keychain update fails; do not claim revocation persisted.
        bluetooth.revoke(device.deviceId)
        do{let updated=devices.filter{$0.deviceId != device.deviceId};try credentials.save(updated);devices=updated;message="Phone authorization revoked."}catch{message="Revocation could not be saved to Keychain. Nearby has been disabled; retry revocation.";disableNearby()}
    }
    func snapshot()->[String:Any]{native.snapshot(triggers:observer.preview,reminders:reminders,ax:ax)}
    func handle(_ request:CommandRequest,device:String,body:Data)async -> CommandResponse{
        guard devices.contains(where:{$0.deviceId==device}) else{return CommandResponse(id:request.id,status:"error",message:"Device authorization was revoked.")}
        do{try request.validate(now:Date())}catch{return CommandResponse(id:request.id,status:"error",message:"The request is invalid or expired.")}
        if request.isMutation {
            guard let executor else {return CommandResponse(id:request.id,status:"error",message:"The durable command journal is unavailable; controls are disabled.")}
            return await executor.execute(request,device:device,body:body,now:Date(),authorized:{self.devices.contains(where:{$0.deviceId==device})}){await self.perform(request)}
        }
        return await perform(request)
    }
    private func perform(_ request:CommandRequest)async ->CommandResponse{
        let result:CommandResponse
        switch request.action{
        case "status":result=CommandResponse(id:request.id,status:"ok")
        case "refresh_triggers":
            _=await observer.refresh(version:native.installedVersion)
            result=CommandResponse(id:request.id,status:observer.preview.state=="ready" ? "ok":"uncertain",message:observer.preview.message)
        case "snooze_reminders","resume_reminders","ack_reminder","set_reminder_settings":
            let previous=reminders
            do{
                switch request.action{
                case "snooze_reminders":reminders.snooze(now:Date())
                case "resume_reminders":reminders.resume()
                case "ack_reminder":reminders.acknowledge()
                default:try reminders.update(settings:request.reminderSettings!,now:Date())
                }
                try persistReminders();result=CommandResponse(id:request.id,status:"ok")
            }catch{reminders=previous;result=CommandResponse(id:request.id,status:"error",message:"Reminder settings could not be saved.")}
        default:
            result=await commands.execute(request);observer.markStale()
        }
        return result
    }
    private var ticks=0
    private func tick(){
        bluetooth.tick();pairingChanged();ticks+=1;guard ticks % 10==0 else{return}
        let status=native.native()
        let settings=UserDefaults(suiteName:"sh.gyorgy.keepresso")?.data(forKey:UserDefaultsSettingsStore.defaultKey)?.base64EncodedString() ?? "unknown"
        let signature="\(status?.isActive.description ?? "unknown")/\(status?.triggersPaused.description ?? "unknown")/\(status?.triggersEnabled.description ?? "unknown")/\(status?.endsAt?.timeIntervalSince1970.description ?? "unknown")/\(settings)"
        if let previous=lastSignature,previous != signature{observer.markStale()};lastSignature=signature
        var events=reminders.observe(active:StatusEvidence.brewingActivity(appRunning:native.runningApp() != nil,nativeActive:status?.isActive),now:Date(),scheduledEnd:status?.endsAt)
        let hot:Bool?
        switch ProcessInfo.processInfo.thermalState{case .nominal,.fair:hot=false;case .serious,.critical:hot=true;@unknown default:hot=nil}
        if let hot,let warning=reminders.observeSafety(kind:"thermal",active:hot,now:Date()){events.append(warning)}
        do{try persistReminders();events.forEach{bluetooth.broadcast($0)}}catch{message="Reminder state cannot be saved. Delivery is suspended until storage is available."}
    }
    private func observedSleep(){reminders.observedSleep();try? persistReminders();observer.markStale()}
    private func persistReminders()throws{
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data=try WireJSON.encoder.encode(reminders);guard data != persistedReminderData else{return}
        try data.write(to:directory.appendingPathComponent("reminders.json"),options:.atomic);persistedReminderData=data
    }
}
