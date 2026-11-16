import Foundation

/// Fixed identity and PID-only helper contract. It never accepts a destination
/// from the caller and must be dispatched before normal application startup.
public enum CompanionRelaunch {
    public static let argument = "--relaunch-companion"
    public static let bundlePath = "/Applications/Keepresso Mobile.app"
    public static let executablePath = bundlePath + "/Contents/MacOS/KeepressoMac"

    public static func parent(arguments: [String], bundlePath: String, executablePath: String,
                              actualParent: Int32, ownPID: Int32, parentExecutablePath: String?) -> Int32? {
        guard bundlePath == Self.bundlePath, executablePath == Self.executablePath,
              parentExecutablePath == Self.executablePath,
              arguments.count == 3, arguments[0] == Self.executablePath,
              arguments[1] == argument, let pid = Int32(arguments[2]),
              String(pid) == arguments[2], pid > 1, pid != ownPID, pid == actualParent else { return nil }
        return pid
    }

    /// Completion policy is shared by the native callback and injected tests.
    public static func acceptsOpenedApplication(processIdentifier: Int32?, terminated: Bool,
        errorOccurred: Bool, parentPID: Int32, helperPID: Int32) -> Bool {
        guard !errorOccurred, !terminated, let processIdentifier, processIdentifier > 1,
              processIdentifier != parentPID, processIdentifier != helperPID else { return false }
        return true
    }

    /// All effects are injected. A failed/late/cancelled wait never opens an app.
    /// Production adds a process-wide deadline for a stuck native open callback.
    @MainActor public static func waitForParentExit(parentPID: Int32, ownPID: Int32,
        now: () -> TimeInterval, isAlive: (Int32) -> Bool,
        pause: () async throws -> Void, open: () async -> Bool) async -> Bool {
        guard parentPID > 1, parentPID != ownPID, !Task.isCancelled else { return false }
        let deadline = now() + 10
        while isAlive(parentPID) {
            guard !Task.isCancelled, now() < deadline else { return false }
            do { try await pause() } catch { return false }
        }
        guard !Task.isCancelled, now() < deadline else { return false }
        return await open()
    }
}

/// Parent-side contract: helper acknowledgement, durable checkpoint, graceful
/// companion Quit. Failed launch/checkpoint and duplicate clicks never quit.
@MainActor public final class CompanionRestartRequest {
    private var running = false
    public init() {}
    public func perform(launch: () async -> Bool, checkpoint: () -> Bool, cancelHelper: () -> Void = {}, dismissSetup: () -> Void = {}, quit: () -> Void) async -> Bool {
        guard !running, !Task.isCancelled else { return false }
        running = true
        defer { running = false }
        guard await launch() else { return false }
        guard !Task.isCancelled, checkpoint(), !Task.isCancelled else {
            cancelHelper()
            return false
        }
        // End modal setup only after preserving its restart checkpoint. AppKit
        // can ignore termination requested from an attached modal sheet.
        dismissSetup()
        quit()
        return true
    }
}
