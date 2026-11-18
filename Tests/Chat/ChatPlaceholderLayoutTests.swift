import UIKit
import Testing
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct ChatPlaceholderLayoutTests {
    @Test func cardKeepsItsVerticalInsetsWhenKeyboardLeavesLittleRoom() throws {
        let backdrop = Backdrop.chats
        let oldSource = backdrop.source
        let oldSame = backdrop.sameAsApp
        // This suite runs on a dedicated simulator; do not replace a saved photo.
        if case .photo = oldSource { Issue.record("Requires a simulator without a saved photo"); return }
        defer {
            if case .preset(let preset) = oldSource { backdrop.setPreset(preset) } else { backdrop.clear() }
            backdrop.setSameAsApp(oldSame)
        }
        backdrop.setPreset(.aurora)
        #expect(backdrop.shows)
        for height: CGFloat in [310, 330, 350, 400, 600] {
            let view = ChatPlaceholderView(frame: CGRect(x: 0, y: 0, width: 402, height: height))
            view.mode = .empty(name: "Scout", head: nil, profile: "scout",
                               intro: .init(role: "Helping with your projects and keeping the details in order.",
                                            talk: true, info: true, name: true))
            view.layoutIfNeeded()
            let stack = try #require(view.subviews.first { $0 is UIStackView } as? UIStackView)
            let card = try #require(view.subviews.first { $0 is UIVisualEffectView })
            let frames = stack.arrangedSubviews.filter { !$0.isHidden }.map { stack.convert($0.frame, to: view) }
            let content = try #require(frames.first).union(frames.dropFirst().reduce(CGRect.null) { $0.union($1) })
            #expect(!card.isHidden)
            #expect(content.minY - card.frame.minY >= 19.5, "top inset at height \(height)")
            #expect(card.frame.maxY - content.maxY >= 19.5, "bottom inset at height \(height)")
            #expect(view.bounds.contains(card.frame), "card fits at height \(height)")
            for id in ["chat.intro.talk", "chat.intro.info", "chat.intro.name"] {
                func find(_ root: UIView) -> UIView? {
                    if root.accessibilityIdentifier == id { return root }
                    return root.subviews.lazy.compactMap { find($0) }.first
                }
                let button = try #require(find(stack))
                #expect(view.bounds.contains(button.convert(button.bounds, to: view)), "\(id) fits at \(height)")
            }
        }
    }

    @Test func introRestoresFaceWhenRoomReturnsWithoutABackground() throws {
        let backdrop = Backdrop.chats
        let oldSource = backdrop.source
        let oldSame = backdrop.sameAsApp
        if case .photo = oldSource { Issue.record("Requires a simulator without a saved photo"); return }
        defer {
            if case .preset(let preset) = oldSource { backdrop.setPreset(preset) } else { backdrop.clear() }
            backdrop.setSameAsApp(oldSame)
        }
        backdrop.clear()
        let view = ChatPlaceholderView(frame: CGRect(x: 0, y: 0, width: 390, height: 150))
        view.mode = .empty(name: "Scout", head: nil, profile: "scout", intro: .init(talk: true, info: true, name: true))
        view.layoutIfNeeded()
        let stack = try #require(view.subviews.first { $0 is UIStackView } as? UIStackView)
        let face = try #require(stack.arrangedSubviews.first)
        #expect(face.isHidden)
        view.frame.size.height = 600
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(!face.isHidden)
        #expect(try #require(view.subviews.first { $0 is UIVisualEffectView }).isHidden)
    }
}
