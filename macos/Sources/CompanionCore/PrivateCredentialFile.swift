import Foundation
import Darwin

/// Owner-only credentials. Every path component is opened without following
/// symlinks; only ENOENT is absence. Invalid storage is never an empty pairing.
public struct PrivateCredentialFile {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Keespresso/Connection/credentials.json")
    }
    private static let maximumBytes = 65_536
    private let url: URL
    private let replace: (Int32, String, String) throws -> Void

    public init(url: URL = Self.defaultURL) {
        self.init(url: url, replace: { directory, source, destination in
            guard renameat(directory, source, directory, destination) == 0 else {
                throw SavedConnectionFailure(reason: .unavailable)
            }
        })
    }
    // The commit boundary is injectable so failures can be tested without
    // changing permissions or relying on filesystem timing/disk exhaustion.
    init(url: URL, replace: @escaping (Int32, String, String) throws -> Void) {
        self.url = url; self.replace = replace
    }

    private struct Record: Codable {
        let version: Int
        let devices: [AuthorizedDevice]
        let relay: RelayConfiguration?
        var saved: SavedAuthorization { SavedAuthorization(devices: devices, relay: relay) }
    }
    private static var invalid: SavedConnectionFailure { SavedConnectionFailure(reason: .invalidData) }
    static func validate(_ saved: SavedAuthorization) throws {
        guard saved.devices.count <= 32,
              Set(saved.devices.map(\.deviceId)).count == saved.devices.count,
              saved.devices.allSatisfy({ WireCrypto.validID($0.deviceId) && $0.key.count == 32 && $0.approvedAt.timeIntervalSince1970.isFinite }) else { throw invalid }
        if let relay = saved.relay {
            guard (try? RelayConfiguration(url: relay.url, macBearer: relay.macBearer)) == relay else { throw invalid }
        }
    }
    private static func decode(_ data: Data) throws -> SavedAuthorization {
        guard data.count <= maximumBytes,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1 else { throw invalid }
        try validate(record.saved)
        return record.saved
    }
    private func directory(create: Bool) throws -> Int32? {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty else { throw Self.invalid }
        let components = url.deletingLastPathComponent().pathComponents.dropFirst()
        guard !components.contains(".."), !components.contains(".") else { throw Self.invalid }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SavedConnectionFailure(reason: .unavailable) }
        do {
            for component in components {
                var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && create {
                    guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
                        throw SavedConnectionFailure(reason: .unavailable)
                    }
                    next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                if next < 0 {
                    if errno == ENOENT && !create { close(descriptor); return nil }
                    throw Self.filesystemFailure()
                }
                close(descriptor); descriptor = next
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw SavedConnectionFailure(reason: .unavailable) }
            guard info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw Self.invalid }
            return descriptor
        } catch { close(descriptor); throw error }
    }
    private static func filesystemFailure() -> SavedConnectionFailure {
        // A path with a symlink/non-directory is invalid; inaccessible storage
        // remains unavailable. Neither case is interpreted as item-not-found.
        SavedConnectionFailure(reason: [ELOOP, ENOTDIR].contains(errno) ? .invalidData : .unavailable)
    }
    private static func read(descriptor: Int32) throws -> SavedAuthorization {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw SavedConnectionFailure(reason: .unavailable) }
        guard info.st_uid == getuid(), info.st_mode & 0o7777 == 0o600,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw invalid }
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw SavedConnectionFailure(reason: .unavailable) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maximumBytes {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
            if count < 0 { if errno == EINTR { continue }; throw SavedConnectionFailure(reason: .unavailable) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumBytes, data.count == info.st_size else { throw invalid }
        return try decode(data)
    }
    private func read(directory: Int32) throws -> SavedAuthorization? {
        let descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Self.filesystemFailure()
        }
        defer { close(descriptor) }
        return try Self.read(descriptor: descriptor)
    }
    public func read() throws -> SavedAuthorization? {
        guard let directory = try directory(create: false) else { return nil }
        defer { close(directory) }
        return try read(directory: directory)
    }
    public func write(_ saved: SavedAuthorization) throws {
        try Self.validate(saved)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Record(version: 1, devices: saved.devices, relay: saved.relay)),
              data.count <= Self.maximumBytes else { throw Self.invalid }
        guard let directory = try directory(create: true) else { throw SavedConnectionFailure(reason: .unavailable) }
        defer { close(directory) }
        // Never overwrite an insecure/corrupt existing file as a repair strategy.
        _ = try read(directory: directory)
        let temporary = ".credentials-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.filesystemFailure() }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw SavedConnectionFailure(reason: .unavailable) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw SavedConnectionFailure(reason: .unavailable) }
                guard count > 0 else { throw SavedConnectionFailure(reason: .unavailable) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw SavedConnectionFailure(reason: .unavailable) }
        // Re-open and fully validate the staged bytes before the only operation
        // that replaces old data. Any earlier failure leaves the old file intact.
        let verification = openat(directory, temporary, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard verification >= 0 else { throw Self.filesystemFailure() }
        do { _ = try Self.read(descriptor: verification); close(verification) }
        catch { close(verification); throw error }
        try replace(directory, temporary, url.lastPathComponent)
    }
}
