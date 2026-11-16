import Foundation

/// The application authentication boundary, independent of iroh's encrypted transport.
/// Each connection gets its own cipher; all connections use the owner's shared executor.
@MainActor public final class InternetSession {
    public typealias Executor = (CommandRequest, String, Data, @escaping () -> Bool) async -> CommandResponse
    private struct Hello: Decodable {
        let type: String; let version: Int; let macId: String; let deviceId: String; let clientNonce: String
    }
    private struct Authentication: Decodable { let type: String; let proof: String }
    private let macId: String
    private let lookupDevice: (String) -> AuthorizedDevice?
    private let authorized: (String) -> Bool
    private let configuration: () -> InternetConfiguration?
    private let execute: Executor
    private let registerPush: (String, PushRegistration) throws -> PushRegistrationAck
    private let snapshot: () -> [String: Any]
    private let now: () -> Date
    private let monotonic: () -> TimeInterval
    private var handshake: ServerHandshake?
    private var device: AuthorizedDevice?
    private var cipher: SealedChannel?
    private var announced=false
    private var closed = false
    private var receiving = false
    private var statusAt: TimeInterval?
    public var ready: Bool { !closed && announced && cipher != nil && live() }

    public init(macId: String, lookupDevice: @escaping (String) -> AuthorizedDevice?, authorized: @escaping (String) -> Bool,
                configuration: @escaping () -> InternetConfiguration?, execute: @escaping Executor,
                registerPush: @escaping (String, PushRegistration) throws -> PushRegistrationAck,
                snapshot: @escaping () -> [String: Any], now: @escaping () -> Date = Date.init,
                monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        guard WireCrypto.validID(macId) else { throw CompanionError.invalid }
        self.macId=macId; self.lookupDevice=lookupDevice; self.authorized=authorized; self.configuration=configuration
        self.execute=execute; self.registerPush=registerPush; self.snapshot=snapshot; self.now=now; self.monotonic=monotonic
    }

    private func live() -> Bool {
        guard !closed, let device, authorized(device.deviceId), let current=lookupDevice(device.deviceId) else { return false }
        return current.key == device.key
    }
    public func close() { closed=true; announced=false;cipher?.close(); cipher=nil; handshake=nil; statusAt=nil }

    public func receive(_ data: Data, emit: (@MainActor (Data)throws->Void)? = nil) async throws -> Data {
        guard !closed, !receiving, data.count <= 65_536 else { close(); throw CompanionError.closed }
        receiving=true
        defer { receiving=false }
        do {
            let plain = try await process(data)
            // Encrypt and enqueue without an intervening await. Foreground
            // events may arrive while execute is suspended on a native read.
            let result = try cipher == nil ? plain : seal(plain)
            guard !closed, result.count <= 65_536 else { throw CompanionError.limit }
            try emit?(result)
            if cipher != nil {announced=true}
            return result
        } catch { close(); throw error }
    }

    private func process(_ data: Data) async throws -> Data {
        if device == nil {
            let hello=try WireJSON.decoder.decode(Hello.self,from:data)
            guard hello.type == "hello", hello.version == 1, hello.macId == macId,
                  let approved=lookupDevice(hello.deviceId), authorized(hello.deviceId) else { throw CompanionError.unauthorized }
            let challenge=try ServerHandshake(mac:macId,device:approved.deviceId,clientNonce:hello.clientNonce,key:approved.key,now:now())
            device=approved; handshake=challenge
            return try WireJSON.data(challenge.challenge)
        }
        guard live(), let device else { throw CompanionError.unauthorized }
        if cipher == nil {
            let auth=try WireJSON.decoder.decode(Authentication.self,from:data)
            guard auth.type == "authenticate", let handshake else { throw CompanionError.unauthorized }
            cipher=try handshake.authenticate(proof:auth.proof,now:now()); self.handshake=nil
            var ready: [String:Any] = ["type":"ready", "macId":macId, "deviceId":device.deviceId, "serverTime":WireJSON.iso(now())]
            if let config=configuration() { ready["internet"]=try WireJSON.object(config.encoded()) }
            return try WireJSON.data(ready)
        }
        guard let cipher else { throw CompanionError.closed }
        let plaintext=try cipher.open(WireJSON.decoder.decode(SealedRecord.self,from:data))
        let object=try WireJSON.object(plaintext)
        if object["type"] as? String == "push_registration" {
            let registration=try PushRegistration.decode(plaintext)
            do {
                guard configuration()?.firebase?.projectId == registration.projectId else { throw CompanionError.mismatch }
                let ack=try registerPush(device.deviceId,registration)
                guard live(), ack.matches(registration) else { throw CompanionError.unauthorized }
                return try WireJSON.encoder.encode(ack)
            } catch {
                guard live() else { throw CompanionError.unauthorized }
                return try WireJSON.data(["type":"push_registration_error", "message":"Notification registration is unavailable."])
            }
        }
        let request=try WireJSON.decoder.decode(CommandRequest.self,from:plaintext)
        try request.validate(now:now())
        let response: CommandResponse
        if request.isMutation && !fresh {
            response=CommandResponse(id:request.id,status:"error",message:"Refresh status before sending this command.")
        } else {
            response=await execute(request,device.deviceId,plaintext,{ [weak self] in
                guard let self else { return false }
                return self.live() && (!request.isMutation || self.fresh)
            })
        }
        guard live() else { throw CompanionError.unauthorized }
        if request.action == "status", response.status == "ok" { statusAt=monotonic() }
        var reply=try WireJSON.object(WireJSON.encoder.encode(response)); reply["snapshot"]=snapshot()
        return try WireJSON.data(reply)
    }
    public func eventRecord(_ event:CompanionEvent,emit:(@MainActor (Data)throws->Void)?=nil)throws->Data {
        guard ready,WireCrypto.validID(event.id),now().timeIntervalSince(event.createdAt)<300,event.createdAt.timeIntervalSince(now())<=10 else{throw CompanionError.closed}
        let record=try seal(WireJSON.data(["type":"event","event":WireJSON.object(WireJSON.encoder.encode(event))]))
        guard record.count<=65_536 else{throw CompanionError.limit}
        try emit?(record);return record
    }
    private var fresh: Bool {
        guard let statusAt else { return false }
        let age=monotonic()-statusAt
        return age >= 0 && age < 15
    }
    private func seal(_ data: Data) throws -> Data {
        guard live(), let cipher else { throw CompanionError.closed }
        return try WireJSON.encoder.encode(cipher.seal(data))
    }
}
