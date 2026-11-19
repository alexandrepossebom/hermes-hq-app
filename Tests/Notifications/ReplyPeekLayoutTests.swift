// The reply peek [owner 2026-11-18 "more detail … overall larger"]: the chat's title beside the name, up to three lines
// of the reply (the card grows for them, then cuts), and one line still a capsule at the larger size.

import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite struct ReplyPeekLayoutTests {
    private func label(_ id: String, in view: UIView) -> UILabel? {
        if let found = view as? UILabel, found.accessibilityIdentifier == id { return found }
        for child in view.subviews { if let found = label(id, in: child) { return found } }
        return nil
    }

    private func peek(_ alert: PeekAlert) -> ReplyPeek.PeekView {
        let view = ReplyPeek.PeekView()
        view.fill(alert, others: 0)
        return view
    }

    @Test func shortReplyIsACapsuleAtTheLargerSize() {
        let view = peek(PeekAlert(name: "Sam", body: "Done.", session: "s", profile: nil, face: nil))
        let height = max(ReplyPeek.height, view.fittingHeight(width: 440))
        #expect(height == ReplyPeek.height)
        #expect(ReplyPeek.height >= 76)
    }

    @Test func longReplyGrowsToThreeLinesAndNoFurther() {
        let long = String(repeating: "The venue confirmed Friday at noon and the deposit is due Monday. ", count: 6)
        let view = peek(PeekAlert(name: "Otto", body: long, session: "s", profile: nil, face: nil))
        let line = label("reply-peek.line", in: view)
        #expect(line?.numberOfLines == 3)
        let height = view.fittingHeight(width: 440)
        let lineHeight = line?.font.lineHeight ?? 0
        #expect(height > ReplyPeek.height)
        #expect(height < ReplyPeek.PeekView.pad * 2 + lineHeight * 5)   // the name's line and three of the reply, not six
    }

    @Test func theChatsTitleShowsBesideTheNameAndInTheLabel() {
        let view = peek(PeekAlert(name: "Otto", body: "Here it is.", chat: "Landing page audit", session: "s", profile: nil, face: nil))
        let chat = label("reply-peek.chat", in: view)
        #expect(chat?.text == "Landing page audit")
        #expect(chat?.isHidden == false)
        #expect(view.accessibilityLabel == "Otto replied in Landing page audit: Here it is.")
    }

    @Test func noTitleOrTheBotsOwnNameShowsNothingExtra() {
        let none = peek(PeekAlert(name: "Otto", body: "Hi", session: "s", profile: nil, face: nil))
        #expect(label("reply-peek.chat", in: none)?.isHidden == true)
        #expect(none.accessibilityLabel == "Otto replied: Hi")
        let same = peek(PeekAlert(name: "Otto", body: "Hi", chat: "Otto", session: "s", profile: nil, face: nil))
        #expect(label("reply-peek.chat", in: same)?.isHidden == true)
    }
}
