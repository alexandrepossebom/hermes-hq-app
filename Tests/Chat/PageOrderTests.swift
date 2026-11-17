import Foundation
import Testing
@testable import HermesHQNative

// Owner, 2026-11-17: a page handed over again keeps one card (the newest); the page's card shows while the reply arrives.
@Suite("Page order") @MainActor
struct PageOrderTests {
    private func reply(_ id: String, _ text: String) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, parts: [.text(text)], timestamp: Date(), rowId: nil)
    }

    @Test func aReplysPagesAreTheOnesAloneOnALine() {
        #expect(PageOrder.paths(in: "Here.\n\n::preview{file=\"/a/chart.html\"}\n\nDone.") == ["/a/chart.html"])
        #expect(PageOrder.paths(in: "MEDIA:/a/b/page.htm") == ["/a/b/page.htm"])
        #expect(PageOrder.paths(in: "I wrote /a/chart.html for you.").isEmpty, "a path inside a sentence is not a card")
        #expect(PageOrder.paths(in: "MEDIA:/a/report.pdf").isEmpty)
        #expect(PageOrder.paths(in: "No pages here.").isEmpty)
    }

    @Test func onlyTheNewestMessageKeepsThePagesCard() {
        let first = "Here.\n\n::preview{file=\"/a/chart.html\"}", second = "Changed.\n\n::preview{file=\"/a/chart.html\"}"
        let latest = PageOrder.latest([reply("a1", first), reply("a2", "Nothing."), reply("a3", second), reply("a4", "::preview{file=\"/a/other.html\"}")])
        #expect(latest == ["/a/chart.html": "a3", "/a/other.html": "a4"])
        #expect(PageOrder.updatedBelow(first, messageId: "a1", latest: latest) == ["/a/chart.html"])
        #expect(PageOrder.updatedBelow(second, messageId: "a3", latest: latest).isEmpty)
        #expect(PageOrder.updatedBelow(first, messageId: "a1", latest: [:]).isEmpty)
    }

    /// A reply that hands the page over again folds the first card at once, not when the chat is next opened.
    @Test func aPageHandedOverAgainFoldsTheEarlierCardAtOnce() {
        func input(_ messages: [ChatMessage]) -> ChatRowBuilder.Input {
            ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Ivy", expanded: [], now: Date(), scope: "test")
        }
        func folded(_ rows: [ChatRow]) -> [String] {
            rows.compactMap { row in
                if case .bubble(let bubble) = row.kind, !bubble.pagesUpdatedBelow.isEmpty { return row.messageId } else { return nil }
            }
        }
        var messages = [reply("a1", "Here.\n\n::preview{file=\"/a/chart.html\"}")]
        for i in 0..<6 { messages.append(reply("f\(i)", "Filler \(i).")) }
        var model = ChatRowModel()
        model.rebuildAll(input(messages), syncMessages: 50, oldestShown: nil)
        #expect(folded(model.allRows).isEmpty)
        messages.append(reply("a2", "Changed.\n\n::preview{file=\"/a/chart.html\"}"))
        model.rebuildNewest(input(messages), touching: ["a2"])
        #expect(folded(model.allRows) == ["a1"])
        #expect(model.allRows.map(\.id) == Array(ChatRowBuilder.build(input(messages)).reversed()).map(\.id))
    }

    @Test func aPageIsACardWhileItsReplyArrives() {
        let style = ChatStyleCache.shared.style(for: .large)
        let streaming = MarkdownRenderer.render("::preview{file=\"/a/chart.html\"}", style: style, streaming: true, pageCards: true).blocks
        #expect(streaming.contains { if case .pageCard = $0 { return true } else { return false } })
        #expect(PageCardView.foldedHeight(style: style) < PageCardView.height(style: style) - PageCardView.pictureHeight + 1)
    }
}
