// [backdrop-ink] Owner 2026-11-15 (a screenshot of Sessions in Light on a night sky, Dim turned down): "When you select
// a darker background, the text on the top … It's not automatically adjusting to the background type. So we need to
// make sure that happens every time."
//
// Dim is what keeps words readable on a picture (it lays the page colour over it), and Soft Cards put the lists on
// cards. But some words stand straight on the picture whatever is switched on, and with Dim turned down a picture of
// the other tone (a night sky in Light, a pale photo in Dark) left them in the mode's own ink: black on near-black.
//
// So words that stand straight on the app's picture take the ink that reads on the picture as it is drawn there (the
// picture under Dim), measured, not assumed from the mode:
// - a page's title in the bar and the line under it (a tab's, a pushed page's, a Settings page's): `barInk`, read from
//   the stretch of picture behind the bar;
// - with Soft Cards off, a page's lists (Bots, Sessions, Jobs…; More, Settings and their pages): `pageInk`, read from
//   the whole picture. They are drawn in the mode whose colours read there, so every colour in them follows (names,
//   times, the tint, a grouped page's own cards), not only the label. A skin with one look has no other mode: there
//   the app lays on the least Dim its words need (`dimNeeded`).
// The mode's own ink is kept wherever it measures 4.5:1 (WCAG), so a picture of the mode's own tone looks as it did.
// Liquid Glass (the bar's buttons, the tab bar, the pills) picks its own ink from what is under it; cards carry their
// own page colour. Chats are not touched: their messages stand in bubbles.

import UIKit

/// The arithmetic, apart from the views (Tests/Theme/BackdropInkMathTests.swift). Luminances are linear, 0…1.
nonisolated enum BackdropInkMath {
    /// What words must measure against what they stand on (WCAG, as `SoftCard.contrast`).
    static let contrast = 4.5

    static func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    /// What the words stand on: the picture under Dim's veil of the page colour, mixed as the screen mixes them (in sRGB).
    static func ground(picture: Double, dim: Double, page: Double) -> Double {
        let dim = min(max(dim, 0), 1)
        return SoftCard.decoded(dim * SoftCard.encoded(page) + (1 - dim) * SoftCard.encoded(picture))
    }

    /// An ink of luminance `ink` at `alpha`, as it lands on `ground`.
    static func landed(ink: Double, alpha: Double, on ground: Double) -> Double {
        let alpha = min(max(alpha, 0), 1)
        return SoftCard.decoded(alpha * SoftCard.encoded(ink) + (1 - alpha) * SoftCard.encoded(ground))
    }

    enum Pick: Equatable, Sendable { case own, other, white, black }

    /// Which ink the words take on `ground`: the mode's own while it reads; otherwise the other mode's if that reads;
    /// otherwise whichever of the four measures most (a mid-tone picture, where nothing reaches 4.5:1).
    /// `own`, `other`: the two modes' labels as they land on the ground.
    static func pick(ground: Double, own: Double, other: Double) -> Pick {
        if ratio(own, ground) >= contrast { return .own }
        if ratio(other, ground) >= contrast { return .other }
        let choices: [(Pick, Double)] = [(.own, ratio(own, ground)), (.other, ratio(other, ground)),
                                         (.white, ratio(1, ground)), (.black, ratio(0, ground))]
        // The first of the best: the mode's own wins a tie.
        return choices.max { $0.1 < $1.1 - 0.001 }?.0 ?? .own
    }

    /// The most Dim the app lays on by itself (`leastDim`).
    static let dimCeiling = 0.9

    /// The least Dim (from `dim` up, in steps of 5 %) at which an ink of luminance `ink` at `alpha` reads on a picture
    /// of tone `picture` under the page colour; `dimCeiling` if none does. "Reads" is `contrast`, or as well as the
    /// ink reads on the plain page where that is less (a skin's faint second label): Dim can do no better than the page.
    static func leastDim(from dim: Double, picture: Double, page: Double, ink: Double, alpha: Double) -> Double {
        func measured(_ dim: Double) -> Double {
            let under = ground(picture: picture, dim: dim, page: page)
            return ratio(landed(ink: ink, alpha: alpha, on: under), under)
        }
        let wanted = min(contrast, measured(1) * 0.9)
        let first = Int((min(max(dim, 0), dimCeiling) * 100).rounded()), last = Int((dimCeiling * 100).rounded())
        for percent in stride(from: first, to: last, by: 5) where measured(Double(percent) / 100) >= wanted { return Double(percent) / 100 }
        return max(dimCeiling, Double(first) / 100)
    }

    /// The part of a picture a view of `view` size shows (it fills the view from its centre), then the stretch of
    /// that from the view's top down to `band` (nil: all of it), in the picture's own unit square.
    static func region(image: CGSize, view: CGSize, band: CGFloat?) -> CGRect {
        guard image.width > 0, image.height > 0, view.width > 0, view.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let scale = max(view.width / image.width, view.height / image.height)
        let shown = CGSize(width: min(1, view.width / scale / image.width), height: min(1, view.height / scale / image.height))
        var rect = CGRect(x: (1 - shown.width) / 2, y: (1 - shown.height) / 2, width: shown.width, height: shown.height)
        if let band { rect.size.height *= min(max(band / view.height, 0.02), 1) }
        return rect
    }
}

