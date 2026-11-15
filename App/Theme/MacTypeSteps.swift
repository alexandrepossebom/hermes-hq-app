// [type-steps] Owner 2026-11-14: "I think that the font size and weights that we use in some places, even on the,
// like, the sidebar are wrong and are part of what makes me feel like the app is not polished enough."
// A trial, not the shipping look: the Mac draws the iPad layout at 77 %, so the iPad text styles × the look's Mac base
// (`ThemeState.macBase`) land on in-between sizes on the screen (11.6, 12.7, 13.9, 14.2, 16.2, 17.7, 19.6, 24.6 pt).
// With `-HQTypeSteps snapped` (a Debug build's launch arguments, read once a launch, never saved) every size HQFont
// makes lands on a whole screen point instead: each text style on its step in `steps` below, and literal sizes on the
// nearest whole point. Off (the default, and always in Release) every font is exactly as before.

import UIKit

nonisolated enum MacTypeSteps {
    /// Catalyst's iPad idiom draws the window at 77 %.
    static let catalyst: CGFloat = 0.77

    /// The trial is on: Debug, Mac, `-HQTypeSteps snapped`.
    static let on: Bool = {
        #if DEBUG && targetEnvironment(macCatalyst)
        // The launch's own arguments, not the defaults: nothing a run of the app saves can turn it on.
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "-HQTypeSteps"), at + 1 < arguments.count else { return false }
        return arguments[at + 1] == "snapped"
        #else
        return false
        #endif
    }()

    /// Each text style's size on the screen at UI Scale 100 %, today → snapped (the proposal; type/PROPOSALS.md).
    /// Normal (Desktop Look off) | Desktop Look:
    ///   largeTitle 30.0 → 30 | 21.9 → 22      title1 24.6 → 24 | 20.0 → 20      title2 19.6 → 20 | 18.1 → 18
    ///   title3     17.7 → 17 | 16.2 → 16      headline 15.0 → 15 | 15.0 → 15   body   15.0 → 15 | 15.0 → 15
    ///   callout    14.2 → 14 | 13.9 → 14      subheadline 13.5 → 13 | 13.5 → 13
    ///   footnote   11.6 → 12 | 12.7 → 12      caption1 (footnote) 11.6 → 12 | 11.9 → 12
    ///   caption2 (footnote) 11.6 → 12 | 11.2 → 11
    /// Every role keeps its own step except the Desktop Look's footnote and caption1, 0.8 pt apart today.
    static func step(_ style: UIFont.TextStyle, desktopLook: Bool) -> CGFloat? {
        switch style {
        case .largeTitle, .extraLargeTitle, .extraLargeTitle2: desktopLook ? 22 : 30
        case .title1: desktopLook ? 20 : 24
        case .title2: desktopLook ? 18 : 20
        case .title3: desktopLook ? 16 : 17
        case .headline, .body: 15
        case .callout: 14
        case .subheadline: 13
        case .footnote, .caption1: 12
        case .caption2: desktopLook ? 11 : 12
        default: nil
        }
    }

    /// A literal or derived size (the app's points, before the 77 %) on the nearest whole point on the screen.
    static func whole(_ size: CGFloat) -> CGFloat {
        guard on, size > 0 else { return size }
        return max(1, (size * catalyst).rounded()) / catalyst
    }

    /// A text style's size as made today (`size`, the app's points) on its step, × UI Scale (and the Mac's 13 pt
    /// body, `ThemeState.macBody`), then on a whole point.
    static func style(_ style: UIFont.TextStyle, size: CGFloat, state: ThemeState) -> CGFloat {
        guard on else { return size }
        guard let step = step(style, desktopLook: state.desktopLook) else { return whole(size) }
        let shipping = state.desktopLook ? 1.3 : 1.15
        let factor = CGFloat(state.scale / shipping)
        return max(1, (step * factor).rounded()) / catalyst
    }

    /// A font made elsewhere in HQFont, on a whole point.
    static func font(_ font: UIFont) -> UIFont {
        guard on else { return font }
        let size = whole(font.pointSize)
        return size == font.pointSize ? font : font.withSize(size)
    }
}
