import Foundation

/// Naturally-awake polling only. The app's existing timer calls tick; this class
/// creates no timer, observer worker, Bluetooth manager or power assertion.
@MainActor public final class RelayCoordinator {
    public private(set) var epoch:String
    public private(set) var status="Internet configured; waiting for relay contact."
    private let macId:String;private let api:RelayAPI;private let outbox:RelayOutbox
    private let devices:()->[AuthorizedDevice];private let nearby:()->Set<String>;private let snapshot:()->[String:Any]
    private let execute:(CommandRequest,String,Data,String?)async->CommandResponse
    private let now:()->Date;private let monotonic:()->TimeInterval;private let enrolled:(String)->Void
    private var active=true,busy=false;private var enrolledDevices:Set<String>=[];private var freshDevices:Set<String>=[]
    private var statusProofs:Set<String>=[];private var lastContact:TimeInterval?;private var epochStarted:TimeInterval
    private var nextPoll:TimeInterval=0;private var lastStates:[String:TimeInterval]=[:];private var revision:Int64=0
    private var foregroundUntil:[String:TimeInterval]=[:]
    public init(macId:String,api:RelayAPI,outbox:RelayOutbox,devices:@escaping()->[AuthorizedDevice],nearby:@escaping()->Set<String>,snapshot:@escaping()->[String:Any],execute:@escaping(CommandRequest,String,Data,String?)async->CommandResponse,now:@escaping()->Date=Date.init,monotonic:@escaping()->TimeInterval={ProcessInfo.processInfo.systemUptime},enrolled:@escaping(String)->Void={_ in})throws {
        guard WireCrypto.validID(macId) else{throw CompanionError.invalid}
        self.macId=macId;self.api=api;self.outbox=outbox;self.devices=devices;self.nearby=nearby;self.snapshot=snapshot;self.execute=execute;self.now=now;self.monotonic=monotonic;self.enrolled=enrolled
        epoch=UUID().uuidString.lowercased();epochStarted=monotonic()
    }
    public func stop(){active=false;freshDevices=[];statusProofs=[]}
    public func wake(){rotateEpoch();nextPoll=0}
    public func nearbyChanged(){let connected=nearby();lastStates=lastStates.filter{connected.contains($0.key)};nextPoll=0}
    public func isEnrolled(_ device:String)->Bool{active && enrolledDevices.contains(device) && authorized(device) != nil}
    public func enqueue(_ event:CompanionEvent)throws{guard active else{throw CompanionError.closed};try outbox.enqueue(event,devices:devices(),macId:macId,epoch:epoch,now:now())}
    public func pendingNearbyEvents(_ device:String)->[CompanionEvent]{guard authorized(device) != nil else{return []};return outbox.events(deviceId:device,epoch:epoch,now:now())}
    public func revoke(_ device:String)async {
        enrolledDevices.remove(device);freshDevices.remove(device);lastStates.removeValue(forKey:device);foregroundUntil.removeValue(forKey:device)
        try? outbox.revoke(device,now:now())
        try? await api.revoke(macId:macId,deviceId:device)
    }
    private func authorized(_ device:String)->AuthorizedDevice?{devices().first{$0.deviceId==device}}
    private func rotateEpoch(){epoch=UUID().uuidString.lowercased();epochStarted=monotonic();lastContact=nil;lastStates=[:];foregroundUntil=[:];freshDevices=[];statusProofs=[];revision=0}
    private func contactGap()->Bool{monotonic()-(lastContact ?? epochStarted)>=15}
    public func tick()async {
        guard active,!busy,monotonic()>=nextPoll else{return}
        busy=true;defer{busy=false}
        nextPoll=monotonic()+5
        if contactGap(){rotateEpoch()}
        let approved=devices();guard approved.count<=8 else{status="Internet supports at most eight authorized phones.";return}
        enrolledDevices.formIntersection(Set(approved.map(\.deviceId)))
        for device in approved where !enrolledDevices.contains(device.deviceId) {
            do {
                try await api.enroll(macId:macId,deviceId:device.deviceId,tokenHash:RelayEnvelope.phoneTokenHash(deviceKey:device.key,macId:macId,deviceId:device.deviceId))
                guard active,authorized(device.deviceId) != nil else{continue}
                enrolledDevices.insert(device.deviceId);enrolled(device.deviceId)
            }catch{status="Internet enrollment unavailable. Nearby pairing is retained."}
        }
        guard active else{return}
        if contactGap(){rotateEpoch()}
        let sentEpoch=epoch;let stamp=monotonic();let date=now();let remote=devices().filter{enrolledDevices.contains($0.deviceId) && !nearby().contains($0.deviceId)}
        var states:[RelayEnvelope]=[]
        do {
            if !remote.isEmpty {
                // Capture only the lightweight native snapshot. An explicit
                // refresh_triggers command is the only observer entry point.
                let due=remote.filter{stamp-(lastStates[$0.deviceId] ?? -Double.greatestFiniteMagnitude)>=(stamp<(foregroundUntil[$0.deviceId] ?? 0) ? 5:10)}
                if !due.isEmpty {
                    revision+=1
                    let body=try WireJSON.data(["type":"relay_state","epoch":sentEpoch,"revision":revision,"snapshot":snapshot()])
                    for device in due {states.append(try RelayEnvelope.seal(body,key:device.key,macId:macId,deviceId:device.deviceId,id:UUID().uuidString.lowercased(),epoch:sentEpoch,direction:"s2c",kind:"state",now:date,lifetime:15))}
                }
            }
            let pending=Array(outbox.pending(epoch:sentEpoch,devices:enrolledDevices.intersection(Set(devices().map(\.deviceId))),nearby:nearby(),now:date).prefix(16-states.count))
            let batch=RelayBatch(macId:macId,epoch:sentEpoch,states:states,responses:pending.filter{$0.kind=="response"},events:pending.filter{$0.kind=="event"})
            let result=try await api.sync(batch)
            guard active,epoch==sentEpoch else{return}
            // A request finishing after a sleep/network gap cannot grant authority
            // to a command queued under the previous reachability interval.
            if contactGap(){rotateEpoch();nextPoll=0;status="Internet contact resumed; renewing authorization freshness.";return}
            lastContact=monotonic();status="Internet connected. Nearby is preferred."
            for state in states where authorized(state.deviceId) != nil{lastStates[state.deviceId]=stamp}
            try outbox.uploaded(pending.filter{$0.kind != "event" || !result.retryEvents.contains($0.id)},now:now())
            for envelope in pending where envelope.kind=="response" && statusProofs.remove(envelope.id) != nil && authorized(envelope.deviceId) != nil{freshDevices.insert(envelope.deviceId)}
            guard result.commands.count<=16 else{throw CompanionError.limit}
            for envelope in result.commands {
                guard active,epoch==sentEpoch,!contactGap(),let device=authorized(envelope.deviceId),enrolledDevices.contains(device.deviceId) else{continue}
                do {
                    let body=try envelope.open(key:device.key,macId:macId,deviceId:device.deviceId,epoch:sentEpoch,direction:"c2s",kinds:["command"],now:now())
                    let request=try WireJSON.decoder.decode(CommandRequest.self,from:body)
                    guard request.id==envelope.id else{throw CompanionError.mismatch};try request.validate(now:now())
                    if try outbox.response(id:request.id,deviceId:device.deviceId,epoch:sentEpoch,body:body,now:now()) != nil{continue}
                    if request.action=="status"{foregroundUntil[device.deviceId]=monotonic()+65}
                    let rejection=request.isMutation && !freshDevices.contains(device.deviceId) ? "Refresh status through the internet connection before issuing controls.":nil
                    let response=await execute(request,device.deviceId,body,rejection)
                    guard active,epoch==sentEpoch,authorized(device.deviceId) != nil,!contactGap() else{continue}
                    var object=try WireJSON.object(WireJSON.encoder.encode(response));object["snapshot"]=snapshot()
                    let sealed=try RelayEnvelope.seal(WireJSON.data(object),key:device.key,macId:macId,deviceId:device.deviceId,id:request.id,epoch:sentEpoch,direction:"s2c",kind:"response",now:now(),lifetime:120)
                    try outbox.addResponse(sealed,body:body,now:now())
                    nextPoll=0
                    if request.action=="status",response.status=="ok"{statusProofs.insert(request.id)}
                    // The next app timer tick uploads the durable response. There
                    // is no command resend or recursive polling/execution path.
                }catch{continue} // malformed/expired routing reveals no plaintext
            }
        }catch{status="Internet unavailable; last-known readings remain on the phone.";if contactGap(){rotateEpoch()}}
    }
}
