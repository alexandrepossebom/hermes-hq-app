import UIKit

/// A page that hasn't drawn yet, as the shape of a page: a title bar, a few lines, a block. Shown where the page
/// will be (the chat's page card, the opened page) in place of a spinner or a grey glyph, so the wait reads as
/// "your page is coming" and the page arriving changes less of what is on screen. A soft light crosses the bars;
/// with Reduce Motion they hold still. It shows only after a short wait (`appear`), so a page that draws at once
/// never flashes it. Owner 2026-11-17 (Grok Bot's page card does this).
final class PageSkeletonView: UIView {
    private let bars: [UIView] = (0..<6).map { _ in UIView() }
    private let light = CAGradientLayer()
    private let lightMask = CALayer()
    private var pending: DispatchWorkItem?
    /// Bars and gaps scaled to the room: a card's picture area is small, an opened page is large.
    var compact = true { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        alpha = 0
        for bar in bars {
            bar.layer.cornerCurve = .continuous
            addSubview(bar)
        }
        light.startPoint = CGPoint(x: 0, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 0.5)
        light.locations = [0, 0.5, 1]
        light.mask = lightMask
        layer.addSublayer(light)
        tone()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: PageSkeletonView, _) in view.tone() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The bars' ink: `over` is the colour behind them (a page's own background on its tile), so they read on a light
    /// page in a dark app too.
    var over: UIColor? { didSet { tone() } }

    private func tone() {
        var white: CGFloat = traitCollection.userInterfaceStyle == .dark ? 0 : 1
        over?.resolvedColor(with: traitCollection).getWhite(&white, alpha: nil)
        let ink: UIColor = white > 0.5 ? .black : .white
        for bar in bars { bar.backgroundColor = ink.withAlphaComponent(white > 0.5 ? 0.07 : 0.09) }
        let glow = ink.withAlphaComponent(white > 0.5 ? 0.05 : 0.08).cgColor
        light.colors = [ink.withAlphaComponent(0).cgColor, glow, ink.withAlphaComponent(0).cgColor]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let k: CGFloat = compact ? 1 : 1.5
        let side: CGFloat = compact ? 16 : max(24, min(48, bounds.width * 0.06))
        let room = bounds.width - 2 * side
        var y: CGFloat = compact ? 16 : 28
        // A title, two lines, a block (the chart or table most pages lead with), a line.
        let rows: [(width: CGFloat, height: CGFloat, gap: CGFloat, radius: CGFloat)] = [
            (0.46, 16 * k, 12 * k, 5), (0.82, 9 * k, 7 * k, 4), (0.64, 9 * k, 14 * k, 4),
            (1.0, max(40, min(bounds.height * 0.42, 220 * k)), 12 * k, 10), (0.72, 9 * k, 7 * k, 4), (0.38, 9 * k, 0, 4),
        ]
        for (bar, row) in zip(bars, rows) {
            bar.frame = CGRect(x: side, y: y, width: (room * row.width).rounded(), height: row.height)
            bar.layer.cornerRadius = row.radius
            bar.isHidden = bar.frame.maxY > bounds.height - 8
            y = bar.frame.maxY + row.gap
        }
        // The light shows only on the bars.
        lightMask.sublayers = nil
        for bar in bars where !bar.isHidden {
            let piece = CALayer()
            piece.frame = bar.frame.offsetBy(dx: bounds.width, dy: 0)   // the light layer is three widths wide, see below
            piece.cornerRadius = bar.layer.cornerRadius
            piece.backgroundColor = UIColor.black.cgColor
            lightMask.addSublayer(piece)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        light.frame = CGRect(x: -bounds.width, y: 0, width: bounds.width * 3, height: bounds.height)
        lightMask.frame = light.bounds
        CATransaction.commit()
        sweep()
    }

    private func sweep() {
        light.removeAnimation(forKey: "sweep")
        guard !HQMotion.reduced, window != nil, alpha > 0 || pending != nil else { return }
        // The gradient's bright band crosses from the left edge to the right while the mask (the bars) stays put.
        let move = CABasicAnimation(keyPath: "locations")
        move.fromValue = [0.0, 0.17, 0.33]
        move.toValue = [0.67, 0.83, 1.0]
        move.duration = 1.8
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        light.add(move, forKey: "sweep")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sweep()
    }

    /// Shows after `delay` (a page that draws before then never shows it).
    func appear(after delay: TimeInterval = 0.18) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.isHidden = false
            self.sweep()
            UIView.animate(withDuration: HQMotion.quick) { self.alpha = 1 }   // motion-ok: a fade
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Gone (faded, or at once).
    func vanish(animated: Bool = true) {
        pending?.cancel()
        pending = nil
        guard alpha > 0 else { isHidden = true; return }
        guard animated else { alpha = 0; isHidden = true; light.removeAnimation(forKey: "sweep"); return }
        UIView.animate(withDuration: HQMotion.quick, animations: { self.alpha = 0 }) { _ in   // motion-ok: a fade
            if self.pending == nil { self.isHidden = true; self.light.removeAnimation(forKey: "sweep") }
        }
    }
}
