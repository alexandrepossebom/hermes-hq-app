// Grok Live's player after the engine's own restart (docs/spec/3x-grok-live.md §5). The owner's phone, builds 1058-1067:
// the hello's audio was queued and never played until the person spoke (which resets the player).

import AVFoundation
import Foundation
import Testing
@testable import HermesHQNative

@Suite(.serialized)
struct GrokPlayerTests {
    /// 200 ms of a quiet tone, PCM16 mono 24 kHz.
    private var piece: Data {
        var data = Data()
        for index in 0..<4_800 {
            let sample = Int16(600 * sin(Double(index) * 2 * .pi * 440 / 24_000))
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func playedOut(_ audio: GrokLiveAudio, atLeast count: Int, within seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if audio.played.out >= count { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return audio.played.out >= count
    }

    @Test func aPieceQueuedOnAFreshEnginePlaysOut() async throws {
        let audio = GrokLiveAudio()
        try audio.startSpeakerOnly()
        defer { audio.stop() }
        _ = audio.play(piece)
        #expect(await playedOut(audio, atLeast: 1, within: 3))
    }

    /// The engine stops for a hardware change and is started again: what is queued afterwards must still play, with
    /// nobody speaking first.
    @Test func piecesQueuedAfterTheEngineRestartedPlayOut() async throws {
        let audio = GrokLiveAudio()
        try audio.startSpeakerOnly()
        defer { audio.stop() }
        audio.stopEngineAsAHardwareChangeDoes()
        #expect(!audio.isRunning)
        #expect(audio.resume())
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<3 { _ = audio.play(piece) }
        #expect(await playedOut(audio, atLeast: 3, within: 4))
    }

    /// A reset player is given what was queued again, and plays it.
    @Test func aResetPlayerPlaysWhatWasQueued() async throws {
        let audio = GrokLiveAudio()
        try audio.startSpeakerOnly()
        defer { audio.stop() }
        for _ in 0..<3 { _ = audio.play(piece) }
        #expect(audio.revive() >= 1)                                 // the first may already have ended
        #expect(await playedOut(audio, atLeast: 2, within: 4))
        #expect(await { () async -> Bool in
            for _ in 0..<40 { if !audio.isPlaying { return true }; try? await Task.sleep(for: .milliseconds(50)) }
            return false
        }())
        #expect(!audio.isStalled)
    }

    /// A rebuilt engine is given what the old one still held.
    @Test func aRebuiltEngineIsGivenTheQueue() async throws {
        let audio = GrokLiveAudio()
        try audio.startSpeakerOnly()
        defer { audio.stop() }
        audio.stopEngineAsAHardwareChangeDoes()
        for _ in 0..<3 { _ = audio.play(piece) }
        let kept = audio.stop(keeping: true)
        #expect(kept.count == 3)
        #expect(!audio.isPlaying)
        try audio.startSpeakerOnly()
        audio.requeue(kept)
        #expect(await playedOut(audio, atLeast: 3, within: 4))
    }

    /// Queued on an engine that is not running, nothing plays: that is a stall, and only after the piece's own length
    /// and the grace.
    @Test func queuedAndNotPlayingIsAStall() async throws {
        let audio = GrokLiveAudio()
        try audio.startSpeakerOnly()
        defer { audio.stop() }
        audio.stopEngineAsAHardwareChangeDoes()
        _ = audio.play(piece)
        #expect(!audio.isStalled)
        try? await Task.sleep(for: .milliseconds(1_100))
        #expect(audio.isStalled)
        #expect(audio.played.out == 0)
    }
}
