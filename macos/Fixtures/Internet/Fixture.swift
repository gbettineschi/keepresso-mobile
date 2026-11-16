import Foundation
import Network
import CompanionCore
import IrohLib
import IrohTransport

// Separate executable with public synthetic authorization and injected actions only.
// Never imports native observation, app lifecycle, Accessibility or power code.
@MainActor final class Fixture {
    let mac="11111111-1111-4111-8111-111111111111"
    let device="22222222-2222-4222-8222-222222222222"
    let key=Data(repeating:0x42,count:32)
    let server:IrohServer
    let executor:MutationExecutor
    let root:URL
    var mutations=0
    var listener:NWListener?
    init(root:URL,relay:Bool)throws {
        self.root=root
        executor=MutationExecutor(journal:try MutationJournal(url:root.appendingPathComponent("mutations.json")))
        server=IrohServer(endpointOptions:{seed in EndpointOptions(preset:relay ? LoopbackRelay():presetN0(),bindAddr:relay ? "127.0.0.1:0":nil,secretKey:seed)})
    }
    func snapshot()->[String:Any] {
        let now=Date()
        let event=try! WireJSON.decoder.decode(CompanionEvent.self,from:WireJSON.data(["id":UUID().uuidString.lowercased(),"kind":"hourly","createdAt":WireJSON.iso(now),"title":"Production fixture reminder","body":"Synthetic encrypted delivery"]))
        let payload=try! WireJSON.data(["type":"event","event":WireJSON.object(WireJSON.encoder.encode(event))])
        let envelope=try! RelayEnvelope.seal(payload,key:key,macId:mac,deviceId:device,id:event.id,epoch:device,direction:"s2c",kind:"event",now:now,lifetime:300)
        return ["capturedAt":WireJSON.iso(now),"fixtureMutationCount":mutations,"fixtureEnvelope":try! WireJSON.object(WireJSON.encoder.encode(envelope))]
    }
    func session()throws->InternetSession {
        let approved=try WireJSON.decoder.decode(AuthorizedDevice.self,from:WireJSON.data(["deviceId":device,"name":"Public fixture","key":key.base64EncodedString(),"approvedAt":WireJSON.iso(Date())]))
        return try InternetSession(macId:mac,lookupDevice:{$0==self.device ? approved:nil},authorized:{$0==self.device},configuration:{
            guard let id=self.server.endpointId else{return nil}
            return try? InternetConfiguration(endpointId:id)
        },execute:{r,d,b,valid in
            await self.executor.execute(r,device:d,body:b,now:Date(),authorized:valid){
                if r.isMutation{self.mutations+=1;await Task.yield()}
                return CommandResponse(id:r.id,status:"ok",message:"Synthetic native action only")
            }
        },registerPush:{_,_ in throw CompanionError.unavailable},snapshot:{self.snapshot()})
    }
    func start(port:UInt16,ready:URL)async throws {
        let seed=try PrivateInternetState(url:root.appendingPathComponent("identity/seed.json")).loadOrCreateSeed()
        try await server.start(seed:seed,sessionFactory:{try self.session()},stateChanged:{state in print("Fixture transport: \(state)");fflush(stdout)},configured:{})
        let params=NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!)
        let listener=try NWListener(using:params)
        self.listener=listener
        listener.newConnectionHandler={connection in Task{@MainActor in await self.bootstrap(connection)}}
        try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in
            listener.stateUpdateHandler={state in
                switch state {
                case .ready:listener.stateUpdateHandler=nil;continuation.resume()
                case .failed(let error):listener.stateUpdateHandler=nil;continuation.resume(throwing:error)
                default:break
                }
            }
            listener.start(queue:DispatchQueue(label:"keepresso.fixture.bootstrap"))
        }
        let record:[String:Any]=["bootstrapPort":port,"endpointId":server.endpointId!,"synthetic":true]
        try WireJSON.data(record).write(to:ready,options:.atomic)
    }
    private func bootstrap(_ connection:NWConnection)async {
        connection.start(queue:DispatchQueue(label:"keepresso.fixture.peer"))
        let deadline=Task{try? await Task.sleep(for:.seconds(25));connection.cancel()}
        defer{deadline.cancel();connection.cancel()}
        do {
            let session=try session(),decoder=FrameDecoder()
            defer{session.close()}
            while !Task.isCancelled {
                let bytes:Data=try await withCheckedThrowingContinuation{continuation in
                    connection.receive(minimumIncompleteLength:1,maximumLength:65_540){data,_,_,error in
                        if let error{continuation.resume(throwing:error)}
                        else if let data,!data.isEmpty{continuation.resume(returning:data)}
                        else{continuation.resume(throwing:CompanionError.closed)}
                    }
                }
                for request in try decoder.feed(bytes,now:ProcessInfo.processInfo.systemUptime){
                    let reply=try FrameDecoder.frame(await session.receive(request))
                    try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in
                        connection.send(content:reply,completion:.contentProcessed{error in
                            if let error{continuation.resume(throwing:error)}else{continuation.resume()}
                        })
                    }
                }
            }
        }catch{}
    }
}
private final class LoopbackRelay:Preset {
    func apply(builder:EndpointBuilder){builder.applyN0();try! builder.bindAddr(addr:"[::1]:0")}
}
@main struct InternetFixture {
    static func main()async throws {
        let args=CommandLine.arguments
        if ProcessInfo.processInfo.environment["KEEPRESSO_FIXTURE_TRACE"]=="1"{setLogLevel(level:.debug)}
        guard args.count==5,["auto","relay"].contains(args[1]),let port=UInt16(args[3]) else{throw CompanionError.invalid}
        let fixture=try Fixture(root:URL(fileURLWithPath:args[2]),relay:args[1]=="relay")
        try await fixture.start(port:port,ready:URL(fileURLWithPath:args[4]))
        try await Task.sleep(for:.seconds(600))
    }
}
