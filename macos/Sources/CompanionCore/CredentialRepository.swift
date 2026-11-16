import Foundation

/// Keeps the file authoritative and confines all legacy access (including the
/// legacy interaction-policy query) to the absent-file branch.
public final class CredentialRepository: @unchecked Sendable {
    private static let lock = NSLock()
    private let file: PrivateCredentialFile
    private let legacyReader: (Bool) throws -> SavedAuthorization
    public init(file: PrivateCredentialFile, legacyReader: @escaping (Bool) throws -> SavedAuthorization) {
        self.file = file; self.legacyReader = legacyReader
    }
    public func loadSaved(allowInteraction: Bool) throws -> SavedAuthorization {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let saved = try file.read() { return saved }
        let legacy = try legacyReader(allowInteraction)
        try file.write(legacy)
        guard let committed = try file.read() else { throw SavedConnectionFailure(reason: .unavailable) }
        return committed
    }
    public func save(_ devices: [AuthorizedDevice]) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let previous = try file.read() ?? legacyReader(false)
        try file.write(SavedAuthorization(devices: devices, relay: previous.relay))
    }
    public func saveRelay(_ relay: RelayConfiguration) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let previous = try file.read() ?? legacyReader(false)
        try file.write(SavedAuthorization(devices: previous.devices, relay: relay))
    }
}
