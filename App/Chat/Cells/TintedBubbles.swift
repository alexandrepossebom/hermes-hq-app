// [tinted-bubbles] Theme › Chats › Chat Bubbles › Style › Tinted (owner 2026-11-01, after a Telegram screenshot: "Can we
// have an option to do the same with our chat bubbles?"). Telegram's way (Telegram-iOS, WallpaperBackgroundNode): every
// bubble shows its own slice of one soft copy of the wallpaper (tiny, blurred, more saturated, none of its detail) lined
// up with the screen. A bubble near the top takes the top's colours, one near the bottom the bottom's, and the colour
// moves as the chat scrolls. One small picture per kind of bubble serves them all: nothing is blurred live.
//
// - Only over a Chat Background: with none (or until its picture is made), under Reduce Transparency and in the Desktop
//   Look, bubbles are solid.
// - Each bubble keeps its own lightness and takes the picture's colour (owner 2026-11-02, Light chat over a night
//   photo: "I'm not sure this is right"). The first way laid the bubble's colour over the copy at part strength: a
//   light colour over a dark picture is white paint in dark paint, a lavender-grey slab. Now every pixel of the copy, as
//   the page shows it under its Dim, is moved to the solid bubble's lightness (with part of its light and shade)
//   and its colour (OKLab a and b) is added to the bubble's: a night sky gives a Light reply lilac, a sunset peach,
//   mountains a cool grey, and a Dark reply over a bright picture stays dark and takes the hues. Replies take 1.3 times
//   the colour, yours half that (the theme's colour leads), Increase Contrast 40 % with no shade. Where a pixel would not
//   keep the words at 4.5:1 (7:1 under Increase Contrast) and the time at 3:1 (or the solid bubble's own, where less)
//   and three quarters of the solid bubble's contrast, less of the picture is taken there, down to the solid colour.
// - Enough of the picture to see it pass (owner 2026-11-02: "Telegram chat bubbles change as you scroll. It's like they
//   have a heavy blur of something so that they adapt to the background. Yours are not doing that."): 0.6 of its light
//   and shade where 0.15 was (a Light reply's lightness moved 0.016 from the top of a night photo to the bottom, a Dark
//   one's 0.020: now 0.06 and 0.11), and half the blur, so a horizon or a hill stays a soft shape.
// - A dark bubble is a soft card (owner 2026-11-15, a Dark Nous chat over a dusk photo: "very messed up in dark mode").
//   The copy is saturated 1.7 times and replies take 1.3 times that: a light bubble has no room for it and stays
//   pastel, but a dark one took all of it, a loud blue-violet slab. Build 1030 stopped its colour at the picture's own:
//   then the bubble had the picture's colour and lightness and no shape at all (owner, beside Sessions on Soft Cards:
//   "Shouldn't it be more like this? At least in dark mode"). Now a dark bubble is frosted glass over the picture:
//   the theme's page colour lifted three quarters of the way to the solid bubble's for a reply (your own bubble's
//   colour for yours) with `cardShow` of the picture, soft and as the page shows it, coming through, and Soft Cards'
//   hairline round it. It lightens and takes colour where the picture does, less where the words need it. Light
//   bubbles are as they were.
// - The tail stays: a mask takes any outline (glass takes rounded corners only).
// - On the Mac too: these are plain layers, which Catalyst draws as the iPhone does (it drew glass without its tint).

import CoreImage
import UIKit

