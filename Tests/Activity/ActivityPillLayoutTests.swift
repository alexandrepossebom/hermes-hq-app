import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite("Minimal activity layout", .serialized)
struct ActivityPillLayoutTests {
    private func makeShelf() -> ActivityShelfView {
        let shelf = ActivityShelfView()
        shelf.summary = ActivityPill(entries: ShelfPieceKind.allCases.map {
            .init(kind: $0, words: $0 == .tasks ? "Tasks 2/5" : "Category \($0.rawValue)", isRunning: $0 == .background)
        })
        for entry in shelf.summary.entries {
            let body = UIView()
            body.heightAnchor.constraint(equalToConstant: 400).isActive = true
            let piece = shelf.piece(entry.kind) { ShelfPieceView(kind: entry.kind, body: body) }
            piece.header.set(words: entry.words, spinner: nil)
            piece.setPresent(true, animated: false)
        }
        return shelf
    }

    private func layout(_ shelf: ActivityShelfView, width: CGFloat = 386) {
        shelf.frame = CGRect(x: 0, y: 0, width: width, height: shelf.height(for: width))
        shelf.setNeedsLayout()
        shelf.layoutIfNeeded()
        shelf.pieces.values.forEach { $0.layoutIfNeeded() }
    }

    @Test func collapsedHugsContentAndOnlyThePillTakesTouches() {
        let shelf = makeShelf()
        layout(shelf)
        #expect(shelf.bounds.height == 44)
        #expect(shelf.summaryHeader.bounds.height == 44)
        #expect(shelf.summaryHeader.bounds.width < shelf.bounds.width)
        let glass = shelf.subviews.compactMap { $0 as? UIVisualEffectView }.first
        #expect(glass?.bounds.height == 34)
        #expect(shelf.pieces.values.allSatisfy { $0.isHidden })
        #expect(shelf.pieces.values.allSatisfy { $0.accessibilityElementsHidden }, "folded categories are not exposed through their explicit accessibility containers")
        #expect(shelf.pieces.values.allSatisfy { $0.accessibilityElements?.isEmpty == true })
        #expect(!shelf.point(inside: CGPoint(x: 0, y: 22), with: nil))
        #expect(shelf.point(inside: CGPoint(x: 193, y: 1), with: nil), "invisible top margin is tappable")
        #expect(shelf.summaryHeader.accessibilityLabel == shelf.summary.accessibilityLabel)
    }

    @Test func overviewHasEveryCategoryAndExactlyOneDetailScroller() throws {
        let shelf = makeShelf()
        shelf.expanded = true
        shelf.maxHeight = 220
        layout(shelf)
        #expect(shelf.bounds.height == 220)
        #expect(shelf.targetFrames(width: 386).count == 6)
        #expect(shelf.pieces.values.allSatisfy { !$0.isOpen && !$0.isHidden })
        #expect(shelf.pieces.values.allSatisfy { !$0.accessibilityElementsHidden }, "opening restores the category controls")
        #expect(shelf.pieces.values.allSatisfy { $0.accessibilityElements?.count == 1 }, "overview exposes headers, not hidden actions or bodies")
        for kind in ShelfPieceKind.allCases where kind != .browser {
            for piece in shelf.pieces.values { piece.setOpen(piece.kind == kind, animated: false) }
            layout(shelf)
            let selected = try #require(shelf.pieces[kind])
            #expect(shelf.targetFrames(width: 386).count == 1)
            #expect(shelf.pieces.values.filter { !$0.isHidden }.map(\.kind) == [kind])
            #expect(shelf.pieces.values.filter { !$0.accessibilityElementsHidden }.map(\.kind) == [kind])
            #expect(selected.scroll.frame.height > 0)
            #expect(selected.scroll.isHidden == false)
            #expect((selected.accessibilityElements?.last as? UIView) === selected.scroll)
            selected.header.showsMore = true
            #expect(selected.accessibilityElements?.count == 3, "visible actions join the open detail")
            selected.header.showsMore = false
            #expect(selected.accessibilityElements?.count == 2, "hidden actions leave the accessibility container immediately")
            var parent = selected.scroll.superview
            while let view = parent {
                #expect(!(view is UIScrollView), "the body scroller has no scrolling ancestor")
                parent = view.superview
            }
            #expect(shelf.summaryHeader.accessibilityLabel == "All activity")
        }
    }

    @Test func arrivingAndRemovedCategoriesFollowAccessibilityVisibility() {
        let shelf = ActivityShelfView()
        shelf.summary.parentIsRunning = true
        layout(shelf)
        let piece = shelf.piece(.tasks) { ShelfPieceView(kind: .tasks, body: UIView()) }
        piece.setPresent(true, animated: false)
        layout(shelf)
        #expect(piece.accessibilityElementsHidden)
        shelf.expanded = true
        piece.setOpen(true, animated: false)
        layout(shelf)
        #expect(!piece.accessibilityElementsHidden)
        #expect(!piece.scroll.accessibilityElementsHidden)
        piece.setOpen(false, animated: false)
        layout(shelf)
        #expect(piece.scroll.accessibilityElementsHidden)
        piece.setPresent(false, animated: false)
        shelf.summary.parentIsRunning = false
        layout(shelf)
        #expect(shelf.accessibilityElementsHidden)
        shelf.summary.parentIsRunning = true
        layout(shelf)
        #expect(!shelf.accessibilityElementsHidden)
    }

