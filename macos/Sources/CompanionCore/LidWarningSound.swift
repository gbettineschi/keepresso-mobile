import AppKit
import CoreAudio
import os

@MainActor public final class LidWarningSound {
    public static let overrideMutePreference = "playLidWarningWhenMuted"

    struct Playback {
        let duration: TimeInterval
        let routeTo: (String) -> Void
        let start: (@escaping @MainActor () -> Void) -> Bool
        let stop: () -> Void
    }

    struct Output {
        let uid: String
        let isMuted: () -> Bool?
        let setMuted: (Bool) -> Bool
    }

    private let makePlayback: () -> Playback?
    private let currentOutput: () -> Output?
    private var active: (id: UUID, playback: Playback, temporarilyUnmuted: Output?)?
    private var timeout: Task<Void, Never>?
    private let logger = Logger(subsystem: "local.keespresso.companion", category: "lid-warning-sound")

    public convenience init() {
        self.init(makePlayback: GlassSound.make, currentOutput: Self.mainOutput)
    }

    init(makePlayback: @escaping () -> Playback?, currentOutput: @escaping () -> Output?) {
        self.makePlayback = makePlayback
        self.currentOutput = currentOutput
    }

    public func play(evenIfMuted: Bool) {
        guard active == nil, let playback = makePlayback() else { return }
        var temporarilyUnmuted: Output?
        if evenIfMuted, let output = currentOutput(), output.isMuted() == true, output.setMuted(false) {
            playback.routeTo(output.uid)
            temporarilyUnmuted = output
        }

        let id = UUID()
        active = (id, playback, temporarilyUnmuted)
        guard playback.start({ [weak self] in self?.finish(id, stopPlayback: false) }) else {
            finish(id, stopPlayback: false)
            return
        }
        guard active?.id == id else { return }
        let bound = playback.duration.isFinite ? min(max(playback.duration + 0.5, 1), 4) : 4
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(bound)) } catch { return }
            self?.finish(id, stopPlayback: true)
        }
    }

    public func stop() {
        if let id = active?.id { finish(id, stopPlayback: true) }
    }

    private func finish(_ id: UUID, stopPlayback: Bool) {
        guard let completed = active, completed.id == id else { return }
        active = nil
        timeout?.cancel()
        timeout = nil
        if stopPlayback { completed.playback.stop() }
        if let output = completed.temporarilyUnmuted, output.isMuted() == false, !output.setMuted(true) {
            logger.error("Could not restore mute on the lid warning’s audio output.")
        }
    }

    private static func mainOutput() -> Output? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = kAudioObjectUnknown
        var size = UInt32(MemoryLayout.size(ofValue: device))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              let uid = deviceUID(device) else { return nil }

        let mute = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var muteAddress = mute
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &muteAddress, &settable) == noErr, settable.boolValue else { return nil }
        return Output(uid: uid, isMuted: {
            guard deviceUID(device) == uid else { return nil }
            var address = mute
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout.size(ofValue: value))
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value != 0
        }, setMuted: { muted in
            guard deviceUID(device) == uid else { return false }
            var address = mute
            var value: UInt32 = muted ? 1 : 0
            let size = UInt32(MemoryLayout.size(ofValue: value))
            return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
        })
    }

    private static func deviceUID(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: uid))
        guard device != kAudioObjectUnknown,
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

@MainActor private final class GlassSound: NSObject, NSSoundDelegate {
    private let audio: NSSound
    private var ended: (@MainActor () -> Void)?

    private init(_ audio: NSSound) { self.audio = audio }

    static func make() -> LidWarningSound.Playback? {
        guard let audio = NSSound(named: NSSound.Name("Glass"))?.copy() as? NSSound else { return nil }
        let glass = GlassSound(audio)
        return .init(duration: audio.duration, routeTo: { audio.playbackDeviceIdentifier = $0 }, start: { ended in
            glass.ended = ended
            audio.delegate = glass
            return audio.play()
        }, stop: { _ = audio.stop() })
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        ended?()
        ended = nil
    }
}
