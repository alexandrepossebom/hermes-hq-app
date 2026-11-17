// The hello a live voice conversation opens with (docs/spec/3x-gpt-live.md §4, owner 2026-11-16: "as soon as it's
// there, it needs to have some warm intro that needs to not be the same thing every time … so it just feels genuine").
// Nothing here is a line to say: the voice model writes its own hello each time. This is what it is asked for, with
// the hour and one of a few leanings picked at random, never the one used last.

import Foundation
import Synchronization

nonisolated enum VoiceHello {
    /// One leaning per start. The thread one only makes sense with a seeded chat; the voice is told to skip it otherwise.
    static let leanings = [
        "Keep it to a plain, easy hello.",
        "Let the time of day colour it.",
        "If the earlier messages you were given make it natural, pick up their thread in a few words (what you were last on together). Never invent anything; with no earlier messages, just say hello.",
        "Ask how they are, or how the day is going.",
        "Sound glad they called.",
    ]

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

    /// What the voice is asked for. Names no bot (see `LiveVoiceWire.toolNote`).
    static func prompt(now: Date = Date(), calendar: Calendar = .current, leaning: Int = nextLeaning()) -> String {
        "The user has just started this voice chat and has not spoken yet. Say hello now, before they speak: one short, "
            + "warm sentence in your own words, the way a friend picks up the phone. It is \(moment(now, calendar: calendar)) "
            + "for them. \(leanings[min(max(leaning, 0), leanings.count - 1)]) Do not say your name, do not list what you can "
            + "do, and avoid stock lines like \"How can I help you today?\". Word it differently every time. Then stop and listen."
    }

    /// GPT-Live's documented way to speak first: the request rides the seed as a developer message, and is sent once
    /// more as commentary when the session starts (`LiveTalkLoop`'s `.greet`).
    static func seedItem(_ prompt: String) -> JSONValue {
        ["type": "message", "role": "developer", "content": [["type": "input_text", "text": .string(prompt)]]]
    }
}
