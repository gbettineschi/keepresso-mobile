import Testing
import Foundation
@testable import CompanionCore
struct CryptoTests {
    @Test func testIndependentNodeDeviceKeyVector() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/vectors.json")
        let v = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        let actual = WireCrypto.deviceKey(token: Data(base64Encoded: v["token"] as! String)!, mac: v["macId"] as! String, device: v["deviceId"] as! String)
        #expect(actual.base64EncodedString() == v["deviceKey"] as? String)
    }
}

extension CryptoTests {
    func vectors() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/vectors.json")
        return (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]).compactMapValues { $0 as? String }
    }
    @Test func testNodeProofsKeysAndAESVector() throws {
        let v = try vectors(); let token = Data(base64Encoded: v["token"]!)!
        let key = WireCrypto.deviceKey(token: token, mac: v["macId"]!, device: v["deviceId"]!)
        XCTAssertEqual(WireCrypto.pairTranscript(mac: v["macId"]!, device: v["deviceId"]!, nonce: v["clientNonce"]!, name: v["deviceName"]!), v["pairTranscript"]!)
        XCTAssertEqual(WireCrypto.hmac(key: token, text: v["pairTranscript"]!).base64EncodedString(), v["pairProof"]!)
        let transcript = WireCrypto.transcript(mac: v["macId"]!, device: v["deviceId"]!, client: v["clientNonce"]!, server: v["serverNonce"]!)
        XCTAssertEqual(transcript, v["transcript"]!)
        XCTAssertEqual(WireCrypto.hmac(key: key, text: "server\n" + transcript).base64EncodedString(), v["serverProof"]!)
        XCTAssertEqual(WireCrypto.hmac(key: key, text: "client\n" + transcript).base64EncodedString(), v["clientProof"]!)
        XCTAssertEqual(WireCrypto.hmac(key: key, text: "paired\n" + v["macId"]! + "\n" + v["deviceId"]!).base64EncodedString(), v["pairedProof"]!)
        let c2s = WireCrypto.directionKey(deviceKey: key, transcript: transcript, direction: "c2s")
        XCTAssertEqual(c2s.base64EncodedString(), v["c2s"]!)
        XCTAssertEqual(WireCrypto.directionKey(deviceKey: key, transcript: transcript, direction: "s2c").base64EncodedString(), v["s2c"]!)
        let sender = SealedChannel(sendKey: c2s, receiveKey: c2s)
        let sealed = try sender.seal(Data(v["plaintext"]!.utf8))
        XCTAssertEqual(sealed.ciphertext, v["ciphertext"]!)
        let receiver = SealedChannel(sendKey: c2s, receiveKey: c2s)
        XCTAssertEqual(try receiver.open(sealed), Data(v["plaintext"]!.utf8))
        XCTAssertThrowsError(try receiver.open(sealed))
        XCTAssertThrowsError(try receiver.seal(Data())) // failed replay closes both directions
    }
    @Test func testTamperWrongKeyAndOutOfOrderCloseSession() throws {
        let key = Data(repeating: 4, count: 32)
        let sender = SealedChannel(sendKey: key, receiveKey: key)
        var record = try sender.seal(Data("secret".utf8))
        var bytes = Data(base64Encoded: record.ciphertext)!; bytes[0] ^= 1; record.ciphertext = bytes.base64EncodedString()
        let receiver = SealedChannel(sendKey: key, receiveKey: key)
        XCTAssertThrowsError(try receiver.open(record))
        XCTAssertTrue(receiver.closed)
        let wrong = SealedChannel(sendKey: key, receiveKey: Data(repeating: 5, count: 32))
        XCTAssertThrowsError(try wrong.open(try SealedChannel(sendKey:key,receiveKey:key).seal(Data())))
    }
}
extension CryptoTests {
    @Test func handshakeWrongProofExpiresAndCannotReuseAndReconnectKeysDiffer() throws {
        let v=try vectors();let key=Data(base64Encoded:v["deviceKey"]!)!;let now=Date()
        let h=try ServerHandshake(mac:v["macId"]!,device:v["deviceId"]!,clientNonce:v["clientNonce"]!,key:key,now:now)
        XCTAssertThrowsError(try h.authenticate(proof:v["clientProof"]!,now:now))
        XCTAssertThrowsError(try h.authenticate(proof:WireCrypto.hmac(key:key,text:"client\n"+h.transcript).base64EncodedString(),now:now))
        let h2=try ServerHandshake(mac:v["macId"]!,device:v["deviceId"]!,clientNonce:v["clientNonce"]!,key:key,now:now)
        XCTAssertFalse(h.transcript==h2.transcript)
        XCTAssertThrowsError(try h2.authenticate(proof:WireCrypto.hmac(key:key,text:"client\n"+h2.transcript).base64EncodedString(),now:now.addingTimeInterval(11)))
    }
}