nonisolated(unsafe) private var tonesKey: UInt8 = 0

/// A picture's tones, small: its luminance on a coarse grid (which evens out fine detail, as the eye does around
/// words), read once per picture and kept with it.
nonisolated final class BackdropTones: NSObject, Sendable {
    static let columns = 16, rows = 32
    /// Linear luminance, row by row from the top.
    let cells: [Double]

    init(cells: [Double]) { self.cells = cells }

    /// The tones of `image`, measured the first time it is asked.
    @MainActor static func of(_ image: UIImage) -> BackdropTones? {
        if let known = objc_getAssociatedObject(image, &tonesKey) as? BackdropTones { return known }
        guard let pixels = image.cgImage, let tones = measure(pixels) else { return nil }
        objc_setAssociatedObject(image, &tonesKey, tones, .OBJC_ASSOCIATION_RETAIN)
        return tones
    }

    static func measure(_ image: CGImage) -> BackdropTones? {
        let width = columns, height = rows
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var cells: [Double] = []
        cells.reserveCapacity(width * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = SoftCard.decoded(Double(pixels[index]) / 255), g = SoftCard.decoded(Double(pixels[index + 1]) / 255)
            let b = SoftCard.decoded(Double(pixels[index + 2]) / 255)
            cells.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        return BackdropTones(cells: cells)
    }

    /// The tone of `region` (the picture's unit square, its top at 0) as words on it meet it: the mean of its cells,
    /// mixed as the screen shows them (in sRGB).
    func tone(in region: CGRect) -> Double {
        let columns = Self.columns, rows = Self.rows
        let x0 = min(max(Int((region.minX * CGFloat(columns)).rounded(.down)), 0), columns - 1)
        let x1 = min(max(Int((region.maxX * CGFloat(columns)).rounded(.up)), x0 + 1), columns)
        let y0 = min(max(Int((region.minY * CGFloat(rows)).rounded(.down)), 0), rows - 1)
        let y1 = min(max(Int((region.maxY * CGFloat(rows)).rounded(.up)), y0 + 1), rows)
        var sum = 0.0
        for y in y0..<y1 { for x in x0..<x1 { sum += SoftCard.encoded(cells[y * columns + x]) } }
        return SoftCard.decoded(sum / Double((y1 - y0) * (x1 - x0)))
    }
}

/// The ink for words standing straight on the picture in one place: resolved colours, and the mode they come from.
struct BackdropInk: Equatable {
    /// A title, a name.
    var label: UIColor
    /// A line under a title, a note.
    var label2: UIColor
    /// The mode whose colours read here when it isn't the page's own (`.unspecified`: the page's own does).
    var style: UIUserInterfaceStyle

    /// Nothing changes: the mode's own label and second label both read.
    var isOwn: Bool { style == .unspecified && !replacesLabel2 }
    fileprivate var replacesLabel2 = false

    /// The ink on a picture of tone `picture` (linear) under `dim` (0…1), for a page drawn with `traits`.
    @MainActor static func make(picture: Double, dim: Double, traits: UITraitCollection) -> BackdropInk {
        let dark = traits.userInterfaceStyle == .dark
        let flipped = traits.modifyingTraits { $0.userInterfaceStyle = dark ? .light : .dark }
        let ground = BackdropInkMath.ground(picture: picture, dim: dim, page: SoftCard.luminance(HQPalette.page.resolvedColor(with: traits)))
        func landed(_ color: UIColor) -> Double {
            var alpha: CGFloat = 1
            color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            return BackdropInkMath.landed(ink: SoftCard.luminance(color.withAlphaComponent(1)), alpha: Double(alpha), on: ground)
        }
        func reads(_ color: UIColor) -> Bool { BackdropInkMath.ratio(landed(color), ground) >= BackdropInkMath.contrast }
        let own = HQPalette.label.resolvedColor(with: traits), other = HQPalette.label.resolvedColor(with: flipped)
        let label: UIColor, style: UIUserInterfaceStyle
        switch BackdropInkMath.pick(ground: ground, own: landed(own), other: landed(other)) {
        case .own: (label, style) = (own, .unspecified)
        case .other: (label, style) = (other, dark ? .light : .dark)
        // Plain white or black: the mode whose label is that kind, unless it is the page's own.
        case .white: (label, style) = (.white, dark ? .unspecified : .dark)
        case .black: (label, style) = (.black, dark ? .light : .unspecified)
        }
        let second = HQPalette.label2.resolvedColor(with: style == .unspecified ? traits : flipped)
        let secondReads = reads(second)
        var ink = BackdropInk(label: label, label2: secondReads ? second : label, style: style)
        ink.replacesLabel2 = !secondReads
        return ink
    }

    /// A skin with one look draws the same colours in Light and in Dark, so its rows cannot be drawn in the other mode
    /// when the picture is the wrong tone for them. There, with Soft Cards off (rows, titles and notes stand straight
    /// on the picture), the app lays on the least Dim at which the skin's second label reads: this is that Dim (0…1),
    /// never under the person's own `dim`. Every other skin, and Soft Cards: `dim` itself.
    @MainActor static func dimNeeded(picture: Double, dim: Double, cards: Bool, traits: UITraitCollection) -> Double {
        guard !cards, ThemeTable.set(generation: traits[ThemeGenerationTrait.self]).forcedDark != nil else { return dim }
        let ink = HQPalette.label2.resolvedColor(with: traits)
        var alpha: CGFloat = 1
        ink.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return BackdropInkMath.leastDim(from: dim, picture: picture, page: SoftCard.luminance(HQPalette.page.resolvedColor(with: traits)),
                                        ink: SoftCard.luminance(ink.withAlphaComponent(1)), alpha: Double(alpha))
    }
}

// MARK: - The bar

nonisolated(unsafe) private var barInkKey: UInt8 = 0
nonisolated(unsafe) private var barPaintedKey: UInt8 = 0

@MainActor enum BackdropBarInk {
    /// Posted on main when an item's ink changed (`object`: the navigation item). A title's own views that draw in the
    /// bar (the gateway line, `GatewayTitleSwitcher`) redraw.
    static let didChange = Notification.Name("hqn.backdropInk.barDidChange")

    private final class Box: NSObject {
        let ink: BackdropInk
        init(_ ink: BackdropInk) { self.ink = ink }
    }

    /// The ink of `item`'s title and the line under it just now; nil where the mode's own reads (or no picture shows).
    static func ink(of item: UINavigationItem) -> BackdropInk? { (objc_getAssociatedObject(item, &barInkKey) as? Box)?.ink }

    /// A page's picture says what its bar's words take (`ink` nil: no picture, or the mode's own reads).
    static func set(_ ink: BackdropInk?, on controller: UIViewController) {
        let item = navigationItem(of: controller)
        let ink = ink.flatMap { $0.isOwn ? nil : $0 }
        guard Self.ink(of: item) != ink else { return }
        objc_setAssociatedObject(item, &barInkKey, ink.map(Box.init), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if ListBarAppearance.owns(item) {
            ListBarAppearance.apply(to: item)   // a tab's bar: its own appearances, with the ink
        } else {
            paintPlain(item, bar: controller.navigationController?.navigationBar)
        }
        NotificationCenter.default.post(name: didChange, object: item)
    }

    /// The item the bar shows for `controller`: its own, or that of the page holding it in the stack (a SwiftUI page
    /// in a host).
    private static func navigationItem(of controller: UIViewController) -> UINavigationItem {
        var page = controller
        while let parent = page.parent, !(parent is UINavigationController), !(parent is UITabBarController), !(parent is UISplitViewController) {
            page = parent
        }
        return page.navigationItem
    }

    /// The ink on an appearance's title, large title and the lines under them.
    static func paint(_ appearance: UINavigationBarAppearance, for item: UINavigationItem) {
        guard let ink = ink(of: item) else { return }
        appearance.titleTextAttributes[.foregroundColor] = ink.label
        appearance.largeTitleTextAttributes[.foregroundColor] = ink.label
        appearance.subtitleTextAttributes[.foregroundColor] = ink.label2
        appearance.largeSubtitleTextAttributes[.foregroundColor] = ink.label2
    }

    /// A page whose bar nobody else styles (a pushed page, a Settings page): the bar's own appearances, with the ink,
    /// on the page's item; taken off again when the ink goes.
    private static func paintPlain(_ item: UINavigationItem, bar: UINavigationBar?) {
        guard ink(of: item) != nil else {
            guard objc_getAssociatedObject(item, &barPaintedKey) != nil else { return }
            objc_setAssociatedObject(item, &barPaintedKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            item.standardAppearance = nil
            item.scrollEdgeAppearance = nil
            item.compactAppearance = nil
            item.compactScrollEdgeAppearance = nil
            return
        }
        // Only where the page has none of its own (or ours from last time).
        let ours = objc_getAssociatedObject(item, &barPaintedKey) != nil
        guard ours || (item.standardAppearance == nil && item.scrollEdgeAppearance == nil) else { return }
        let standard = bar?.standardAppearance.copy() ?? UINavigationBarAppearance()
        paint(standard, for: item)
        // With no scroll-edge appearance a bar draws its standard one with a clear background: the same here.
        let edge: UINavigationBarAppearance
        if let own = bar?.scrollEdgeAppearance {
            edge = own.copy()
        } else {
            edge = standard.copy()
            edge.configureWithTransparentBackground()
        }
        paint(edge, for: item)
        item.standardAppearance = standard
        item.scrollEdgeAppearance = edge
        item.compactAppearance = standard
        item.compactScrollEdgeAppearance = edge
        objc_setAssociatedObject(item, &barPaintedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
