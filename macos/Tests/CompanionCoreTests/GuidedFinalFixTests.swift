import Foundation
import Testing
@testable import KeepressoCore

struct GuidedFinalFixTests {
    @Test func incompleteAgentGraceNeedsDirectProofButCompleteIdleRetainsGrace() throws {
        let fixture = CompanionObservationInputsTests()
        var records = [AgentHooks.HookRecord(sessionId: "fixture", state: .working, agentPid: 42, agent: "codex", updatedAt: fixture.instant)]
        var raw = "42 1 0.0 ?? codex"
        var d = CompanionObservationDependencies()
        d.agents = {
            CompanionObservationAgentReader.read(raw: raw, now: fixture.instant, hookRecords: { _ in records }, hooksAvailable: { true }, pathOf: { _ in nil }, cwdOf: { _ in nil }, evidence: { _, _, _ in nil }, origin: { _ in nil }, codexWrite: { _ in nil })
        }
        let input = fixture.inputs(d, steam: .init()), rule = TriggerRule.agentActivity(.init(grace: 180))
        let trigger = try #require(input.factory.makeTrigger(for: rule) as? GracePeriodTrigger)
        func evaluate() -> Bool? {
            input.beginSample(); trigger.tick()
            return input.assessed(.init(rule: rule, satisfied: trigger.isSatisfied(), inGrace: !trigger.wrappedIsSatisfied && trigger.isSatisfied()))
        }
        #expect(evaluate() == true)
        records = []
        #expect(evaluate() == nil)
        #expect(trigger.isSatisfied() && !trigger.wrappedIsSatisfied)
        records = [.init(sessionId: "fixture", state: .idle, agentPid: 42, agent: "codex", updatedAt: fixture.instant)]
        #expect(evaluate() == true)
        #expect(!trigger.wrappedIsSatisfied)
        records = [.init(sessionId: "fixture", state: .working, agentPid: 42, agent: "codex", updatedAt: fixture.instant)]
        raw += "\n43 1 0.0 ?? codex"
        #expect(evaluate() == true)
        #expect(trigger.wrappedIsSatisfied)
    }
}
extension GuidedFinalFixTests {
    @Test func powerKeepsProviderAndChargingEvidenceIndependent() {
        let fixture = CompanionObservationInputsTests()
        var sample = CompanionObservationSystem.power(provider: .ac, charging: [nil, false])
        var d = CompanionObservationDependencies(); d.power = { sample }
        let input = fixture.inputs(d, steam: .init())
        func verdict(_ match: PowerSourceTrigger.Match) -> Bool? {
            input.beginSample(); return input.assessed(fixture.state(.powerSource(match), inputs: input))
        }
        #expect(verdict(.onACPower) == true)
        #expect(verdict(.onBattery) == false)
        #expect(verdict(.charging) == nil)
        sample = CompanionObservationSystem.power(provider: .battery, charging: nil)
        #expect(verdict(.onACPower) == false)
        #expect(verdict(.onBattery) == true)
        #expect(verdict(.charging) == nil)
        for sources: [Bool?] in [[true, nil], [nil, true]] {
            sample = CompanionObservationSystem.power(provider: .unknown, charging: sources)
            #expect(verdict(.charging) == true)
            #expect(verdict(.onACPower) == nil)
            #expect(verdict(.onBattery) == nil)
        }
        sample = CompanionObservationSystem.power(provider: .ac, charging: [false])
        #expect(verdict(.charging) == false)
        sample = CompanionObservationSystem.power(provider: .ac, charging: [])
        #expect(verdict(.charging) == false)
    }
    @Test func volumeMetadataFailuresKeepVerifiedSiblingNamesAndUnmatchedUnknown() {
        let fixture = CompanionObservationInputsTests()
        let target = URL(fileURLWithPath: "/fixture/target"), failed = URL(fileURLWithPath: "/fixture/failed")
        for urls in [[target, failed], [failed, target]] {
            let sample = CompanionObservationSystem.volumes(urls: urls) { url in
                if url == failed { throw ObserverError.unavailable }; return "FixtureDisk"
            }
            var d = CompanionObservationDependencies(); d.volumes = { sample }
            let input = fixture.inputs(d, steam: .init())
            #expect(input.assessed(fixture.state(.volumeMounted("FixtureDisk"), inputs: input)) == true)
            #expect(input.assessed(fixture.state(.volumeMounted("Other"), inputs: input)) == nil)
            #expect(input.assessed(.init(rule: .volumeMounted("FixtureDisk"), satisfied: true, inGrace: true)) == nil)
        }
        var d = CompanionObservationDependencies()
        d.volumes = { CompanionObservationSystem.volumes(urls: []) { _ in nil } }
        let input = fixture.inputs(d, steam: .init())
        #expect(input.assessed(fixture.state(.volumeMounted("Other"), inputs: input)) == false)
    }
    @Test func processRowsValidateIndependentlyWhileAgentTreeStaysStrict() {
        let fixture = CompanionObservationInputsTests()
        let raw = "42 1 0.0 ?? /fixture/WORKER --job\ninvalid row\n43 1 nan ?? /fixture/other\n0 0 0.0 ?? kernel_task\n44 1 -1 ?? invalid"
        var sample = CompanionObservationSystem.processes(raw)
        #expect(!CompanionObservationSystem.validPS(raw))
        #expect(sample.commands == ["/fixture/WORKER --job", "kernel_task"])
        #expect(!sample.complete)
        var d = CompanionObservationDependencies(); d.processes = { sample }
        let input = fixture.inputs(d, steam: .init())
        #expect(input.assessed(fixture.state(.process("worker"), inputs: input)) == true)
        #expect(input.assessed(fixture.state(.process("kernel_task"), inputs: input)) == true)
        #expect(input.assessed(fixture.state(.process("other"), inputs: input)) == nil)
        #expect(input.assessed(.init(rule: .process("worker"), satisfied: true, inGrace: true)) == nil)
        sample = CompanionObservationSystem.processes("42 1 0.0 ?? /fixture/WORKER --job")
        input.beginSample()
        #expect(input.assessed(fixture.state(.process("other"), inputs: input)) == false)
        sample = CompanionObservationSystem.processes("")
        input.beginSample()
        #expect(input.assessed(fixture.state(.process("worker"), inputs: input)) == false)
    }
}

