import Foundation
import Darwin

/// Kernel-owned lifetime lock: crashes release it without stale PID files.
/// It prevents a manual launch and launchd's managed launch running two servers.
public final class CompanionInstanceLease {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }
    public static func acquire(directory: URL) throws -> CompanionInstanceLease? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("runtime.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CompanionError.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG else { close(fd); throw CompanionError.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            close(fd)
            if busy { return nil }
            throw CompanionError.unavailable
        }
        return CompanionInstanceLease(fd)
    }
}
