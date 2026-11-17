// A bot's question during a live voice conversation (docs/spec/3x-gpt-live.md §4). The owner, 2026-11-16, with the app
// closed and a voice chat going: the bot put up a question card ("Do you mean a government shutdown, an outage, or
// something else?") that can only be answered by tapping. The voice asks it instead, and what the person says next is
// the answer.

import Foundation

/// The chat's open question as the voice asks it.
nonisolated struct VoiceQuestion: Equatable, Sendable {
    var id: String
    var spoken: String
}

nonisolated enum VoiceQuestionText {
    /// What the voice is given to ask: each question, then its choices.
    static func spoken(_ questions: [ClarifyQuestion]) -> String {
        let asked = questions.map { question -> String in
            let words = LiveVoiceWire.collapse(question.question)
            let choices = (question.choices ?? []).map(LiveVoiceWire.collapse).filter { !$0.isEmpty }
            guard !choices.isEmpty else { return words }
            let list = choices.count == 1 ? choices[0]
                : choices.dropLast().joined(separator: ", ") + ", or " + choices[choices.count - 1]
            return "\(words) The choices are: \(list)."
        }
        return "Before I can go on, I need to know: " + asked.joined(separator: " And: ")
    }

    /// The answer sent for one question: the choice the person named (its words, or "the first one"), else what they said.
    static func answer(_ said: String, to question: ClarifyQuestion) -> String {
        let words = LiveVoiceWire.collapse(said)
        guard let choices = question.choices, !choices.isEmpty else { return words }
        let heard = plain(words)
        let named = choices.filter { choice in
            let name = plain(choice)
            return !name.isEmpty && (" \(heard) ".contains(" \(name) ") || (heard.count >= 4 && " \(name) ".contains(" \(heard) ")))
        }
        if named.count == 1 { return named[0] }
        guard named.isEmpty else { return words }
        // "The first one", "option two", "number 3", "the last one".
        let said = heard.split(separator: " ").map(String.init)
        guard said.count <= 4 else { return words }
        if said.contains("last") { return choices[choices.count - 1] }
        let ordinals = ["first", "second", "third", "fourth", "fifth"], numbers = ["one", "two", "three", "four", "five"]
        let counting = said.count == 1 || said.contains("option") || said.contains("number") || said.contains("choice")
        let hits = choices.indices.prefix(ordinals.count).filter { index in
            said.contains(ordinals[index]) || said.contains(String(index + 1)) || (counting && said.contains(numbers[index]))
        }
        if hits.count == 1 { return choices[hits[0]] }
        return words
    }

    /// Lowercased letters and digits, single spaces.
    static func plain(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }
}
