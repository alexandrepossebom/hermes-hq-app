// One clip of the computer's voice through `AVAudioPlayer` (docs/spec/3x-talk.md §3.4), and what its failure means
// (#412). A clip whose kind `VoiceWire.canPlay` accepts and that still would not play is not a format problem: the
// audio output was busy, the session lost to another owner, or the bytes are not what the label says. So the clip is
// tried the tolerant ways first (the bytes with the type they really are, then a temporary file, then once more after
// the audio session is set active again), and if it still fails it is a playback failure for this reply, with the
// reason, and the next reply asks the computer's voice again. "A format iPhone can't play" (and the 30 minutes on the
// iPhone's voice) stays for a kind no player here reads: a label `canPlay` refuses, or bytes that are Ogg or WebM
// whatever the label says.

import Foundation

/// A kind of audio file: what `AVAudioPlayer` is told to expect, and whether it can play it at all.
nonisolated struct AudioKind: Equatable, Sendable {
    var fileExtension: String
    /// The type identifier for `AVAudioPlayer(data:fileTypeHint:)` (nil: it looks at the bytes).
    var typeHint: String?
    var mime: String
    var playable: Bool

    static let mp3 = AudioKind(fileExtension: "mp3", typeHint: "public.mp3", mime: "audio/mpeg", playable: true)
    static let aac = AudioKind(fileExtension: "aac", typeHint: "public.aac-audio", mime: "audio/aac", playable: true)
    static let m4a = AudioKind(fileExtension: "m4a", typeHint: "com.apple.m4a-audio", mime: "audio/mp4", playable: true)
    static let wav = AudioKind(fileExtension: "wav", typeHint: "com.microsoft.waveform-audio", mime: "audio/wav", playable: true)
    static let flac = AudioKind(fileExtension: "flac", typeHint: "org.xiph.flac", mime: "audio/flac", playable: true)
    static let caf = AudioKind(fileExtension: "caf", typeHint: "com.apple.coreaudio-format", mime: "audio/x-caf", playable: true)
    static let aiff = AudioKind(fileExtension: "aiff", typeHint: "public.aiff-audio", mime: "audio/aiff", playable: true)
    static let ogg = AudioKind(fileExtension: "ogg", typeHint: nil, mime: "audio/ogg", playable: false)
    static let webm = AudioKind(fileExtension: "webm", typeHint: nil, mime: "audio/webm", playable: false)
}

/// One way of starting a clip, in the order `plan` gives.
nonisolated enum ClipAttempt: Equatable, Sendable {
    /// The bytes as they came, with the type they are (from their first bytes, else the label).
    case data(hint: String?)
    /// Written to a temporary file named for its kind and played from there (`AVAudioPlayer(contentsOf:)`, the more
    /// tolerant path). `reactivate`: the audio session is set active again first; only after a player that was made
    /// and would not start.
    case file(extension: String, reactivate: Bool)

    static func plan(_ clip: SpeechClip) -> [ClipAttempt] {
        let kind = VoiceWire.clipKind(clip)
        return [.data(hint: kind.typeHint), .file(extension: kind.fileExtension, reactivate: false),
                .file(extension: kind.fileExtension, reactivate: true)]
    }

    var name: String {
        switch self {
        case .data: "from memory"
        case .file(_, let reactivate): reactivate ? "from a file, audio session set active again" : "from a file"
        }
    }
}

/// A player was made and `play()` said no: the output or the session, not the bytes.
nonisolated struct ClipNotStarted: Error, Equatable, Sendable {}

nonisolated enum ClipStart {
    /// Tries `ClipAttempt.plan(clip)` in order and answers the first player that started. Nil: `stopped()` turned true
    /// meanwhile (nothing to report). Throws `VoiceWire.clipFailure` for the last attempt's error.
    @MainActor static func first<Player>(_ clip: SpeechClip, stopped: () -> Bool,
                                         attempt: (ClipAttempt) async throws -> Player) async throws -> Player? {
        var last: (any Error)?
        for step in ClipAttempt.plan(clip) {
            if stopped() { return nil }
            // Setting the session active again cannot help bytes that would not decode.
            if case .file(_, true) = step, !(last is ClipNotStarted) { continue }
            do {
                let player = try await attempt(step)
                if last != nil { VoiceEvents.note("speech: clip played \(step.name)") }
                return player
            } catch {
                last = error
                VoiceEvents.note("speech: clip \(step.name) didn’t play (\(VoiceWire.playbackCode(error)))")
            }
        }
        if stopped() { return nil }
        throw VoiceWire.clipFailure(clip, last ?? ClipNotStarted())
    }
}