    @Test func countRefreshDoesNotOpenOrResizeTheOverview() {
        let shelf = makeShelf()
        layout(shelf)
        shelf.summary.entries[1].words = "Tasks 3/5"
        layout(shelf)
        #expect(!shelf.expanded)
        #expect(shelf.bounds.height == 44)
        shelf.expanded = true
        layout(shelf)
        let size = shelf.bounds.size
        shelf.summary.entries[1].words = "Tasks 4/5"
        layout(shelf)
        #expect(shelf.bounds.size == size)
        #expect(shelf.pieces.values.allSatisfy { !$0.isOpen })
    }

    @Test func attentionAndLargeTextGrowWithoutClippingTheAction() {
        let shelf = makeShelf()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 280, height: 500))
        window.addSubview(shelf)
        defer { shelf.removeFromSuperview(); window.isHidden = true }
        shelf.summary = ActivityPill(entries: [.init(kind: .browser, words: "Browser needs you", needsAttention: true)])
        layout(shelf, width: 180)
        #expect(shelf.bounds.height == 44, "ordinary text keeps the approved one-line touch target even when urgent")
        #expect(shelf.summaryHeader.label.numberOfLines == 1)
        #expect(shelf.summaryHeader.label.frame.minY >= 0)
        #expect(shelf.summaryHeader.label.frame.maxY <= shelf.summaryHeader.bounds.height)
        shelf.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        shelf.updateTraitsIfNeeded()
        shelf.summaryHeader.updateTraitsIfNeeded()
        layout(shelf, width: 180)
        #expect(shelf.summaryHeader.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge)
        #expect(shelf.bounds.height > 44, "accessibility text grows beyond the ordinary touch row")
        #expect(shelf.summaryHeader.label.numberOfLines == 2)
        #expect(shelf.summaryHeader.label.frame.height > shelf.summaryHeader.label.font.lineHeight, "the narrow accessibility pill actually wraps")
        #expect(shelf.summaryHeader.label.frame.minY >= 0)
        #expect(shelf.summaryHeader.label.frame.maxY <= shelf.summaryHeader.bounds.height)
        shelf.expanded = true
        layout(shelf, width: 280)
        #expect(shelf.targetFrames(width: 280)[.browser]?.width == 280)
    }

    @Test func newAttentionStaysVisibleWhileAnotherDetailIsOpen() {
        let shelf = makeShelf()
        shelf.expanded = true
        shelf.pieces[.tasks]?.setOpen(true, animated: false)
        shelf.summary.entries.removeAll { $0.kind == .browser }
        shelf.summary.entries.append(.init(kind: .browser, words: "Browser needs you", needsAttention: true))
        layout(shelf)
        #expect(shelf.summaryHeader.label.text?.hasPrefix("Browser needs you") == true)
        #expect(shelf.summaryHeader.accessibilityValue == "detail")
        #expect(shelf.pieces[.tasks]?.isHidden == false, "a refresh does not switch the selected detail")
    }

    @Test func parentOnlyPillAndExpandedStepAreVisibleWithoutCategoryRows() {
        let shelf = ActivityShelfView()
        shelf.summary = ActivityPill(entries: [], parentIsRunning: true, currentStep: "Reading release-notes.md")
        layout(shelf)
        #expect(shelf.bounds.height == 44)
        #expect(!shelf.summaryHeader.isHidden)
        #expect(shelf.summaryHeader.spinner != nil)
        shelf.expanded = true
        layout(shelf)
        #expect(shelf.summaryHeader.label.text == "Reading release-notes.md")
        #expect(shelf.summaryHeader.label.frame.minY >= 0)
        #expect(shelf.summaryHeader.label.frame.maxY <= shelf.summaryHeader.bounds.height)
        shelf.summary.parentIsRunning = false
        shelf.summary.currentStep = nil
        layout(shelf)
        #expect(shelf.bounds.height == 0)
        #expect(shelf.summaryHeader.isHidden)
    }

    @Test func aLongCurrentStepCannotTakeOverTheViewport() {
        let shelf = ActivityShelfView()
        shelf.summary = ActivityPill(entries: [], parentIsRunning: true,
                                     currentStep: String(repeating: "Checking a very long command argument ", count: 30))
        shelf.expanded = true
        shelf.maxHeight = 160
        shelf.maxCardHeight = 160
        layout(shelf, width: 280)
        #expect(shelf.bounds.height <= 160)
        #expect(shelf.summaryHeader.label.frame.minY >= 0)
        #expect(shelf.summaryHeader.label.frame.maxY <= shelf.bounds.height)
        #expect(shelf.summaryHeader.accessibilityLabel?.contains("command argument") == true)
    }

    @Test func aLargeGoalHeaderMeasuresTheSpaceItsControlsActuallyLeave() {
        let header = ShelfHeader()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        window.addSubview(header)
        defer { header.removeFromSuperview(); window.isHidden = true }
        header.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        header.updateTraitsIfNeeded()
        #expect(header.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge)
        header.label.font = .systemFont(ofSize: 22)
        header.showsLeadingDot = true
        header.showsMore = true
        header.setOpen(true, animated: false)
        header.set(words: "Goal blocked · Turn 12345/99999 · 23h", spinner: nil)
        for width: CGFloat in [180, 220, 280, 300] {
            header.frame = CGRect(x: 0, y: 0, width: width, height: header.height(width: width))
            header.setNeedsLayout()
            header.layoutIfNeeded()
            #expect(header.label.frame.minY >= 0)
            #expect(header.label.frame.maxY <= header.bounds.height)
        }
    }
}
