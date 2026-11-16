import Foundation

/// An empty file under `~/Library/Application Support/Keepresso/` whose
/// presence is the state: crash-recovery flags that must outlive the process.
public struct AppSupportFlagFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/Keepresso/<name>`, falling back to the
    /// temporary directory if Application Support can't be resolved.
    public static func defaultURL(named name: String) -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Keepresso", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    public var isPresent: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Create the flag (and its folder). Returns whether the write succeeded.
    public func create() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
