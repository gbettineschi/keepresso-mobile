import Foundation
import Testing
@testable import CompanionCore

/// Explicit owner-relay integration fixture. Never imports the native app or power adapters.
struct LiveRelayFixtureTests {
    @MainActor @Test func syntheticMacForAndroidInternetAcceptance()async throws{
        guard let path=ProcessInfo.processInfo.environment["KEEPRESSO_LIVE_FIXTURE_CONFIG"] else{return}
        let url=URL(fileURLWithPath:path),config=try WireJSON.object(Data(contentsOf:url))
        let mac=try #require(config["macId"] as? String),device=try #require(config["deviceId"] as? String)
        let bearerPath=try #require(config["bearerPath"] as? String),relayURL=try #require(config["url"] as? String)
        let key=try WireCrypto.bytes32(try #require(config["key"] as? String))
        let bearer=try String(contentsOfFile:bearerPath,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        let credential=AuthorizedDevice(deviceId:device,name:"Disposable Android fixture",key:key,approvedAt:Date())
        let directory=url.deletingLastPathComponent().appendingPathComponent("live-journal")
        let api=RelayHTTPClient(configuration:try RelayConfiguration(url:relayURL,macBearer:bearer))
        let journal=try MutationJournal(url:directory.appendingPathComponent("mutations")),outbox=try RelayOutbox(url:directory.appendingPathComponent("outbox"))
        let executor=MutationExecutor(journal:journal)
        var effects=0,active=false,paused=true
        var samples:[Double]=[]
        func snapshot()->[String:Any]{[
            "capturedAt":WireJSON.iso(Date()),"macName":"Synthetic internet Mac","fixtureStartCount":effects,
            "mac":["lock":"locked","display":"off","lid":"closed","batteryPercent":83,"powerSource":"ac","isCharging":false,"temperatureC":63,"temperatureSensor":"Fixture","thermal":"normal"],
            "keepresso":["appRunning":true,"version":"1.27.0","isActive":active,"endsAt":NSNull(),"triggersEnabled":true,"triggersPaused":paused,"sessionKind":active ? "manual":"unknown","safetyPause":"none"],
            "capabilities":["startManual":true,"stopManual":true,"pauseTriggers":false,"resumeTriggers":false,"sleepNow":false,"refreshTriggers":false],
            "triggers":["state":"not_checked","checkedAt":NSNull(),"combined":NSNull(),"rules":[],"message":NSNull()],
            "reminders":["enabled":true,"intervalSeconds":3600,"endedAwakeDelaySeconds":300,"snoozedUntil":NSNull()]
        ]}
        let coordinator=try RelayCoordinator(macId:mac,api:api,outbox:outbox,devices:{[credential]},nearby:{[]},snapshot:snapshot,execute:{request,device,body,rejection in
            await executor.execute(request,device:device,body:body,now:Date(),authorized:{true},rejection:rejection){
                switch request.action{case "start_manual":effects+=1;active=true;paused=true;case "stop_manual":active=false;default:break}
                return CommandResponse(id:request.id,status:"ok")
            }
        })
        let ticket=try RelayEnvelope.accessTicket(macBearer:bearer,deviceKey:key,macId:mac,deviceId:device)
        var phone=config;phone.removeValue(forKey:"bearerPath");phone["authTicket"]=ticket
        try WireJSON.data(phone).write(to:url.deletingLastPathComponent().appendingPathComponent("phone.json"),options:.atomic)
        let end=Date()+150
        repeat{
            let start=Date();await coordinator.tick();samples.append(Date().timeIntervalSince(start))
            if FileManager.default.fileExists(atPath:url.deletingLastPathComponent().appendingPathComponent("done").path){break}
            try await Task.sleep(for:.seconds(1))
        }while Date()<end
        await coordinator.revoke(device);coordinator.stop()
        try WireJSON.data(["effects":effects,"syncSeconds":samples.filter{$0>0.01},"revoked":true]).write(to:url.deletingLastPathComponent().appendingPathComponent("mac-report.json"),options:.atomic)
        #expect(effects==1)
    }
}
