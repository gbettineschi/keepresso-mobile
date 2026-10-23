import Foundation
import Darwin
import CryptoKit

/// Local authorization survives a Keychain or remote cleanup failure. The in-memory
/// tombstone is deliberately retained even when durable storage fails.
public final class DeviceRevocations {
    private let url:URL;private var devices:Set<String>
    public init(url:URL)throws {
        self.url=url
        if FileManager.default.fileExists(atPath:url.path) {
            let data=try Data(contentsOf:url);guard data.count<=1024*1024 else{throw CompanionError.limit}
            devices=try WireJSON.decoder.decode(Set<String>.self,from:data)
            guard devices.count<=10000,devices.allSatisfy(WireCrypto.validID) else{throw CompanionError.invalid}
        }else{devices=[]}
    }
    public func contains(_ device:String)->Bool{devices.contains(device)}
    public func revoke(_ device:String)throws {
        guard WireCrypto.validID(device) else{throw CompanionError.invalid}
        devices.insert(device)
        try PrivateDurableFile.save(WireJSON.encoder.encode(devices),to:url)
    }
}

public enum PrivateDurableFile {
    public static func save(_ data:Data,to url:URL)throws {
        let directory=url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath:directory.path){try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        try data.write(to:url,options:[.atomic,.completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        let handle=try FileHandle(forWritingTo:url);defer{try? handle.close()};try handle.synchronize()
        guard fcntl(handle.fileDescriptor,F_FULLFSYNC)==0 else{throw CompanionError.unavailable}
        let parent=open(directory.path,O_RDONLY);guard parent>=0 else{throw CompanionError.unavailable};defer{close(parent)}
        guard fsync(parent)==0 else{throw CompanionError.unavailable}
    }
}

/// Only response/event envelopes are retried. Exact ciphertext, nonce and metadata
/// survive retries and process restarts. Commands never enter this store.
public final class RelayOutbox {
    private struct Record:Codable {var envelope:RelayEnvelope;var uploaded:Bool;var bodyDigest:String?}
    private struct State:Codable {var events:[CompanionEvent]=[];var records:[Record]=[]}
    private let url:URL;private var state:State
    public init(url:URL)throws {
        self.url=url
        if FileManager.default.fileExists(atPath:url.path) {
            let data=try Data(contentsOf:url);guard data.count<=8*1024*1024 else{throw CompanionError.limit}
            state=try WireJSON.decoder.decode(State.self,from:data)
            guard state.events.count<=128,state.records.count<=512,state.records.allSatisfy({["event","response"].contains($0.envelope.kind) && $0.envelope.direction=="s2c"}) else{throw CompanionError.invalid}
        }else{state=State()}
    }
    private func persist(_ updated:State)throws {
        let data=try WireJSON.encoder.encode(updated);guard updated.events.count<=128,updated.records.count<=512,data.count<=8*1024*1024 else{throw CompanionError.limit}
        try PrivateDurableFile.save(data,to:url);state=updated
    }
    private func pruned(now:Date)->State {
        var next=state
        next.events.removeAll{now.timeIntervalSince($0.createdAt)>=300 || $0.createdAt.timeIntervalSince(now)>10}
        next.records.removeAll{Double($0.envelope.expiresAt)<=now.timeIntervalSince1970}
        return next
    }
    public func enqueue(_ event:CompanionEvent,devices:[AuthorizedDevice],macId:String,epoch:String,now:Date)throws {
        guard WireCrypto.validID(event.id),devices.count<=8,now.timeIntervalSince(event.createdAt)<300,event.createdAt.timeIntervalSince(now)<=10 else{throw CompanionError.invalid}
        var next=pruned(now:now)
        if let old=next.events.first(where:{$0.id==event.id}) {
            guard try WireJSON.encoder.encode(old)==WireJSON.encoder.encode(event) else{throw CompanionError.mismatch};return
        }
        let payload=try WireJSON.data(["type":"event","event":WireJSON.object(WireJSON.encoder.encode(event))])
        for device in devices {
            let envelope=try RelayEnvelope.seal(payload,key:device.key,macId:macId,deviceId:device.deviceId,id:event.id,epoch:epoch,direction:"s2c",kind:"event",now:event.createdAt,lifetime:300)
            next.records.append(Record(envelope:envelope,uploaded:false))
        }
        next.events.append(event);try persist(next)
    }
    public func response(id:String,deviceId:String,epoch:String,body:Data,now:Date)throws->RelayEnvelope? {
        guard let record=state.records.first(where:{$0.envelope.kind=="response" && $0.envelope.id==id && $0.envelope.deviceId==deviceId && $0.envelope.epoch==epoch && Double($0.envelope.expiresAt)>now.timeIntervalSince1970}) else{return nil}
        guard record.bodyDigest==Data(SHA256.hash(data:body)).base64EncodedString() else{throw CompanionError.mismatch}
        return record.envelope
    }
    public func addResponse(_ envelope:RelayEnvelope,body:Data,now:Date)throws {
        guard envelope.kind=="response",envelope.direction=="s2c" else{throw CompanionError.invalid}
        try envelope.validate(now:now)
        if let old=try response(id:envelope.id,deviceId:envelope.deviceId,epoch:envelope.epoch,body:body,now:now){guard old==envelope else{throw CompanionError.mismatch};return}
        var next=pruned(now:now);next.records.append(Record(envelope:envelope,uploaded:false,bodyDigest:Data(SHA256.hash(data:body)).base64EncodedString()));try persist(next)
    }
    public func pending(epoch:String,devices:Set<String>,nearby:Set<String>,now:Date)->[RelayEnvelope] {
        state.records.filter{!$0.uploaded && devices.contains($0.envelope.deviceId) && ($0.envelope.kind != "event" || !nearby.contains($0.envelope.deviceId)) && Double($0.envelope.expiresAt)>now.timeIntervalSince1970}.map(\.envelope)
    }
    public func uploaded(_ envelopes:[RelayEnvelope],now:Date)throws {
        guard !envelopes.isEmpty else{return}
        var next=pruned(now:now)
        for envelope in envelopes {if let i=next.records.firstIndex(where:{$0.envelope==envelope}){next.records[i].uploaded=true}}
        try persist(next)
    }
    public func events(now:Date)->[CompanionEvent] {pruned(now:now).events}
    public func events(deviceId:String,epoch:String,now:Date)->[CompanionEvent] {
        let ids=Set(state.records.filter{$0.envelope.deviceId==deviceId && $0.envelope.kind=="event" && Double($0.envelope.expiresAt)>now.timeIntervalSince1970}.map{$0.envelope.id})
        return events(now:now).filter{ids.contains($0.id)}
    }
    public func revoke(_ device:String,now:Date)throws {var next=pruned(now:now);next.records.removeAll{$0.envelope.deviceId==device};try persist(next)}
}
