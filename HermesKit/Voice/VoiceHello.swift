// The hello a live voice conversation opens with (docs/spec/3x-gpt-live.md §4, owner 2026-11-16: "as soon as it's
// there, it needs to have some warm intro that needs to not be the same thing every time … so it just feels genuine").
// Nothing here is a line to say: the voice model writes its own hello each time. This is what it is asked for, with
// one of a few leanings picked at random (never the one used last), a tone, and its last few hellos to stay away from.

import Foundation
import Synchronization

nonisolated enum VoiceHello {
    /// One leaning per start. The thread one only makes sense with a seeded chat; the voice is told to skip it otherwise.
    /// The owner on GPT-Live, build 1063: "the weirdest intro message of all time lol it was creepy". The request then
    /// said "the way a friend picks up the phone", "sound glad they called" and "pick up their thread": lines like "good
    /// to hear your voice, glad you called" before the person had spoken. So: an ordinary hello, nothing about the
    /// person, and the time only in the one leaning that is about it.
    static let leanings = [
        "Keep it to a plain, easy hello.",
        "Let the time of day colour it.",
        "Let them know you are ready when they are.",
        "Ask how they are, or how the day is going.",
        "Make it light and upbeat.",
    ]
    /// The leaning that is told the day and time.
    static let timeLeaning = 1

    /// How it should sound, picked apart from the leaning.
    static let tones = ["easygoing", "bright", "calm and unhurried", "quietly warm"]

    private static let last = Mutex<Int?>(nil)

    /// A leaning other than the last one handed out.
    static func nextLeaning(random: (Range<Int>) -> Int = { Int.random(in: $0) }) -> Int {
        last.withLock { last in
            var pick = random(0..<leanings.count)
            if pick == last { pick = (pick + 1) % leanings.count }
            last = pick
            return pick
        }
    }

    /// "Monday evening".
    static func moment(_ date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let part = switch hour {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<22: "evening"
        default: "late at night"
        }
        let day = calendar.weekdaySymbols[calendar.component(.weekday, from: date) - 1]
        return hour >= 22 || hour < 5 ? "\(part) on \(day)" : "\(day) \(part)"
    }

    // MARK: The last few hellos

    /// What the voice said the last few times, so it is told not to say it again (asked the same way, Grok gave the
    /// same line word for word, and named the day and time in nearly every one).
    static let recentKey = "hq.voice.hello.recent"
    static let recentKeep = 3
    static let recentChars = 90

    static func recent(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: recentKey) ?? []
    }

    static func remember(_ said: String, defaults: UserDefaults = .standard) {
        let line = String(LiveVoiceWire.collapse(said).replacingOccurrences(of: "\"", with: "'").prefix(recentChars))
        guard !line.isEmpty else { return }
        defaults.set(Array((recent(defaults).filter { $0 != line } + [line]).suffix(recentKeep)), forKey: recentKey)
    }

    /// What the voice is asked for. Names no bot (see `LiveVoiceWire.toolNote`). Build 1063, the owner's phone: asked
    /// to say hello over a seeded chat, Grok acted on the chat's last request instead (a search, then a sign-in), so
    /// the request says outright that nobody has asked for anything.
    static func prompt(now: Date = Date(), calendar: Calendar = .current, leaning: Int = nextLeaning(),
                       tone: String? = tones.randomElement(), recent: [String] = VoiceHello.recent()) -> String {
        let before = recent.suffix(recentKeep).map { "\"\(String($0.prefix(recentChars)))\"" }.joined(separator: ", ")
        let pick = min(max(leaning, 0), leanings.count - 1)
        return "The user has just opened this voice chat and has not spoken yet. Greet them now, before they speak: one "
            + "short, friendly, ordinary hello in your own words" + (tone.map { ", \($0)" } ?? "") + ". \(leanings[pick]) "
            + (pick == timeLeaning ? "It is \(moment(now, calendar: calendar)) for them. " : "Leave the day and the time out of it. ")
            + (before.isEmpty ? "" : "Your last hellos were \(before): do not open the same way or reuse their phrases. ")
            + "Keep it simple and normal: nothing about hearing their voice, calling, the phone, or what they have been doing; "
            + "do not say your name, do not list what you can do, and avoid stock lines like \"How can I help you today?\". "
            + "Nobody has asked for anything yet: do not pass anything to your agent or backend, and do not act on the earlier "
            + "messages. Then stop and listen."
    }

    /// GPT-Live's documented way to speak first: the request rides the seed as a developer message, and is sent once
    /// more as commentary when the session starts (`LiveTalkLoop`'s `.greet`).
    static func seedItem(_ prompt: String) -> JSONValue {
        ["type": "message", "role": "developer", "content": [["type": "input_text", "text": .string(prompt)]]]
    }
}
