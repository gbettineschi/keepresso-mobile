import Foundation
import Testing
@testable import CompanionCore

struct InternetConfigurationTests {
    private let endpoint = Data(repeating: 0x42, count: 32).base64EncodedString()
    private func firebase() throws -> FirebaseClientConfiguration {
        try FirebaseClientConfiguration(projectId: "keepresso-test", applicationId: "1:123456:android:abcdef", apiKey: "public-fixture-api-key", senderId: "123456")
    }

    @Test func authenticatedConfigurationRoundTripsWithoutPairingMaterial() throws {
        let configuration = try InternetConfiguration(endpointId: endpoint, firebase: firebase())
        let data = try configuration.encoded()
        #expect(try InternetConfiguration.decode(data) == configuration)
        let object = try WireJSON.object(data)
        #expect(object["type"] as? String == "internet_config")
        #expect(object["key"] == nil && object["token"] == nil)
        #expect(object["endpointId"] as? String == endpoint)
    }

    @Test func malformedMetadataCannotReplaceAValidAddress() throws {
        let good = try InternetConfiguration(endpointId: endpoint)
        for invalid in ["", " "+endpoint, Data(repeating: 1, count: 31).base64EncodedString(), endpoint+"="] {
            #expect(throws: (any Error).self) { try InternetConfiguration(endpointId: invalid) }
        }
        var object = try WireJSON.object(good.encoded())
        object["version"] = 2
        #expect(throws: (any Error).self) { try InternetConfiguration.decode(WireJSON.data(object)) }
        object["version"] = true
        #expect(throws: (any Error).self) { try InternetConfiguration.decode(WireJSON.data(object)) }
        object["version"] = 1; object["type"] = "hello"
        #expect(throws: (any Error).self) { try InternetConfiguration.decode(WireJSON.data(object)) }
    }

    @Test func firebaseOptionsMustBeCompleteAndConsistent() throws {
        #expect(throws: (any Error).self) {
            try FirebaseClientConfiguration(projectId: "keepresso-test", applicationId: "1:999:android:abcdef", apiKey: "public-fixture-api-key", senderId: "123456")
        }
        #expect(throws: (any Error).self) {
            try FirebaseClientConfiguration(projectId: "https://attacker.test", applicationId: "1:123456:android:abcdef", apiKey: "public-fixture-api-key", senderId: "123456")
        }
        var object = try WireJSON.object(InternetConfiguration(endpointId: endpoint).encoded())
        object["firebase"] = ["projectId":"keepresso-test"]
        #expect(throws: (any Error).self) { try InternetConfiguration.decode(WireJSON.data(object)) }
    }
}

struct PushRegistrationTests {
    private let device = "22222222-2222-4222-8222-222222222222"
    @Test func tokenRevisionIsMonotonicAndExactDuplicatesAreIdempotent() throws {
        var registry = PushTokenRegistry()
        let current = try PushRegistration(projectId: "keepresso-test", token: "current-fixture-token", revision: 2)
        let ack = try registry.register(deviceId: device, registration: current)
        #expect(try registry.register(deviceId: device, registration: current) == ack)
        #expect(ack.revision == 2 && ack.tokenHash == current.tokenHash)
        #expect(throws: (any Error).self) {
            try registry.register(deviceId: device, registration: PushRegistration(projectId:"keepresso-test",token:"old-fixture-token",revision:1))
        }
        #expect(throws: (any Error).self) {
            try registry.register(deviceId: device, registration: PushRegistration(projectId:"keepresso-test",token:"different-token",revision:2))
        }
        #expect(registry.registration(deviceId: device) == current)
        registry.remove(deviceId: device)
        #expect(registry.registration(deviceId: device) == nil)
    }
    @Test func invalidTokenAndRevisionAreRejected() {
        for token in ["", "token\nvalue", String(repeating: "x", count: 4097)] {
            #expect(throws: (any Error).self) { try PushRegistration(projectId:"keepresso-test",token:token,revision:1) }
        }
        #expect(throws: (any Error).self) { try PushRegistration(projectId:"keepresso-test",token:"fixture",revision:0) }
    }
}
