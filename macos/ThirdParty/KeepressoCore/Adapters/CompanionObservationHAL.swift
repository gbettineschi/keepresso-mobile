import Foundation
import CoreAudio
import CoreMediaIO

/// State properties only. No capture sessions, device opens, recording or
/// microphone/camera consent requests are used by these reads.
enum CompanionObservationHAL {
    struct Flag { var active: Bool; var complete: Bool }
    struct Audio { var input: Flag; var output: Flag }
    struct Capturers { var values: Set<String>; var complete: Bool }

    static func assemble(camera: Flag, audio: Audio, capturers: () -> Capturers) -> CompanionObservationMedia {
        let ids = audio.input.complete && !audio.input.active ? Capturers(values: [], complete: true) : capturers()
        return .init(snapshot: .init(cameraInUse: camera.active, microphoneInUse: audio.input.active, audioPlaying: audio.output.active, micCapturingBundleIDs: ids.values), cameraComplete: camera.complete, microphoneComplete: audio.input.complete, capturersComplete: ids.complete, audioComplete: audio.output.complete)
    }
    static func cameraEvidence(devices: [UInt32]?, running: (UInt32) -> Bool?) -> Flag {
        guard let devices else { return .init(active: false, complete: false) }
        var result = Flag(active: false, complete: true)
        for device in devices {
            guard let value = running(device) else { result.complete = false; continue }
            result.active = result.active || value
        }
        return result
    }
    static func audioEvidence(devices: [UInt32]?, running: (UInt32) -> Bool?, inputStreams: (UInt32) -> Bool?, outputStreams: (UInt32) -> Bool?) -> Audio {
        guard let devices else { return .init(input: .init(active: false, complete: false), output: .init(active: false, complete: false)) }
        var result = Audio(input: .init(active: false, complete: true), output: .init(active: false, complete: true))
        for device in devices {
            guard let active = running(device) else { result.input.complete = false; result.output.complete = false; continue }
            guard active else { continue }
            if let input = inputStreams(device) { result.input.active = result.input.active || input }
            else { result.input.complete = false }
            if let output = outputStreams(device) { result.output.active = result.output.active || output }
            else { result.output.complete = false }
        }
        return result
    }
    static func capturerEvidence(processes: [UInt32]?, running: (UInt32) -> Bool?, bundleID: (UInt32) -> String?) -> Capturers {
        guard let processes else { return .init(values: [], complete: false) }
        var result = Capturers(values: [], complete: true)
        for process in processes {
            guard let active = running(process) else { result.complete = false; continue }
            guard active else { continue }
            guard let id = bundleID(process), !id.isEmpty else { result.complete = false; continue }
            result.values.insert(id)
        }
        return result
    }
    static func read() -> CompanionObservationMedia {
        assemble(camera: camera(), audio: audio(), capturers: capturers)
    }
    private static func camera() -> Flag {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == kCMIOHardwareNoError,
              size % UInt32(MemoryLayout<CMIOObjectID>.size) == 0 else { return .init(active: false, complete: false) }
        if size == 0 { return .init(active: false, complete: true) }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == kCMIOHardwareNoError, used == size else { return .init(active: false, complete: false) }
        var runningAddress = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        return cameraEvidence(devices: devices) { device in
            var running: UInt32 = 0; var used: UInt32 = 0
            guard CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == kCMIOHardwareNoError, used == MemoryLayout<UInt32>.size else { return nil }
            return running != 0
        }
    }
    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0; let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return nil }
        if size == 0 { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let expected = size
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &result) == noErr, size == expected else { return nil }
        return result
    }
    private static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, size == MemoryLayout<UInt32>.size else { return nil }
        return value != 0
    }
    private static func streams(_ object: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        return size > 0
    }
    private static func audio() -> Audio {
        audioEvidence(devices: objects(kAudioHardwarePropertyDevices), running: { flag($0, kAudioDevicePropertyDeviceIsRunningSomewhere) }, inputStreams: { streams($0, kAudioObjectPropertyScopeInput) }, outputStreams: { streams($0, kAudioObjectPropertyScopeOutput) })
    }
    private static func capturers() -> Capturers {
        capturerEvidence(processes: objects(kAudioHardwarePropertyProcessObjectList), running: { flag($0, kAudioProcessPropertyIsRunningInput) }, bundleID: capturerBundleID)
    }
    private static func capturerBundleID(_ process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size); var out: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &out) { AudioObjectGetPropertyData(process, &address, 0, nil, &size, $0) }
        guard status == noErr, let id = out?.takeRetainedValue() as String?, !id.isEmpty else { return nil }
        return id
    }
}
