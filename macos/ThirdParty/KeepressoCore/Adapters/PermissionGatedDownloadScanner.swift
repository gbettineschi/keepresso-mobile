import Foundation

/// Companion-only gate at upstream's public scanner seam. A missing approval
/// must never call the real scanner (which could prompt for folder access).
public final class PermissionGatedDownloadScanner: DownloadFolderScanning {
    private let scanner: DownloadFolderScanning
    private let isApproved: (URL) -> Bool
    public init(scanner: DownloadFolderScanning = FileManagerDownloadScanner(), isApproved: @escaping (URL) -> Bool = { _ in false }) {
        self.scanner = scanner
        self.isApproved = isApproved
    }
    public func newestPartialDownloadWrite(in folder: URL) -> Date? {
        guard isApproved(folder) else { return nil }
        return scanner.newestPartialDownloadWrite(in: folder)
    }
}
