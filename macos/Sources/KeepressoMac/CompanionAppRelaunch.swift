import AppKit
import CompanionCore
import Darwin
import OSLog

/// Native effects are confined here; sequencing and identity checks live in Core.
/// The child receives only its parent's PID and has no normal startup fallback.
@MainActor enum CompanionAppRelaunch {
    private static let log=Logger(subsystem:"local.keespresso.companion",category:"Restart")
    private static var helper: Process?
    private static var canonicalIdentity: (bundle: String, executable: String)? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let bundle = Bundle.main.bundleURL
        guard bundle.path == CompanionRelaunch.bundlePath,
              bundle.resolvingSymlinksInPath().path == CompanionRelaunch.bundlePath,
              executable.path == CompanionRelaunch.executablePath,
              executable.resolvingSymlinksInPath().path == CompanionRelaunch.executablePath else {
            log.error("Canonical identity mismatch: bundle=\(bundle.path,privacy:.public) executable=\(executable.path,privacy:.public)")
            return nil
        }
        return (bundle.path, executable.path)
    }

    static func launchHelper() async -> Bool {
        guard let identity = canonicalIdentity else { return false }
        if let retained=helper,!retained.isRunning{helper=nil}
        guard helper == nil else { log.error("A relaunch helper is already retained");return false }
        let process = Process(), acknowledgement = Pipe()
        process.executableURL = URL(fileURLWithPath: identity.executable)
        process.arguments = [CompanionRelaunch.argument, String(getpid())]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = acknowledgement
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {log.error("Helper spawn failed: \(String(describing:error),privacy:.public)");return false }
        helper = process
        // Do not quit merely because exec succeeded. Child must validate its
        // canonical identity and actual parent, then acknowledge it is waiting.
        let accepted = await Task.detached(priority: .utility) {
            let handle = acknowledgement.fileHandleForReading
            defer { try? handle.close() }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 2_000) > 0 && descriptor.revents & Int16(POLLIN) != 0
            var byte: UInt8 = 0
            let accepted = ready && read(handle.fileDescriptor, &byte, 1) == 1 && byte == 0x52
            if !accepted, process.isRunning { process.terminate() }
            return accepted
        }.value
        if !accepted { log.error("Helper did not acknowledge readiness");helper = nil }
        else{log.info("Helper acknowledged readiness")}
        return accepted
    }

    static func cancelHelper() {
        if let helper, helper.isRunning { helper.terminate() }
        helper = nil
    }

    static func runHelper() -> Never {
        guard let identity = canonicalIdentity else { exit(2) }
        let parentPID = getppid()
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let parentPath = proc_pidpath(parentPID, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
        guard let parent = CompanionRelaunch.parent(arguments: CommandLine.arguments,
                bundlePath: identity.bundle, executablePath: identity.executable,
                actualParent: parentPID, ownPID: getpid(), parentExecutablePath: parentPath) else {
            log.error("Helper parent validation failed: executable=\(parentPath ?? "unavailable",privacy:.public) argv0=\(CommandLine.arguments.first ?? "unavailable",privacy:.public)")
            exit(2)
        }
        do { try FileHandle.standardOutput.write(contentsOf: Data([0x52])) }
        catch { exit(2) }
        // Hard bound also covers an unresponsive NSWorkspace completion.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12) { exit(2) }
        Task { @MainActor in
            let opened = await CompanionRelaunch.waitForParentExit(parentPID: parent, ownPID: getpid(),
                now: { ProcessInfo.processInfo.systemUptime },
                isAlive: { kill($0, 0) == 0 || errno != ESRCH },
                pause: { try await Task.sleep(for: .milliseconds(100)) },
                open: {
                    // No caller-supplied URL, shell or executable is accepted.
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    // The helper itself is still a same-bundle process. Ask for
                    // a normal fresh instance instead of reusing that helper.
                    configuration.createsNewApplicationInstance = true
                    return await withCheckedContinuation { continuation in
                        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: CompanionRelaunch.bundlePath), configuration: configuration) { app, error in
                            continuation.resume(returning: CompanionRelaunch.acceptsOpenedApplication(
                                processIdentifier: app?.processIdentifier, terminated: app?.isTerminated ?? true,
                                errorOccurred: error != nil, parentPID: parent, helperPID: getpid()))
                        }
                    }
                })
            exit(opened ? 0 : 2)
        }
        dispatchMain()
    }
}
