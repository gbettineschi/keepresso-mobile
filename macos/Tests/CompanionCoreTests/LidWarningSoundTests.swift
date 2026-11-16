import Testing
@testable import CompanionCore

@MainActor struct LidWarningSoundTests {
    @MainActor private final class Fixture {
        var muted: Bool? = true
        var acceptsWrites = true
        var canPlay = true
        var writes: [Bool] = []
        var route: String?
        var ended: (@MainActor () -> Void)?
        var stopCount = 0
        var starts = 0

        func player() -> LidWarningSound {
            LidWarningSound(makePlayback: {
                LidWarningSound.Playback(duration: 1, routeTo: { self.route = $0 }, start: {
                    self.starts += 1
                    self.ended = $0
                    return self.canPlay
                }, stop: { self.stopCount += 1 })
            }, currentOutput: {
                LidWarningSound.Output(uid: "fixture-output", isMuted: { self.muted }, setMuted: {
                    self.writes.append($0)
                    guard self.acceptsWrites else { return false }
                    self.muted = $0
                    return true
                })
            })
        }
    }

    @Test func defaultPlaybackLeavesMuteAlone() {
        let audio = Fixture()
        let player = audio.player()
        player.play(evenIfMuted: false)
        #expect(audio.starts == 1)
        #expect(audio.writes.isEmpty)
        #expect(audio.route == nil)
        audio.ended?()
        #expect(audio.muted == true)
    }

    @Test func optedInPlaybackPinsOutputAndRestoresMuteAtCompletion() {
        let audio = Fixture()
        let player = audio.player()
        player.play(evenIfMuted: true)
        player.play(evenIfMuted: true)
        #expect(audio.starts == 1)
        #expect(audio.route == "fixture-output")
        #expect(audio.writes == [false])
        audio.ended?()
        #expect(audio.writes == [false, true])
    }

    @Test func playbackFailureOrShutdownRestoresMuteImmediately() {
        let audio = Fixture()
        let player = audio.player()
        audio.canPlay = false
        player.play(evenIfMuted: true)
        #expect(audio.writes == [false, true])
        audio.canPlay = true
        player.play(evenIfMuted: true)
        player.stop()
        #expect(audio.stopCount == 1)
        #expect(audio.writes == [false, true, false, true])
    }

    @Test func existingUnmuteAndUnsupportedOutputsAreLeftAlone() {
        let audio = Fixture()
        let player = audio.player()
        for setting: Bool? in [false, nil] {
            audio.muted = setting
            player.play(evenIfMuted: true)
            audio.ended?()
        }
        #expect(audio.starts == 2)
        #expect(audio.writes.isEmpty)
        #expect(audio.route == nil)
    }
}
