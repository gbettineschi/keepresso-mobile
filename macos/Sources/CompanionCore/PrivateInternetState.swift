import Foundation
import Darwin

/// Owner-only independent state. Every path component is opened without following
/// symlinks; only ENOENT is absence. Invalid storage is never an empty pairing.
struct PrivateStateFile {
    private let maximumBytes: Int
    private let url: URL
    private let replace: (Int32, String, String) throws -> Void

    init(url: URL, maximumBytes: Int = 65_536) {
        self.maximumBytes=maximumBytes
        self.url=url
        replace={directory,source,destination in
            guard renameat(directory,source,directory,destination)==0 else {throw SavedConnectionFailure(reason:.unavailable)}
        }
    }
    private static var invalid: SavedConnectionFailure { SavedConnectionFailure(reason: .invalidData) }
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
    private static func read(descriptor: Int32, maximumBytes:Int) throws -> Data {
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
        return data
    }
    private func read(directory: Int32) throws -> Data? {
        let descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Self.filesystemFailure()
        }
        defer { close(descriptor) }
        return try Self.read(descriptor: descriptor,maximumBytes:maximumBytes)
    }
    func read() throws -> Data? {
        guard let directory = try directory(create: false) else { return nil }
        defer { close(directory) }
        return try read(directory: directory)
    }
    func write(_ data: Data) throws {
        guard data.count <= maximumBytes else {throw Self.invalid}
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
        do { _ = try Self.read(descriptor: verification,maximumBytes:maximumBytes); close(verification) }
        catch { close(verification); throw error }
        try replace(directory, temporary, url.lastPathComponent)
        guard fsync(directory)==0 else{throw SavedConnectionFailure(reason:.unavailable)}
    }
}


public struct PrivateInternetState {
    private struct Seed: Codable {let version:Int;let value:String}
    private let file:PrivateStateFile
    public init(url:URL){file=PrivateStateFile(url:url)}
    public func loadOrCreateSeed()throws->Data {
        if let data=try file.read(){
            let seed=try JSONDecoder().decode(Seed.self,from:data)
            guard seed.version==1 else{throw CompanionError.invalid}
            return try WireCrypto.bytes32(seed.value)
        }
        let seed=try WireCrypto.random32()
        try file.write(JSONEncoder().encode(Seed(version:1,value:seed.base64EncodedString())))
        return seed
    }
}
