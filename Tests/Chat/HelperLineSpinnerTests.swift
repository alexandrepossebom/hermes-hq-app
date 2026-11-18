import Testing
import UIKit
@testable import HermesHQNative

/// The centred helper line ("1 helper working · 2 dispatched") runs its spinner in the lead mark's place, clear of its
/// words. It used to stay in a tool row's glyph slot at the press area's edge, half under the robot mark (owner, 2026-11-18).
@MainActor
@Suite("Helpers · the line's spinner")
struct HelperLineSpinnerTests {
    private func helper(_ id: String, _ status: SubagentStatus) -> SubagentProgress {
        SubagentProgress(id: id, goal: "Invented goal \(id)", sessionId: nil, delegationId: nil, model: nil, status: status,
                         taskCount: 1, taskIndex: 0, startedAt: 1_800_000_000, updatedAt: 1_800_000_001,
                         filesRead: [], filesWritten: [], stream: [], summary: nil)
    }

    private func row(live: Bool) -> ChatRow {
        let message = ChatMessage(id: "a1", role: .assistant, parts: [.text("On it.")],
                                  timestamp: Date(timeIntervalSince1970: 1_800_000_000), rowId: nil)
        let input = ChatRowBuilder.Input(messages: [message], isRunning: live, botName: "Lumen", expanded: [], scope: "spinner-test")
        let helpers = live ? [helper("h1", .running), helper("h2", .dispatched), helper("h3", .dispatched)]
                           : [helper("h1", .completed), helper("h2", .completed)]
        return HelperStatusRows.Group(requestID: "u1", anchor: 0, span: 0...0, helpers: helpers).row(input: input)
    }

    private func configured(_ cell: ChatToolCell, live: Bool) throws -> (button: UIControl, spinner: GlyphSpinner, title: UILabel, lead: UIView) {
        let row = row(live: live)
        cell.configure(row, layout: TextLayout.layout(row, width: 402, style: ChatStyle.make(category: .large)))
        let button = try #require(cell.contentView.subviews.compactMap { $0 as? UIControl }.first)
        let spinner = try #require(button.subviews.compactMap { $0 as? GlyphSpinner }.first)
        let title = try #require(button.subviews.first { $0 is UILabel && !($0 is GlyphSpinner) && ($0 as? UILabel)?.text?.contains("helper") == true } as? UILabel)
        // The marks are the plain views holding a shape layer.
        let lead = try #require(button.subviews.filter { type(of: $0) == UIView.self && $0.layer.sublayers?.first is CAShapeLayer }
            .min { $0.frame.minX < $1.frame.minX })
        return (button, spinner, title, lead)
    }

    @Test func theSpinnerTakesTheLeadMarksPlaceClearOfTheWords() throws {
        let cell = ChatToolCell(style: .default, reuseIdentifier: nil)
        let live = try configured(cell, live: true)
        #expect(live.title.text?.hasPrefix("1 helper working") == true, "\(live.title.text ?? "")")
        #expect(!live.spinner.isHidden)
        #expect(live.lead.isHidden, "the spinner replaces the robot mark rather than sitting on it")
        #expect(abs(live.spinner.frame.midX - live.lead.frame.midX) <= 1, "spinner \(live.spinner.frame) mark \(live.lead.frame)")
        #expect(abs(live.spinner.frame.midY - live.lead.frame.midY) <= 1)
        #expect(live.spinner.frame.maxX <= live.title.frame.minX, "spinner \(live.spinner.frame) title \(live.title.frame)")
        #expect(live.spinner.frame.minX >= 0, "inside the pill")

        // The same cell, reused for a finished line: the mark comes back and the spinner goes.
        let done = try configured(cell, live: false)
        #expect(done.spinner.isHidden)
        #expect(!done.lead.isHidden)
    }
}
