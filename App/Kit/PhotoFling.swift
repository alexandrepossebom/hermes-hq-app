// Fling a photo away to close it (owner 2026-11-19: "I catch myself trying to like fling the image away to close and it
// doesn't work"). Other apps' viewers close on a flick either way; ours only closed on a drag down. The photo follows the
// finger while the bars fade; let go past a short way, or with a flick, and the viewer closes, otherwise the photo
// settles back. Only at the fitted size (a zoomed photo pans) and only for a mostly-up-or-down move (sideways pages).
//
// The chat's viewers keep the system zoom transition's own drag down (it shrinks the photo back into its bubble) and
// take only the upward fling here; the Artifacts viewer, which has no zoom transition, takes both ways here.

import UIKit

@MainActor final class PhotoFling: NSObject, UIGestureRecognizerDelegate {
    nonisolated struct Directions: OptionSet, Sendable {
        let rawValue: Int
        static let up = Directions(rawValue: 1)
        static let down = Directions(rawValue: 2)
    }

    /// How far a slow drag has to travel to close (points).
    nonisolated static let distance: CGFloat = 110
    /// How much of the release speed counts as distance still to come (seconds): a flick at ~750 pt/s closes alone.
    nonisolated static let carry: CGFloat = 0.15

    /// Whether a release closes: the drag plus where its speed would carry it is past `distance`, the same way it
    /// started (a drag up flicked back down settles).
    nonisolated static func closes(translation: CGPoint, velocity: CGPoint, directions: Directions) -> Bool {
        let projected = translation.y + velocity.y * carry
        if directions.contains(.up), translation.y < 0, projected < -distance { return true }
        if directions.contains(.down), translation.y > 0, projected > distance { return true }
        return false
    }

    /// Whether a move may start a fling: mostly vertical, a way it handles.
    nonisolated static func begins(velocity: CGPoint, directions: Directions) -> Bool {
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        return directions.contains(velocity.y < 0 ? .up : .down)
    }

    private weak var host: UIViewController?
    private let directions: Directions
    private let flyOff: Bool
    private let content: () -> UIView?
    private let canBegin: () -> Bool
    private weak var moving: UIView?
    let pan = UIPanGestureRecognizer()

    /// `content` is what moves with the finger; `canBegin` says the photo is at its fitted size. `flyOff` sends the
    /// photo off the screen before the dismiss (for a viewer whose dismiss doesn't move the photo itself).
    init(host: UIViewController, directions: Directions, flyOff: Bool, content: @escaping () -> UIView?,
         canBegin: @escaping () -> Bool) {
        self.host = host
        self.directions = directions
        self.flyOff = flyOff
        self.content = content
        self.canBegin = canBegin
        super.init()
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1   // two fingers pinch
        host.view.addGestureRecognizer(pan)
    }

    private var bars: [UIView] {
        guard let nav = host?.navigationController else { return [] }
        return [nav.navigationBar, nav.toolbar].compactMap { $0 }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let host else { return }
        switch pan.state {
        case .began:
            moving = content()
        case .changed:
            let t = pan.translation(in: host.view)
            let shrink = 1 - min(0.12, abs(t.y) / 2500)
            moving?.transform = CGAffineTransform(translationX: t.x, y: t.y).scaledBy(x: shrink, y: shrink)
            let fade = 1 - min(1, abs(t.y) / 160)
            bars.forEach { $0.alpha = fade }
        case .ended:
            let t = pan.translation(in: host.view), v = pan.velocity(in: host.view)
            if Self.closes(translation: t, velocity: v, directions: directions) { close(translation: t, velocity: v) } else { settle() }
        case .cancelled, .failed:
            settle()
        default: break
        }
    }

    private func settle() {
        let moving = moving, bars = bars
        HQMotion.spring(duration: 0.35, damping: 0.85, changes: {
            moving?.transform = .identity
            bars.forEach { $0.alpha = 1 }
        })
        self.moving = nil
    }

    private func close(translation t: CGPoint, velocity v: CGPoint) {
        guard let host else { return }
        AppLog.trace("chatui", "photo flung \(t.y < 0 ? "up" : "down") to close")
        guard flyOff, let moving else {
            host.dismiss(animated: true) { [bars] in bars.forEach { $0.alpha = 1 } }
            return
        }
        // Off the screen the way it was going, as fast as it was thrown (never slower than a short pane's travel).
        let height = host.view.bounds.height
        let towardY: CGFloat = t.y < 0 ? -height : height
        let speed = max(abs(v.y), 1500)
        let duration = min(HQMotion.pane, TimeInterval(abs(towardY - t.y) / speed))
        let towardX = t.x + v.x * CGFloat(duration)
        HQMotion.animate(duration, options: [.curveEaseOut], changes: {
            moving.transform = CGAffineTransform(translationX: towardX, y: towardY)
        }, reduced: {}, completion: { _ in
            host.dismiss(animated: true)
        })
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let host else { return true }
        return Self.begins(velocity: pan.velocity(in: host.view), directions: directions) && canBegin()
    }

    /// The pager's and the photo's scroll views wait for a fling to be ruled out (it is, at once, for a sideways move
    /// or a zoomed photo), so neither takes a vertical throw first.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let host, let scroll = other.view as? UIScrollView else { return false }
        return other === scroll.panGestureRecognizer && scroll.isDescendant(of: host.view)
    }
}
