import Foundation
import CompanionCore
import IrohLib

private final class InternetProtocol: ProtocolCreator, ProtocolHandler, @unchecked Sendable {
    weak var server:IrohServer?
    init(_ server:IrohServer){self.server=server}
    func create(endpoint:Endpoint)->ProtocolHandler {self}
    func accept(conn:Connection)async throws {await server?.accept(conn)}
    func shutdown()async {}
}

@MainActor private final class InternetOutput {
    private let stream:SendStream
    private let connection:Connection
    private var tail:Task<Void,Error>?
    private var bytes=0
    init(stream:SendStream,connection:Connection){self.stream=stream;self.connection=connection}
    func enqueue(_ record:Data)throws {
        let framed=try FrameDecoder.frame(record)
        guard bytes+framed.count<=262_144 else{throw CompanionError.limit}
        bytes+=framed.count
        let previous=tail
        tail=Task{
            defer{self.bytes-=framed.count}
            do{try await previous?.value;try await self.stream.writeAll(buf:framed)}
            catch{try? self.connection.close(errorCode:1,reason:Data());throw error}
        }
    }
    func flush()async throws{try await tail?.value}
}

/// No wake assertions or native actions. The router owns concurrent TLS acceptance.
@MainActor public final class IrohServer {
    public static let alpn=Data("keepresso-mobile/iroh/1".utf8)
    private let admission=InternetAdmission()
    private var endpoint:Endpoint?
    private var generation=UUID()
    private var connections:[UUID:Connection]=[:]
    private var sessions:[UUID:InternetSession]=[:]
    private var outputs:[UUID:InternetOutput]=[:]
    private var factory:(()throws->InternetSession)?
    private var online:Task<Void,Never>?
    public private(set) var endpointId:String?

    private let endpointOptions:(Data)->EndpointOptions
    public init(endpointOptions:@escaping (Data)->EndpointOptions = {seed in
        EndpointOptions(preset:presetN0(),secretKey:seed,relayMode:RelayMode.defaultMode())
    }){self.endpointOptions=endpointOptions}

    public func start(seed:Data,sessionFactory:@escaping ()throws->InternetSession,stateChanged:@escaping(String)->Void,configured:@escaping()->Void)async throws {
        guard seed.count==32 else{throw CompanionError.invalid}
        stop()
        let token=generation
        factory=sessionFactory
        var options=endpointOptions(seed)
        options.secretKey=seed;options.alpns=[Self.alpn];options.protocols=[Self.alpn:InternetProtocol(self)]
        let bound=try await Endpoint.bind(options:options)
        guard generation==token,!Task.isCancelled else{try? await bound.close();throw CompanionError.closed}
        endpoint=bound;endpointId=bound.id().toBytes().base64EncodedString()
        configured();stateChanged("Connecting to Internet…")
        online=Task{[weak self] in
            await bound.online()
            guard let self,self.generation==token,!Task.isCancelled else{return}
            stateChanged("Internet ready. Nearby is preferred.")
        }
    }
    public func stop() {
        generation=UUID();online?.cancel();online=nil;factory=nil
        admission.invalidate()
        sessions.values.forEach{$0.close()};sessions.removeAll();outputs.removeAll()
        connections.values.forEach{try? $0.close(errorCode:0,reason:Data("Connection closed".utf8))};connections.removeAll()
        if let endpoint {Task{try? await endpoint.close()}}
        endpoint=nil;endpointId=nil
    }
    public func broadcast(_ event:CompanionEvent){
        for (id,session) in sessions where session.ready {
            guard let output=outputs[id] else{continue}
            do{_=try session.eventRecord(event,emit:{try output.enqueue($0)})}
            catch{session.close();try? connections[id]?.close(errorCode:1,reason:Data())}
        }
    }
    public func revoke(_ device:String) {
        // The session rechecks the current device key and authorization before
        // and after every await. Close every connection to remove stale proofs.
        for (id,connection) in connections {sessions[id]?.close();try? connection.close(errorCode:0,reason:Data())}
    }
    fileprivate func accept(_ connection:Connection)async {
        guard let factory,let id=try? admission.acquire() else{
            try? connection.close(errorCode:1,reason:Data("Unavailable".utf8));return
        }
        guard let session=try? factory() else{admission.release(id);try? connection.close(errorCode:1,reason:Data());return}
        let token=generation
        connections[id]=connection;sessions[id]=session
        defer {session.close();sessions.removeValue(forKey:id);connections.removeValue(forKey:id);outputs.removeValue(forKey:id);admission.release(id);try? connection.close(errorCode:0,reason:Data())}
        await withTaskGroup(of:Void.self){group in
            group.addTask{await self.serve(connection,id:id,session:session,generation:token)}
            group.addTask{
                while !Task.isCancelled {
                    do{try await Task.sleep(for:.milliseconds(250))}catch{return}
                    guard await self.valid(id,generation:token) else{try? connection.close(errorCode:1,reason:Data("Expired".utf8));return}
                }
            }
            await group.next()
            session.close();try? connection.close(errorCode:0,reason:Data());group.cancelAll()
        }
    }
    private func valid(_ id:UUID,generation:UUID)->Bool {self.generation==generation && admission.valid(id)}
    private func record(_ input:RecvStream,id:UUID)async throws->Data {
        // Start the partial-frame deadline at its very first byte.
        let first=try await input.readExact(size:1);admission.partial(id)
        let tail=try await input.readExact(size:3)
        let count=(first+tail).reduce(UInt32(0)){($0<<8)|UInt32($1)}
        guard count>0,count<=65_536 else{throw CompanionError.limit}
        let data=try await input.readExact(size:count)
        guard admission.valid(id) else{throw CompanionError.expired}
        admission.activity(id);return data
    }
    private func serve(_ connection:Connection,id:UUID,session:InternetSession,generation:UUID)async {
        do {
            let stream=try await connection.acceptBi();try admission.openStream(id)
            let output=InternetOutput(stream:stream.send(),connection:connection);outputs[id]=output
            await withTaskGroup(of:Void.self){group in
                group.addTask {
                    // A second stream invalidates this connection, rather than
                    // creating a second application cipher or command queue.
                    do{_=try await connection.acceptBi();try? connection.close(errorCode:1,reason:Data("One stream only".utf8))}catch{}
                }
                group.addTask {
                    do {
                        var authenticated=false
                        while await self.valid(id,generation:generation),!Task.isCancelled {
                            let record=try await self.record(stream.recv(),id:id)
                            _=try await session.receive(record,emit:{record in try output.enqueue(record)})
                            guard await self.valid(id,generation:generation) else{throw CompanionError.closed}
                            if await session.ready,!authenticated{try await self.admission.authenticate(id);authenticated=true}
                            try await output.flush()
                        }
                    }catch{}
                }
                await group.next();try? connection.close(errorCode:0,reason:Data());group.cancelAll()
            }
        }catch{}
    }
}
