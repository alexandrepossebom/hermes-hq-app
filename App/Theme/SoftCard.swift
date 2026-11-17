// [soft-cards] The one material of Soft Cards (Theme › Backgrounds › App Background › Soft Cards). Owner 2026-11-12,
// after the first build: "This needs a TON of work to be something we can actually release proudly." The first cards
// were near-solid slabs of the card colour (78 %) that hid the picture they were chosen for, in three makes (a card, a
// lighter plate behind grouped pages' cards, SwiftUI's own material for loose lines), with boxes inside boxes.
//
// The same day: "These need to always match the theme that is currently used … Must be subtle - only to make things more
// legible."
//
// Now every backing is this surface and nothing nests. It is the theme's own page seen through frosted glass, no more:
// - the picture softened behind it (iOS's plain blur, which has no colour of its own; the Desktop Look's bars are made
//   the same way, DesktopFrost.swift), so line drawings and photo detail do not run through words;
// - the theme's page colour over that (the colour Dim lays over the picture, so a card is a little more Dim where the
//   words are), only as dense as this picture needs for the faintest words on it (label 2) to read at 4.5:1
//   (`SoftCard.density`): a calm or dimmed picture gets a card that is barely there, a bright photo in the dark a
//   denser one;
// - a hairline edge in the theme's ink, so a card on a picture of its own tone still has a shape;
// - the grouped cards' corners (`HQShape`).

import SwiftUI
import UIKit

/// [soft-card-style] Owner 2026-11-15: "settings to change the appearance of the soft cards … pick from similar background
/// types like we have for the text bubbles." Theme › Backgrounds › App Background › Soft Cards › Style, the same three
/// as Chat Bubbles › Style. Tinted is the card the switch has always drawn (the picture softened under the theme's page
/// colour), so turning Soft Cards on still looks as it did; Solid and Glass are new.
nonisolated enum SoftCardStyle: String, Sendable, Hashable, CaseIterable {
    /// The skin's own grouped card colour, as a grouped page's rows draw it on a plain page: the picture shows only
    /// between the cards.
    case solid
    /// Liquid Glass carrying the theme's page colour, only as much of it as this picture needs (`SoftCard.density`).
    case glass
    /// iOS's plain blur of the picture under the theme's page colour at that density (the first Soft Cards).
    case tinted

    static let standard = SoftCardStyle.tinted

    /// A stored value: nothing, or one this build doesn't know, is the standard.
    init(stored: String?) { self = stored.flatMap(SoftCardStyle.init(rawValue:)) ?? .standard }

    var title: String {
        switch self {
        case .solid: "Solid"
        case .glass: "Glass"
        case .tinted: "Tinted"
        }
    }

    /// The line under the picker about the style picked (as Chat Bubbles' `styleLine`).
    var line: String {
        switch self {
        case .solid: "Solid: your theme’s card color, the picture only between the cards."
        case .glass: "Glass: Liquid Glass in your theme’s colors."
        case .tinted: "Tinted: the picture softened in your theme’s color, only as strong as it needs."
        }
    }

    /// As the cards draw it: Glass is solid under Reduce Transparency, as Glass bubbles are.
    func shown(reduceTransparency: Bool) -> SoftCardStyle { self == .glass && reduceTransparency ? .solid : self }
}

@MainActor enum SoftCard {
    /// The corners of every soft card.
    static var radius: CGFloat { HQShape.radius(26, .card) }
    /// The lightest and the densest a card gets.
    nonisolated static let densityRange = 0.2...0.9
    /// What the faintest words on a card must measure against it (WCAG).
    nonisolated static let contrast = 4.5

