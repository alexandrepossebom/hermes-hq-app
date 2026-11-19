// [model-sheet] The model panel as a bottom sheet (owner 2026-11-18: "rebuilt as a pop-up from the bottom, just like
// when you click on the plus icon. But then I want like all the same kind of like animations and functionality and fun
// of it too. But it needs to be designed very cleanly"; of three mockups he said "Build A", the quick tiles).
//
// The sheet is the system's, set up as the Add context sheet is (`ComposerContextSheet`): the app's plain glass as
// Commands has it ([popup-consistency] owner 2026-11-19), the screen's own corners, fitted to its page so nothing sits under its bottom
// edge. The page is `ModelPanelView` in its `.sheet` style: the same name button, face, thinking bar, facts and rows
// as the card, so the menus, the drive and its haptics are the card's own. The drive's sky sits over the chat, behind
// the sheet.

import UIKit

@MainActor final class ModelCardSheet: UIViewController, UISheetPresentationControllerDelegate {
    /// The sheet's cards (Thinking, the rows) and tiles (the facts) share the Add context sheet's corners.
    static let cardRadius: CGFloat = 26
    static let tileRadius: CGFloat = 24
    /// About the sheet's own top corners, for the sky's cut-out behind it.
    static let radius: CGFloat = 38

    /// The cards' and tiles' fill: the sheets' frosted card (`HQPalette.sheetCard`), as Commands' rows have it, with
    /// its thin edge (`hqGlassEdge`). [popup-consistency] Owner 2026-11-19, of + / the model sheet / Commands in Dark:
    /// every pop-up is the lighter grey glass of Commands, so the page-colour wash and its white-lift cards are gone.
    static let cardFill = HQPalette.sheetCard

    private let panel: ModelPanelView
    private var watchesStyle = false
    private var shown = false

    init(panel: ModelPanelView) {
        self.panel = panel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false   // [popup-consistency] none, as Commands and every ChatSheet
            sheet.delegate = self
        }
    }

    @objc required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = panel
        panel.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        panel.onHeight = { [weak self] height in self?.fit(height) }
    }

    /// The sheet sizes to its page (up to the large detent, where the page scrolls).
    private func fit(_ height: CGFloat) {
        guard let sheet = sheetPresentationController, height > 0 else { return }
        let fitted = UISheetPresentationController.Detent.custom(identifier: .init("fit")) { context in
            min(height, context.maximumDetentValue)
        }
        if shown { sheet.animateChanges { sheet.detents = [fitted] } } else { sheet.detents = [fitted] }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard let sheet = sheetPresentationController else { return }
        if !watchesStyle {
            watchesStyle = true
            registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, GlassSheetTrait.self]) { (page: ModelCardSheet, _) in
                page.sheetPresentationController?.hqGlassPage()
            }
            // Its height before it rises, so it comes up at its own size.
            let width = view.bounds.width > 0 ? view.bounds.width : (presentingViewController?.view.bounds.width ?? 390)
            fit(panel.sheetHeight(width: width))
            placeSky()
            panel.sheetAppearing()
        }
        // On the app's glass, plain as Commands' ([popup-consistency] owner 2026-11-19: no page-colour wash in Dark).
        sheet.hqGlassPage()
    }

    /// The drive's sky goes in the sheet's own container: over the dimmed chat, right behind the sheet, as it sat right
    /// behind the card. (In the chat's view, under the system's dim, it was the arrangement build 1124 shipped with.)
    private func placeSky() {
        guard let sky = panel.sheetBackdrop, let container = sheetPresentationController?.containerView else { return }
        var top: UIView = view
        while let above = top.superview, above !== container { top = above }
        guard top.superview === container else {
            AppLog.trace("thinking", "sky: the sheet is not in its container yet, not placed")
            return
        }
        sky.frame = container.bounds
        sky.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.insertSubview(sky, belowSubview: top)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        shown = true
        panel.sheetAppeared()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { panel.sheetDismissed() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { panel.sheetDismissed() }

    override func accessibilityPerformEscape() -> Bool {
        panel.close()
        return true
    }
}

/// [model-sheet] Thinking's card on the sheet, where the Add context sheet has its recent photos: the bar sits on it,
/// and behind the bar a few small stars twinkle, faint at Off and brighter the harder the bot is set to think (the
/// drive's own sky pours out behind the sheet while the bar is held). Still under Reduce Motion and in Low Power Mode.
final class ThinkingCard: UIView {
    static let inset = UIEdgeInsets(top: 13, left: 16, bottom: 16, right: 16)

    private let sky = UIView()
    private var stars: [CALayer] = []
    private var strength: CGFloat = 0
    /// Where each star sits (0…1 across and down) and how large it is: the same sky every time.
    private static let places: [(x: CGFloat, y: CGFloat, size: CGFloat)] = (0..<26).map { (i: Int) -> (x: CGFloat, y: CGFloat, size: CGFloat) in
        let x: Int = (i * 37 + 11) % 100
        let y: Int = (i * 53 + 7) % 62
        let size: CGFloat = i % 5 == 0 ? 2.5 : (i % 2 == 0 ? 2 : 1.5)
        return (CGFloat(x) / 100, CGFloat(y) / 100, size)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        backgroundColor = ModelCardSheet.cardFill
        layer.cornerRadius = ModelCardSheet.cardRadius
        layer.cornerCurve = .continuous
        hqGlassEdge()   // [popup-consistency] the cards' thin edge, as Commands' rows
        clipsToBounds = true
        sky.alpha = 0
        addSubview(sky)
        for _ in Self.places {
            let star = CALayer()
            sky.layer.addSublayer(star)
            stars.append(star)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (card: ThinkingCard, _) in card.recolor() }
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func recolor() {
        // The tint, lifted toward white in Dark so a star reads as light, not as a blue dot.
        let dark = traitCollection.userInterfaceStyle == .dark
        let tint = ChatPalette.tint.resolvedColor(with: traitCollection)
        let ink = dark ? DriveInk.mix(tint, .white, 0.6) : tint
        for star in stars { star.backgroundColor = ink.cgColor }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sky.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (star, place) in zip(stars, Self.places) {
            star.bounds = CGRect(x: 0, y: 0, width: place.size, height: place.size)
            star.cornerRadius = place.size / 2
            star.position = CGPoint(x: (bounds.width * place.x).rounded(), y: (6 + bounds.height * place.y).rounded())
        }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !HQMotion.decorativeStill else { return }
        for (i, star) in stars.enumerated() where star.animation(forKey: "twinkle") == nil {
            let twinkle = CABasicAnimation(keyPath: "opacity")   // motion-ok: decoration, guarded by decorativeStill above
            twinkle.fromValue = 1
            twinkle.toValue = 0.2
            twinkle.duration = 1.1 + Double(i % 5) * 0.27
            twinkle.timeOffset = Double(i % 7) * 0.31
            twinkle.autoreverses = true
            twinkle.repeatCount = .infinity
            twinkle.isRemovedOnCompletion = false
            star.add(twinkle, forKey: "twinkle")
        }
    }

    /// `level` ("none" for Off) and where it sits among the thinking levels (0 the least … 1 the most).
    func show(level: String, fraction: CGFloat) {
        let next: CGFloat = level == "none" ? 0.12 : 0.3 + 0.7 * fraction
        guard abs(next - strength) > 0.001 else { return }
        strength = next
        guard window != nil, !HQMotion.reduced else { sky.alpha = next; return }
        HQMotion.animate(HQMotion.quick) { self.sky.alpha = next }
    }
}
