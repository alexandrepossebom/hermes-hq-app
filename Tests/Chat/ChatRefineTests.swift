// [chat-refine] Chat polish (owner, 2026-11-16): a work line that never shows cut-off words, a gap that says the speaker
// changed, tails on your bubbles under Fewer Timestamps, and one time per minute of replies. Drawing only.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite("Chat · refine")
@MainActor struct ChatRefineTests {
    func call(_ id: String, _ name: String, _ args: String = "{}", seconds: Double? = nil) -> ToolCall {
        ToolCall(id: id, name: name, title: name, argsText: args, summary: nil, state: .done, durationSeconds: seconds)
    }

    func input(_ messages: [ChatMessage], fewerTimes: Bool = true, style: ToolCallStyle = .bottom) -> ChatRowBuilder.Input {
        var a = ActivityRowsInput()
        a.style = style
        var i = ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Hermes", expanded: [], scope: "t", activity: a)
        i.fewerTimes = fewerTimes
        return i
    }

    /// 12:00:00 two days ago, plus `seconds`.
    func at(_ seconds: Double) -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date().addingTimeInterval(-86_400 * 2))!.addingTimeInterval(seconds)
    }

    func me(_ id: String, _ t: Double, _ words: String = "go") -> ChatMessage {
        ChatMessage(id: id, role: .user, parts: [.text(words)], timestamp: at(t), rowId: nil)
    }

    func bot(_ id: String, _ t: Double, _ parts: [ChatPart] = [.text("ok")]) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, parts: parts, timestamp: at(t), rowId: nil)
    }

    func bubbles(_ rows: [ChatRow]) -> [(id: String, row: ChatRow, bubble: BubbleRow)] {
        rows.compactMap { row in if case .bubble(let b) = row.kind { return (row.messageId, row, b) } else { return nil } }
    }

    // MARK: 3 · tails

    @Test func yourBubblesKeepTheirTailUnderFewerTimestamps() {
        let messages = [me("u1", 0), me("u2", 20), bot("a1", 65), me("u3", 600)]
        for fewer in [true, false] {
            let all = bubbles(ChatRowBuilder.build(input(messages, fewerTimes: fewer)))
            let tails = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.bubble.tail) })
            // A run's last bubble has the tail, yours and the bot's alike; the first of your two doesn't.
            #expect(tails == ["u1": false, "u2": true, "a1": true, "u3": true], "fewer \(fewer): \(tails)")
            // Fewer Timestamps still draws no time in yours.
            #expect(all.filter { $0.bubble.mine && $0.bubble.tail }.allSatisfy { ($0.bubble.time == nil) == fewer })
        }
    }

    // MARK: 7 · one time per minute

    @Test func aMinuteOfRepliesDrawsItsTimeOnce() {
        // 12:01:05 and 12:01:40 are one minute; 12:03 is its own.
        let messages = [me("u1", 0), bot("a1", 65), me("u2", 80), bot("a2", 100), me("u3", 170), bot("a3", 185)]
        func replies(_ fewer: Bool) -> [(String, Date?, Date?)] {
            bubbles(ChatRowBuilder.build(input(messages, fewerTimes: fewer))).filter { !$0.bubble.mine }.map { ($0.id, $0.bubble.time, $0.bubble.spokenTime) }
        }
        let fewer = replies(true)
        #expect(fewer.map(\.0) == ["a1", "a2", "a3"])
        #expect(fewer.map(\.1) == [nil, at(100), at(185)], "the minute's last reply carries its time")
        #expect(fewer.map(\.2) == [at(65), nil, nil], "VoiceOver still reads the one not drawn")
        // Every reply keeps its tail.
        #expect(bubbles(ChatRowBuilder.build(input(messages))).filter { !$0.bubble.mine }.allSatisfy { $0.bubble.tail })
        // With Fewer Timestamps off, every time is drawn.
        #expect(replies(false).map(\.1) == [at(65), at(100), at(185)])
    }

    @Test func aReplyThatDrewNothingOrFailedHidesNoTime() {
        var failed = bot("a2", 100)
        failed.error = "overloaded"
        #expect(!ChatRowBuilder.laterReplyInTheSameMinute([bot("a1", 65), me("u", 80), failed], after: 0))
        #expect(!ChatRowBuilder.laterReplyInTheSameMinute([bot("a1", 65), me("u", 80), bot("a2", 100, [.text("  ")])], after: 0))
        #expect(!ChatRowBuilder.laterReplyInTheSameMinute([bot("a1", 65), me("u", 80)], after: 0))
        #expect(!ChatRowBuilder.laterReplyInTheSameMinute([bot("a1", 65), bot("a2", 125)], after: 0), "the next minute")
        #expect(ChatRowBuilder.laterReplyInTheSameMinute([bot("a1", 65), me("u", 80), bot("a2", 100)], after: 0))
    }

    /// A reply arriving in the newest minute takes the time off the one before it: the rows the screen holds after the
    /// partial rebuild are the rows a full build makes.
    @Test func aNewReplyInTheMinuteRebuildsTheOneBeforeIt() {
        let before = [me("u1", 0), bot("a1", 65), me("u2", 80)]
        var model = ChatRowModel()
        model.rebuildAll(input(before), syncMessages: 160, oldestShown: nil)
        #expect(bubbles(Array(model.allRows)).first { $0.id == "a1" }?.bubble.time == at(65))
        let after = before + [bot("a2", 100)]
        model.rebuildNewest(input(after), touching: ["a2"])
        let held = bubbles(Array(model.allRows.reversed()))
        let full = bubbles(ChatRowBuilder.build(input(after)))
        #expect(held.map(\.id) == full.map(\.id))
        #expect(held.map(\.bubble.time) == full.map(\.bubble.time))
        #expect(held.first { $0.id == "a1" }?.bubble.time == nil)
        let heldRows = held.map(\.row), fullRows = full.map(\.row)
        for i in heldRows.indices where i < fullRows.count {
            #expect(ChatRowDiff.same(heldRows[i], fullRows[i]), "row \(i) is the row a full build makes")
        }
    }

    @Test func aMissingTimestampDoesNotBreakMinuteRebuilds() {
        var untimed = me("u2", 80)
        untimed.timestamp = nil
        var anotherUntimed = me("u3", 90)
        anotherUntimed.timestamp = nil
        let before = [me("u1", 0), bot("a1", 65), untimed, anotherUntimed]
        var model = ChatRowModel()
        model.rebuildAll(input(before), syncMessages: 160, oldestShown: nil)
        let after = before + [bot("a2", 100)]
        model.rebuildNewest(input(after), touching: ["a2"])
        let held = bubbles(Array(model.allRows.reversed()))
        let full = bubbles(ChatRowBuilder.build(input(after)))
        #expect(held.map(\.bubble.time) == full.map(\.bubble.time))
    }

    @Test func editingAnOlderReplyUpdatesThePrecedingMinuteTimes() {
        var failed = bot("a2", 100)
        failed.error = "overloaded"
        let before = [me("u1", 0), bot("a1", 65), me("u2", 80), failed, me("u3", 170), bot("a3", 185)]
        for newest in [true, false] {
            var model = ChatRowModel()
            model.rebuildAll(input(before), syncMessages: 160, oldestShown: nil)
            var after = before
            after[3] = bot("a2", 100)
            if newest { model.rebuildNewest(input(after), touching: ["a2"]) }
            else { model.rebuildMessages(input(after), 3...3) }
            let held = bubbles(Array(model.allRows.reversed()))
            let full = bubbles(ChatRowBuilder.build(input(after)))
            #expect(held.map(\.id) == full.map(\.id))
            #expect(held.map(\.bubble.time) == full.map(\.bubble.time), "newest \(newest)")
        }
    }

    @Test func shortenedWorkLineKeepsFullAccessibilityWords() throws {
        let steps = [call("t1", "tool_describe", #"{"names":["web_search"]}"#),
                     call("t2", "terminal"), call("t3", "read_file", #"{"path":"notes/a-long-name.txt"}"#)]
        let rows = ChatRowBuilder.build(input([me("u1", 0), bot("a1", 65, steps.map { .tool($0) } + [.text("Done.")])]))
        let row = try #require(rows.first { if case .toolRun(let t) = $0.kind { return t.line != nil } else { return false } })
        let layout = TextLayout.layout(row, width: 402, style: ChatStyle.make(category: .large))
        let cell = ChatToolCell(style: .default, reuseIdentifier: nil)
        cell.configure(row, layout: layout)
        let button = try #require(cell.contentView.subviews.first { $0 is UIControl })
        #expect(button.accessibilityLabel?.contains("Checked how to use web search") == true)
        #expect(button.accessibilityLabel?.contains("ran 1 command") == true)
    }

    @Test func aShortenedWorkLineStillNamesFailedHelpers() throws {
        let steps = [call("t1", "tool_describe", #"{"names":["web_search"]}"#), call("t2", "terminal")]
        let message = bot("a1", 65, steps.map { .tool($0) } + [.text("Done.")])
        let helper = ToolCards.DelegateRow(activity: [], durationSeconds: nil, goal: "Check", id: "h1", model: nil,
                                           sessionId: nil, status: .failed, startedAt: nil)
        let row = ChatRowBuilder.oneLineRow(message, steps: steps, thoughts: [], firstThought: nil, lastVisiblePart: 2,
                                            input: input([message]), helpers: [helper])
        guard case .tool(let t) = TextLayout.layout(row, width: 320, style: ChatStyle.make(category: .large)).content else {
            Issue.record("missing line"); return
        }
        #expect(t.title.contains("1 failed"), "\(t.title)")
    }

    // MARK: 4 · 6 · chosen composer defaults

    @Test func composerKeepsItsInsetAndHasTheStrongerPlaceholder() throws {
        var state = ThemeTable.current.state
        state.desktopLook = false
        try ThemeTable.$testSet.withValue(ThemeResolver.resolve(state)) {
            // Owner 2026-11-16: tried 16 pt, kept 26.
            #expect(ChatMetrics.composerSideDown == 26)
            let composer = ComposerView(frame: CGRect(x: 0, y: 0, width: 402, height: 180))
            composer.layoutIfNeeded()
            func labels(_ view: UIView) -> [UILabel] {
                (view as? UILabel).map { [$0] } ?? view.subviews.flatMap { labels($0) }
            }
            let hint = try #require(labels(composer).first { $0.text == "Message" })
            for mode in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: mode)
                #expect(hint.textColor.resolvedColor(with: traits) == ChatPalette.label2.resolvedColor(with: traits))
            }
        }
    }

    // MARK: 2 · gaps

    @Test func aChangeOfSpeakerHasItsOwnGap() {
        let rows = bubbles(ChatRowBuilder.build(input([me("u1", 0), me("u2", 20), bot("a1", 65), me("u3", 600)])))
        let gaps = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.row.gapAbove) })
        #expect(gaps["u2"] == ChatMetrics.runGap)
        #expect(gaps["a1"] == ChatMetrics.speakerGap && gaps["u3"] == ChatMetrics.speakerGap)
        #expect(ChatMetrics.speakerGap > ChatMetrics.turnGap)
    }

    @Test func theCentredWorkLineStandsInItsOwnRowAlone() throws {
        let parts: [ChatPart] = [.tool(call("t1", "terminal", #"{"command":"npm test"}"#, seconds: 40)),
                                 .tool(call("t2", "read_file", #"{"path":"/a/README.md"}"#, seconds: 2)), .text("All good.")]
        let rows = ChatRowBuilder.build(input([me("u1", 0), bot("a1", 65, parts)]))
        let at = try #require(rows.firstIndex { if case .toolRun(let t) = $0.kind { return t.line != nil && t.group != nil } else { return false } })
        #expect(rows[at].gapAbove == 0, "no gap over the line's 40 pt row")
        guard case .bubble = rows[at + 1].kind else { Issue.record("the reply's words follow its line"); return }
        #expect(rows[at + 1].gapAbove == 0, "nor under it")
    }

    // MARK: 1 · the work line's words

    @Test func aSummaryTooLongForItsRowGivesWayToItsCount() throws {
        // No time known (history): the line says what the reply did, which is longer than a phone is wide.
        let long: [ChatPart] = [.tool(call("t1", "tool_describe", #"{"names":["web_search"]}"#)),
                                .tool(call("t2", "terminal", #"{"command":"python3 scripts/check.py"}"#)),
                                .tool(call("t3", "read_file", #"{"path":"notes/a-rather-long-file-name.txt"}"#)), .text("Done.")]
        let short: [ChatPart] = [.tool(call("t1", "terminal", #"{"command":"ls"}"#)), .tool(call("t2", "terminal", #"{"command":"pwd"}"#)), .text("Done.")]
        func title(_ parts: [ChatPart], style: ToolCallStyle, width: CGFloat, category: UIContentSizeCategory = .large) throws -> (String, String?, String) {
            let rows = ChatRowBuilder.build(input([me("u1", 0), bot("a1", 65, parts)], style: style))
            let row = try #require(rows.first { if case .toolRun(let t) = $0.kind { return t.line != nil } else { return false } })
            guard case .toolRun(let run) = row.kind, let line = run.line,
                  case .tool(let t) = TextLayout.layout(row, width: width, style: ChatStyle.make(category: category)).content else {
                throw CancellationError()
            }
            return (t.title, t.meta, line.title)
        }
        for style in [ToolCallStyle.bottom, .line] {
            let cut = try title(long, style: style, width: 402)
            #expect(cut.2.count > 40, "the summary is the long one: \(cut.2)")
            #expect(cut.0 == "3 steps" && cut.1 == nil, "\(style): \(cut.0) / \(cut.1 ?? "-")")
            // Words that fit are kept (and One Line's count beside them).
            let kept = try title(short, style: style, width: 402)
            #expect(kept.0 == kept.2 && kept.0 == "Ran 2 commands", "\(style): \(kept.0)")
            // A wide chat has room for the long one.
            #expect(try title(long, style: style, width: 1000).0 == cut.2)
            // The largest text: the count, whole.
            #expect(try title(long, style: style, width: 402, category: .accessibilityExtraExtraExtraLarge).0 == "3 steps")
        }
        // A timed line is short by construction and is never swapped.
        let timed: [ChatPart] = [.tool(call("t1", "terminal", #"{"command":"ls"}"#, seconds: 30)), .tool(call("t2", "terminal", #"{"command":"pwd"}"#, seconds: 12)), .text("Done.")]
        #expect(try title(timed, style: .bottom, width: 320).0 == "Worked for 42s · 2 steps")
    }
}