    /// A grouped row on a soft card: nothing of its own (the card is behind it), and the ink at 9 % while pressed.
    static let rowClear = UIColor { @Sendable _ in .clear }
    static let rowPressed = UIColor { @Sendable traits in HQPalette.label.resolvedColor(with: traits).withAlphaComponent(0.09) }
    static let edge = UIColor { @Sendable traits in
        HQPalette.label.resolvedColor(with: traits).withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.09 : 0.06)
    }

    /// The theme's page colour at the density this picture needs, for `traits` (Light or Dark, the skin).
    /// [bubble-card] `backdrop`: the picture the card stands on (a chat's reply stands on the chats').
    static func tint(_ traits: UITraitCollection, on backdrop: Backdrop = .app) -> UIColor {
        HQPalette.page.resolvedColor(with: traits).withAlphaComponent(CGFloat(density(traits, on: backdrop)))
    }

    /// [soft-card-style] The style the cards draw just now.
    static var style: SoftCardStyle { Backdrop.app.cardStyle.shown(reduceTransparency: HQAccessibility.reduceTransparency) }

    static func density(_ traits: UITraitCollection, on backdrop: Backdrop = .app) -> Double {
        let dark = traits.userInterfaceStyle == .dark
        let tone = backdrop.picture(for: traits).flatMap { picture in
            BackdropImages.shared.image(picture).map { SoftCardTone.of($0, picture: picture) }
        }
        let ink = HQPalette.label2.resolvedColor(with: traits)
        var alpha: CGFloat = 1
        ink.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        // No picture made yet: the worst one (white in the dark, black in the light).
        return density(picture: tone.map { dark ? $0.bright : $0.dark } ?? (dark ? 1 : 0), dim: Double(backdrop.dim) / 100,
                       page: luminance(HQPalette.page.resolvedColor(with: traits)), card: luminance(HQPalette.page.resolvedColor(with: traits)),
                       ink: luminance(ink.withAlphaComponent(1)), inkAlpha: Double(alpha))
    }

    /// The least density at which words in `ink` (at `inkAlpha` over the card) read at `contrast` on a card of
    /// luminance `card` over a picture whose hardest part for them is `picture`, under Dim's veil of the page colour.
    /// All luminances are linear (0…1); the layers are mixed as the screen mixes them, in sRGB.
    nonisolated static func density(picture: Double, dim: Double, page: Double, card: Double, ink: Double, inkAlpha: Double) -> Double {
        let under = dim * encoded(page) + (1 - dim) * encoded(picture)
        let cardTone = encoded(card), inkTone = encoded(ink)
        var density = densityRange.lowerBound
        while density < densityRange.upperBound {
            let surface = density * cardTone + (1 - density) * under
            let words = inkAlpha * inkTone + (1 - inkAlpha) * surface
            let a = decoded(words) + 0.05, b = decoded(surface) + 0.05
            if max(a, b) / min(a, b) >= contrast { return density }
            density += 0.02
        }
        return densityRange.upperBound
    }

    nonisolated static func encoded(_ linear: Double) -> Double {
        let value = min(max(linear, 0), 1)
        return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    nonisolated static func decoded(_ tone: Double) -> Double {
        let value = min(max(tone, 0), 1)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func luminance(_ color: UIColor) -> Double {
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * decoded(Double(r)) + 0.7152 * decoded(Double(g)) + 0.0722 * decoded(Double(b))
    }
}

/// How bright and how dark a picture gets, as a card sees it: the picture drawn small (which evens out fine detail, as
/// the card's blur does), then its brightest and darkest tenths.
nonisolated struct SoftCardTone: Sendable, Equatable {
    var bright: Double
    var dark: Double

    @MainActor private static var known: [BackdropPicture: SoftCardTone] = [:]

    @MainActor static func of(_ image: UIImage, picture: BackdropPicture) -> SoftCardTone {
        if let tone = known[picture] { return tone }
        let tone = image.cgImage.map(measure) ?? SoftCardTone(bright: 1, dark: 0)
        if known.count > 8 { known.removeAll() }
        known[picture] = tone
        return tone
    }

    static func measure(_ image: CGImage) -> SoftCardTone {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return SoftCardTone(bright: 1, dark: 0) }
        var tones: [Double] = []
        tones.reserveCapacity(side * side)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = SoftCard.decoded(Double(pixels[index]) / 255), g = SoftCard.decoded(Double(pixels[index + 1]) / 255)
            let b = SoftCard.decoded(Double(pixels[index + 2]) / 255)
            tones.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        tones.sort()
        let tenth = max(1, tones.count / 10)
        return SoftCardTone(bright: tones.suffix(tenth).reduce(0, +) / Double(tenth), dark: tones.prefix(tenth).reduce(0, +) / Double(tenth))
    }
}

/// The surface itself. `shape` picks its corners; `open` sides run on into a neighbour (no corners, no edge there).
final class SoftCardSurface: UIView {
    enum Shape { case card, capsule }
    struct Sides: OptionSet { let rawValue: Int; static let top = Sides(rawValue: 1); static let bottom = Sides(rawValue: 2) }

    var shape: Shape = .card { didSet { setNeedsLayout() } }
    var open: Sides = [] { didSet { setNeedsLayout() } }
    /// [bubble-card] A chat bubble's own corner instead of the cards' (Chat Bubbles › Style › Card).
    var radius: CGFloat? { didSet { if radius != oldValue { setNeedsLayout() } } }
    /// [bubble-card] The picture this card stands on: the app's, or the chats' for a reply.
    var backdrop: Backdrop = .app { didSet { if backdrop !== oldValue { paint() } } }