@MainActor enum TintedBubbles {
    /// How much of the picture's colour a bubble takes: replies a third more than the copy holds, yours half that (the
    /// theme's colour leads), less under Increase Contrast.
    nonisolated static let replyColour = 1.3
    nonisolated static let ownColour = 0.65
    nonisolated static let contrastColour = 0.4
    /// How much of the picture's light and shade shows (OKLab lightness, either side of the bubble's): none under
    /// Increase Contrast. A light bubble takes half of it on its lighter side: near white there is no room for colour.
    /// (0.15 until the owner, 2026-11-02: "Telegram chat bubbles change as you scroll … Yours are not doing that.")
    nonisolated static let shade = 0.6
    /// The copy's long side in pixels: blurred this hard, a bigger one would only cost memory.
    nonisolated static let longSide = 48
    /// The blur, in parts of the long side: a sixteenth leaves a sky, a horizon and a hill as soft shapes that drift
    /// through a bubble as it scrolls (an eighth left one smooth wash).
    nonisolated static let blurPart = 16.0
    /// How much the copy's colour is raised (Telegram's 1.7): a wash this soft would be grey without it.
    nonisolated static let saturation = 1.7
    /// [tinted-dark] How much of the picture comes through a dark bubble's card, and under Increase Contrast. 0.24 in
    /// build 1033 and 0.14 in 1035, each a card with almost none of the picture's colour (owner: "They don't feel
    /// tinted in the right way to me"). He picked this from four ways drawn for him ("2 is the winner"): most of the
    /// picture through the card, as frosted glass, so a reply lightens and takes colour where the picture does.
    nonisolated static let cardShow = 0.6
    /// Yours takes half as much, as a light bubble of yours takes half the colour (`ownColour`): the theme's colour
    /// leads, and your message stays the colour that says it is yours over any part of the picture.
    nonisolated static let ownCardShow = 0.3
    nonisolated static let contrastCardShow = 0.1
    /// [tinted-dark] How far a reply's card is lifted from the page's colour toward the solid reply bubble's. Build
    /// 1035 took less of the picture and so fell to the page's own near-black (owner: "These got darker…"): the
    /// picture had been what lit the card. The four ways he chose from were drawn at three quarters.
    nonisolated static let cardLift = 0.75

    /// [tinted-dark] A reply's card: the page's colour lifted `lift` of the way to the solid reply bubble's.
    nonisolated static func replyCard(bubble: RGBA, page: RGBA, lift: Double = cardLift) -> RGBA {
        let ground = page.over(.white)
        return ground.mixOklab((1 - lift) * 100, bubble.over(ground))
    }
    /// [tinted-dark] A bubble this dark or darker (OKLab lightness of its solid colour) is drawn as a card.
    nonisolated static let darkBelow = 0.6

    /// Picked, the look is the iOS one, Reduce Transparency is off, and chats show a background.
    static var applies: Bool {
        // [bubble-card] Card draws your own messages (and a reply in a bot's own colour) as Tinted does.
        (ThemeTable.bubbleStyle == .tinted || ThemeTable.bubbleStyle == .card) && !HQAccessibility.reduceTransparency && Backdrop.chats.shows
    }

    /// The soft copy of a picture, and its pixels for the contrast check.
    struct Soft {
        let image: CGImage
        /// Every pixel, row by row from the top.
        let pixels: [RGBA]
        /// [tinted-dark] The same pixels before the copy's colour is raised: the picture's own colour, as the page
        /// shows it, which a bubble never goes past.
        let plain: [RGBA]
        let width: Int, height: Int
        /// The picture's own shape: the chat fills itself with it from its centre (`BackdropView`).
        let aspect: CGSize
    }

    private static var softs: [(picture: BackdropPicture, soft: Soft)] = []

    /// The copy of the chats' picture as drawn for `traits`, or nil until the picture is made (`Backdrop.pictureReady`
    /// follows).
    static func soft(for traits: UITraitCollection) -> Soft? {
        guard let picture = Backdrop.chats.picture(for: traits) else { return nil }
        if let hit = softs.first(where: { $0.picture == picture }) { return hit.soft }
        var part = blurPart
        #if DEBUG
        // `-HQDebugTintBlur <part>`: another blur side by side without a build (8 was the first).
        if UserDefaults.standard.double(forKey: "HQDebugTintBlur") > 0 { part = UserDefaults.standard.double(forKey: "HQDebugTintBlur") }
        #endif
        guard let image = BackdropImages.shared.image(picture)?.cgImage, let soft = makeSoft(image, blurPart: part) else { return nil }
        // Light and Dark each have their copy; anything older is let go.
        softs = Array((softs + [(picture, soft)]).suffix(2))
        return soft
    }

