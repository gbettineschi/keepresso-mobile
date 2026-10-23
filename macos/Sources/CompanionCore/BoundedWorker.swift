import Foundation
import Darwin
public enum BoundedWorker {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock(); private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    /// Only the Mac helper's fixed executable/worker arguments are used by the
    /// app. No wire action accepts a path, argument list, URL or shell fragment.
    public static func run(executable:URL,arguments:[String],timeout:TimeInterval=5,outputLimit:Int=65536)async throws->Data {
        guard timeout>0,timeout<=5,outputLimit>0,outputLimit<=65536 else{throw CompanionError.invalid}
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority:.utility){try blocking(executable:executable,arguments:arguments,timeout:timeout,outputLimit:outputLimit,cancellation:cancellation)}.value
        }, onCancel: { cancellation.cancel() })
    }
    private static func blocking(executable:URL,arguments:[String],timeout:TimeInterval,outputLimit:Int,cancellation:Cancellation)throws->Data {
        guard !cancellation.isCancelled else { throw CancellationError() }
        let process=Process();process.executableURL=executable;process.arguments=arguments
        let pipe=Pipe();process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
        defer { try? pipe.fileHandleForReading.close();try? pipe.fileHandleForWriting.close() }
        let input=pipe.fileHandleForReading.fileDescriptor
        guard fcntl(input,F_SETFD,FD_CLOEXEC) != -1,
              fcntl(pipe.fileHandleForWriting.fileDescriptor,F_SETFD,FD_CLOEXEC) != -1,
              fcntl(input,F_SETFL,fcntl(input,F_GETFL)|O_NONBLOCK) != -1 else { throw CompanionError.unavailable }
        try process.run();let pid=process.processIdentifier
        try? pipe.fileHandleForWriting.close()
        var data=Data();var overflow=false;var failed=false;var eof=false
        var buffer=[UInt8](repeating:0,count:4096)
        func captureAvailable() {
            while !eof && !overflow && !failed {
                let count=Darwin.read(input,&buffer,buffer.count)
                if count>0 {
                    guard data.count+count<=outputLimit else{overflow=true;return}
                    data.append(contentsOf:buffer.prefix(count))
                } else if count==0 { eof=true }
                else if errno==EINTR { continue }
                else if errno==EAGAIN || errno==EWOULDBLOCK { return }
                else { failed=true }
            }
        }
        // Drain on this worker thread. A second utility-queue reader can starve
        // while concurrent blocking workers wait for it on small CI machines.
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        var expired=false
        while true {
            captureAvailable()
            if cancellation.isCancelled || overflow || failed || !process.isRunning { break }
            if ProcessInfo.processInfo.systemUptime>=deadline { expired=true;break }
            Thread.sleep(forTimeInterval:0.02)
        }
        // The observer establishes this group before constructing any monitor.
        // Kill descendants even if its own async main has already returned.
        kill(-pid,SIGKILL)
        if process.isRunning { kill(pid,SIGKILL) }
        process.waitUntilExit()
        let drainDeadline=ProcessInfo.processInfo.systemUptime+0.5
        repeat {
            captureAvailable()
            if eof || overflow || failed { break }
            Thread.sleep(forTimeInterval:0.01)
        } while ProcessInfo.processInfo.systemUptime<drainDeadline
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard eof else { throw CompanionError.expired }
        guard !expired,!overflow,!failed,process.terminationStatus==0 else { throw expired ? CompanionError.expired:CompanionError.unavailable }
        return data
    }
}