    private let blur = UIVisualEffectView(effect: DesktopFrost.blur())
    private let tint = UIView()
    private let rim = UIView()
    /// [soft-card-style] Glass: made the first time it is picked.
    private var glass: UIVisualEffectView?
    /// The glass's tint last painted: a new glass effect is only made when it changes.
    private var paintedGlassTint: UIColor?
    private var watches: [NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        clipsToBounds = true
        layer.cornerCurve = .continuous
        rim.layer.cornerCurve = .continuous
        rim.isUserInteractionEnabled = false
        for view in [blur, tint, rim] as [UIView] { addSubview(view) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) { (view: SoftCardSurface, _) in
            view.paint()
        }
        for name in [Backdrop.didChange, Backdrop.pictureReady, Theme.didChange, UIAccessibility.reduceTransparencyStatusDidChangeNotification] {
            watches.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.paint() }
            })
        }
        paint()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit { watches.forEach(NotificationCenter.default.removeObserver) }

    /// [soft-card-style] What the surface is made of for each style (Theme › App Background › Soft Cards › Style):
    /// - Tinted: the blur, the page colour at the picture's density over it, the hairline.
    /// - Solid: the skin's grouped card colour, whole, and the hairline (a card on a picture of its own tone).
    /// - Glass: Liquid Glass carrying the page colour at the same density (untinted glass failed 4.5:1 over a busy
    ///   picture for bubbles); the glass draws its own edge.
    private func paint() {
        let style = SoftCard.style
        blur.isHidden = style != .tinted
        tint.isHidden = style == .glass
        rim.isHidden = style == .glass
        switch style {
        case .tinted: tint.backgroundColor = SoftCard.tint(traitCollection, on: backdrop)
        case .solid: tint.backgroundColor = HQPalette.card.resolvedColor(with: traitCollection).withAlphaComponent(1)
        case .glass: break
        }
        rim.layer.borderColor = SoftCard.edge.resolvedColor(with: traitCollection).cgColor
        let glassTint = style == .glass ? SoftCard.tint(traitCollection, on: backdrop) : nil
        if style == .glass, glass == nil {
            let view = UIVisualEffectView(effect: nil)
            view.isUserInteractionEnabled = false
            insertSubview(view, at: 0)
            glass = view
            setNeedsLayout()
        }
        glass?.isHidden = style != .glass
        if let glass, let glassTint, paintedGlassTint != glassTint || glass.effect == nil {
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = glassTint
            glass.effect = effect
        }
        paintedGlassTint = glassTint
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { paint() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = shape == .capsule ? bounds.height / 2 : min(self.radius ?? SoftCard.radius, min(bounds.width, bounds.height) / 2)
        var corners: CACornerMask = []
        if !open.contains(.top) { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if !open.contains(.bottom) { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        layer.cornerRadius = radius
        layer.maskedCorners = corners
        blur.frame = bounds
        tint.frame = bounds
        // The edge runs off an open side, where the card's own clipping cuts it.
        let line = HQShape.line(1 / max(traitCollection.displayScale, 2))   // [Mac AAA 2026-11-16] one whole pixel on the Mac
        var frame = bounds
        if open.contains(.top) { frame.origin.y -= radius + 2; frame.size.height += radius + 2 }
        if open.contains(.bottom) { frame.size.height += radius + 2 }
        rim.frame = frame
        rim.layer.cornerRadius = radius
        rim.layer.borderWidth = line
        // [soft-card-style] The glass rounds itself (its edge light follows its own corners): it too runs off an open
        // side, so only the card's clipping squares it there.
        if let glass {
            glass.frame = frame
            glass.cornerConfiguration = shape == .capsule && open.isEmpty ? .capsule() : .corners(radius: .fixed(radius))
        }
    }
}

/// The surface behind a SwiftUI view (`hqPictureBacking`).
struct SoftCardBackground: UIViewRepresentable {
    var capsule = false
    /// [bubble-card] A chat bubble's corner, on the chats' picture (the Chat Bubbles preview).
    var bubbleRadius: CGFloat?
    func makeUIView(context: Context) -> SoftCardSurface {
        let surface = SoftCardSurface()
        updateUIView(surface, context: context)
        return surface
    }
    func updateUIView(_ surface: SoftCardSurface, context: Context) {
        surface.shape = capsule ? .capsule : .card
        surface.radius = bubbleRadius
        surface.backdrop = bubbleRadius == nil ? .app : .chats
    }
}
