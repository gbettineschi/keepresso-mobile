import Foundation
import CoreBluetooth
import CompanionCore
import OSLog

private let bluetoothLog=Logger(subsystem:"local.keespresso.companion",category:"bluetooth")

/// The Mac is the physical central, and remains the logical authenticated server.
@MainActor final class BluetoothServer: NSObject, @preconcurrency CBCentralManagerDelegate {
    static let service=CBUUID(string:NearbyGattV2.serviceUUID)
    static let input=CBUUID(string:NearbyGattV2.phoneToMacUUID)
    static let output=CBUUID(string:NearbyGattV2.macToPhoneUUID)

    @MainActor final class Peer:NSObject,@preconcurrency CBPeripheralDelegate {
        let peripheral:CBPeripheral
        let managerGeneration:UUID
        let session=NearbyCentralSession(now:ProcessInfo.processInfo.systemUptime)
        let decoder=FrameDecoder()
        let queue=NearbyAcknowledgedWrites()
        weak var owner:BluetoothServer?
        var input:CBCharacteristic?;var output:CBCharacteristic?
        var handshake:ServerHandshake?;var channel:SealedChannel?;var device:String?
        var authenticatedAt:Date?;var busy=false;let connectedAt=Date()
        var commandTask:Task<Void,Never>?
        init(_ peripheral:CBPeripheral,owner:BluetoothServer,generation:UUID){
            self.peripheral=peripheral;self.owner=owner;managerGeneration=generation;super.init()
        }
        func peripheral(_ peripheral:CBPeripheral,didDiscoverServices error:Error?){guard peripheral === self.peripheral else{return};owner?.discoveredServices(self,error:error)}
        func peripheral(_ peripheral:CBPeripheral,didDiscoverCharacteristicsFor service:CBService,error:Error?){guard peripheral === self.peripheral else{return};owner?.discoveredCharacteristics(self,service:service,error:error)}
        func peripheral(_ peripheral:CBPeripheral,didUpdateNotificationStateFor characteristic:CBCharacteristic,error:Error?){guard peripheral === self.peripheral else{return};owner?.subscribed(self,characteristic:characteristic,error:error)}
        func peripheral(_ peripheral:CBPeripheral,didUpdateValueFor characteristic:CBCharacteristic,error:Error?){guard peripheral === self.peripheral else{return};owner?.received(self,characteristic:characteristic,error:error)}
        func peripheral(_ peripheral:CBPeripheral,didWriteValueFor characteristic:CBCharacteristic,error:Error?){guard peripheral === self.peripheral else{return};owner?.wrote(self,characteristic:characteristic,error:error)}
        func peripheral(_ peripheral:CBPeripheral,didModifyServices invalidatedServices:[CBService]){guard peripheral === self.peripheral else{return};owner?.invalidatedServices(self)}
    }
    private var manager:CBCentralManager?
    private let lifetime=NearbyCentralLifetime()
    private var managerGeneration=UUID()
    private var renewOnPowerOn=false
    private var wasPoweredOn=false
    private var peers:[UUID:Peer]=[:]
    // Do not reuse a peripheral until CoreBluetooth finishes the old connection.
    private var retiring:[UUID:(peripheral:CBPeripheral,since:TimeInterval)]=[:]
    private var retryAfter:[UUID:TimeInterval]=[:]
    private var banned:[UUID:Date]=[:]
    private var globallyBlockedUntil=Date.distantPast
    private var nextDiscovery = -TimeInterval.infinity
    let model:CompanionModel
    init(model:CompanionModel){self.model=model;super.init()}
    var started:Bool{manager != nil}
    func start(){
        // First-use privacy requests belong to foreground setup, including
        // starts reached through hidden login, native relaunch or wake recovery.
        guard CBManager.authorization == .allowedAlways else{model.bluetoothState="Allow Bluetooth in Mac setup.";return}
        guard manager==nil else{return}
        managerGeneration=lifetime.begin();nextDiscovery = -TimeInterval.infinity
        renewOnPowerOn=false;wasPoweredOn=false
        manager=CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionShowPowerAlertKey:false])
    }
    var authenticatedDevices:Set<String>{Set(peers.values.compactMap{peer in guard current(peer),peer.session.authorized,peer.channel != nil,let device=peer.device,model.isAuthorized(device) else{return nil};return device})}
    func stop(){
        lifetime.end()
        let old=manager;manager=nil
        if old?.state == .poweredOn{old?.stopScan()}
        old?.delegate=nil
        for peer in Array(peers.values){invalidate(peer);if old?.state == .poweredOn{old?.cancelPeripheralConnection(peer.peripheral)}}
        if old?.state == .poweredOn{for entry in retiring.values{old?.cancelPeripheralConnection(entry.peripheral)}}
        peers.removeAll();retiring.removeAll();retryAfter.removeAll()
        model.pairing.deny();model.pairingChanged();model.connectionCount=0;model.nearbyChanged()
    }
    private func current(_ peer:Peer)->Bool{
        manager?.state == .poweredOn && lifetime.accepts(peer.managerGeneration) && peers[peer.peripheral.identifier] === peer && peer.session.accepts(peer.session.generation)
    }
    private func commandAuthorized(_ peer:Peer,device:String)->Bool{
        !Task.isCancelled && current(peer) && peer.session.authorized && peer.channel != nil && model.isAuthorized(device)
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager){
        guard central === manager else{return}
        model.setup.frameworkStatusChanged()
        bluetoothLog.notice("Central state \(central.state.rawValue,privacy:.public)")
        switch central.state {
        case .unknown:model.bluetoothState="Checking Bluetooth…"
        case .resetting:model.bluetoothState="Bluetooth restarting…"
        case .unsupported:model.bluetoothState="Bluetooth unavailable"
        case .unauthorized:model.bluetoothState="Bluetooth access needed"
        case .poweredOff:model.bluetoothState="Bluetooth is off"
        case .poweredOn:model.bluetoothState="Searching for nearby phones…"
        @unknown default:model.bluetoothState="Bluetooth unavailable"
        }
        guard central.state == .poweredOn,model.nativeRunning else{
            for id in Array(peers.keys){drop(id,ban:false,cancel:false)}
            retiring.removeAll()
            if wasPoweredOn{renewOnPowerOn=true}
            return
        }
        // A new manager gives power/reset callbacks an unambiguous identity.
        if renewOnPowerOn{stop();start();return}
        wasPoweredOn=true;discover()
    }
    private func discover(){
        guard let manager,manager.state == .poweredOn,model.nativeRunning else{return}
        nextDiscovery=ProcessInfo.processInfo.systemUptime+10
        // Repeated bounded scans also revisit candidates whose backoff expired.
        manager.stopScan()
        for peripheral in manager.retrieveConnectedPeripherals(withServices:[Self.service]){consider(peripheral)}
        manager.scanForPeripherals(withServices:[Self.service],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
    }
    func centralManager(_ central:CBCentralManager,didDiscover peripheral:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber){guard central === manager else{return};consider(peripheral)}
    private func consider(_ peripheral:CBPeripheral){
        let id=peripheral.identifier,now=Date(),uptime=ProcessInfo.processInfo.systemUptime
        guard let manager,manager.state == .poweredOn,model.nativeRunning,now>=globallyBlockedUntil,
              peers.count+retiring.count<8,peers[id]==nil,retiring[id]==nil,
              banned[id].map({$0>now}) != true,retryAfter[id].map({$0>uptime}) != true else{return}
        let peer=Peer(peripheral,owner:self,generation:managerGeneration)
        peers[id]=peer;peripheral.delegate=peer;manager.connect(peripheral,options:nil)
    }
    func centralManager(_ central:CBCentralManager,didConnect peripheral:CBPeripheral){
        guard central === manager,central.state == .poweredOn else{return}
        guard let peer=peers[peripheral.identifier],peer.peripheral === peripheral,current(peer),peer.session.stage == .connecting,model.nativeRunning else{central.cancelPeripheralConnection(peripheral);return}
        do{try peer.session.advance(to:.services,now:ProcessInfo.processInfo.systemUptime);peripheral.discoverServices([Self.service])}catch{drop(peripheral.identifier,ban:false)}
    }
    func centralManager(_ central:CBCentralManager,didFailToConnect peripheral:CBPeripheral,error:Error?){disconnected(central,peripheral:peripheral)}
    func centralManager(_ central:CBCentralManager,didDisconnectPeripheral peripheral:CBPeripheral,error:Error?){disconnected(central,peripheral:peripheral)}
    private func disconnected(_ central:CBCentralManager,peripheral:CBPeripheral){
        guard central === manager else{return}
        let id=peripheral.identifier
        if let peer=peers[id],peer.peripheral === peripheral{drop(id,ban:false,cancel:false)}
        if retiring[id]?.peripheral === peripheral{retiring.removeValue(forKey:id)}
    }
    private func discoveredServices(_ peer:Peer,error:Error?){
        guard current(peer) else{return}
        guard error==nil,peer.session.stage == .services,let services=peer.peripheral.services,
              services.filter({$0.uuid==Self.service}).count==1,let service=services.first(where:{$0.uuid==Self.service}) else{drop(peer.peripheral.identifier,ban:false);return}
        do{try peer.session.advance(to:.characteristics,now:ProcessInfo.processInfo.systemUptime);peer.peripheral.discoverCharacteristics([Self.input,Self.output],for:service)}catch{drop(peer.peripheral.identifier,ban:false)}
    }
    private func discoveredCharacteristics(_ peer:Peer,service:CBService,error:Error?){
        guard current(peer) else{return}
        guard error==nil,peer.session.stage == .characteristics,service.uuid==Self.service,
              let characteristics=service.characteristics,
              characteristics.filter({$0.uuid==Self.input}).count==1,characteristics.filter({$0.uuid==Self.output}).count==1,
              let input=characteristics.first(where:{$0.uuid==Self.input}),input.properties.contains(.notify),
              let output=characteristics.first(where:{$0.uuid==Self.output}),output.properties.contains(.write) else{drop(peer.peripheral.identifier,ban:false);return}
        peer.input=input;peer.output=output
        do{try peer.session.advance(to:.subscribing,now:ProcessInfo.processInfo.systemUptime);peer.peripheral.setNotifyValue(true,for:input)}catch{drop(peer.peripheral.identifier,ban:false)}
    }
    private func subscribed(_ peer:Peer,characteristic:CBCharacteristic,error:Error?){
        guard current(peer) else{return}
        guard error==nil,characteristic === peer.input,characteristic.isNotifying,peer.session.stage == .subscribing else{drop(peer.peripheral.identifier,ban:false);return}
        do{
            try peer.session.advance(to:.ready,now:ProcessInfo.processInfo.systemUptime)
            model.connectionCount=peers.values.filter{$0.session.ready}.count;model.bluetoothState="Available nearby"
            bluetoothLog.notice("Nearby phone subscription established")
            for record in peer.session.takeBufferedRecords(){try receive(record,peer:peer)}
        }catch{drop(peer.peripheral.identifier,ban:true)}
    }
    private func received(_ peer:Peer,characteristic:CBCharacteristic,error:Error?){
        guard current(peer) else{return}
        guard model.nativeRunning,error==nil,(peer.session.ready || peer.session.stage == .subscribing),characteristic === peer.input,Date()>=globallyBlockedUntil,let data=characteristic.value else{drop(peer.peripheral.identifier,ban:false);return}
        do{
            for record in try peer.decoder.feed(data,now:Date().timeIntervalSince1970){
                for ready in try peer.session.receiveRecord(record){try receive(ready,peer:peer)}
            }
        }catch{drop(peer.peripheral.identifier,ban:true)}
    }
    private func wrote(_ peer:Peer,characteristic:CBCharacteristic,error:Error?){
        guard current(peer) else{return}
        guard characteristic === peer.output,peer.session.ready else{drop(peer.peripheral.identifier,ban:false);return}
        do{try peer.queue.acknowledge(success:error==nil,now:ProcessInfo.processInfo.systemUptime);flush(peer)}catch{drop(peer.peripheral.identifier,ban:false)}
    }
    private func invalidatedServices(_ peer:Peer){guard current(peer) else{return};drop(peer.peripheral.identifier,ban:false)}
    func receive(_ data:Data,peer:Peer)throws {
        guard current(peer),peer.session.ready,!peer.busy else{throw CompanionError.limit}
        let object=try WireJSON.object(data);let type=object["type"] as? String
        if let channel=peer.channel {
            guard let device=peer.device,model.isAuthorized(device) else{throw CompanionError.unauthorized}
            let record=try WireJSON.decoder.decode(SealedRecord.self,from:data)
            let plain=try channel.open(record)
            if try WireJSON.object(plain)["type"] as? String == "push_registration" {
                let registration=try PushRegistration.decode(plain)
                do{let ack=try model.registerPush(registration,device:device);try sendPrivate(WireJSON.object(WireJSON.encoder.encode(ack)),peer:peer)}
                catch{try sendPrivate(["type":"push_registration_error","message":"Notification registration is unavailable."],peer:peer)}
                return
            }
            let command=try WireJSON.decoder.decode(CommandRequest.self,from:plain)
            try command.validate(now:Date())
            guard let device=peer.device else{throw CompanionError.unauthorized}
            peer.busy=true
            peer.commandTask=Task { @MainActor [weak self,weak peer] in
                guard let self,let peer,self.commandAuthorized(peer,device:device) else{return}
                defer{peer.busy=false;peer.commandTask=nil}
                let response=await self.model.handle(command,device:device,body:plain,additionalAuthorization:{[weak self,weak peer] in
                    guard let self,let peer else{return false};return self.commandAuthorized(peer,device:device)
                })
                guard self.commandAuthorized(peer,device:device) else{return}
                do { var object=try WireJSON.object(WireJSON.encoder.encode(response));object["snapshot"]=self.model.snapshot();try self.sendPrivate(object,peer:peer) } catch { self.drop(peer.peripheral.identifier,ban:true) }
            }
            return
        }
        switch type {
        case "pair":
            guard peers.values.filter({$0.handshake != nil}).count<4 else{throw CompanionError.limit}
            let r=try WireJSON.decoder.decode(PairRequest.self,from:data)
            guard !model.devices.contains(where:{$0.deviceId==r.deviceId}) else{throw CompanionError.unauthorized}
            try model.pairing.request(r,peer:peer.peripheral.identifier.uuidString,now:Date());model.pairingChanged();try send(["type":"pair_pending"],peer:peer)
        case "hello":
            guard peer.handshake==nil,peers.values.filter({$0.handshake != nil}).count<4,
                  (object["version"] as? Int)==1,(object["macId"] as? String)==model.macId,
                  let device=object["deviceId"] as? String,let nonce=object["clientNonce"] as? String,
                  model.isAuthorized(device),let credential=model.devices.first(where:{$0.deviceId==device}) else{throw CompanionError.unauthorized}
            let handshake=try ServerHandshake(mac:model.macId,device:device,clientNonce:nonce,key:credential.key,now:Date());peer.handshake=handshake;peer.device=device
            try send(handshake.challenge,peer:peer)
        case "authenticate":
            guard let handshake=peer.handshake,let proof=object["proof"] as? String,model.isAuthorized(handshake.deviceId) else{throw CompanionError.unauthorized}
            peer.channel=try handshake.authenticate(proof:proof,now:Date());try peer.session.authenticate();peer.handshake=nil;peer.authenticatedAt=Date()
            bluetoothLog.notice("Nearby authentication completed")
            try sendPrivate(["type":"ready","macId":model.macId,"deviceId":handshake.deviceId,"serverTime":WireJSON.iso(Date())],peer:peer)
            model.deviceBecameNearby(handshake.deviceId)
        default:throw CompanionError.unauthorized
        }
    }
    func approvePending()throws {
        guard let pending=model.pairing.pending,let id=UUID(uuidString:pending.peer),let peer=peers[id],current(peer),peer.session.ready else{throw CompanionError.unavailable}
        let device=try model.pairing.approve(now:Date())
        try model.addDevice(device)
        try send(["type":"paired","macId":model.macId,"deviceId":device.deviceId,"proof":WireCrypto.hmac(key:device.key,text:"paired\n"+model.macId+"\n"+device.deviceId).base64EncodedString()],peer:peer)
        model.pairingChanged()
    }
    func denyPending(){if let p=model.pairing.pending,let id=UUID(uuidString:p.peer),let peer=peers[id]{try? send(["type":"pair_denied"],peer:peer)};model.pairing.deny();model.pairingChanged()}
    func revoke(_ device:String){for (id,peer) in peers where peer.device==device{drop(id,ban:false)}}
    func tick(){
        let now=Date(),stamp=now.timeIntervalSince1970,uptime=ProcessInfo.processInfo.systemUptime
        banned=banned.filter{$0.value>now};retryAfter=retryAfter.filter{$0.value>uptime}
        for (id,peer) in Array(peers) {
            do{try peer.decoder.checkTimeout(now:stamp)}catch{drop(id,ban:true);continue}
            if peer.session.expired(now:uptime) || peer.queue.expired(now:uptime){drop(id,ban:false)}
            else if let device=peer.device,!model.isAuthorized(device){drop(id,ban:false)}
            else if let handshake=peer.handshake,now>=handshake.expires{drop(id,ban:true)}
            else if let authenticated=peer.authenticatedAt,now.timeIntervalSince(authenticated)>3600{drop(id,ban:false)}
            else if peer.channel==nil,now.timeIntervalSince(peer.connectedAt)>360{drop(id,ban:false)}
        }
        if let p=model.pairing.pending,now>=p.expires{denyPending()}
        model.pairing.expire(now:now)
        // Cancellation itself has a deadline. A missing disconnect completion
        // must not strand all discovery slots or allow old callbacks to attach
        // to a replacement connection on the same peripheral object.
        if retiring.values.contains(where:{uptime-$0.since>=15}),manager?.state == .poweredOn{stop();start();return}
        if uptime>=nextDiscovery{discover()}
    }
    func sendRelayConfiguration(device:String,url:String,authTicket:String){
        guard model.isAuthorized(device) else{return}
        for (id,peer) in peers where peer.device==device && peer.channel != nil{do{try sendPrivate(["type":"relay_config","url":url,"enabled":true,"authTicket":authTicket],peer:peer)}catch{drop(id,ban:true)}}
    }
    func sendInternetConfiguration(device:String,configuration:InternetConfiguration){
        guard let payload=try? WireJSON.object(configuration.encoded()) else{return}
        for (id,peer) in peers where peer.device==device && peer.channel != nil {
            do{try sendPrivate(payload,peer:peer)}catch{drop(id,ban:true)}
        }
    }
    func sendEvent(_ event:CompanionEvent,device:String){
        guard model.isAuthorized(device),Date().timeIntervalSince(event.createdAt)<300,let payload=try? WireJSON.object(WireJSON.encoder.encode(event)) else{return}
        for (id,peer) in peers where peer.device==device && peer.channel != nil{do{try sendPrivate(["type":"event","event":payload],peer:peer)}catch{drop(id,ban:true)}}
    }
    func broadcast(_ event:CompanionEvent){guard let payload=try? WireJSON.object(WireJSON.encoder.encode(event)) else{return};for (id,peer) in peers where peer.channel != nil && peer.device.map(model.isAuthorized)==true {do{try sendPrivate(["type":"event","event":payload],peer:peer)}catch{drop(id,ban:true)}}}
    private func sendPrivate(_ object:[String:Any],peer:Peer)throws {guard current(peer),peer.session.authorized,let c=peer.channel,let device=peer.device,model.isAuthorized(device) else{throw CompanionError.unauthorized};let record=try c.seal(WireJSON.data(object));try send(record,peer:peer)}
    private func send<T:Encodable>(_ object:T,peer:Peer)throws {try enqueue(WireJSON.encoder.encode(object),peer:peer)}
    private func send(_ object:[String:Any],peer:Peer)throws {try enqueue(WireJSON.data(object),peer:peer)}
    private func enqueue(_ data:Data,peer:Peer)throws{
        guard current(peer),peer.session.ready else{throw CompanionError.closed}
        try peer.queue.enqueue(record:data,mtu:peer.peripheral.maximumWriteValueLength(for:.withResponse));flush(peer)
    }
    private func flush(_ peer:Peer){
        guard current(peer),peer.session.ready,let output=peer.output,
              let next=peer.queue.take(now:ProcessInfo.processInfo.systemUptime) else{return}
        peer.peripheral.writeValue(next,for:output,type:.withResponse)
    }
    private func invalidate(_ peer:Peer){
        peer.session.invalidate();peer.commandTask?.cancel();peer.commandTask=nil
        peer.channel?.close();peer.channel=nil;peer.handshake=nil;peer.queue.invalidate()
        peer.peripheral.delegate=nil;peer.owner=nil
    }
    private func drop(_ id:UUID,ban:Bool,cancel:Bool=true){
        guard let peer=peers.removeValue(forKey:id) else{return}
        let authenticated=peer.channel != nil
        invalidate(peer)
        if cancel,let manager,manager.state == .poweredOn{retiring[id]=(peer.peripheral,ProcessInfo.processInfo.systemUptime);manager.cancelPeripheralConnection(peer.peripheral)}
        let now=Date()
        if retryAfter.count<64{retryAfter[id]=ProcessInfo.processInfo.systemUptime+3}
        if ban{if banned.count<64{banned[id]=now.addingTimeInterval(60)}else{globallyBlockedUntil=now.addingTimeInterval(60)}}
        model.connectionCount=peers.values.filter{$0.session.ready}.count
        if authenticated{model.nearbyChanged()}
        if model.pairing.pending?.peer==id.uuidString{model.pairing.deny();model.pairingChanged()}
        if manager?.state == .poweredOn,model.connectionCount==0{model.bluetoothState="Searching for nearby phones…"}
    }
}
