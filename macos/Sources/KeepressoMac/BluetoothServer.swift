import Foundation
import CoreBluetooth
import CompanionCore
import OSLog

private let bluetoothLog=Logger(subsystem:"local.keespresso.companion",category:"bluetooth")

@MainActor final class BluetoothServer: NSObject, @preconcurrency CBPeripheralManagerDelegate {
    static let service=CBUUID(string:"73f8d1c0-823f-4c2f-9e0a-4454129f3001")
    static let input=CBUUID(string:"73f8d1c0-823f-4c2f-9e0a-4454129f3002")
    static let output=CBUUID(string:"73f8d1c0-823f-4c2f-9e0a-4454129f3003")
    final class Peer {
        let central:CBCentral;let decoder=FrameDecoder();let queue=NotificationQueue()
        var handshake:ServerHandshake?;var channel:SealedChannel?;var device:String?;var authenticatedAt:Date?;var busy=false;let connectedAt=Date()
        init(_ central:CBCentral){self.central=central}
    }
    private var manager:CBPeripheralManager?;private var notify:CBMutableCharacteristic?
    private var peers:[UUID:Peer]=[:];private var banned:[UUID:Date]=[:];private var globallyBlockedUntil=Date.distantPast
    let model:CompanionModel
    init(model:CompanionModel){self.model=model;super.init()}
    func start(){guard manager==nil else{return};manager=CBPeripheralManager(delegate:self,queue:.main,options:[CBPeripheralManagerOptionShowPowerAlertKey:false])}
    var authenticatedDevices:Set<String>{Set(peers.values.compactMap{peer in guard peer.channel != nil,let device=peer.device,model.isAuthorized(device) else{return nil};return device})}
    func stop(){manager?.stopAdvertising();manager?.removeAllServices();manager?.delegate=nil;manager=nil;peers.values.forEach{$0.channel?.close()};peers.removeAll();notify=nil;model.connectionCount=0;model.nearbyChanged()}
    func peripheralManagerDidUpdateState(_ peripheral:CBPeripheralManager){
        guard peripheral === manager,model.nativeRunning else{return}
        model.bluetoothState=String(describing:peripheral.state)
        bluetoothLog.info("Peripheral state \(peripheral.state.rawValue,privacy:.public)")
        guard peripheral.state == .poweredOn else { peers.removeAll();return }
        let input=CBMutableCharacteristic(type:Self.input,properties:[.write],value:nil,permissions:[.writeable])
        let output=CBMutableCharacteristic(type:Self.output,properties:[.notify],value:nil,permissions:[])
        notify=output;let service=CBMutableService(type:Self.service,primary:true);service.characteristics=[input,output];peripheral.add(service)
    }
    func peripheralManager(_ peripheral:CBPeripheralManager,didAdd service:CBService,error:Error?){guard peripheral === manager,model.nativeRunning else{return};guard error==nil else{model.bluetoothState="Bluetooth service unavailable";return};peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey:[Self.service],CBAdvertisementDataLocalNameKey:"Keepresso Mobile"])}
    func peripheralManager(_ peripheral:CBPeripheralManager,central:CBCentral,didSubscribeTo characteristic:CBCharacteristic){
        guard peripheral === manager,model.nativeRunning else{return}
        guard characteristic.uuid==Self.output,peers.count<8,banned[central.identifier].map({$0>Date()}) != true else{return}
        peers[central.identifier]=Peer(central);model.connectionCount=peers.count
        bluetoothLog.info("Nearby subscription established")
    }
    func peripheralManager(_ peripheral:CBPeripheralManager,central:CBCentral,didUnsubscribeFrom characteristic:CBCharacteristic){guard peripheral === manager else{return};drop(central.identifier,ban:false)}
    func peripheralManager(_ peripheral:CBPeripheralManager,didReceiveWrite requests:[CBATTRequest]){
        guard peripheral === manager,model.nativeRunning else{if let first=requests.first{peripheral.respond(to:first,withResult:.insufficientAuthorization)};return}
        guard requests.count==1,let first=requests.first else{if let first=requests.first{peripheral.respond(to:first,withResult:.insufficientResources)};return}
        guard Date()>=globallyBlockedUntil else{peripheral.respond(to:first,withResult:.insufficientAuthorization);return}
        for request in requests {
            let id=request.central.identifier
            guard request.characteristic.uuid==Self.input,request.offset==0,let peer=peers[id],banned[id].map({$0>Date()}) != true,let data=request.value else{peripheral.respond(to:request,withResult:.insufficientAuthorization);continue}
            do {
                let records=try peer.decoder.feed(data,now:Date().timeIntervalSince1970)
                for record in records { try receive(record,peer:peer) }
                peripheral.respond(to:request,withResult:.success)
            } catch { peripheral.respond(to:request,withResult:.unlikelyError);drop(id,ban:true) }
        }
    }
    func receive(_ data:Data,peer:Peer)throws {
        guard !peer.busy else{throw CompanionError.limit}
        let object=try WireJSON.object(data);let type=object["type"] as? String
        if let channel=peer.channel {
            guard let device=peer.device,model.isAuthorized(device) else{throw CompanionError.unauthorized}
            let record=try WireJSON.decoder.decode(SealedRecord.self,from:data)
            let plain=try channel.open(record)
            let command=try WireJSON.decoder.decode(CommandRequest.self,from:plain)
            try command.validate(now:Date())
            guard let device=peer.device else{throw CompanionError.unauthorized}
            peer.busy=true
            Task { @MainActor [weak self,weak peer] in
                guard let self,let peer else{return}
                let response=await self.model.handle(command,device:device,body:plain)
                defer{peer.busy=false}
                guard self.peers[peer.central.identifier] === peer,self.model.isAuthorized(device) else{return}
                do { var object=try WireJSON.object(WireJSON.encoder.encode(response));object["snapshot"]=self.model.snapshot();try self.sendPrivate(object,peer:peer) } catch { self.drop(peer.central.identifier,ban:true) }
            }
            return
        }
        switch type {
        case "pair":
            guard peers.values.filter({$0.handshake != nil}).count<4 else{throw CompanionError.limit}
            let r=try WireJSON.decoder.decode(PairRequest.self,from:data)
            guard !model.devices.contains(where:{$0.deviceId==r.deviceId}) else{throw CompanionError.unauthorized}
            try model.pairing.request(r,peer:peer.central.identifier.uuidString,now:Date());model.pairingChanged();try send(["type":"pair_pending"],peer:peer)
        case "hello":
            guard peer.handshake==nil,peers.values.filter({$0.handshake != nil}).count<4,
                  (object["version"] as? Int)==1,(object["macId"] as? String)==model.macId,
                  let device=object["deviceId"] as? String,let nonce=object["clientNonce"] as? String,
                  model.isAuthorized(device),let credential=model.devices.first(where:{$0.deviceId==device}) else{throw CompanionError.unauthorized}
            let handshake=try ServerHandshake(mac:model.macId,device:device,clientNonce:nonce,key:credential.key,now:Date());peer.handshake=handshake;peer.device=device
            try send(handshake.challenge,peer:peer)
        case "authenticate":
            guard let handshake=peer.handshake,let proof=object["proof"] as? String,model.isAuthorized(handshake.deviceId) else{throw CompanionError.unauthorized}
            peer.channel=try handshake.authenticate(proof:proof,now:Date());peer.handshake=nil;peer.authenticatedAt=Date()
            bluetoothLog.info("Nearby authentication completed")
            try sendPrivate(["type":"ready","macId":model.macId,"deviceId":handshake.deviceId,"serverTime":WireJSON.iso(Date())],peer:peer)
            model.deviceBecameNearby(handshake.deviceId)
        default:throw CompanionError.unauthorized
        }
    }
    func approvePending()throws {
        guard let pending=model.pairing.pending,let id=UUID(uuidString:pending.peer),let peer=peers[id] else{throw CompanionError.unavailable}
        let device=try model.pairing.approve(now:Date())
        try model.addDevice(device)
        try send(["type":"paired","macId":model.macId,"deviceId":device.deviceId,"proof":WireCrypto.hmac(key:device.key,text:"paired\n"+model.macId+"\n"+device.deviceId).base64EncodedString()],peer:peer)
        model.pairingChanged()
    }
    func denyPending(){if let p=model.pairing.pending,let id=UUID(uuidString:p.peer),let peer=peers[id]{try? send(["type":"pair_denied"],peer:peer)};model.pairing.deny();model.pairingChanged()}
    func revoke(_ device:String){for (id,peer) in peers where peer.device==device{drop(id,ban:false)}}
    func tick(){
        let now=Date()
        banned=banned.filter{$0.value>now}
        for (id,peer) in peers {
            do{try peer.decoder.checkTimeout(now:now.timeIntervalSince1970)}catch{drop(id,ban:true);continue}
            if let handshake=peer.handshake,now>=handshake.expires {drop(id,ban:true)}
            else if let authenticated=peer.authenticatedAt,now.timeIntervalSince(authenticated)>3600 {drop(id,ban:false)}
            else if peer.channel==nil,now.timeIntervalSince(peer.connectedAt)>360 {drop(id,ban:false)}
        }
        if let p=model.pairing.pending,now>=p.expires{denyPending()}
        model.pairing.expire(now:now)
    }
    func sendRelayConfiguration(device:String,url:String,authTicket:String){
        guard model.isAuthorized(device) else{return}
        for (id,peer) in peers where peer.device==device && peer.channel != nil{do{try sendPrivate(["type":"relay_config","url":url,"enabled":true,"authTicket":authTicket],peer:peer)}catch{drop(id,ban:true)}}
    }
    func sendEvent(_ event:CompanionEvent,device:String){
        guard model.isAuthorized(device),Date().timeIntervalSince(event.createdAt)<300,let payload=try? WireJSON.object(WireJSON.encoder.encode(event)) else{return}
        for (id,peer) in peers where peer.device==device && peer.channel != nil{do{try sendPrivate(["type":"event","event":payload],peer:peer)}catch{drop(id,ban:true)}}
    }
    func broadcast(_ event:CompanionEvent){guard let payload=try? WireJSON.object(WireJSON.encoder.encode(event)) else{return};for (id,peer) in peers where peer.channel != nil && peer.device.map(model.isAuthorized)==true {do{try sendPrivate(["type":"event","event":payload],peer:peer)}catch{drop(id,ban:true)}}}
    private func sendPrivate(_ object:[String:Any],peer:Peer)throws {guard let c=peer.channel,let device=peer.device,model.isAuthorized(device) else{throw CompanionError.unauthorized};let record=try c.seal(WireJSON.data(object));try send(record,peer:peer)}
    private func send<T:Encodable>(_ object:T,peer:Peer)throws {try enqueue(WireJSON.encoder.encode(object),peer:peer)}
    private func send(_ object:[String:Any],peer:Peer)throws {try enqueue(WireJSON.data(object),peer:peer)}
    private func enqueue(_ data:Data,peer:Peer)throws {try peer.queue.enqueue(record:data,mtu:peer.central.maximumUpdateValueLength);flush()}
    private func flush(){guard let manager,let notify else{return};for peer in peers.values {while let next=peer.queue.next {guard manager.updateValue(next,for:notify,onSubscribedCentrals:[peer.central]) else{return};peer.queue.accepted()}}}
    func peripheralManagerIsReady(toUpdateSubscribers peripheral:CBPeripheralManager){flush()}
    private func drop(_ id:UUID,ban:Bool){let authenticated=peers[id]?.channel != nil;peers[id]?.channel?.close();peers.removeValue(forKey:id);if authenticated{model.nearbyChanged()};model.connectionCount=peers.count;if ban{if banned.count<64{banned[id]=Date().addingTimeInterval(60)}else{globallyBlockedUntil=Date().addingTimeInterval(60)}};if model.pairing.pending?.peer==id.uuidString{model.pairing.deny();model.pairingChanged()}}
}