    /// Shrunk to `longSide`, blurred by `blurPart` of it and saturated `saturation` times (Telegram's 64 px, blurred
    /// twice, 1.7).
    nonisolated static func makeSoft(_ image: CGImage, blurPart: Double = blurPart) -> Soft? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = Double(longSide) / Double(max(width, height))
        let w = max(1, Int((Double(width) * scale).rounded())), h = max(1, Int((Double(height) * scale).rounded()))
        func context() -> CGContext? {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let small = context() else { return nil }
        small.interpolationQuality = .high
        small.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let shrunk = small.makeImage() else { return nil }
        let input = CIImage(cgImage: shrunk)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(longSide) / blurPart)
        let soft = blurred.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation]).cropped(to: input.extent)
        let ci = CIContext(options: [.cacheIntermediates: false, .outputColorSpace: space])
        func read(_ made: CGImage) -> [RGBA]? {
            guard let read = context() else { return nil }
            read.draw(made, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = read.data else { return nil }
            let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
            var pixels: [RGBA] = []
            pixels.reserveCapacity(w * h)
            for i in 0..<(w * h) {
                let a = max(Double(bytes[i * 4 + 3]) / 255, 1.0 / 255)
                pixels.append(RGBA(unit: min(1, Double(bytes[i * 4]) / 255 / a), min(1, Double(bytes[i * 4 + 1]) / 255 / a),
                                   min(1, Double(bytes[i * 4 + 2]) / 255 / a)))
            }
            return pixels
        }
        guard let made = ci.createCGImage(soft, from: input.extent), let pixels = read(made),
              let unraised = ci.createCGImage(blurred.cropped(to: input.extent), from: input.extent), let plain = read(unraised)
        else { return nil }
        return Soft(image: made, pixels: pixels, plain: plain, width: w, height: h, aspect: CGSize(width: width, height: height))
    }

    // MARK: The bubble's own copy

    private struct PaintKey: Hashable {
        let picture: BackdropPicture?, bubble: RGBA, ground: RGBA?, page: RGBA, text: RGBA, time: RGBA, dim: Int, colour: Double,
            shade: Double, target: Double, show: Double
    }
    private static var painted: [PaintKey: CGImage] = [:]

    /// The copy as a bubble of `bubble`'s colour shows it: `paint` over the chat's picture as drawn for `traits`.
    static func image(_ soft: Soft, picture: BackdropPicture?, bubble: UIColor, mine: Bool, increaseContrast: Bool,
                      traits: UITraitCollection) -> CGImage? {
        func rgba(_ colour: UIColor) -> RGBA {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            colour.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return RGBA(unit: Double(r), Double(g), Double(b), Double(a))
        }
        var colour = increaseContrast ? contrastColour : mine ? ownColour : replyColour
        var shade = increaseContrast ? 0 : Self.shade
        #if DEBUG
        // `-HQDebugTintColour <times>` scales every colour strength, `-HQDebugTintShade <x>` sets the shade: other
        // strengths side by side without a build.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "HQDebugTintColour") != nil { colour *= defaults.double(forKey: "HQDebugTintColour") }
        if !increaseContrast, defaults.object(forKey: "HQDebugTintShade") != nil { shade = defaults.double(forKey: "HQDebugTintShade") }
        #endif
        // [tinted-dark] A reply's card is the page's colour lifted toward its solid bubble (`replyCard`); yours (and a
        // reply in a bot's own colour) keeps its own.
        let fill = rgba(bubble), page = rgba(HQPalette.page)
        var show = increaseContrast ? contrastCardShow : mine ? ownCardShow : cardShow
        var lift = cardLift
        #if DEBUG
        // `-HQDebugTintCard <part>`: another share of the picture through a dark bubble without a build;
        // `-HQDebugTintLift <part>`: another lift of a reply's card.
        if defaults.object(forKey: "HQDebugTintCard") != nil { show = defaults.double(forKey: "HQDebugTintCard") }
        if defaults.object(forKey: "HQDebugTintLift") != nil { lift = defaults.double(forKey: "HQDebugTintLift") }
        #endif
        let key = PaintKey(picture: picture, bubble: fill,
                           ground: fill == rgba(ChatPalette.botBubble) ? replyCard(bubble: fill, page: page, lift: lift) : nil, page: page,
                           text: rgba(mine ? ChatPalette.meText : ChatPalette.label),
                           time: rgba(mine ? ChatPalette.meTime : ChatPalette.label2), dim: Backdrop.chats.dim,
                           colour: colour, shade: shade, target: increaseContrast ? 7 : 4.5, show: show)
        if let hit = painted[key] { return hit }
        let colours = paint(pixels: soft.pixels, plain: soft.plain, bubble: key.bubble, ground: key.ground, page: key.page,
                            dim: Double(key.dim) / 100, text: key.text, time: key.time, colour: key.colour, shade: key.shade,
                            target: key.target, show: key.show)
        guard let made = makeImage(colours, width: soft.width, height: soft.height) else { return nil }
        if painted.count > 16 { painted.removeAll() }
        painted[key] = made
        return made
    }

    /// How much of the solid bubble's contrast a tinted one keeps at least.
    nonisolated static let keep = 0.75

    /// Each pixel of the copy as the page shows it (the page colour at `dim` over it), moved to the solid bubble's
    /// lightness give or take `shade` of its own (half on the lighter side of a light bubble), with `colour` of its
    /// OKLab colour added to the bubble's. Where that would leave `text` under `target` or `time` under 3:1 (or under the
    /// solid bubble's own, where less, or under `keep` of it), less of the picture is taken there, down to the solid
    /// bubble itself.
    ///
    /// [tinted-dark] A dark bubble (`isDark`) is a card instead: `ground` (the solid bubble with none) with `show` of
    /// the picture through it, the picture being `plain` (the copy before its colour was raised; `pixels` with none)
    /// under the same veil. Less of the picture where the words need it, as above.
    nonisolated static func paint(pixels: [RGBA], plain: [RGBA]? = nil, bubble: RGBA, ground: RGBA? = nil, page: RGBA,
                                  dim: Double, text: RGBA, time: RGBA, colour: Double, shade: Double, target: Double,
                                  show: Double = cardShow) -> [RGBA] {
        let solid = bubble.over(page.over(.white))
        func want(_ ink: RGBA, _ goal: Double) -> Double {
            let own = ink.over(solid).contrast(with: solid)
            return max(min(goal, own), own * keep) - 0.01
        }
        let wantText = want(text, target), wantTime = want(time, 3)
        func reads(_ shown: RGBA) -> Bool {
            text.over(shown).contrast(with: shown) >= wantText && time.over(shown).contrast(with: shown) >= wantTime
        }
        let veil = page.alpha(dim * page.a)
        // As much as still reads, found by halving: next to each other, pixels take next to the same part (steps of
        // a quarter showed a hill's outline as a dark blotch where it crossed the limit).
        func most(_ shown: (Double) -> RGBA, else none: RGBA) -> RGBA {
            let all = shown(1)
            if reads(all) { return all }
            var low = 0.0, high = 1.0
            for _ in 0..<10 {
                let middle = (low + high) / 2
                if reads(shown(middle)) { low = middle } else { high = middle }
            }
            return low > 0 ? shown(low) : none
        }
        if isDark(solid) {
            let card = (ground ?? bubble).over(page.over(.white))
            let picture = plain.flatMap { $0.count == pixels.count ? $0 : nil } ?? pixels
            return picture.map { pixel in
                let under = veil.over(pixel)
                return most({ part in card.alpha(1 - show * part).over(under) }, else: card)
            }
        }
        let seen = pixels.map { veil.over($0).oklab }
        let middle = seen.isEmpty ? 0 : seen.reduce(0) { $0 + $1.0 } / Double(seen.count)
        let (lightness, a0, b0) = solid.oklab
        let lighter = lightness > 0.6 ? shade / 2 : shade
        return seen.map { lab in
            let step = (lab.0 - middle) * (lab.0 > middle ? lighter : shade)
            return most({ part in inGamut(lightness + part * step, a0, b0, colour * part * lab.1, colour * part * lab.2) }, else: solid)
        }
    }

    /// [tinted-dark] Whether a bubble of this solid colour is drawn as a card.
    nonisolated static func isDark(_ solid: RGBA) -> Bool { solid.oklab.0 <= darkBelow }

    /// [tinted-dark] The same for a bubble's fill as `traits` resolve it (the hairline round a card: `BubbleShapeView`).
    static func isDark(_ fill: UIColor, traits: UITraitCollection) -> Bool {
        func rgba(_ colour: UIColor) -> RGBA {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            colour.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return RGBA(unit: Double(r), Double(g), Double(b), Double(a))
        }
        return isDark(rgba(fill).over(rgba(HQPalette.page).over(.white)))
    }

    /// `l` with the bubble's colour (`a0`, `b0`) and as much of `da`, `db` on top as sRGB can show.
    nonisolated static func inGamut(_ l: Double, _ a0: Double, _ b0: Double, _ da: Double, _ db: Double) -> RGBA {
        let l = min(max(l, 0), 1)
        func linear(_ part: Double) -> (Double, Double, Double) {
            let a = a0 + part * da, b = b0 + part * db
            let x = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
            let y = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
            let z = pow(l - 0.0894841775 * a - 1.291485548 * b, 3)
            return (4.0767416621 * x - 3.3077115913 * y + 0.2309699292 * z,
                    -1.2684380046 * x + 2.6097574011 * y - 0.3413193965 * z,
                    -0.0041960863 * x - 0.7034186147 * y + 1.707614701 * z)
        }
        func fits(_ part: Double) -> Bool {
            let (r, g, b) = linear(part)
            return [r, g, b].allSatisfy { $0 >= -0.0005 && $0 <= 1.0005 }
        }
        var part = 1.0
        if !fits(1) {
            var low = 0.0, high = 1.0
            for _ in 0..<12 { let mid = (low + high) / 2; if fits(mid) { low = mid } else { high = mid } }
            part = low
        }
        return RGBA.fromOklab(l, a0 + part * da, b0 + part * db, 1)
    }

    /// `colours` (row by row from the top) as an opaque sRGB picture.
    nonisolated static func makeImage(_ colours: [RGBA], width: Int, height: Int) -> CGImage? {
        guard colours.count == width * height, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for (i, c) in colours.enumerated() {
            bytes[i * 4] = UInt8((min(max(c.r, 0), 1) * 255).rounded())
            bytes[i * 4 + 1] = UInt8((min(max(c.g, 0), 1) * 255).rounded())
            bytes[i * 4 + 2] = UInt8((min(max(c.b, 0), 1) * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Lining up

    /// Bubbles drawing the tint now: every scroll step lines their copy up with the chat's background again.
    private static let live = NSHashTable<BubbleShapeView>.weakObjects()

    static func track(_ bubble: BubbleShapeView, _ on: Bool) {
        if on { live.add(bubble) } else { live.remove(bubble) }
    }

    /// The chat table laid out (a scroll step, a row moved): every tinted bubble on the screen lines its copy up again.
    static func realign() {
        guard live.count > 0 else { return }
        for bubble in live.allObjects where bubble.window != nil { bubble.alignTint() }
    }

    /// The chat's background behind `view`: `ChatViewController` puts it first under its view.
    static func anchor(for view: UIView) -> BackdropView? {
        var ancestor = view.superview
        while let current = ancestor {
            for child in current.subviews.prefix(3) {
                if let backdrop = child as? BackdropView, backdrop.place == .chats { return backdrop }
            }
            ancestor = current.superview
        }
        return nil
    }

    /// Where the picture lies in `bounds`: filling it from its centre (`UIView.ContentMode.scaleAspectFill`).
    nonisolated static func fillRect(_ aspect: CGSize, in bounds: CGRect) -> CGRect {
        guard aspect.width > 0, aspect.height > 0 else { return bounds }
        let scale = max(bounds.width / aspect.width, bounds.height / aspect.height)
        let size = CGSize(width: aspect.width * scale, height: aspect.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// [tinted-bubbles] A bubble's tint: its own copy of the picture (laid over the chat's background, so the bubble shows
/// its own slice, tail included), clipped to the outline. Nothing in it animates: it follows the bubble as drawn.
nonisolated final class TintedBubbleLayer: CALayer {
    let copy = CALayer()
    let outline = CAShapeLayer()

    override init() {
        super.init()
        copy.contentsGravity = .resize
        copy.magnificationFilter = .linear
        addSublayer(copy)
        mask = outline
        for layer in [self, copy, outline] { layer.delegate = NoMotion.shared }
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSublayers() {
        super.layoutSublayers()
        outline.frame = bounds
    }

    /// Every implicit animation off: the bubble's own view animates nothing of this either.
    private final class NoMotion: NSObject, CALayerDelegate, Sendable {
        static let shared = NoMotion()
        func action(for layer: CALayer, forKey event: String) -> (any CAAction)? { NSNull() }
    }
}
