import Foundation
import Testing
import KeepressoCore
struct ObserverTests {
    @Test func cpuFallbackPolicyIsPerRuleAndPartOfTheObserverSettings() throws {
        let data = Data("""
        {"triggersEnabled":true,"ruleSet":{"combine":"any","rules":[
          {"agentActivity":{"_0":{"grace":0,"countWaitingAsWorking":false}}},
          {"agentActivity":{"_0":{"grace":0,"countWaitingAsWorking":false,"allowCPUFallback":false}}},
          {"agentActivity":{"_0":{"grace":0,"countWaitingAsWorking":false,"allowCPUFallback":true}}}
        ]}}
        """.utf8)
        let settings = try CompanionObserverSettings.decode(data)
        #expect(settings.ruleSet.rules.count == 3)
        #expect(settings.evidenceOnlyAgentRuleIndices == [1])

        let changed = try CompanionObserverSettings.decode(Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"allowCPUFallback\":false", with: "\"allowCPUFallback\":true").utf8))
        #expect(settings.ruleSet == changed.ruleSet)
        #expect(settings != changed)
    }

    @Test func unknownAndMissingRulesCannotSilentlyBecomeAnEmptyDefault() throws {
        XCTAssertThrowsError(try CompanionObserverSettings.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try CompanionObserverSettings.decode(Data("{\"triggersEnabled\":true,\"ruleSet\":{\"combine\":\"any\",\"rules\":[{\"futureUnknownRule\":{}}]}}".utf8)))
    }
}
extension ObserverTests {
    @Test func hookReaderPrunesOnlyDisposableCopiesAndRemovesScratch()throws{
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);let source=base.appendingPathComponent("source");let scratch=base.appendingPathComponent("scratch");defer{try? FileManager.default.removeItem(at:base)}
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let record=AgentHooks.HookRecord(sessionId:"expired-test",state:.working,agentPid:2147483640,agent:"codex",updatedAt:Date(timeIntervalSince1970:0))
        AgentHooks.write(record,in:source)
        let urls=try FileManager.default.contentsOfDirectory(at:source,includingPropertiesForKeys:nil);let original=try Data(contentsOf:urls[0])
        let copied=CompanionHookCopies(source:source,root:scratch);XCTAssertTrue(copied.read(now:Date()).isEmpty)
        XCTAssertEqual(try Data(contentsOf:urls[0]),original)
        XCTAssertFalse(FileManager.default.fileExists(atPath:scratch.path))
    }
}
