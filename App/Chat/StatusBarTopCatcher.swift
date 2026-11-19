// [status-bar-top] A tap on the status bar goes to the top of the chat, as in Messages (owner 2026-11-19: "Tapping the
// top of the screen in a session should take you to the top of the chat and it doesn't").
//
// The transcript is an upside-down table, so the system's own scroll-to-top would take it to the newest end: the table
// keeps `scrollsToTop` off. This stand-in takes the tap instead. It is a tiny scroll view, left a point short of its
// top so the system has somewhere to send it, that never moves: it says no to the scroll and hands the tap to the chat.

import UIKit

final class StatusBarTopCatcher: UIScrollView, UIScrollViewDelegate {
    /// The status bar was tapped while this chat is on show.
    var onTap: (() -> Void)?
    /// False while something is presented over the chat: a sheet's own list takes the tap then (on the iPhone, two
    /// scroll views that both want the status bar's tap leave it to neither).
    var isFrontmost: (() -> Bool)?

    override var scrollsToTop: Bool {
        get { super.scrollsToTop && (isFrontmost?() ?? true) }
        set { super.scrollsToTop = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollsToTop = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Always a point below its own top: a scroll view already at its top is skipped by the status bar.
        let size = CGSize(width: bounds.width, height: bounds.height + 2)
        if contentSize != size { contentSize = size }
        if contentOffset.y != 1 { contentOffset = CGPoint(x: 0, y: 1) }
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        onTap?()
        return false
    }
}
