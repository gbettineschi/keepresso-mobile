import Foundation
import Darwin
import Testing
@testable import CompanionCore

struct PrivateCredentialStoreTests {
    private func fixture() throws -> (URL, URL) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("credentials-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (root, root.appendingPathComponent("Connection/credentials.json"))
    }
    private var saved: SavedAuthorization {
        SavedAuthorization(devices: [AuthorizedDevice(deviceId: "11111111-1111-4111-8111-111111111111", name: "Fixture", key: Data(repeating: 7, count: 32), approvedAt: Date(timeIntervalSince1970: 1234))], relay: try! RelayConfiguration(url: "https://relay.example", macBearer: Data(repeating: 9, count: 32).base64EncodedString()))
    }
    @Test func migrationRetainsCredentialsAndRestartNeverReadsLegacy() throws {
        let (root, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = CredentialRepository(file: PrivateCredentialFile(url: url), legacyReader: { allow in
            #expect(allow); return saved
        })
        let migrated = try repository.loadSaved(allowInteraction: true)
        #expect(migrated.devices.first?.key == Data(repeating: 7, count: 32))
        #expect(migrated.devices.first?.deviceId == "11111111-1111-4111-8111-111111111111")
        #expect(migrated.devices.first?.name == "Fixture")
        #expect(migrated.relay?.url == "https://relay.example")
        #expect(migrated.devices.first?.approvedAt == Date(timeIntervalSince1970: 1234))
        #expect(migrated.relay?.macBearer == Data(repeating: 9, count: 32).base64EncodedString())
        let restarted = CredentialRepository(file: PrivateCredentialFile(url: url), legacyReader: { _ in throw SavedConnectionFailure(reason: .locked) })
        #expect(try restarted.loadSaved(allowInteraction: false).devices.count == 1)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((fileAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
    }
    @Test func partialUpdatesPreserveOtherFieldsAndRevokedDevicesStayRemoved() throws {
        let (root, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = CredentialRepository(file: PrivateCredentialFile(url: url), legacyReader: { _ in saved })
        let relay = try RelayConfiguration(url: "https://other.example", macBearer: Data(repeating: 4, count: 32).base64EncodedString())
        try repository.saveRelay(relay)
        #expect(try repository.loadSaved(allowInteraction: false).devices.first?.key == Data(repeating: 7, count: 32))
        try repository.save([])
        #expect(try repository.loadSaved(allowInteraction: false).devices.isEmpty)
        #expect(try repository.loadSaved(allowInteraction: false).relay == relay)
        try repository.saveRelay(relay)
        let restarted = CredentialRepository(file: PrivateCredentialFile(url: url), legacyReader: { _ in saved })
        #expect(try restarted.loadSaved(allowInteraction: false).devices.isEmpty)
        #expect(try restarted.loadSaved(allowInteraction: false).relay == relay)
    }
    @Test func silentPolicyAndLegacyFailureArePreservedWithoutCreatingFile() throws {
        let (root, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = CredentialRepository(file: PrivateCredentialFile(url: url), legacyReader: { allow in
            #expect(!allow); throw SavedConnectionFailure(reason: .permissionRequired)
        })
        #expect(throws: SavedConnectionFailure(reason: .permissionRequired)) { try repository.loadSaved(allowInteraction: false) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func insecureCorruptOversizedAndNonregularStateNeverFallsBack() throws {
        for kind in ["file-mode", "directory-mode", "corrupt", "oversize", "symlink", "directory", "fifo", "parent-symlink", "hardlink", "invalid-relay", "duplicate-devices", "unknown-version"] {
            let (root, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let file = PrivateCredentialFile(url: url)
            try file.write(saved)
            switch kind {
            case "file-mode": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            case "directory-mode": try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.deletingLastPathComponent().path)
            case "corrupt": try Data("{}".utf8).write(to: url)
            case "oversize": try Data(repeating: 0, count: 65_537).write(to: url)
            case "symlink":
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("missing"))
            case "directory":
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            case "fifo":
                try FileManager.default.removeItem(at: url); #expect(mkfifo(url.path, 0o600) == 0)
            case "hardlink":
                try FileManager.default.linkItem(at: url, to: root.appendingPathComponent("linked-credentials"))
            case "invalid-relay", "duplicate-devices", "unknown-version":
                var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                if kind == "invalid-relay" {
                    var relay = object["relay"] as! [String: Any]; relay["url"] = "http://relay.example"; object["relay"] = relay
                } else if kind == "duplicate-devices" {
                    let devices = object["devices"] as! [[String: Any]]; object["devices"] = devices + devices
                } else { object["version"] = 2 }
                try JSONSerialization.data(withJSONObject: object).write(to: url)
            default:
                let original = root.appendingPathComponent("Original")
                try FileManager.default.moveItem(at: url.deletingLastPathComponent(), to: original)
                try FileManager.default.createSymbolicLink(at: url.deletingLastPathComponent(), withDestinationURL: original)
            }
            let repository = CredentialRepository(file: file, legacyReader: { _ in Issue.record("Unexpected legacy fallback for \(kind)"); return saved })
            #expect(throws: SavedConnectionFailure.self) { try repository.loadSaved(allowInteraction: false) }
        }
    }
    @Test func failedAtomicReplacementKeepsPreviousBytesAndNoTemporaryFile() throws {
        let (root, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try PrivateCredentialFile(url: url).write(saved)
        let before = try Data(contentsOf: url)
        let file = PrivateCredentialFile(url: url, replace: { _, _, _ in throw SavedConnectionFailure(reason: .unavailable) })
        let repository = CredentialRepository(file: file, legacyReader: { _ in throw SavedConnectionFailure(reason: .locked) })
        #expect(throws: SavedConnectionFailure.self) { try repository.save([]) }
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["credentials.json"])
    }
    @Test func migrationWriteFailureNeverReturnsAuthorization() throws {
        let (root, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = PrivateCredentialFile(url: url, replace: { _, _, _ in throw SavedConnectionFailure(reason: .unavailable) })
        let repository = CredentialRepository(file: file, legacyReader: { _ in saved })
        #expect(throws: SavedConnectionFailure.self) { try repository.loadSaved(allowInteraction: true) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func oversizedUpdateAndInsecureRelayPreservePreviousFile() throws {
        let (root, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try PrivateCredentialFile(url: url).write(saved)
        let before = try Data(contentsOf: url)
        let repository = CredentialRepository(file: PrivateCredentialFile(url: url), legacyReader: { _ in throw SavedConnectionFailure(reason: .locked) })
        var oversized = saved.devices[0]; oversized.name = String(repeating: "x", count: 65_536)
        #expect(throws: SavedConnectionFailure.self) { try repository.save([oversized]) }
        let insecure = try RelayConfiguration(url: "http://localhost", macBearer: Data(repeating: 2, count: 32).base64EncodedString(), allowLocalhost: true)
        #expect(throws: SavedConnectionFailure.self) { try repository.saveRelay(insecure) }
        #expect(try Data(contentsOf: url) == before)
    }
    @Test func invalidLegacyKeyCannotBecomeAuthoritative() throws {
        let (root, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var device = saved.devices[0]; device.key = Data(repeating: 0, count: 31)
        let invalid = SavedAuthorization(devices: [device], relay: nil)
        let repository = CredentialRepository(file: PrivateCredentialFile(url: url), legacyReader: { _ in invalid })
        #expect(throws: SavedConnectionFailure.self) { try repository.loadSaved(allowInteraction: true) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try PrivateCredentialFile(url: url).write(saved)
        let before = try Data(contentsOf: url)
        #expect(throws: SavedConnectionFailure.self) { try repository.save([device]) }
        #expect(try Data(contentsOf: url) == before)
    }
}
