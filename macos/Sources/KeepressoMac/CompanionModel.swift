import Foundation
import AppKit
import CompanionCore
import IrohTransport
import KeepressoCore
import CoreBluetooth
import OSLog

private let connectionLog=Logger(subsystem:"local.keespresso.companion",category:"transport")

@MainActor final class CompanionModel:ObservableObject {
    let authorization=SavedAuthorizationLoader()
    let triggerFolderSetup=TriggerFolderSetup()
    lazy var setup:CompanionSetup = CompanionSetup(
        eligible:{[weak self] in self?.setupEligible == true},
        rules:{[weak self] in self?.setupRules() ?? []},
        buildIdentity:{CompanionAuthorizationIdentity.current},
        requestFolders:{[weak self] in
            guard let self else{return false}
            await self.triggerFolderSetup.allowAccess()
            return self.triggerFolderSetup.allConfiguredApproved
        },
        requestSteam:{await CompanionSteamObservation.prepareConsent(buildIdentity:CompanionAuthorizationIdentity.current,folderProbe:TriggerFolderSetup.probe)},
        steamReady:{CompanionSteamObservation.isPrepared($0,buildIdentity:CompanionAuthorizationIdentity.current)},
        directTriggerControl:{[weak self] in self?.native.supportsDirectTriggerMode == true})
    private func setupRules()->[TriggerRule]{
        guard native.installedVersion == CompanionObserverSettings.supportedVersion,let defaults=UserDefaults(suiteName:"sh.gyorgy.keepresso"),let data=defaults.data(forKey:UserDefaultsSettingsStore.defaultKey),let settings=try? CompanionObserverSettings.decode(data) else{return []}
        return settings.ruleSet.rules
    }
    @Published var settingsVisible=false
    // Root supplies the live ownership state, avoiding a stale view callback
    // while the foreground process is preparing a managed handoff.
    var setupForegroundSettled:()->Bool = {false}
    var setupEligible:Bool { settingsVisible && setupForegroundSettled() }
    func offerSetupWhenEligible(returningFromSettings:Bool=false){
        if setupEligible{
            setup.presentIfNeeded(returningFromSettings:returningFromSettings)
            if !setup.running{
                nearbyRecovery.permissionRefreshed(enabled:nearbyEnabled,nativeRunning:nativeRunning,
                    authorizationReady:authorizationReady,permissionGranted:CBManager.authorization == .allowedAlways,
                    alreadyStarted:bluetooth.started)
            }
        }else{setup.cancelForLifecycleChange()}
    }
    @Published private(set) var authorizationReady=false
    @Published var deletingPairing=false
    @Published private(set) var nativeRunning = false
    private var lifecycle = NativeLifecycleGate()
    private let refreshOwner=TriggerRefreshOwner()
    private let internet=IrohServer()
    private var internetStart:Task<Void,Never>?
    private var internetGeneration=UUID()
    private var internetSeed:Data?
    private var firebaseClient:FirebaseClientConfiguration?
    private var notificationSender:FirebaseSender?
    private var notificationOutbox:NotificationOutbox?
    private var pushTokens:PushTokenStorage?
    private var internetMigration:InternetMigration?
    private var notificationTask:Task<Void,Never>?
    private var notificationGeneration=UUID()
    @Published var notificationState="Notifications are not configured."
    var internetConnectionEnabled:Bool {internetEnabled}
    private var internetEnabled:Bool {UserDefaults.standard.object(forKey:"internetEnabled") as? Bool ?? relayEnabled}
    private var relayTask: Task<Void, Never>?
    private var relayTaskID: UUID?
    private let lidWarningSound = LidWarningSound()
    @Published var invitation:PairInvitation?;@Published var pendingName:String?;@Published var devices:[AuthorizedDevice]=[]
    @Published var message="Unofficial Keepresso companion. Enable Nearby when you are ready to connect.";@Published var bluetoothState="Off";@Published var connectionCount=0
    @Published var reminders=ReminderMachine();@Published var nearbyEnabled=false
    @Published var relayEnabled=false;@Published var relayState="Internet not configured."
    @Published var relayURLInput="";@Published var relayBearerInput=""
    let macId:String;let pairing:PairingManager
    private let credentials=CredentialStore();private let native=NativeStatus();private let observer=TriggerObserver()
    private lazy var ax=AccessibilityControl(status:native);private lazy var commands=NativeCommands(status:native,ax:ax)
    lazy var bluetooth=BluetoothServer(model:self)
    private lazy var nearbyRecovery=NearbyWakeRecovery(stop:{[weak self] in self?.bluetooth.stop()},start:{[weak self] in self?.bluetooth.start()})
    private var relay:RelayCoordinator?;private var relayConfiguration:RelayConfiguration?;private var eventOutbox:RelayOutbox?;private var revocations:DeviceRevocations?;private var locallyRevoked:Set<String>=[]
    private let localEventEpoch=UUID().uuidString.lowercased();private var wakeToken:NSObjectProtocol?
    private let directory:URL;private var executor:MutationExecutor?;private var timer:Timer?;private var sleepToken:NSObjectProtocol?;private var persistedReminderData:Data?
    init(){
        let defaults=UserDefaults.standard
        if let saved=defaults.string(forKey:"macUUID"),WireCrypto.validID(saved){macId=saved}else{let id=UUID().uuidString.lowercased();macId=id;defaults.set(id,forKey:"macUUID")}
        pairing=PairingManager(macId:macId)
        // Retain the existing journal, revocations and reminders on an in-place update.
        directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Keespresso")
        do {
            let revoked=try DeviceRevocations(url:directory.appendingPathComponent("revocations.json"));revocations=revoked
        }catch{devices=[];message="Local authorization storage is unavailable. Phone access is disabled."}
        eventOutbox=try? RelayOutbox(url:directory.appendingPathComponent("delivery-outbox.json"))
        if let journal=try? MutationJournal(url:directory.appendingPathComponent("mutations.json")){executor=MutationExecutor(journal:journal)}
        let reminderURL=directory.appendingPathComponent("reminders.json")
        if FileManager.default.fileExists(atPath:reminderURL.path){
            if let data=try? Data(contentsOf:reminderURL),let state=try? WireJSON.decoder.decode(ReminderMachine.self,from:data),(try? state.settings.validate()) != nil{persistedReminderData=data;reminders=state;reminders.resumedAfterUnknownInterval()}
            else{message="Saved reminder state could not be read. Routine reminders are disabled until settings are saved.";reminders.settings.enabled=false}
        }
        internetMigration=try? InternetMigration(url:directory.appendingPathComponent("Internet/migration.json"))
        notificationOutbox=try? NotificationOutbox(url:directory.appendingPathComponent("Notifications/outbox.json"))
        pushTokens=try? PushTokenStorage(url:directory.appendingPathComponent("Notifications/tokens.json"))
        do {
            if let configuration=try FirebaseSenderStorage(url:directory.appendingPathComponent("Notifications/sender.json")).load(){
                firebaseClient=configuration.client;notificationSender=FirebaseSender(configuration:configuration)
                notificationState="Firebase configured. Waiting for phone registration."
            }
        }catch{notificationState="Saved Firebase configuration could not be read. Import it again after checking its private file."}
        nearbyEnabled=defaults.bool(forKey:"nearbyEnabled") && revocations != nil
        relayEnabled=defaults.bool(forKey:"relayEnabled")
        message="Waiting for native Keepresso. Your saved connection choices are retained."
    }
    func loadSavedAuthorization(allowInteraction:Bool=false){
        let store=credentials
        authorization.load(operation:{try store.loadSaved(allowInteraction:allowInteraction)}){[weak self] saved in self?.acceptSavedAuthorization(saved)}
    }
    func retrySavedAuthorization(){
        guard !authorizationReady else{return}
        let store=credentials
        authorization.retryAfterEnvironmentChange(operation:{try store.loadSaved(allowInteraction:false)}){[weak self] saved in self?.acceptSavedAuthorization(saved)}
    }
    private func acceptSavedAuthorization(_ saved:SavedAuthorization){
        guard revocations != nil else{return}
        devices=saved.devices.filter{revocations?.contains($0.deviceId) != true}
        relayConfiguration=saved.relay;relayURLInput=saved.relay?.url ?? ""
        relayEnabled=UserDefaults.standard.bool(forKey:"relayEnabled") && saved.relay != nil
        authorizationReady=true
        if lifecycle.isActive{resume()}
    }
    func updateNativeApplication(token: String?) {
        for action in lifecycle.update(applicationToken: token) {
            switch action { case .stop: suspend(); case .start: resume() }
        }
    }
    private func resume() {
        nativeRunning=true
        guard authorizationReady else{message="Connections are paused until saved pairing keys can be read.";return}
        nearbyRecovery.reset()
        native.network.start()
        reminders.resumedAfterUnknownInterval()
        resolveEvents(["hourly","session_ended_awake","sleep_failed","thermal"])
        let generation=lifecycle.generation
        sleepToken=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in guard let self,self.lifecycle.accepts(generation:generation) else{return};self.observedSleep()}}
        wakeToken=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in guard let self,self.lifecycle.accepts(generation:generation) else{return};self.observedWake()}}
        if nearbyEnabled { enableNearby() }
        if internetEnabled {startInternet()}
        if internetEnabled,legacyNeeded,let configuration=relayConfiguration { startRelay(configuration) }
        message="Native Keepresso is running. Saved connections resume automatically."
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in Task{@MainActor in guard let self,self.lifecycle.accepts(generation:generation) else{return};self.tick()}}
    }
    private func suspend() {
        nativeRunning=false;timer?.invalidate();timer=nil
        stopInternet();stopNotificationDelivery()
        native.network.stop()
        lidWarningSound.stop();reminders.resumedAfterUnknownInterval()
        relay?.stop();relay=nil;relayTask?.cancel();relayTask=nil;relayTaskID=nil
        refreshOwner.cancel();observer.invalidate()
        bluetooth.stop();pairing.deny();pairingChanged()
        nearbyRecovery.reset()
        for token in [sleepToken,wakeToken].compactMap({$0}) { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        sleepToken=nil;wakeToken=nil
        bluetoothState="Waiting for Keepresso";relayState="Waiting for Keepresso"
        message="Waiting for native Keepresso. Connections are paused; your saved choices are retained."
    }
    func shutdown() { setup.cancelForLifecycleChange();authorization.stop();authorizationReady=false;_=lifecycle.update(applicationToken:nil);suspend() }
    func enableNearby(){guard authorizationReady,revocations != nil else{message="Allow access to the saved connection first.";return};UserDefaults.standard.set(true,forKey:"nearbyEnabled");nearbyEnabled=true;guard nativeRunning,!nearbyRecovery.sleeping else{bluetoothState="Waiting for Keepresso";return};bluetooth.start();message="Nearby Bluetooth is enabled. Saved phone authorization is retained."}
    func disableNearby(){UserDefaults.standard.set(false,forKey:"nearbyEnabled");bluetooth.stop();nearbyEnabled=false;bluetoothState="Off";pairing.deny();pairingChanged()}
    func armPairing(){
        guard setupEligible,nativeRunning,authorizationReady,devices.isEmpty else{return}
        if setup.preparePairing(bluetoothAuthorized:CBManager.authorization == .allowedAlways){armPreparedPairing()}
    }
    func guidedSetupFinished(){
        if nearbyEnabled,nativeRunning,authorizationReady,!nearbyRecovery.sleeping{bluetooth.start()}
        if devices.isEmpty{
            if CBManager.authorization == .allowedAlways{armPreparedPairing()}
            else{message="Bluetooth access is needed to pair your phone. Review setup or enable it in System Settings."}
        }
    }
    private func armPreparedPairing(){guard setupEligible,nativeRunning,authorizationReady,devices.isEmpty,CBManager.authorization == .allowedAlways else{return};if !nearbyEnabled{enableNearby()};do{invitation=try pairing.arm(name:Host.current().localizedName ?? "Mac",now:Date());message="Scan this five-minute invitation on your phone, then approve its name here."}catch{message="Could not create a secure invitation."}}
    func pairingChanged(){invitation=pairing.invitation;pendingName=pairing.pending?.request.deviceName}
    func approve(){do{try bluetooth.approvePending();message="Phone authorized. It must now complete the encrypted handshake."}catch{pairing.deny();pairingChanged();message="Approval could not be saved securely. Pair again."}}
    func deny(){bluetooth.denyPending()}
    func deletePairing(){
        guard authorizationReady else{return}
        deny()
        for device in devices{revoke(device)}
    }
    func isAuthorized(_ device:String)->Bool{authorizationReady && nativeRunning && !nearbyRecovery.sleeping && lifecycle.isActive && revocations != nil && !locallyRevoked.contains(device) && revocations?.contains(device) != true && devices.contains{$0.deviceId==device}}
    private var authorizedDevices:[AuthorizedDevice]{devices.filter{isAuthorized($0.deviceId)}}
    func addDevice(_ device:AuthorizedDevice)throws{
        guard authorizationReady,revocations != nil,devices.isEmpty,!locallyRevoked.contains(device.deviceId),revocations?.contains(device.deviceId) != true else{throw CompanionError.invalid}
        let updated=devices+[device];try credentials.save(updated);devices=updated;relay?.nearbyChanged();runRelayTick()
    }
    func revoke(_ device:AuthorizedDevice){
        guard authorizationReady else{return}
        // Local tombstones gate both transports before any fallible cleanup.
        locallyRevoked.insert(device.deviceId);devices.removeAll{$0.deviceId==device.deviceId};bluetooth.revoke(device.deviceId);internet.revoke(device.deviceId)
        var durable=false
        do{guard let revocations else{throw CompanionError.unavailable};try revocations.revoke(device.deviceId);durable=true}catch{}
        do{try credentials.save(devices);durable=true}catch{}
        if let relay{Task{await relay.revoke(device.deviceId)}}
        try? notificationOutbox?.revoke(device.deviceId,now:Date());try? pushTokens?.remove(device.deviceId)
        if durable{message="Phone authorization revoked. Remote cleanup will be attempted while connected."}
        else{disableNearby();disableRelay();message="Phone access is blocked for this session, but revocation could not be saved. Both connections are disabled; retry after storage is available."}
    }
    func configureRelay(){
        guard authorizationReady else{return}
        do {
            let configuration=try RelayConfiguration(url:relayURLInput.trimmingCharacters(in:.whitespacesAndNewlines),macBearer:relayBearerInput.trimmingCharacters(in:.whitespacesAndNewlines))
            guard !devices.contains(where:{$0.key.base64EncodedString()==configuration.macBearer || (try? RelayEnvelope.phoneBearer(deviceKey:$0.key,macId:macId,deviceId:$0.deviceId))==configuration.macBearer}) else{throw CompanionError.invalid}
            try credentials.saveRelay(configuration);relayConfiguration=configuration;relayBearerInput="";startRelay(configuration)
        }catch{relayState="Enter an HTTPS relay URL and its independent 32-byte Base64 Mac bearer. Configuration could not be saved."}
    }
    func enableStoredRelay(){setInternetEnabled(true)}
    func setInternetEnabled(_ enabled:Bool){
        UserDefaults.standard.set(enabled,forKey:"internetEnabled");relayEnabled=enabled
        if enabled{startInternet();if legacyNeeded,let configuration=relayConfiguration{startRelay(configuration)}}
        else{stopInternet();stopNotificationDelivery();relay?.stop();relay=nil;relayTask?.cancel();relayTask=nil;relayTaskID=nil;relayState="Internet disabled. Nearby authorization is retained."}
    }
    func disableRelay(){setInternetEnabled(false);UserDefaults.standard.set(false,forKey:"relayEnabled");relay?.stop();relay=nil;relayTask?.cancel();relayTask=nil;relayTaskID=nil;relayEnabled=false;relayState="Internet disabled. Nearby authorization is retained."}
    private func startRelay(_ configuration:RelayConfiguration){
        guard authorizationReady,legacyNeeded,internetEnabled else{return}
        relay?.stop();relay=nil
        relayEnabled=true;UserDefaults.standard.set(true,forKey:"relayEnabled")
        guard nativeRunning else{relayState="Saved; waiting for Keepresso.";return}
        do {
            guard revocations != nil,let eventOutbox else{throw CompanionError.unavailable}
            relay=try RelayCoordinator(macId:macId,api:RelayHTTPClient(configuration:configuration),outbox:eventOutbox,devices:{[weak self] in self?.authorizedDevices ?? []},nearby:{[weak self] in self?.bluetooth.authenticatedDevices ?? []},snapshot:{[weak self] in self?.snapshot() ?? [:]},execute:{[weak self] request,device,body,rejection in guard let self else{return CommandResponse(id:request.id,status:"error")};return await self.handle(request,device:device,body:body,policyRejection:rejection)},enrolled:{[weak self] device in self?.sendRelayConfiguration(device)},canDeliverAlerts:{[weak self] in self?.native.fullWake == true})
            relayEnabled=true;UserDefaults.standard.set(true,forKey:"relayEnabled");relayState="Internet configured; waiting for relay contact.";runRelayTick()
        }catch{relayEnabled=false;relayState="Internet cannot start because local authorization or delivery storage is unavailable."}
    }
    private func runRelayTick(){
        guard nativeRunning,!nearbyRecovery.sleeping,relayTask==nil,let current=relay else{return}
        let id=UUID();relayTaskID=id;let generation=lifecycle.generation
        relayTask=Task{[weak self] in
            defer{if self?.relayTaskID==id{self?.relayTask=nil;self?.relayTaskID=nil}}
            guard !Task.isCancelled else{return};await current.tick()
            guard let self,self.lifecycle.accepts(generation:generation),self.relay === current else{return};if self.internet.endpointId==nil{self.relayState=current.status}
        }
    }
    func nearbyChanged(){relay?.nearbyChanged();runRelayTick()}
    func deviceBecameNearby(_ device:String){
        guard isAuthorized(device) else{return};nearbyChanged();sendRelayConfiguration(device)
        if let configuration=internetConfiguration {bluetooth.sendInternetConfiguration(device:device,configuration:configuration)}
        if native.fullWake, let eventOutbox{for event in eventOutbox.events(deviceId:device,epoch:relay?.epoch ?? localEventEpoch,now:Date()){bluetooth.sendEvent(event,device:device)}}
    }
    private func sendRelayConfiguration(_ device:String){
        guard isAuthorized(device),relay?.isEnrolled(device)==true,let configuration=relayConfiguration,let credential=devices.first(where:{$0.deviceId==device}),let ticket=try? RelayEnvelope.accessTicket(macBearer:configuration.macBearer,deviceKey:credential.key,macId:macId,deviceId:device) else{return}
        bluetooth.sendRelayConfiguration(device:device,url:configuration.url,authTicket:ticket)
    }
    var internetConfiguration:InternetConfiguration? {
        guard let endpointId=internet.endpointId else{return nil}
        return try? InternetConfiguration(endpointId:endpointId,firebase:firebaseClient)
    }
    func registerPush(_ registration:PushRegistration,device:String)throws->PushRegistrationAck {
        guard isAuthorized(device),firebaseClient?.projectId==registration.projectId,let pushTokens,let notificationOutbox else{throw CompanionError.unavailable}
        let ack=try pushTokens.register(registration,device:device)
        try notificationOutbox.tokenChanged(device,now:Date())
        notificationState="Phone registered. No notification has been accepted by Firebase yet."
        runNotificationDelivery();return ack
    }
    private func stopInternet(){internetGeneration=UUID();internetStart?.cancel();internetStart=nil;internet.stop()}
    private func startInternet(){
        guard authorizationReady,nativeRunning,!nearbyRecovery.sleeping,internetStart==nil,internet.endpointId==nil else{return}
        let generation=UUID();internetGeneration=generation
        internetStart=Task{[weak self] in
            guard let self else{return}
            defer{if self.internetGeneration==generation{self.internetStart=nil}}
            do {
                let seed=try PrivateInternetState(url:self.directory.appendingPathComponent("Internet/seed.json")).loadOrCreateSeed()
                self.internetSeed=seed
                try await self.internet.start(seed:seed,sessionFactory:{[weak self] in
                    guard let self,self.internetGeneration==generation else{throw CompanionError.closed}
                    return try InternetSession(macId:self.macId,lookupDevice:{[weak self] id in self?.devices.first{$0.deviceId==id}},
                        authorized:{[weak self] id in self?.internetGeneration==generation && self?.isAuthorized(id)==true},
                        configuration:{[weak self] in self?.internetConfiguration},execute:{[weak self] request,device,body,valid in
                            guard let self else{return CommandResponse(id:request.id,status:"error")}
                            self.learnedInternet(device)
                            return await self.handle(request,device:device,body:body,additionalAuthorization:valid)
                        },registerPush:{[weak self] device,registration in
                            guard let self else{throw CompanionError.closed};self.learnedInternet(device);return try self.registerPush(registration,device:device)
                        },snapshot:{[weak self] in self?.snapshot() ?? [:]})
                },stateChanged:{[weak self] state in if self?.internetGeneration==generation{self?.relayState=state}},configured:{[weak self] in
                    guard let self,self.internetGeneration==generation,let configuration=self.internetConfiguration else{return}
                    for device in self.authorizedDevices{self.bluetooth.sendInternetConfiguration(device:device.deviceId,configuration:configuration)}
                })
            }catch{if self.internetGeneration==generation{self.relayState="Internet is unavailable. Nearby remains available."}}
        }
    }
    func snapshot()->[String:Any]{
        observer.syncRules(version:native.installedVersion)
        var snapshot=native.snapshot(triggers:observer.preview,reminders:reminders,ax:ax)
        if let configuration=internetConfiguration{snapshot["internetConfiguration"]=try? WireJSON.object(configuration.encoded())}
        return snapshot
    }
    func handle(_ request:CommandRequest,device:String,body:Data,policyRejection:String?=nil,additionalAuthorization:@escaping()->Bool={true})async -> CommandResponse{
        let generation=lifecycle.generation,powerGeneration=nearbyRecovery.generation
        let authorized={additionalAuthorization() && self.lifecycle.accepts(generation:generation) && self.nearbyRecovery.accepts(generation:powerGeneration) && self.isAuthorized(device)}
        guard authorized() else{return CommandResponse(id:request.id,status:"error",message:"Device authorization was revoked.")}
        do{try request.validate(now:Date())}catch{return CommandResponse(id:request.id,status:"error",message:"The request is invalid or expired.")}
        if let executor {
            return await executor.execute(request,device:device,body:body,now:Date(),authorized:authorized,rejection:policyRejection){await self.perform(request,authorized:authorized)}
        }
        guard !request.isMutation,request.action != "operation_status" else{return CommandResponse(id:request.id,status:"error",message:"The durable command journal is unavailable; controls and operation lookup are disabled.")}
        return await perform(request,authorized:authorized)
    }
    private func perform(_ request:CommandRequest,authorized:@escaping()->Bool={true})async ->CommandResponse{
        guard nativeRunning else{return CommandResponse(id:request.id,status:"error",message:"Native Keepresso is not running.")}
        let result:CommandResponse
        switch request.action{
        case "status":result=CommandResponse(id:request.id,status:"ok")
        case "refresh_triggers":
            guard !refreshOwner.isRunning else{return CommandResponse(id:request.id,status:"error",message:"A trigger check is already in progress.")}
            let generation=lifecycle.generation
            let checked=await refreshOwner.run{await self.observer.refresh(version:self.native.installedVersion,folderConsent:CompanionObservationConsent.encode(folders:self.setup.running ? nil:self.triggerFolderSetup.workerConsent(),steam:self.setup.running ? nil:self.setup.steamConsent))}
            guard lifecycle.accepts(generation:generation),authorized(),let checked else{return CommandResponse(id:request.id,status:"error",message:"Keepresso changed while checking triggers.")}
            result=CommandResponse(id:request.id,status:checked.checking != true && checked.checkError == nil && checked.checkedAt != nil && ["ready","unknown"].contains(checked.state) ? "ok":"uncertain",message:checked.checkError ?? checked.message)
        case "snooze_reminders","resume_reminders","ack_reminder","set_reminder_settings":
            let previous=reminders
            do{
                switch request.action{
                case "snooze_reminders":reminders.snooze(now:Date())
                case "resume_reminders":reminders.resume()
                case "ack_reminder":reminders.acknowledge()
                default:try reminders.update(settings:request.reminderSettings!)
                }
                try persistReminders();result=CommandResponse(id:request.id,status:"ok")
            }catch{reminders=previous;result=CommandResponse(id:request.id,status:"error",message:"Reminder settings could not be saved.")}
        default:
            result=await commands.execute(request,authorized:authorized)
        }
        return result
    }
    private var legacyNeeded:Bool {internetMigration?.needsLegacy(devices) ?? true}
    private func learnedInternet(_ device:String){
        guard isAuthorized(device),let approved=devices.first(where:{$0.deviceId==device}),let internetMigration else{return}
        do{
            try internetMigration.authenticated(approved)
            if !legacyNeeded{relay?.stop();relay=nil;relayTask?.cancel();relayTask=nil;relayTaskID=nil}
        }catch{connectionLog.error("Internet migration marker unavailable")}
    }
    func importFirebase(){
        do {
            guard let configuration=try FirebaseImportUI.choose() else{return}
            try FirebaseSenderStorage(url:directory.appendingPathComponent("Notifications/sender.json")).save(configuration)
            stopNotificationDelivery()
            firebaseClient=configuration.client;notificationSender=FirebaseSender(configuration:configuration)
            notificationState="Firebase configured. Waiting for phone registration."
            if let configuration=internetConfiguration{for device in authorizedDevices{bluetooth.sendInternetConfiguration(device:device.deviceId,configuration:configuration)}}
            // Current iroh clients learn changed public options from their next status.
            for event in eventOutbox?.events(now:Date()) ?? []{try enqueueNotification(event)}
        }catch{notificationState="Import could not finish. Check the matching Firebase files and private storage. Your phone pairing is unchanged."}
    }
    private func enqueueNotification(_ event:CompanionEvent)throws {
        guard let notificationOutbox else{throw CompanionError.unavailable}
        let payload=try WireJSON.data(["type":"event","event":WireJSON.object(WireJSON.encoder.encode(event))])
        for device in authorizedDevices {
            if notificationOutbox.existing(event:event.id,device:device.deviceId,now:Date()) != nil{continue}
            let envelope=try RelayEnvelope.seal(payload,key:device.key,macId:macId,deviceId:device.deviceId,id:event.id,epoch:localEventEpoch,direction:"s2c",kind:"event",now:event.createdAt,lifetime:event.deliveryLifetimeSeconds)
            try notificationOutbox.enqueue(envelope,kind:event.deliveryKind,now:Date())
        }
    }
    private func stopNotificationDelivery(){notificationGeneration=UUID();notificationTask?.cancel();notificationTask=nil}
    private func runNotificationDelivery(){
        guard internetEnabled,nativeRunning,!nearbyRecovery.sleeping,native.fullWake,notificationTask==nil,let sender=notificationSender,let queue=notificationOutbox,let tokens=pushTokens,let project=firebaseClient?.projectId else{return}
        let pending=queue.due(devices:Set(authorizedDevices.map(\.deviceId)),now:Date()).prefix(8)
        guard !pending.isEmpty else{return}
        let generation=notificationGeneration
        notificationTask=Task{[weak self] in
            guard let self else{return}
            defer{if self.notificationGeneration==generation{self.notificationTask=nil}}
            do{try await NotificationDelivery.drain(Array(pending),sender:sender,registration:{envelope in
                guard self.notificationGeneration==generation,self.native.fullWake,self.isAuthorized(envelope.deviceId),
                      queue.existing(event:envelope.id,device:envelope.deviceId,now:Date())==envelope,
                      let registration=tokens.registration(envelope.deviceId),registration.projectId==project else{return nil}
                return registration
            },completed:{envelope,_,result in
                try queue.completed(envelope,result:result,now:Date())
                switch result {
                case .accepted:self.notificationState="Last notification accepted by Firebase at \(Date().formatted(date:.omitted,time:.shortened))."
                case .transient:self.notificationState="Firebase temporarily unavailable. Notification retry scheduled."
                case .unregistered:self.notificationState="Waiting for the phone to renew notification registration."
                case .rejected:self.notificationState="Firebase rejected a notification. Check the sender account and project."
                case .expired,.cancelled:break
                }
            })}catch{self.notificationState="Notification delivery state could not be saved."}
        }
    }
    private var ticks = 0
    private func tick() {
        guard nativeRunning, !nearbyRecovery.sleeping else { return }
        bluetooth.tick()
        pairingChanged()
        checkAlerts()
        runRelayTick()
        runNotificationDelivery()
        ticks += 1
        if ticks % 10 == 0 { observer.syncRules(version: native.installedVersion) }
    }

    private func checkAlerts() {
        let now = Date()
        let reading = native.alertReadings(now: now)
        var events = reminders.observeAwake(reading.awake, now: now)
        if reading.awake.wake == .full {
            let hadNoncritical = reminders.noncriticalHeatActive
            let warning = reminders.observeHeat(reading.thermal, exposure: .init(lidClosed: reading.awake.lidClosed, isBrewing: reading.awake.isBrewing), now: now)
            if hadNoncritical && !reminders.noncriticalHeatActive { resolveEvents(["thermal"]) }
            if let warning { events.append(warning) }
        }
        if reminders.consumeLidClosureSound() {
            lidWarningSound.play(evenIfMuted: UserDefaults.standard.bool(forKey: LidWarningSound.overrideMutePreference))
        }
        deliver(events)
    }

    private func deliver(_ events:[CompanionEvent]){
        guard !events.isEmpty else { return }
        do{
            guard let eventOutbox else{throw CompanionError.unavailable}
            for event in events {
                resolveEvents([event.deliveryKind])
                try eventOutbox.enqueue(event, devices: authorizedDevices, macId: macId, epoch: relay?.epoch ?? localEventEpoch, now: Date())
            }
            try persistReminders()
            for event in events {
                NotificationDelivery.live(enqueuePush:{try self.enqueueNotification(event)},broadcast:{
                    self.bluetooth.broadcast(event);self.internet.broadcast(event)
                },pushFailed:{self.notificationState="Internet notification storage unavailable. Nearby delivery remains active."})
            }
            runNotificationDelivery()
        }catch{message="Reminder state cannot be saved. Delivery is suspended until storage is available."}
    }
    private func resolveEvents(_ kinds:Set<String>){
        do{try eventOutbox?.resolve(kinds:kinds,now:Date());try notificationOutbox?.resolve(kinds:kinds,now:Date())}catch{message="Resolved warnings could not be cleared from delivery storage."}
    }
    private func observedSleep() {
        connectionLog.info("Machine sleeping; invalidating nearby sessions")
        // Resolve the existing phone card before shutting down transports.
        // The durable outbox can deliver it after wake if the last live send loses the race.
        let closedLidEnded = reminders.observedSleep(now: Date())
        resolveEvents(["hourly", "unattended_brew", "session_ended_awake", "sleep_failed", "thermal", "critical_episode"])
        if let closedLidEnded { deliver([closedLidEnded]) }
        nearbyRecovery.willSleep()
        stopInternet()
        stopNotificationDelivery()
        native.network.stop()
        lidWarningSound.stop()
        relay?.wake()
        refreshOwner.cancel()
        try? persistReminders()
        observer.markStale()
    }
    private func observedWake(){connectionLog.info("Machine awake; rebuilding nearby transport");nearbyRecovery.didWake(enabled:nativeRunning && authorizationReady && nearbyEnabled);native.network.reset();if internetEnabled{startInternet()};relay?.wake();runRelayTick()}
    private func persistReminders()throws{
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data=try WireJSON.encoder.encode(reminders);guard data != persistedReminderData else{return}
        try data.write(to:directory.appendingPathComponent("reminders.json"),options:.atomic);persistedReminderData=data
    }
}