extension GuidedFinalFixTests {
    @Test func reservedKernelRowDoesNotInvalidateAnOtherwiseCompleteAgentTree() {
        let fixture = CompanionObservationInputsTests()
        let raw = "0 0 0.0 ?? kernel_task\n42 1 0.0 ?? codex"
        #expect(CompanionObservationSystem.validPS(raw))
        let sample = CompanionObservationAgentReader.read(raw: raw, now: fixture.instant, hookRecords: { _ in [.init(sessionId: "fixture", state: .working, agentPid: 42, agent: "codex", updatedAt: fixture.instant)] }, hooksAvailable: { true }, pathOf: { _ in nil }, cwdOf: { _ in nil }, evidence: { _, _, _ in nil }, origin: { _ in nil }, codexWrite: { _ in nil })
        var d = CompanionObservationDependencies(); d.agents = { sample }
        let input = fixture.inputs(d, steam: .init())
        #expect(input.assessed(fixture.state(.agentActivity(.init(grace: 0)), inputs: input)) == true)
        for invalid in ["-1 0 0.0 ?? bad", "0 1 0.0 ?? kernel_task", "0 0 0.0 ?? arbitrary", "43 1 nan ?? broken", "malformed row"] {
            #expect(!CompanionObservationSystem.validPS(raw + "\n" + invalid))
            #expect(CompanionObservationAgentReader.read(raw: raw + "\n" + invalid, now: fixture.instant, hookRecords: { _ in [] }, hooksAvailable: { true }, pathOf: { _ in nil }, cwdOf: { _ in nil }, evidence: { _, _, _ in nil }, origin: { _ in nil }, codexWrite: { _ in nil }) == nil)
        }
    }
}
