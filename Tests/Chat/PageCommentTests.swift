import Foundation
import UIKit
import Testing
@testable import HermesHQNative

// Owner, 2026-11-17: a page a bot made is commented on by pointing at the part (as Grok Bot's pages are).
@Suite("Page comment") @MainActor
struct PageCommentTests {
    private func target(_ kind: String = "element", label: String = "Heading", text: String = "Replies per 100 follow-ups") -> PageComment.Target? {
        PageComment.Target(["kind": kind, "label": label, "text": text, "path": "div.card > h1",
                            "x": 20.0, "y": 40.0, "w": 300.0, "h": 28.0, "vw": 390.0])
    }

    @Test func thePageNamesThePartThatWasClicked() throws {
        let picked = try #require(target())
        #expect(picked.caption == "Heading · “Replies per 100 follow-ups”")
        #expect(PageComment.Target(["kind": "escape"]) == nil, "Escape is not a part of the page")
        #expect(PageComment.Target(["kind": "element", "x": 1.0]) == nil, "a part with no place is refused")
    }

    @Test func theBotIsToldWhichPartAndTheBubbleStaysShort() throws {
        let message = PageComment.message("Make this shorter", about: try #require(target()), file: "followups.html")
        #expect(message.display == "On followups.html, about the heading “Replies per 100 follow-ups”:\nMake this shorter")
        #expect(message.text.hasPrefix(message.display))
        #expect(message.text.contains("div.card > h1"), "the bot gets where the part is in the markup")
        #expect(!message.display.contains("div.card"), "the chat's bubble does not")

        let words = PageComment.message("Too vague", about: try #require(target("text", label: "Selected text", text: "last 90 days")), file: "a.html")
        #expect(words.display == "On a.html, about the words “last 90 days”:\nToo vague")
        let chart = PageComment.message("Bigger", about: try #require(target(label: "Chart", text: "")), file: "a.html")
        #expect(chart.display == "On a.html, about the chart:\nBigger")
    }

    @Test func thePartIsPlacedInTheWebViewsOwnPoints() throws {
        // The Mac lays a page out at its own zoom: 390 page pixels across a 780-point view.
        let web = UIView(frame: CGRect(x: 0, y: 0, width: 780, height: 800))
        let frame = try #require(target()).frame(in: web)
        #expect(frame == CGRect(x: 40, y: 80, width: 600, height: 56))
    }

    /// A click on the page while Comment is on names the part and does not press the page's own button.
    @Test func aClickWhileCommentingPicksThePartAndDoesNotPressIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("comment-\(UUID().uuidString).html")
        let html = """
        <html><head><title>Sales</title></head><body><h1 id=h>Revenue by week</h1>
        <button id=b data-hermes-send="Pressed">Go</button>
        <script>window.addEventListener('load',function(){setTimeout(function(){window.__hqComment.set(true);
        var e=document.getElementById('b'),r=e.getBoundingClientRect();
        e.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:r.left+2,clientY:r.top+2}));
        document.title=document.querySelector('[data-hq-comment-ring]')?'ringed':'bare'},200)})</script></body></html>
        """
        try html.write(to: url, atomically: true, encoding: .utf8)
        var prompts: [String] = []
        let source = HTMLPageSheet.Source(path: "/tmp/page.html", context: MediaContext(accountId: "t", profile: "default"),
                                          send: { prompts.append($0) }, botName: "Otto", comment: { _, _ in })
        let page = HTMLPageSheet(file: url, source: source)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = page
        window.isHidden = false
        defer { window.isHidden = true }
        var title: String?
        for _ in 0..<60 where title != "ringed" && title != "bare" {
            try await Task.sleep(for: .milliseconds(100))
            title = page.debugWebTitle
        }
        #expect(title == "ringed", "the clicked part is ringed")
        try await Task.sleep(for: .milliseconds(300))
        #expect(prompts.isEmpty, "the page's own button was not pressed")
        #expect(HTMLPageSheet.titleInPage(url) == "Sales")
    }
}
