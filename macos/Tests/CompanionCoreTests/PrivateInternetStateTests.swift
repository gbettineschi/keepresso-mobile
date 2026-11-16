import Foundation
import Testing
@testable import CompanionCore

struct PrivateInternetStateTests {
    @Test func stableSeedAndIndependentCorruptFiles() throws {
        let directory=URL(fileURLWithPath:"/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url=directory.appendingPathComponent("internet/seed.json")
        let seed=try PrivateInternetState(url:url).loadOrCreateSeed()
        #expect(seed.count==32)
        #expect(try PrivateInternetState(url:url).loadOrCreateSeed()==seed)
        try Data("broken notifications".utf8).write(to:directory.appendingPathComponent("firebase.json"))
        #expect(try PrivateInternetState(url:url).loadOrCreateSeed()==seed)
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:url.path)
        #expect(throws:Error.self){try PrivateInternetState(url:url).loadOrCreateSeed()}
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        try Data("corrupt".utf8).write(to:url)
        #expect(throws:Error.self){try PrivateInternetState(url:url).loadOrCreateSeed()}
        #expect(try String(contentsOf:url,encoding:.utf8)=="corrupt")
    }
    @Test func symlinkCannotRedirectSeedReadsOrWrites() throws {
        let directory=URL(fileURLWithPath:"/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let target=directory.appendingPathComponent("target")
        try Data("untouched".utf8).write(to:target)
        let link=directory.appendingPathComponent("seed.json")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        #expect(throws:Error.self){try PrivateInternetState(url:link).loadOrCreateSeed()}
        #expect(try String(contentsOf:target,encoding:.utf8)=="untouched")
    }
}

@MainActor struct InternetAdmissionTests {
    @Test func capacityDeadlinesAndLifecycle() throws {
        var clock=0.0
        let gate=InternetAdmission(now:{clock})
        let pending=try (0..<4).map{_ in try gate.acquire()}
        #expect(throws:Error.self){try gate.acquire()}
        for id in pending {try gate.authenticate(id)}
        let next=try (0..<4).map{_ in try gate.acquire()}
        for id in next {try gate.authenticate(id)}
        let ninth=try gate.acquire()
        #expect(throws:Error.self){try gate.authenticate(ninth)}
        gate.release(ninth)
        try gate.openStream(pending[0])
        #expect(throws:Error.self){try gate.openStream(pending[0])}
        clock=19; #expect(gate.valid(pending[0]))
        gate.activity(pending[0]); clock=21; #expect(gate.valid(pending[0]))
        gate.partial(pending[0]); clock=31; #expect(!gate.valid(pending[0]))
        gate.invalidate(); #expect(!gate.valid(next[0]))
        clock=100; let expired=try gate.acquire();clock=110; #expect(!gate.valid(expired))
    }
}
