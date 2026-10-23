import Foundation
import AppKit
import CompanionCore
import KeepressoCore

@MainActor final class CompanionModel:ObservableObject {
    @Published private(set) var nativeRunning = false
    private var lifecycle = NativeLifecycleGate()
    private let refreshOwner=TriggerRefreshOwner()
    private var relayTask: Task<Void, Never>?
    private var relayTaskID: UUID?
    @Published var invitation:PairInvitation?;@Published var pendingName:String?;@Published var devices:[AuthorizedDevice]=[]
    @Published var message="Unofficial Keepresso companion. Enable Nearby when you are ready to connect.";@Published var bluetoothState="Off";@Published var connectionCount=0
    @Published var reminders=ReminderMachine();@Published var nearbyEnabled=false
    @Published var relayEnabled=false;@Published var relayState="Internet not configured."
    @Published var relayURLInput="";@Published var relayBearerInput=""
    let macId:String;let pairing:PairingManager
    private let credentials=CredentialStore();private let native=NativeStatus();private let observer=TriggerObserver()
    private lazy var ax=AccessibilityControl(status:native);private lazy var commands=NativeCommands(status:native,ax:ax)
    lazy var bluetooth=BluetoothServer(model:self)
    private var relay:RelayCoordinator?;private var relayConfiguration:RelayConfiguration?;private var eventOutbox:RelayOutbox?;private var revocations:DeviceRevocations?;private var locallyRevoked:Set<String>=[]
    private let localEventEpoch=UUID().uuidString.lowercased();private var wakeToken:NSObjectProtocol?
    private let directory:URL;private var executor:MutationExecutor?;private var timer:Timer?;private var sleepToken:NSObjectProtocol?;private var lastSignature:String?;private var persistedReminderData:Data?
    init(){
        let defaults=UserDefaults.standard
        if let saved=defaults.string(forKey:"macUUID"),WireCrypto.validID(saved){macId=saved}else{let id=UUID().uuidString.lowercased();macId=id;defaults.set(id,forKey:"macUUID")}
        pairing=PairingManager(macId:macId)
        // Retain the existing journal, revocations and reminders on an in-place update.
        directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Keespresso")
        do {
            let revoked=try DeviceRevocations(url:directory.appendingPathComponent("revocations.json"));revocations=revoked
            devices=credentials.load().filter{!revoked.contains($0.deviceId)}
        }catch{devices=[];message="Local authorization storage is unavailable. Phone access is disabled."}
        eventOutbox=try? RelayOutbox(url:directory.appendingPathComponent("delivery-outbox.json"))
        relayConfiguration=credentials.loadRelay();relayURLInput=relayConfiguration?.url ?? ""
        if let journal=try? MutationJournal(url:directory.appendingPathComponent("mutations.json")){executor=MutationExecutor(journal:journal)}
        let reminderURL=directory.appendingPathComponent("reminders.json")
        if FileManager.default.fileExists(atPath:reminderURL.path){
            if let data=try? Data(contentsOf:reminderURL),let state=try? WireJSON.decoder.decode(ReminderMachine.self,from:data),(try? state.settings.validate()) != nil{persistedReminderData=data;reminders=state;reminders.resumedAfterUnknownInterval()}
            else{message="Saved reminder state could not be read. Routine reminders are disabled until settings are saved.";reminders.settings.enabled=false}
        }
        nearbyEnabled=defaults.bool(forKey:"nearbyEnabled") && revocations != nil
        relayEnabled=defaults.bool(forKey:"relayEnabled") && relayConfiguration != nil
        message="Waiting for native Keepresso. Your saved connection choices are retained."
    }
    func updateNativeApplication(token: String?) {
        for action in lifecycle.update(applicationToken: token) {
            switch action { case .stop: suspend(); case .start: resume() }
        }
    }
    private func resume() {
        nativeRunning=true; reminders.resumedAfterUnknownInterval(); lastSignature=nil
        let generation=lifecycle.generation
        sleepToken=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in guard let self,self.lifecycle.accepts(generation:generation) else{return};self.observedSleep()}}
        wakeToken=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in guard let self,self.lifecycle.accepts(generation:generation) else{return};self.relay?.wake();self.runRelayTick()}}
        if nearbyEnabled { enableNearby() }
        if relayEnabled,let configuration=relayConfiguration { startRelay(configuration) }
        message="Native Keepresso is running. Saved connections resume automatically."
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in Task{@MainActor in guard let self,self.lifecycle.accepts(generation:generation) else{return};self.tick()}}
    }
    private func suspend() {
        nativeRunning=false;timer?.invalidate();timer=nil
        relay?.stop();relay=nil;relayTask?.cancel();relayTask=nil;relayTaskID=nil
        refreshOwner.cancel();observer.invalidate()
        bluetooth.stop();pairing.deny();pairingChanged()
        for token in [sleepToken,wakeToken].compactMap({$0}) { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        sleepToken=nil;wakeToken=nil
        bluetoothState="Waiting for Keepresso";relayState="Waiting for Keepresso"
        message="Waiting for native Keepresso. Connections are paused; your saved choices are retained."
    }
    func shutdown() { _=lifecycle.update(applicationToken:nil);suspend() }
    func enableNearby(){guard revocations != nil else{message="Local authorization storage is unavailable.";return};UserDefaults.standard.set(true,forKey:"nearbyEnabled");nearbyEnabled=true;guard nativeRunning else{bluetoothState="Waiting for Keepresso";return};bluetooth.start();message="Nearby Bluetooth is enabled. Authorize a phone using the QR code on this Mac."}
    func disableNearby(){UserDefaults.standard.set(false,forKey:"nearbyEnabled");bluetooth.stop();nearbyEnabled=false;bluetoothState="Off";pairing.deny();pairingChanged()}
    func armPairing(){guard nativeRunning else{return};do{invitation=try pairing.arm(name:Host.current().localizedName ?? "Mac",now:Date());message="Scan this five-minute invitation on your phone, then approve its name here."}catch{message="Could not create a secure invitation."}}
    func pairingChanged(){invitation=pairing.invitation;pendingName=pairing.pending?.request.deviceName}
    func approve(){do{try bluetooth.approvePending();message="Phone authorized. It must now complete the encrypted handshake."}catch{pairing.deny();pairingChanged();message="Approval could not be saved securely. Pair again."}}
    func deny(){bluetooth.denyPending()}
    func isAuthorized(_ device:String)->Bool{nativeRunning && lifecycle.isActive && revocations != nil && !locallyRevoked.contains(device) && revocations?.contains(device) != true && devices.contains{$0.deviceId==device}}
    private var authorizedDevices:[AuthorizedDevice]{devices.filter{isAuthorized($0.deviceId)}}
    func addDevice(_ device:AuthorizedDevice)throws{
        guard revocations != nil,!locallyRevoked.contains(device.deviceId),revocations?.contains(device.deviceId) != true,!devices.contains(where:{$0.deviceId==device.deviceId}),devices.count<8 else{throw CompanionError.invalid}
        let updated=devices+[device];try credentials.save(updated);devices=updated;relay?.nearbyChanged();runRelayTick()
    }
    func revoke(_ device:AuthorizedDevice){
        // Local tombstones gate both transports before any fallible cleanup.
        locallyRevoked.insert(device.deviceId);devices.removeAll{$0.deviceId==device.deviceId};bluetooth.revoke(device.deviceId)
        var durable=false
        do{guard let revocations else{throw CompanionError.unavailable};try revocations.revoke(device.deviceId);durable=true}catch{}
        do{try credentials.save(devices);durable=true}catch{}
        if let relay{Task{await relay.revoke(device.deviceId)}}
        if durable{message="Phone authorization revoked. Remote cleanup will be attempted while connected."}
        else{disableNearby();disableRelay();message="Phone access is blocked for this session, but revocation could not be saved. Both connections are disabled; retry after storage is available."}
    }
    func configureRelay(){
        do {
            let configuration=try RelayConfiguration(url:relayURLInput.trimmingCharacters(in:.whitespacesAndNewlines),macBearer:relayBearerInput.trimmingCharacters(in:.whitespacesAndNewlines))
            guard !devices.contains(where:{$0.key.base64EncodedString()==configuration.macBearer || (try? RelayEnvelope.phoneBearer(deviceKey:$0.key,macId:macId,deviceId:$0.deviceId))==configuration.macBearer}) else{throw CompanionError.invalid}
            try credentials.saveRelay(configuration);relayConfiguration=configuration;relayBearerInput="";startRelay(configuration)
        }catch{relayState="Enter an HTTPS relay URL and its independent 32-byte Base64 Mac bearer. Configuration could not be saved."}
    }
    func enableStoredRelay(){if let configuration=relayConfiguration{startRelay(configuration)}}
    func disableRelay(){UserDefaults.standard.set(false,forKey:"relayEnabled");relay?.stop();relay=nil;relayTask?.cancel();relayTask=nil;relayTaskID=nil;relayEnabled=false;relayState="Internet disabled. Nearby authorization is retained."}
    private func startRelay(_ configuration:RelayConfiguration){
        relay?.stop();relay=nil
        relayEnabled=true;UserDefaults.standard.set(true,forKey:"relayEnabled")
        guard nativeRunning else{relayState="Saved; waiting for Keepresso.";return}
        do {
            guard revocations != nil,let eventOutbox else{throw CompanionError.unavailable}
            relay=try RelayCoordinator(macId:macId,api:RelayHTTPClient(configuration:configuration),outbox:eventOutbox,devices:{[weak self] in self?.authorizedDevices ?? []},nearby:{[weak self] in self?.bluetooth.authenticatedDevices ?? []},snapshot:{[weak self] in self?.snapshot() ?? [:]},execute:{[weak self] request,device,body,rejection in guard let self else{return CommandResponse(id:request.id,status:"error")};return await self.handle(request,device:device,body:body,policyRejection:rejection)},enrolled:{[weak self] device in self?.sendRelayConfiguration(device)})
            relayEnabled=true;UserDefaults.standard.set(true,forKey:"relayEnabled");relayState="Internet configured; waiting for relay contact.";runRelayTick()
        }catch{relayEnabled=false;relayState="Internet cannot start because local authorization or delivery storage is unavailable."}
    }
    private func runRelayTick(){
        guard nativeRunning,relayTask==nil,let current=relay else{return}
        let id=UUID();relayTaskID=id;let generation=lifecycle.generation
        relayTask=Task{[weak self] in
            defer{if self?.relayTaskID==id{self?.relayTask=nil;self?.relayTaskID=nil}}
            guard !Task.isCancelled else{return};await current.tick()
            guard let self,self.lifecycle.accepts(generation:generation),self.relay === current else{return};self.relayState=current.status
        }
    }
    func nearbyChanged(){relay?.nearbyChanged();runRelayTick()}
    func deviceBecameNearby(_ device:String){
        guard isAuthorized(device) else{return};nearbyChanged();sendRelayConfiguration(device)
        if let eventOutbox{for event in eventOutbox.events(deviceId:device,epoch:relay?.epoch ?? localEventEpoch,now:Date()){bluetooth.sendEvent(event,device:device)}}
    }
    private func sendRelayConfiguration(_ device:String){
        guard isAuthorized(device),relay?.isEnrolled(device)==true,let configuration=relayConfiguration,let credential=devices.first(where:{$0.deviceId==device}),let ticket=try? RelayEnvelope.accessTicket(macBearer:configuration.macBearer,deviceKey:credential.key,macId:macId,deviceId:device) else{return}
        bluetooth.sendRelayConfiguration(device:device,url:configuration.url,authTicket:ticket)
    }
    func snapshot()->[String:Any]{native.snapshot(triggers:observer.preview,reminders:reminders,ax:ax)}
    func handle(_ request:CommandRequest,device:String,body:Data,policyRejection:String?=nil)async -> CommandResponse{
        let generation=lifecycle.generation
        guard isAuthorized(device) else{return CommandResponse(id:request.id,status:"error",message:"Device authorization was revoked.")}
        do{try request.validate(now:Date())}catch{return CommandResponse(id:request.id,status:"error",message:"The request is invalid or expired.")}
        if let executor {
            return await executor.execute(request,device:device,body:body,now:Date(),authorized:{self.lifecycle.accepts(generation:generation) && self.isAuthorized(device)},rejection:policyRejection){await self.perform(request)}
        }
        guard !request.isMutation,request.action != "operation_status" else{return CommandResponse(id:request.id,status:"error",message:"The durable command journal is unavailable; controls and operation lookup are disabled.")}
        return await perform(request)
    }
    private func perform(_ request:CommandRequest)async ->CommandResponse{
        guard nativeRunning else{return CommandResponse(id:request.id,status:"error",message:"Native Keepresso is not running.")}
        let result:CommandResponse
        switch request.action{
        case "status":result=CommandResponse(id:request.id,status:"ok")
        case "refresh_triggers":
            guard !refreshOwner.isRunning else{return CommandResponse(id:request.id,status:"error",message:"A trigger check is already in progress.")}
            let generation=lifecycle.generation
            let checked=await refreshOwner.run{await self.observer.refresh(version:self.native.installedVersion)}
            guard lifecycle.accepts(generation:generation),checked != nil else{return CommandResponse(id:request.id,status:"error",message:"Keepresso changed while checking triggers.")}
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
        guard nativeRunning else{return}
        bluetooth.tick();pairingChanged();runRelayTick();ticks+=1;guard ticks % 10==0 else{return}
        let status=native.native()
        let settings=UserDefaults(suiteName:"sh.gyorgy.keepresso")?.data(forKey:UserDefaultsSettingsStore.defaultKey)?.base64EncodedString() ?? "unknown"
        let signature="\(status?.isActive.description ?? "unknown")/\(status?.triggersPaused.description ?? "unknown")/\(status?.triggersEnabled.description ?? "unknown")/\(status?.endsAt?.timeIntervalSince1970.description ?? "unknown")/\(settings)"
        if let previous=lastSignature,previous != signature{observer.markStale()};lastSignature=signature
        var events=reminders.observe(active:StatusEvidence.brewingActivity(appRunning:native.runningApp() != nil,nativeActive:status?.isActive),now:Date(),scheduledEnd:status?.endsAt)
        let hot:Bool?
        switch ProcessInfo.processInfo.thermalState{case .nominal,.fair:hot=false;case .serious,.critical:hot=true;@unknown default:hot=nil}
        if let hot,let warning=reminders.observeSafety(kind:"thermal",active:hot,now:Date()){events.append(warning)}
        do{
            guard let eventOutbox else{throw CompanionError.unavailable}
            for event in events{try eventOutbox.enqueue(event,devices:authorizedDevices,macId:macId,epoch:relay?.epoch ?? localEventEpoch,now:Date())}
            try persistReminders();events.forEach{bluetooth.broadcast($0)}
        }catch{message="Reminder state cannot be saved. Delivery is suspended until storage is available."}
    }
    private func observedSleep(){relay?.wake();reminders.observedSleep();try? persistReminders();observer.markStale()}
    private func persistReminders()throws{
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data=try WireJSON.encoder.encode(reminders);guard data != persistedReminderData else{return}
        try data.write(to:directory.appendingPathComponent("reminders.json"),options:.atomic);persistedReminderData=data
    }
}
