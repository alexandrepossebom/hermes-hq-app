import Foundation
import Testing
@testable import HermesHQNative

/// [narration] A long turn's progress notes show as it writes them, then join its line once it has settled; only its
/// last words stay a bubble (owner, 2026-11-18: "Live while working, then fold into the Worked line when done").
@MainActor
struct ProgressNotesTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var n = 0

    private static func run(_ id: String) -> ChatPart {
        .tool(ToolCall(id: id, name: "terminal", title: "terminal", argsText: #"{"command":"make \#(id)"}"#,
                       summary: "ok", state: .done, durationSeconds: 2))
    }

    private func turn(_ parts: [ChatPart], streaming: Bool = false) -> [ChatMessage] {
        var reply = ChatMessage(id: "a1", role: .assistant, parts: parts, timestamp: now, rowId: nil)
        reply.isStreaming = streaming
        return [ChatMessage(id: "u1", role: .user, parts: [.text("Ship")], timestamp: now.addingTimeInterval(-60), rowId: nil), reply]
    }

    private func rows(_ messages: [ChatMessage], style: ToolCallStyle = .bottom, running: Bool = false) -> [ChatRow] {
        var input = ChatRowBuilder.Input(messages: messages, isRunning: running, botName: "App", expanded: [], scope: "t")
        input.activity.style = style
        return ChatRowBuilder.build(input)
    }

    private func bubbleTexts(_ rows: [ChatRow]) -> [String] {
        rows.compactMap { if case .bubble(let b) = $0.kind, !b.mine { return b.text } else { return nil } }
    }

    private func line(_ rows: [ChatRow]) -> OneLineRow? {
        for r in rows { if case .toolRun(let t) = r.kind, let l = t.line { return l } }
        return nil
    }

    private var ship: [ChatPart] {
        [.text("Checking their trees."), Self.run("t1"), Self.run("t2"),
         .text("Gates are running; waiting on both."), Self.run("t3"),
         .text("Unit suite still going. Checking back shortly."), Self.run("t4"),
         .text("Build 1106 is uploaded and in the internal group.")]
    }

    @Test func settledNotesJoinTheLine() throws {
        for style in [ToolCallStyle.bottom, .line] {
            let built = rows(turn(ship), style: style)
            #expect(bubbleTexts(built) == ["Build 1106 is uploaded and in the internal group."], "\(style)")
            let l = try #require(line(built), "\(style)")
            #expect(l.title.hasPrefix("Worked"), "\(l.title)")
            #expect(l.thought == "Checking their trees.\n\nGates are running; waiting on both.\n\nUnit suite still going. Checking back shortly.")
        }
    }

    /// While it works, every note shows as it was written.
    @Test func liveNotesStay() {
        let built = rows(turn(Array(ship.dropLast()), streaming: true), running: true)
        #expect(bubbleTexts(built).count == 3, "\(built.map(\.id))")
    }

    /// A reply that ended on a step: its last note is its last word.
    @Test func lastNoteStaysWhenNoWordsFollow() {
        let built = rows(turn(Array(ship.dropLast())))
        #expect(bubbleTexts(built) == ["Unit suite still going. Checking back shortly."], "\(built.map(\.id))")
    }

    /// Words with a picture in them, or a long write-up midway, keep their bubble.
    @Test func picturesAndLongWordsStay() {
        let long = String(repeating: "A finding worth reading. ", count: 30)
        let parts: [ChatPart] = [.text("Here is the comparison:\n\nMEDIA:/tmp/compare.png"), Self.run("t1"),
                                 .text(long), Self.run("t2"), .text("Short note."), Self.run("t3"), .text("Done.")]
        let texts = bubbleTexts(rows(turn(parts)))
        #expect(texts.count == 3 && texts.last == "Done." && !texts.contains("Short note."), "\(texts)")
    }

    /// Styles that draw each step where it ran keep every note in place.
    @Test func otherStylesUnchanged() {
        for style in [ToolCallStyle.header, .rows, .bubbles] {
            #expect(bubbleTexts(rows(turn(ship), style: style)).count == 4, "\(style)")
        }
    }

    /// A one-message reply is untouched.
    @Test func plainReplyUnchanged() {
        #expect(bubbleTexts(rows(turn([.text("Hello.")]))) == ["Hello."])
    }
}
