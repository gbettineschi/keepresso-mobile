import Foundation
import Testing
@testable import KeepressoCore

struct CompanionObservationPartialEvidenceTests {
    @Test func directPartialMediaPositivesSurviveButUnmatchedAndGraceOnlyResultsStayUnknown() {
        let fixture = CompanionObservationInputsTests()
        var sample = CompanionObservationMedia(snapshot: .init(cameraInUse: true, microphoneInUse: true, audioPlaying: true, micCapturingBundleIDs: ["org.fixture.call.helper"]), cameraComplete: false, microphoneComplete: false, capturersComplete: false, audioComplete: false)
        var d = CompanionObservationDependencies(); d.media = { sample }
        let input = fixture.inputs(d, steam: .init())
        for rule in [TriggerRule.mediaInUse(.camera), .mediaInUse(.microphone), .micInUse(.init(apps: [.init(bundleID: "org.fixture.call")]))] {
            #expect(input.assessed(fixture.state(rule, inputs: input)) == true)
        }
        #expect(input.assessed(fixture.state(.micInUse(.init(apps: [.init(bundleID: "org.fixture.other")])), inputs: input)) == nil)
        let audio = input.factory.makeTrigger(for: .audioPlaying); audio.tick()
        #expect(input.assessed(.init(rule: .audioPlaying, satisfied: audio.isSatisfied(), inGrace: false)) == true)
        sample = .init(snapshot: .init(), cameraComplete: false, microphoneComplete: false, capturersComplete: false, audioComplete: false)
        input.beginSample(); audio.tick()
        #expect(audio.isSatisfied())
        #expect(input.assessed(.init(rule: .audioPlaying, satisfied: audio.isSatisfied(), inGrace: true)) == nil)
        #expect(input.assessed(fixture.state(.mediaInUse(.camera), inputs: input)) == nil)
    }
    @Test func verifiedFreshPartialDownloadSurvivesSiblingFailureButIncompleteGraceDoesNot() {
        let fixture = CompanionObservationInputsTests()
        let marker = fixture.folder.appendingPathComponent("fresh.part"), broken = fixture.folder.appendingPathComponent("broken.part")
        let scanner = CompanionObservationDownloadScanner(list: { _ in [marker, broken] }, metadata: { url in
            if url == broken { throw ObserverError.unavailable }
            return .init(modified: fixture.instant, directory: url == fixture.folder)
        })
        var sample = scanner.read(in: fixture.folder)
        #expect(sample?.newestWrite == fixture.instant); #expect(sample?.complete == false)
        var d = CompanionObservationDependencies(); d.downloads = { _ in sample }
        let input = fixture.inputs(d, steam: .init()), rule = TriggerRule.downloadInFolder(fixture.folder)
        let trigger = input.factory.makeTrigger(for: rule); trigger.tick()
        #expect(input.assessed(.init(rule: rule, satisfied: trigger.isSatisfied(), inGrace: false)) == true)
        sample = .init(newestWrite: nil, complete: false)
        input.beginSample(); trigger.tick()
        #expect(trigger.isSatisfied())
        #expect(input.assessed(.init(rule: rule, satisfied: trigger.isSatisfied(), inGrace: true)) == nil)
        sample = .init(newestWrite: fixture.instant.addingTimeInterval(-600), complete: false)
        input.beginSample(); trigger.tick()
        #expect(input.assessed(.init(rule: rule, satisfied: trigger.isSatisfied(), inGrace: true)) == nil)
    }
    @Test func downloadInspectionLimitRetainsAnAlreadyVerifiedMarker() {
        let fixture = CompanionObservationInputsTests(), marker = URL(fileURLWithPath: "/fixture/downloads/fresh.download")
        let scanner = CompanionObservationDownloadScanner(list: { url in
            url == fixture.folder ? [marker] : (0..<9000).map { marker.appendingPathComponent("child-\($0)") }
        }, metadata: { url in
            if url != fixture.folder && url != marker { Issue.record("inspection exceeded the bound") }
            return .init(modified: fixture.instant, directory: true)
        })
        let sample = scanner.read(in: fixture.folder)
        #expect(sample?.newestWrite == fixture.instant)
        #expect(sample?.complete == false)
    }
}
extension CompanionObservationPartialEvidenceTests {
    @Test func missingCriticalHIDMetadataCannotInventOrExcludeAController() {
        typealias Device = CompanionObservationSystem.HIDDevice
        let vendor = 0x28DE
        for incomplete in [Device(vendorID: vendor, transport: "USB", productID: nil), Device(vendorID: vendor, transport: nil, productID: 0x1142), Device(vendorID: nil, transport: "USB", productID: 0x1102)] {
            #expect(CompanionObservationSystem.controllerCount(frameworkCount: 0, devices: [incomplete]) == nil)
            #expect(CompanionObservationSystem.controllerCount(frameworkCount: 1, devices: [incomplete]) == 1)
        }
        let receiver = Device(vendorID: vendor, transport: "USB", productID: 0x1142)
        #expect(CompanionObservationSystem.controllerCount(frameworkCount: 0, devices: [receiver]) == 0)
        #expect(CompanionObservationSystem.controllerCount(frameworkCount: 0, devices: [receiver, .init(vendorID: vendor, transport: "USB", productID: nil)]) == nil)
        let direct = Device(vendorID: vendor, transport: "USB", productID: 0x1102)
        #expect(CompanionObservationSystem.controllerCount(frameworkCount: 0, devices: [direct, .init(vendorID: nil, transport: nil, productID: nil)]) == 1)
        #expect(CompanionObservationSystem.controllerCount(frameworkCount: 0, devices: [receiver, .init(vendorID: vendor, transport: "Virtual", productID: 0x1102)]) == 1)
        #expect(CompanionObservationSystem.controllerCount(frameworkCount: 0, devices: []) == 0)
        #expect(CompanionObservationSystem.controllerCount(frameworkCount: 0, devices: nil) == nil)
    }
    @Test func connectedNamedBluetoothTargetSurvivesUnnamedSiblingButNonMatchStaysUnknown() {
        let fixture = CompanionObservationInputsTests()
        var sample = CompanionObservationSystem.bluetooth(devices: [.init(name: "Fixture Pad", connected: true), .init(name: nil, connected: true)])
        var d = CompanionObservationDependencies(); d.bluetooth = { sample }
        let input = fixture.inputs(d, steam: .init())
        #expect(input.assessed(fixture.state(.bluetoothDevice("FIXTURE PAD"), inputs: input)) == true)
        #expect(input.assessed(fixture.state(.bluetoothDevice("Other"), inputs: input)) == nil)
        let trigger = input.factory.makeTrigger(for: .bluetoothDevice("Fixture Pad")); trigger.tick()
        #expect(trigger.isSatisfied())
        sample = CompanionObservationSystem.bluetooth(devices: [.init(name: nil, connected: true)])
        input.beginSample(); trigger.tick()
        #expect(trigger.isSatisfied())
        #expect(input.assessed(.init(rule: .bluetoothDevice("Fixture Pad"), satisfied: trigger.isSatisfied(), inGrace: true)) == nil)
        sample = CompanionObservationSystem.bluetooth(devices: [])
        input.beginSample()
        #expect(input.assessed(fixture.state(.bluetoothDevice("Other"), inputs: input)) == false)
    }
    @Test func knownCloudAndSteamGamingIdentityDoesNotNeedReadableCategoryMetadata() {
        let fixture = CompanionObservationInputsTests()
        for (id, path) in [(Optional("com.nvidia.gfnpc.mall"), Optional<String>.none), (nil, "/fixture/steamapps/common/Game.app")] {
            let sample = CompanionObservationSystem.gaming(bundleID: id, path: path) { Issue.record("metadata read despite independent game identity"); return nil }
            var d = CompanionObservationDependencies(); d.gaming = { sample }
            let input = fixture.inputs(d, steam: .init())
            #expect(input.assessed(fixture.state(.gaming, inputs: input)) == true)
        }
        var sample = CompanionObservationSystem.gaming(bundleID: "org.fixture.non-game", path: "/fixture/NonGame.app", metadata: { nil })
        var d = CompanionObservationDependencies(); d.gaming = { sample }
        let input = fixture.inputs(d, steam: .init())
        #expect(input.assessed(fixture.state(.gaming, inputs: input)) == nil)
        sample = CompanionObservationSystem.gaming(bundleID: "org.fixture.non-game", path: "/fixture/NonGame.app", metadata: { ["LSApplicationCategoryType": "public.app-category.productivity"] })
        input.beginSample()
        #expect(input.assessed(fixture.state(.gaming, inputs: input)) == false)
    }
}
extension CompanionObservationPartialEvidenceTests {
    @Test func cameraAggregationRetainsActiveEvidenceAcrossAnotherDeviceFailure() {
        let fixture = CompanionObservationInputsTests()
        let active = CompanionObservationHAL.cameraEvidence(devices: [1, 2], running: { $0 == 1 ? true : nil })
        #expect(active.active); #expect(!active.complete)
        let none = CompanionObservationHAL.cameraEvidence(devices: [1], running: { _ in nil })
        #expect(!none.active && !none.complete)
        let idle = CompanionObservationHAL.cameraEvidence(devices: [], running: { _ in Issue.record("read of absent camera"); return nil })
        #expect(!idle.active && idle.complete)
        var d = CompanionObservationDependencies()
        d.media = { CompanionObservationHAL.assemble(camera: active, audio: .init(input: .init(active: false, complete: true), output: .init(active: false, complete: true)), capturers: { Issue.record("idle mic queried"); return .init(values: [], complete: false) }) }
        let input = fixture.inputs(d, steam: .init())
        #expect(input.assessed(fixture.state(.mediaInUse(.camera), inputs: input)) == true)
    }
    @Test func audioAggregationPreservesIndependentInputAndOutputAcrossFailedScopesAndDevices() {
        let fixture = CompanionObservationInputsTests()
        let audio = CompanionObservationHAL.audioEvidence(devices: [1, 2, 3], running: { $0 == 3 ? nil : true }, inputStreams: { $0 == 1 ? true : nil }, outputStreams: { $0 == 2 ? true : nil })
        #expect(audio.input.active && audio.output.active)
        #expect(!audio.input.complete && !audio.output.complete)
        let inputOnly = CompanionObservationHAL.audioEvidence(devices: [1], running: { _ in true }, inputStreams: { _ in true }, outputStreams: { _ in nil })
        #expect(inputOnly.input.active && inputOnly.input.complete)
        #expect(!inputOnly.output.active && !inputOnly.output.complete)
        var sample = CompanionObservationHAL.assemble(camera: .init(active: false, complete: true), audio: audio, capturers: { .init(values: [], complete: false) })
        var d = CompanionObservationDependencies(); d.media = { sample }
        let input = fixture.inputs(d, steam: .init())
        #expect(input.assessed(fixture.state(.mediaInUse(.microphone), inputs: input)) == true)
        let trigger = input.factory.makeTrigger(for: .audioPlaying); trigger.tick()
        #expect(input.assessed(.init(rule: .audioPlaying, satisfied: trigger.isSatisfied(), inGrace: false)) == true)
        sample = .init(snapshot: .init(), cameraComplete: false, microphoneComplete: false, capturersComplete: false, audioComplete: false)
        input.beginSample(); trigger.tick()
        #expect(trigger.isSatisfied())
        #expect(input.assessed(.init(rule: .audioPlaying, satisfied: trigger.isSatisfied(), inGrace: true)) == nil)
        #expect(input.assessed(fixture.state(.mediaInUse(.microphone), inputs: input)) == nil)
    }
    @Test func capturerAggregationRetainsMatchingIDsAcrossFailedProcessesAndBundleProperties() {
        let fixture = CompanionObservationInputsTests()
        for bundleFailure in [true, false] {
            let ids = CompanionObservationHAL.capturerEvidence(processes: [1, 2], running: { $0 == 2 && !bundleFailure ? nil : true }, bundleID: { $0 == 1 ? "org.fixture.call.helper" : nil })
            #expect(ids.values == ["org.fixture.call.helper"]); #expect(!ids.complete)
            var d = CompanionObservationDependencies()
            d.media = { CompanionObservationHAL.assemble(camera: .init(active: false, complete: true), audio: .init(input: .init(active: true, complete: false), output: .init(active: false, complete: true)), capturers: { ids }) }
            let input = fixture.inputs(d, steam: .init())
            #expect(input.assessed(fixture.state(.micInUse(.init(apps: [.init(bundleID: "org.fixture.call")])), inputs: input)) == true)
            #expect(input.assessed(fixture.state(.micInUse(.init(apps: [.init(bundleID: "org.fixture.other")])), inputs: input)) == nil)
        }
    }
}
extension CompanionObservationPartialEvidenceTests {
    @Test func safariChildReadFailureStillAllowsAnotherVerifiedFreshChild() {
        let fixture = CompanionObservationInputsTests(), marker = URL(fileURLWithPath: "/fixture/downloads/fresh.download")
        let broken = marker.appendingPathComponent("broken"), fresh = marker.appendingPathComponent("fresh")
        let scanner = CompanionObservationDownloadScanner(list: { $0 == fixture.folder ? [marker] : [broken, fresh] }, metadata: { url in
            if url == broken { throw ObserverError.unavailable }
            return .init(modified: url == fresh ? fixture.instant : fixture.instant.addingTimeInterval(-600), directory: url != fresh)
        })
        let sample = scanner.read(in: fixture.folder)
        #expect(sample?.newestWrite == fixture.instant); #expect(sample?.complete == false)
        var d = CompanionObservationDependencies(); d.downloads = { _ in sample }
        let input = fixture.inputs(d, steam: .init())
        #expect(input.assessed(fixture.state(.downloadInFolder(fixture.folder), inputs: input)) == true)
    }
    @Test func topLevelInspectionLimitKeepsFreshEvidenceFromInspectedPrefix() {
        let fixture = CompanionObservationInputsTests()
        let entries = (0..<4097).map { fixture.folder.appendingPathComponent("marker-\($0).part") }
        let scanner = CompanionObservationDownloadScanner(list: { _ in entries }, metadata: { url in
            if url == entries[4096] { Issue.record("metadata read beyond top-level bound") }
            return .init(modified: url == entries[0] ? fixture.instant : fixture.instant.addingTimeInterval(-600), directory: url == fixture.folder)
        })
        let sample = scanner.read(in: fixture.folder)
        #expect(sample?.newestWrite == fixture.instant); #expect(sample?.complete == false)
    }
    @Test func gamingGraceAfterUnreadableNonGameInputDoesNotBecomeDirectProof() {
        let fixture = CompanionObservationInputsTests()
        var sample = CompanionObservationSystem.gaming(bundleID: "com.nvidia.gfnpc.mall", path: nil, metadata: { nil })
        var d = CompanionObservationDependencies(); d.gaming = { sample }
        let input = fixture.inputs(d, steam: .init()), trigger = input.factory.makeTrigger(for: .gaming)
        trigger.tick(); #expect(input.assessed(.init(rule: .gaming, satisfied: trigger.isSatisfied(), inGrace: false)) == true)
        sample = CompanionObservationSystem.gaming(bundleID: "org.fixture.other", path: nil, metadata: { nil })
        input.beginSample(); trigger.tick()
        #expect(trigger.isSatisfied())
        #expect((trigger as? GracePeriodTrigger)?.wrappedIsSatisfied == false)
        #expect(input.assessed(.init(rule: .gaming, satisfied: trigger.isSatisfied(), inGrace: true)) == nil)
    }
}
