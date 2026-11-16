import Foundation
import CompanionCore
import IrohLib

// Public synthetic fixtures, NEVER the installed app's credentials or readings.
private let macID = "11111111-1111-4111-8111-111111111111"
private let deviceID = "22222222-2222-4222-8222-222222222222"
private let deviceKey = Data(repeating: 0x42, count: 32)
private let alpn = Data("keepresso-mobile/iroh-trial/1".utf8)

private func trace(_ message: String) {
    print("\(Date().timeIntervalSince1970) \(message)")
    fflush(stdout)
}

private actor Admission {
    private var count = 0
    private var sequence = 0
    func acquire() -> Int? {
        guard count < 4 else { return nil }
        count += 1
        sequence += 1
        return sequence
    }
    func release() { count -= 1 }
}

private final class TrialProtocolFactory: ProtocolCreator {
    func create(endpoint: Endpoint) -> ProtocolHandler { TrialProtocolHandler() }
}

private final class TrialProtocolHandler: ProtocolHandler {
    private let admission = Admission()

    func accept(conn: Connection) async throws {
        guard let id = await admission.acquire() else {
            try? conn.close(errorCode: 2, reason: Data("trial capacity".utf8))
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await serve(conn, id: id) }
            group.addTask {
                do { try await Task.sleep(nanoseconds: 20_000_000_000) }
                catch { return }
                trace("\(id) deadline")
                try? conn.close(errorCode: 1, reason: Data("trial deadline".utf8))
            }
            await group.next()
            group.cancelAll()
        }
        await admission.release()
    }

    func shutdown() async {}
}

private final class RelayFixturePreset: Preset {
    func apply(builder: EndpointBuilder) {
        builder.applyN0()
        // bindAddr only replaces the default for that address family. Restrict
        // IPv6 too, otherwise the trial can still upgrade to a direct IPv6 path.
        try! builder.bindAddr(addr: "[::1]:0")
    }
}

private func receive(_ stream: RecvStream) async throws -> Data {
    let prefix = try await stream.readExact(size: 4)
    let count = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard count > 0, count <= 65536 else { throw CompanionError.limit }
    let data = try await stream.readExact(size: count)
    guard String(data: data, encoding: .utf8) != nil else { throw CompanionError.invalid }
    return data
}

private func send(_ record: Data, _ stream: SendStream) async throws {
    try await stream.writeAll(buf: FrameDecoder.frame(record))
}

private func serve(_ conn: Connection, id: Int) async {
    do {
        trace("\(id) accepted")
        let bi = try await conn.acceptBi()
        trace("\(id) stream")
        let hello = try WireJSON.object(await receive(bi.recv()))
        guard hello["type"] as? String == "hello", hello["version"] as? Int == 1,
              hello["macId"] as? String == macID,
              hello["deviceId"] as? String == deviceID,
              let nonce = hello["clientNonce"] as? String else { throw CompanionError.unauthorized }
        let handshake = try ServerHandshake(mac: macID, device: deviceID,
            clientNonce: nonce, key: deviceKey, now: Date())
        try await send(WireJSON.data(handshake.challenge), bi.send())
        let auth = try WireJSON.object(await receive(bi.recv()))
        guard auth["type"] as? String == "authenticate", let proof = auth["proof"] as? String
        else { throw CompanionError.unauthorized }
        let channel = try handshake.authenticate(proof: proof, now: Date())
        trace("\(id) authenticated")
        let ready = try WireJSON.data(["type": "ready", "macId": macID,
            "deviceId": deviceID, "serverTime": WireJSON.iso(Date())])
        try await send(WireJSON.encoder.encode(channel.seal(ready)), bi.send())
        trace("\(id) ready")
        // No production dispatcher is imported. No command can reach native Keepresso.
        for _ in 0..<100 {
            let sealed = try WireJSON.decoder.decode(SealedRecord.self, from: await receive(bi.recv()))
            let plain = try channel.open(sealed)
            let request = try WireJSON.decoder.decode(CommandRequest.self, from: plain)
            try request.validate(now: Date())
            let allowed = request.action == "status"
            let reply = CommandResponse(id: request.id, status: allowed ? "ok" : "error",
                message: allowed ? "Synthetic iroh trial" : "Read-only trial")
            try await send(WireJSON.encoder.encode(channel.seal(WireJSON.encoder.encode(reply))), bi.send())
        }
    } catch {
        // Error category only: never output protocol records, keys, or IP addresses.
        let category = (error as? CompanionError).map { String(describing: $0) } ?? String(describing: type(of: error))
        trace("\(id) session_closed \(category)")
    }
    try? conn.close(errorCode: 0, reason: Data("trial complete".utf8))
}

@main struct Trial {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3, ["direct", "auto", "relay"].contains(args[1]) else {
            throw CompanionError.invalid
        }
        let relay = args[1] == "relay"
        let internet = args[1] != "direct"
        // Loopback-only UDP in relay mode prevents a direct Mac/emulator path,
        // without changing the host's firewall or network configuration.
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: relay ? RelayFixturePreset() : (internet ? presetN0() : presetMinimal()),
            bindAddr: relay ? "127.0.0.1:0" : "0.0.0.0:0",
            alpns: [alpn], relayMode: internet ? RelayMode.defaultMode() : RelayMode.disabled(),
            protocols: [alpn: TrialProtocolFactory()]))
        if internet { await endpoint.online() }
        let addr: EndpointAddr
        if relay {
            guard let url = endpoint.addr().relayUrl() else { throw CompanionError.unavailable }
            addr = EndpointAddr(id: endpoint.id(), relayUrl: url, addresses: [])
        } else if internet {
            // Real devices use iroh's current address/relay information, never
            // the emulator-specific 10.0.2.2 shortcut.
            addr = endpoint.addr()
        } else {
            guard let socket = endpoint.boundSockets().first,
                  let port = socket.split(separator: ":").last else { throw CompanionError.unavailable }
            // Android emulator's documented alias for its host, not LAN discovery.
            addr = EndpointAddr(id: endpoint.id(), relayUrl: nil, addresses: ["10.0.2.2:\(port)"])
        }
        let ticket = try EndpointTicket.fromAddr(addr: addr).description
        try WireJSON.data(["ticket": ticket, "mode": args[1]])
            .write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        trace("fixture_ready \(args[1])")
        // The native iroh Router owns the accept loop, including parallel TLS
        // handshakes. Awaiting a handshake in a custom loop can block later peers.
        // This passive wait creates no polling timer or keep-awake assertion.
        let lifetime = AsyncStream<Void> { _ in }
        for await _ in lifetime {}
        try await endpoint.close()
    }
}
