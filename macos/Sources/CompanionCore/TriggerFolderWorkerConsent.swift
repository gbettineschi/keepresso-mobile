import Foundation
import Darwin

/// A bounded private handoff, removed with the worker's scratch directory.
/// Folder names never need to appear in process arguments or diagnostic logs.
public enum TriggerFolderWorkerConsent {
    private static let filename = "folder-consent.json"
    public static func write(_ data: Data?, to scratch: URL) throws {
        guard let data else { return }
        guard data.count <= TriggerFolderAccess.maximumConsentBytes else { throw CompanionError.invalid }
        let root = try ObserverScratch.validate(scratch.path)
        let fd = open(root.appendingPathComponent(filename).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CompanionError.invalid }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: data)
    }
    public static func read(from scratch: URL) -> Data? {
        guard let root = try? ObserverScratch.validate(scratch.path) else { return nil }
        let fd = open(root.appendingPathComponent(filename).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= TriggerFolderAccess.maximumConsentBytes,
              let data = try? file.read(upToCount: TriggerFolderAccess.maximumConsentBytes + 1),
              data.count <= TriggerFolderAccess.maximumConsentBytes else { return nil }
        return data
    }
}
