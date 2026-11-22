// A clip of the computer's voice that would not play (docs/spec/3x-talk.md §3.4, #412): a playable kind is tried the
// tolerant ways (its real kind, a temporary file, the audio session set active again) and then reported as a playback
// failure with its reason, never as "a format iPhone can't play"; only bytes no player here reads are the format.

import AVFAudio
import Foundation
import Testing
@testable import HermesHQNative

@Suite("Speech clip playback")
@MainActor
struct SpeechClipPlaybackTests {
    nonisolated static func bytes(_ values: [UInt8], padTo count: Int = 64) -> Data {
        Data(values + [UInt8](repeating: 0, count: max(0, count - values.count)))
    }

    /// A short silent WAV.
    nonisolated static let wav: Data = {
        var wav = Data("RIFF".utf8)
        func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        let pcm = Data(count: 1_600)
        wav += le32(36 + pcm.count) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(16_000) + le32(32_000) + le16(2) + le16(16)
        wav += Data("data".utf8) + le32(pcm.count) + pcm
        return wav
    }()

    // MARK: What the bytes are

    @Test func theFirstBytesSayWhatAClipIs() {
        // MPEG-2 Layer III, 24 kHz mono (the clip in #412), and MPEG-1 Layer III.
        #expect(VoiceWire.sniff(Self.bytes([0xFF, 0xF3, 0x64, 0xC4])) == .mp3)
        #expect(VoiceWire.sniff(Self.bytes([0xFF, 0xFB, 0x90, 0x64])) == .mp3)
        // ADTS AAC (MPEG-4 and MPEG-2 ids).
        #expect(VoiceWire.sniff(Self.bytes([0xFF, 0xF1, 0x50, 0x80])) == .aac)
        #expect(VoiceWire.sniff(Self.bytes([0xFF, 0xF9, 0x50, 0x80])) == .aac)
        // An ID3 tag is skipped: what follows decides; a tag longer than what is read is an MP3's.
        let id3 = Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, 10]) + Data(count: 10)
        #expect(VoiceWire.sniff(id3 + Self.bytes([0xFF, 0xF1, 0x50, 0x80])) == .aac)
        #expect(VoiceWire.sniff(id3 + Self.bytes([0xFF, 0xFB, 0x90, 0x64])) == .mp3)
        #expect(VoiceWire.sniff(Data("ID3".utf8) + Data([4, 0, 0, 0, 0x7F, 0x7F, 0x7F]) + Data(count: 20)) == .mp3)
        #expect(VoiceWire.sniff(Self.wav) == .wav)
        #expect(VoiceWire.sniff(Data("fLaC".utf8) + Data(count: 40)) == .flac)
        #expect(VoiceWire.sniff(Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(count: 40)) == .m4a)
        #expect(VoiceWire.sniff(Data("caff".utf8) + Data(count: 40)) == .caf)
        #expect(VoiceWire.sniff(Data("FORM".utf8) + Data(count: 4) + Data("AIFF".utf8) + Data(count: 40)) == .aiff)
        #expect(VoiceWire.sniff(Data("OggS".utf8) + Data(count: 40)) == .ogg)
        #expect(VoiceWire.sniff(Self.bytes([0x1A, 0x45, 0xDF, 0xA3])) == .webm)
        // Nothing known: the label decides.
        #expect(VoiceWire.sniff(Data("hello there, not audio".utf8)) == nil)
        #expect(VoiceWire.sniff(Data([0xFF])) == nil)
        #expect(VoiceWire.sniff(Data()) == nil)
    }

    @Test func aMislabelledClipIsPlayedAsWhatItIs() {
        // A gateway labels a body whose extension it does not know `audio/mpeg`: the AAC inside is played as AAC.
        let aac = SpeechClip(data: Self.bytes([0xFF, 0xF1, 0x50, 0x80]), mime: "audio/mpeg")
        #expect(ClipAttempt.plan(aac) == [.data(hint: "public.aac-audio"), .file(extension: "aac", reactivate: false),
                                          .file(extension: "aac", reactivate: true)])
        let wav = SpeechClip(data: Self.wav, mime: "audio/mpeg")
        #expect(ClipAttempt.plan(wav).first == .data(hint: "com.microsoft.waveform-audio"))
        // Bytes that say nothing: the label decides, as before.
        let unknown = SpeechClip(data: Data("not audio at all".utf8), mime: "audio/mpeg")
        #expect(ClipAttempt.plan(unknown) == [.data(hint: "public.mp3"), .file(extension: "mp3", reactivate: false),
                                              .file(extension: "mp3", reactivate: true)])
        #expect(ClipAttempt.plan(SpeechClip(data: Data("x".utf8), mime: "audio/flac")).first == .data(hint: nil))
    }

    // MARK: The tolerant ways, in order

    final class Tries {
        var steps: [ClipAttempt] = []
    }

    private func run(_ clip: SpeechClip, stopped: @escaping () -> Bool = { false },
                     _ answer: @escaping (ClipAttempt, Int) throws -> String) async throws -> (String?, [ClipAttempt]) {
        let tries = Tries()
        let player = try await ClipStart.first(clip, stopped: stopped) { step in
            tries.steps.append(step)
            return try answer(step, tries.steps.count)
        }
        return (player, tries.steps)
    }

    nonisolated static let mp3 = SpeechClip(data: bytes([0xFF, 0xF3, 0x64, 0xC4]), mime: "audio/mpeg")
    nonisolated static let busy = NSError(domain: NSOSStatusErrorDomain, code: 561_015_905)   // '!pla'
    nonisolated static let unreadable = NSError(domain: NSOSStatusErrorDomain, code: 1_954_115_647)   // 'typ?'

    @Test func aClipThatPlaysIsTriedOnce() async throws {
        let (player, steps) = try await run(Self.mp3) { _, _ in "player" }
        #expect(player == "player")
        #expect(steps == [.data(hint: "public.mp3")])
    }

    @Test func bytesTheMemoryPathRefusesArePlayedFromAFile() async throws {
        let (player, steps) = try await run(Self.mp3) { step, _ in
            if case .data = step { throw Self.unreadable }
            return "from file"
        }
        #expect(player == "from file")
        #expect(steps == [.data(hint: "public.mp3"), .file(extension: "mp3", reactivate: false)])
    }

    @Test func aPlayerThatWouldNotStartIsTriedOnceMoreAfterTheSessionIsSetActiveAgain() async throws {
        let (player, steps) = try await run(Self.mp3) { step, _ in
            guard case .file(_, true) = step else { throw ClipNotStarted() }
            return "after reactivation"
        }
        #expect(player == "after reactivation")
        #expect(steps.count == 3 && steps.last == .file(extension: "mp3", reactivate: true))
    }

    @Test func aBusyOutputIsAPlaybackFailureNotAFormat() async throws {
        do {
            _ = try await run(Self.mp3) { _, _ in throw ClipNotStarted() }
            Issue.record("must throw")
        } catch let failure as VoiceFailure {
            #expect(failure.reason == VoiceWire.playbackFailed("the audio output didn’t start"))
            #expect(failure.reason == "\(DeviceWord.Subject) couldn’t play your gateway’s voice just now (the audio output didn’t start). Try again.")
            #expect(failure.detail != "unplayable")
            #expect(failure.detail?.hasPrefix("playback: play() returned false; audio/mpeg") == true, "\(failure.detail ?? "")")
            #expect(!failure.reason.contains("format"))
            // The card says it as it is (no developer words to hide).
            #expect(VoicePlainWords.plain(failure, .speech).reason == failure.reason)
        }
        let failure = VoiceWire.clipFailure(Self.mp3, Self.busy)
        #expect(failure.reason == VoiceWire.playbackFailed("the audio output was busy"))
        #expect(failure.detail?.contains("NSOSStatusErrorDomain 561015905 '!pla'") == true, "\(failure.detail ?? "")")
    }

    @Test func undecodableBytesOfAPlayableKindAreNotTriedAgainAfterReactivating() async throws {
        do {
            _ = try await run(Self.mp3) { _, _ in throw Self.unreadable }
            Issue.record("must throw")
        } catch let failure as VoiceFailure {
            #expect(failure.reason == VoiceWire.playbackFailed("the audio couldn’t be read"))
            #expect(failure.detail?.contains("'typ?'") == true)
            #expect(failure.detail != "unplayable")
        }
        let tries = Tries()
        _ = try? await ClipStart.first(Self.mp3, stopped: { false }) { step -> String in
            tries.steps.append(step)
            throw Self.unreadable
        }
        #expect(tries.steps == [.data(hint: "public.mp3"), .file(extension: "mp3", reactivate: false)])
    }

    @Test func oggBytesUnderAnMP3LabelAreTheFormat() async throws {
        let ogg = SpeechClip(data: Data("OggS".utf8) + Data(count: 60), mime: "audio/mpeg")
        do {
            _ = try await run(ogg) { _, _ in throw Self.unreadable }
            Issue.record("must throw")
        } catch let failure as VoiceFailure {
            #expect(failure.detail == "unplayable")
            #expect(failure.reason == VoiceWire.unplayable("audio/ogg"))
        }
    }

    @Test func aClipStoppedWhileItStartsIsNotTriedAnotherWay() async throws {
        var stopped = false
        let (player, steps) = try await run(Self.mp3, stopped: { stopped }) { _, _ in
            stopped = true
            throw ClipNotStarted()
        }
        #expect(player == nil)
        #expect(steps.count == 1)
    }

    @Test func aMislabelledClipNamesBothInTheDetails() {
        let aac = SpeechClip(data: Self.bytes([0xFF, 0xF1, 0x50, 0x80]), mime: "audio/mpeg")
        let failure = VoiceWire.clipFailure(aac, Self.unreadable)
        #expect(failure.detail?.contains("audio/mpeg, bytes audio/aac, 64 bytes") == true, "\(failure.detail ?? "")")
        #expect(VoiceWire.playbackWords(NSError(domain: "x", code: 42)) == nil)
        #expect(VoiceWire.playbackFailed(nil) == "\(DeviceWord.Subject) couldn’t play your gateway’s voice just now. Try again.")
    }

    // MARK: The real player

    @Test func theRealOutputCallsBytesItCannotReadAPlaybackFailure() async {
        let output = EngineSpeechOutput()
        do {
            try await output.playClip(SpeechClip(data: Data(repeating: 0x5A, count: 2_048), mime: "audio/mpeg"))
            Issue.record("garbage must not play")
        } catch let failure as VoiceFailure {
            #expect(failure.detail != "unplayable")
            #expect(failure.reason.hasPrefix("\(DeviceWord.Subject) couldn’t play your gateway’s voice just now"), "\(failure.reason)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func theRealOutputPlaysAWAVLabelledMP3() async throws {
        let output = EngineSpeechOutput()
        let began = Date()
        try await output.playClip(SpeechClip(data: Self.wav, mime: "audio/mpeg"))
        #expect(Date().timeIntervalSince(began) < 5)
    }
}