nonisolated extension VoiceWire {
    /// What the clip's bytes are, from their first bytes. Nil: nothing known (the label decides).
    static func sniff(_ data: Data) -> AudioKind? {
        let bytes = [UInt8](data.prefix(64 * 1024))
        var at = 0
        // An ID3 tag (or a few) before the audio: skipped, then the audio's own first bytes decide.
        for _ in 0..<4 {
            guard bytes.count >= at + 10, bytes[at] == 0x49, bytes[at + 1] == 0x44, bytes[at + 2] == 0x33 else { break }
            let size = bytes[(at + 6)...(at + 9)].reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
            at += 10 + size + (bytes[at + 5] & 0x10 != 0 ? 10 : 0)
            // Past what was read (a large cover image): an ID3 tag is an MP3's.
            guard at + 4 <= bytes.count else { return .mp3 }
        }
        guard bytes.count >= at + 4 else { return nil }
        func ascii(_ offset: Int, _ text: String) -> Bool {
            let wanted = Array(text.utf8)
            return bytes.count >= at + offset + wanted.count && Array(bytes[(at + offset)..<(at + offset + wanted.count)]) == wanted
        }
        if bytes[at] == 0xFF, bytes[at + 1] & 0xE0 == 0xE0 {
            // Frame sync. Layer bits 00 under a 12-bit sync is ADTS (AAC); anything else is an MPEG audio frame.
            return bytes[at + 1] & 0xF6 == 0xF0 ? .aac : .mp3
        }
        if ascii(0, "RIFF"), ascii(8, "WAVE") { return .wav }
        if ascii(0, "fLaC") { return .flac }
        if ascii(4, "ftyp") { return .m4a }
        if ascii(0, "caff") { return .caf }
        if ascii(0, "FORM"), ascii(8, "AIFF") || ascii(8, "AIFC") { return .aiff }
        if ascii(0, "OggS") { return .ogg }
        if bytes[at] == 0x1A, bytes[at + 1] == 0x45, bytes[at + 2] == 0xDF, bytes[at + 3] == 0xA3 { return .webm }
        return nil
    }

    /// The kind a clip is played as: its bytes' when they say, else its label's. A gateway labels a body whose
    /// extension it does not know `audio/mpeg`, so an AAC or M4A clip can arrive as "MP3" (#412).
    static func clipKind(_ clip: SpeechClip) -> AudioKind {
        if let sniffed = sniff(clip.data) { return sniffed }
        switch fileExtension(clip.mime) {
        case "mp3": return .mp3
        case "wav": return .wav
        case "flac": return AudioKind(fileExtension: "flac", typeHint: nil, mime: "audio/flac", playable: true)
        case "aac": return AudioKind(fileExtension: "aac", typeHint: nil, mime: "audio/aac", playable: true)
        default: return .m4a
        }
    }

    /// A clip that would not play (§3.4, §7.6). Bytes of a kind no player here reads (Ogg, WebM, whatever the label
    /// said): the format, as for a refused label, and the computer's voice is skipped for a while. Anything else: this
    /// reply's playback failed, with the reason, and the next reply asks the computer's voice again.
    static func clipFailure(_ clip: SpeechClip, _ error: any Error) -> VoiceFailure {
        if let kind = sniff(clip.data), !kind.playable {
            return VoiceFailure(reason: unplayable(kind.mime), detail: "unplayable")
        }
        let label = clip.mime.isEmpty ? "unknown" : clip.mime
        let kind = clipKind(clip)
        let what = kind.mime == canonicalMime(clip.mime) ? label : "\(label), bytes \(kind.mime)"
        return VoiceFailure(reason: playbackFailed(playbackWords(error)), detail: "playback: \(playbackCode(error)); \(what), \(clip.data.count) bytes")
    }

    /// The person's sentence for a clip of a playable kind that did not play.
    static func playbackFailed(_ why: String?) -> String {
        "\(DeviceWord.Subject) couldn’t play your gateway’s voice just now\(why.map { " (\($0))" } ?? ""). Try again."
    }

    /// Why a player would not make or start, in a few plain words, when the code says. Nil: no plain words for it.
    static func playbackWords(_ error: any Error) -> String? {
        if error is ClipNotStarted { return "the audio output didn’t start" }
        switch (error as NSError).code {
        case 561_015_905, 560_557_684, 561_017_449, 560_030_580: return "the audio output was busy"   // '!pla' '!int' '!pri' '!act'
        case 1_768_841_571: return "the audio session wasn’t active"   // 'inac'
        case 1_718_449_215, 1_954_115_647, 1_685_348_671: return "the audio couldn’t be read"   // 'fmt?' 'typ?' 'dta?'
        default: return nil
        }
    }

    /// The error's domain and code, the code as four characters too when it is one ("NSOSStatusErrorDomain 561015905 '!pla'").
    static func playbackCode(_ error: any Error) -> String {
        if error is ClipNotStarted { return "play() returned false" }
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        if ns.code > 0, ns.code <= Int(UInt32.max) {
            let scalars = [24, 16, 8, 0].map { UInt8((ns.code >> $0) & 0xFF) }
            if scalars.allSatisfy({ (0x20...0x7E).contains($0) }) { text += " '\(String(decoding: scalars, as: UTF8.self))'" }
        }
        return text
    }

    /// The label without parameters, lowercased; `audio/x-wav` is `audio/wav`.
    static func canonicalMime(_ mime: String) -> String {
        let bare = mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return bare == "audio/x-wav" ? "audio/wav" : bare
    }
}
