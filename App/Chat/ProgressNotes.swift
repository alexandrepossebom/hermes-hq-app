import Foundation

// [narration] A long turn narrates its work: "Checking their trees.", "Gates are running; waiting on both.", "Unit suite
// still going. Checking back shortly." Each note was a bubble of its own (kwojt, 2026-11-14: one long bubble of them
// read badly), so a ship turn drew eight bubbles for one answer (owner, 2026-11-18: "sessions on HQ are including a
// lot of internal chatter"). While the turn works they still show as it writes them, so you can follow along; once it
// has settled they join its line ("Worked for 4m · 14 steps"), which opens on them with the steps, and only its last
// words stay a bubble (owner's pick, 2026-11-18: "Live while working, then fold into the Worked line when done").
//
// A note folds only when the reply went back to a step drawn on its line after it and then wrote again: the last words
// are the answer, however many steps ran before them. A note before a message to another bot, a picture, a draft, a
// product card or a question stays: what follows it is a row of its own, not the line. Words that carry a picture or
// a file, and long ones (a findings summary written midway), keep their bubble: they are something to read, not a note
// on progress. One Line and At the Bottom only, and not with After Reply › Hide (no line to fold into).

nonisolated enum ProgressNotes {
    /// Longer than this is a message, not a note (the same bar as `UpdateGroups.answerLength`).
    static let longest = 600

    /// Steps drawn as rows of their own in every style, never on the reply's line.
    private static let ownRows: Set<String> = [BotDMs.tool, "image_generate", DraftCards.tool, "clarify"]

    /// The indexes of `m`'s text parts (at `index` in the chat) that fold into its line; empty while its turn works.
    static func folded(_ m: ChatMessage, at index: Int, input: ChatRowBuilder.Input) -> Set<Int> {
        guard !m.isStreaming, m.error == nil, m.sender == nil, !working(at: index, input: input) else { return [] }
        var out: Set<Int> = []
        var pending: [Int] = []      // notes waiting for a step after them
        var stepped: [Int] = []      // notes with a step after them, waiting for words after that
        for (i, part) in m.parts.enumerated() {
            switch part {
            case .text(let t):
                if ReasoningTags.isBlank(t) { continue }
                // Words after a step: every note before that step is a progress note.
                out.formUnion(stepped)
                stepped = []
                // Words with no step between them draw as one bubble: they fold together or not at all.
                if isNote(t) { pending.append(i) } else { pending = [] }
            case .tool(let call):
                if ChatRunSummary.isSilent(call.name) && call.state != .failed { continue }
                if ownRows.contains(call.name) || ShoppingCards.tools.contains(call.name) {
                    // A row of its own follows the words: they stay with it.
                    pending = []
                    stepped = []
                    continue
                }
                stepped += pending
                pending = []
            case .reasoning:
                continue
            }
        }
        return out
    }

    /// The turn at `index` is still going: the chat runs and nothing you wrote comes after it (its helpers and
    /// background tasks can still be at work after the reply itself has ended).
    private static func working(at index: Int, input: ChatRowBuilder.Input) -> Bool {
        let external = input.externalWorking && index == input.messages.count - 1   // [external-turn]
        guard input.isRunning || external else { return false }
        guard index + 1 < input.messages.count else { return true }
        return !input.messages[(index + 1)...].contains { $0.role == .user && $0.sender == nil && $0.job == nil }
    }

    /// Words that read as a note on progress: short, and no picture or file in them.
    static func isNote(_ text: String) -> Bool {
        let t = ChatText.trimmed(text)
        guard !t.isEmpty, t.count <= longest else { return false }
        if t.contains("MEDIA:") || t.contains("![") { return false }
        return true
    }
}
