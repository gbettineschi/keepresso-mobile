import Foundation
import CryptoKit
import Darwin
/// Synchronous atomic replace before side effects. A corrupt/missing-but-existing journal fails closed.
public final class MutationJournal {
    private struct Entry: Codable { var device: String; var fingerprint: String; var result: CommandResponse }
    private var entries: [String:Entry]; private let url: URL
    public init(url: URL) throws {
        self.url=url
        if FileManager.default.fileExists(atPath: url.path) { guard let size=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize,size<=8*1024*1024 else{throw CompanionError.limit}; entries=try WireJSON.decoder.decode([String:Entry].self,from: Data(contentsOf:url)) } else { entries=[:] }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try WireJSON.encoder.encode(entries).write(to:url,options:[.atomic,.completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        let handle=try FileHandle(forWritingTo:url);defer{try? handle.close()};try handle.synchronize()
        guard fcntl(handle.fileDescriptor,F_FULLFSYNC)==0 else{throw CompanionError.unavailable}
        let dir=open(url.deletingLastPathComponent().path,O_RDONLY);guard dir>=0 else{throw CompanionError.unavailable};defer{close(dir)}
        guard fsync(dir)==0 else{throw CompanionError.unavailable}
    }
    public func reserve(id: String, device: String, body: Data) throws -> CommandResponse? {
        let fingerprint=Data(SHA256.hash(data:body)).base64EncodedString()
        if let entry=entries[id] { guard entry.device==device,entry.fingerprint==fingerprint else { throw CompanionError.mismatch }; return entry.result }
        guard entries.count<10000 else { throw CompanionError.limit } // never evict IDs into replay eligibility
        entries[id]=Entry(device:device,fingerprint:fingerprint,result:CommandResponse(id:id,status:"uncertain",message:"An operation was reserved; its outcome may be unknown. It will not be replayed."))
        do { try persist() } catch { entries.removeValue(forKey:id); throw error }
        return nil
    }
    public func finish(id: String, result: CommandResponse) throws { guard var e=entries[id] else { throw CompanionError.invalid }; let previous=e; e.result=result; entries[id]=e; do { try persist() } catch { entries[id]=previous; throw error } }
}
