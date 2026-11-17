// What was said in a live voice chat (GPT-Live, Grok Live), kept with the chat. The live voice's words and the person's
// were held in memory only and gone when the conversation ended: the bot learned only what was delegated to it, and
// nobody could read the conversation back (owner, 2026-11-17: "the bot should have the transcript. I mean you were
// literally talking to the bot"). The gateway has no way to add words to a chat without a turn, so when the conversation
// ends the app sends one message: a marked first line, a note for the bot, then the exchange. Hermes has no notion of
// it; the convention is client-side, as a voice memo's is (`VoiceMemo`). The chat draws it as one line, "Voice Chat ·
// 4:12", that opens on the words.

import Foundation

nonisolated enum VoiceChatRecord {
    struct Turn: Equatable, Sendable {
        var user: Bool
        var text: String
    }

    /// How the message opens: what `parse` looks for.
    static let markLead = "[Voice chat transcript"
    /// Rides the message, for the bot. It names no bot (see `LiveVoiceWire.toolNote`).
    static let note = "(From the app, not typed by the user: this is what was said in the voice chat that just ended, "
        + "kept here so you have it. \"Voice assistant\" is the voice that spoke with the user for you. Everything they "
        + "asked for in it was already passed to you as it was said. Do not act on this message and do not answer it: "
        + "reply with exactly NO_REPLY.)"
    /// The newest of a long conversation is what is kept.
    static let maxChars = 24_000
    static let cutNote = "(The earlier part of a long voice chat is left out.)"

    /// One more piece of the live transcript: the same speaker's pieces are one turn.
    static func add(_ fragment: LiveTranscriptFragment, to turns: inout [Turn]) {
        guard !fragment.text.isEmpty else { return }
        let user = fragment.speaker == .user
        if let last = turns.indices.last, turns[last].user == user {
            turns[last].text += fragment.text
        } else {
            turns.append(Turn(user: user, text: fragment.text))
        }
    }

    /// The turns with words in them, each on one line's worth of text.
    static func settled(_ turns: [Turn]) -> [Turn] {
        var out: [Turn] = []
        for turn in turns {
            let words = LiveVoiceWire.collapse(turn.text)
            guard !words.isEmpty else { continue }
            if let last = out.indices.last, out[last].user == turn.user {
                out[last].text += " " + words
            } else {
                out.append(Turn(user: turn.user, text: words))
            }
        }
        return out
    }

    /// The message a finished conversation sends, or nil when the person said nothing worth keeping (silence, or only
    /// the word that ended it).
    static func message(_ turns: [Turn], seconds: TimeInterval, stopPhrases: TalkStopWord.Config = .standard) -> String? {
        let said = settled(turns)
        let person = said.filter(\.user).map(\.text).joined(separator: " ")
        guard !person.isEmpty, !TalkStopWord.isStop(person, config: stopPhrases) else { return nil }
        var lines = said.map { "\($0.user ? "User" : "Voice assistant"): \($0.text)" }
        var cut = false
        while lines.count > 1, lines.reduce(0, { $0 + $1.count + 1 }) > maxChars {
            lines.removeFirst()
            cut = true
        }
        if let only = lines.first, lines.count == 1, only.count > maxChars { lines = [String(only.suffix(maxChars))]; cut = true }
        let head = "\(markLead) · \(TalkDockState.formatElapsed(seconds))]"
        return ([head, note, ""] + (cut ? [cutNote] : []) + lines).joined(separator: "\n")
    }

    struct Found: Equatable, Sendable {
        /// "4:12", when the first line carries it.
        var length: String?
        /// The exchange as the chat shows it: "You: …" and "Voice: …", a blank line between turns.
        var words: String

        var title: String { length.map { "Voice Chat · \($0)" } ?? "Voice Chat" }
    }

    private static let head = try! NSRegularExpression(pattern: #"^\[Voice chat transcript(?: · ([0-9:]{1,9}))?\][ \t]*(?:\r?\n|$)"#)

    /// A stored message that is a voice chat's record, or nil.
    static func parse(_ text: String) -> Found? {
        guard text.hasPrefix(markLead) else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = head.firstMatch(in: text, range: whole), match.range.location == 0 else { return nil }
        let length = Range(match.range(at: 1), in: text).map { String(text[$0]) }
        var rest = Substring(text)[(Range(match.range, in: text)?.upperBound ?? text.endIndex)...]
        // The note for the bot is one bracketed paragraph: never shown.
        if rest.hasPrefix("(From the app"), let close = rest.range(of: ")\n") ?? rest.range(of: ")", options: .backwards) {
            rest = rest[close.upperBound...]
        }
        var out: [String] = []
        for line in rest.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("User: ") {
                out.append("You: " + line.dropFirst("User: ".count))
            } else if line.hasPrefix("Voice assistant: ") {
                out.append("Voice: " + line.dropFirst("Voice assistant: ".count))
            } else {
                out.append(line)
            }
        }
        return Found(length: length, words: out.joined(separator: "\n\n"))
    }

    /// True for a stored message that is a record: previews and titles pass over it.
    static func isRecord(_ text: String) -> Bool { text.hasPrefix(markLead) && parse(text) != nil }
}
