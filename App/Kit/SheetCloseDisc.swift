// [popup-consistency] Owner 2026-11-19: "Look at all pop ups like plus button, commands, model, and anything similar.
// Not designed the same, X buttons differ." The chat's pop-ups closed with four ✕s: the system bar's (Chat Info and
// its siblings), the same glyph that VoiceOver called Cancel (Commands, Models), a 56 pt glass disc with a small glyph
// sitting lower (Add context), and a 15 pt semibold glyph on a disc of its own (the model sheet); in the Desktop Look an
// outlined box, a grey disc and the bar's bare glyph. The system bar's ✕ is the one every sheet closes with
// (`UIBarButtonItem.hqClose`), so a sheet that draws its own header (Add context, the model sheet) uses this disc,
// drawn as that ✕ is: the bar's glyph (`SheetCloseDiscTests` pins it to the bar's own), 44 pt, 16 pt in from the
// sheet's top and leading edges, the label ink, on Liquid Glass in the iOS look and bare in the Desktop Look (the look
// takes the bars' capsules away, `DesktopBars`). Its glyph grows with the text size as far as the bar's does, and it
// shows the large content viewer at the accessibility sizes. The Mac keeps its words (`MacCloseItem`): neither sheet opens there.

import SwiftUI
import UIKit

@MainActor enum SheetCloseDisc {
    /// The tap target and the disc, as the bar's ✕.
    static let side: CGFloat = 44
    /// From the sheet's top and leading edges to the disc, where the bar puts its ✕.
    static let inset: CGFloat = 16
    /// What UI tests and VoiceOver find (`ChatSheet.wrap`'s ✕ has the same).
    static let identifier = "sheet.close"
    /// The bar's own glyph for its ✕, read off the bar's image view (`theDiscsGlyphIsTheSystemBarsClose`): Body,
    /// medium, large scale. It follows the text size as the bar's does: never smaller than at the default size, and no
    /// larger than at XXL (`smallest`, `largest`).
    static let symbol = UIImage.SymbolConfiguration(textStyle: .body, scale: .large).applying(UIImage.SymbolConfiguration(weight: .medium))
    /// The text sizes the bar's ✕ keeps to (measured: 22.7 pt wide from XS to L, 28 pt from XXL up; the large content
    /// viewer shows it larger).
    static let smallest = UIContentSizeCategory.large
    static let largest = UIContentSizeCategory.extraExtraLarge

    /// The title beside the disc: the bar's title in each look (the iOS look's Headline, the Desktop Look's bar title).
    static var titleFont: UIFont { Theme.isDesktop ? ThemeChrome.barTitleFont : HQFont.style(.headline) }

    enum Glyph {
        /// Closes the sheet.
        case close
        /// Inside a sheet's own page (Add context's submenu): back to its first page.
        case back

        var symbol: String { self == .close ? "xmark" : "chevron.left" }
        var label: String { self == .close ? "Close" : "Back" }
    }

    static func image(_ glyph: Glyph) -> UIImage? {
        UIImage(systemName: glyph.symbol, withConfiguration: symbol)
    }

    /// The disc's frame in a sheet page `width` wide (leading edge; mirrored right to left).
    static func frame(width: CGFloat, rightToLeft: Bool = false) -> CGRect {
        CGRect(x: rightToLeft ? width - inset - side : inset, y: inset, width: side, height: side)
    }

    /// The disc's look: Liquid Glass (Paper: its soft grey disc, `hqGlass`), or in the Desktop Look the glyph alone.
    static func configuration(_ glyph: Glyph, desktop: Bool = Theme.isDesktop) -> UIButton.Configuration {
        var config: UIButton.Configuration = desktop ? .plain() : .hqGlass()
        config.image = image(glyph)
        config.baseForegroundColor = HQPalette.label
        config.cornerStyle = .capsule
        config.contentInsets = .zero
        if desktop { config.background.backgroundColor = .clear }
        return config
    }
}

/// The disc itself: a 44 pt button with the bar's ✕ (or ‹), restyled when the look or the appearance changes.
final class SheetCloseButton: UIButton {
    /// ✕ or ‹ (Add context's submenu turns its ✕ into Back and back).
    var glyph: SheetCloseDisc.Glyph {
        didSet { if glyph != oldValue { name(); restyle() } }
    }

    init(_ glyph: SheetCloseDisc.Glyph, action: UIAction?) {
        self.glyph = glyph
        super.init(frame: CGRect(x: 0, y: 0, width: SheetCloseDisc.side, height: SheetCloseDisc.side))
        restyle()
        name()
        if let action { addAction(action, for: .primaryActionTriggered) }
        minimumContentSizeCategory = SheetCloseDisc.smallest
        maximumContentSizeCategory = SheetCloseDisc.largest
        // [a11y] As the bar's items: a hold at the accessibility text sizes shows it large, named.
        showsLargeContentViewer = true
        scalesLargeContentImage = true
        addInteraction(UILargeContentViewerInteraction())
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (button: SheetCloseButton, _) in
            button.restyle()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func restyle() { configuration = SheetCloseDisc.configuration(glyph) }

    private func name() {
        accessibilityLabel = glyph.label
        accessibilityIdentifier = glyph == .close ? SheetCloseDisc.identifier : "sheet.back"
        largeContentTitle = glyph.label
        largeContentImage = UIImage(systemName: glyph.symbol)
    }

    override var intrinsicContentSize: CGSize { CGSize(width: SheetCloseDisc.side, height: SheetCloseDisc.side) }
}

/// The disc in a SwiftUI header (Add context): the same UIKit button, so both headers draw one control.
struct SheetCloseDiscView: UIViewRepresentable {
    var glyph: SheetCloseDisc.Glyph = .close
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SheetCloseButton {
        let coordinator = context.coordinator
        let button = SheetCloseButton(glyph, action: UIAction { _ in coordinator.action?() })
        coordinator.action = action
        return button
    }

    func updateUIView(_ button: SheetCloseButton, context: Context) {
        context.coordinator.action = action
        button.glyph = glyph
        button.restyle()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SheetCloseButton, context: Context) -> CGSize? {
        CGSize(width: SheetCloseDisc.side, height: SheetCloseDisc.side)
    }

    final class Coordinator {
        var action: (() -> Void)?
    }
}
