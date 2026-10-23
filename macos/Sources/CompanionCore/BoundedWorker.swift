import Foundation
import Darwin
public enum BoundedWorker {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock(); private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    private final class Capture:@unchecked Sendable {
        let lock=NSLock();var data=Data();var overflow=false;var failed=false
        func append(_ chunk:Data,limit:Int)->Bool{lock.lock();defer{lock.unlock()};if data.count+chunk.count>limit{overflow=true;return false};data.append(chunk);return true}
        func result()->(Data,Bool){lock.lock();defer{lock.unlock()};return(data,overflow || failed)}
        func fail(){lock.lock();failed=true;lock.unlock()}
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
    private static func blocking(executable:URL,arguments:[String],timeout:TimeInterval,outputLimit:Int,cancellation:Cancellation)throws->Data{
            guard !cancellation.isCancelled else { throw CancellationError() }
            let process=Process();process.executableURL=executable;process.arguments=arguments
            let pipe=Pipe();process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
            let capture=Capture();let readers=DispatchGroup()
            try process.run();let pid=process.processIdentifier
            try pipe.fileHandleForWriting.close()
            readers.enter()
            DispatchQueue.global(qos:.utility).async{
                defer{try? pipe.fileHandleForReading.close();readers.leave()}
                do{
                    while let data=try pipe.fileHandleForReading.read(upToCount:4096),!data.isEmpty{
                        if !capture.append(data,limit:outputLimit){kill(-pid,SIGKILL);kill(pid,SIGKILL);return}
                    }
                }catch{capture.fail()}
            }
            let deadline=ProcessInfo.processInfo.systemUptime+timeout
            var expired=false
            while process.isRunning{
                if cancellation.isCancelled { break }
                if capture.result().1{break}
                if ProcessInfo.processInfo.systemUptime>=deadline{expired=true;break}
                Thread.sleep(forTimeInterval:0.02)
            }
            // The worker establishes this group before constructing any monitor;
            // kill descendants even after its own async main returns. A child
            // process ID cannot designate this parent's process group.
            kill(-pid,SIGKILL)
            if process.isRunning{kill(pid,SIGKILL)}
            process.waitUntilExit()
            let drained = readers.wait(timeout:.now()+0.5) == .success
            if !drained { try? pipe.fileHandleForReading.close() }
            guard !cancellation.isCancelled else { throw CancellationError() }
            guard drained else { throw CompanionError.expired }
            let (data,invalid)=capture.result()
            guard !expired,!invalid,process.terminationStatus==0 else{throw expired ? CompanionError.expired:CompanionError.unavailable}
            return data
    }
}
