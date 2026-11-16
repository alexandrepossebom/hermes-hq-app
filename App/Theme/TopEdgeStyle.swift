// [top-edge] Theme › Themes › Top Edge (owner 2026-11-03, a screenshot of Claude's app): where rows scroll under the
// top bar, the system's soft edge (the blur fades out going down, the bar has no bottom) or its hard edge (a frosted
// band the height of the bar, cut off on a straight line: "straight across in a rectangle"), the default since
// 2026-11-04. Every tab's still edge host (`ListBarAppearance.pinTitle(softEdgeAround:)`) draws it. Chats are always
// soft at both ends (owner 2026-11-05, [chat-soft-edge] in `ChatViewController`). The Mac draws no top edge (its bars have a backing
// instead), so it has no choice.

import UIKit

enum TopEdgeStyle {
    static var offered: Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        true
        #endif
    }

    /// [desktop-hard-edge] Owner 2026-11-15: in the Desktop Look every page's top is the hard edge, as its chats' and the
    /// Mac's; the Top Edge choice applies to the iOS look.
    static var current: UIScrollEdgeEffect.Style {
        guard offered else { return .soft }
        if Theme.isDesktop { return .hard }
        return Theme.shared.state.topEdge == .hard ? .hard : .soft
    }

    /// Sets `scroll`'s top edge to the chosen style now and again whenever the theme changes.
    static func follow(_ scroll: UIScrollView) {
        scroll.topEdgeEffect.style = current
        scroll.registerForTraitChanges([ThemeGenerationTrait.self]) { (scroll: UIScrollView, _) in
            let style = TopEdgeStyle.current
            if scroll.topEdgeEffect.style != style { scroll.topEdgeEffect.style = style }
        }
    }
}

/// [desktop-hard-edge] The strip of pills under a tab's bar (Sessions' chips, Tasks' views). Owner 2026-11-15 on 1023:
/// "You missed the background to the pills at the top": in the Desktop Look the strip was the page colour, an opaque
/// block over the hard frosted band that already reaches under it. On the iPhone it is clear in both looks, so the band
/// shows through; the Mac draws no edge, so there the look keeps the page colour.
enum DesktopPillBand {
    static var color: UIColor {
        #if targetEnvironment(macCatalyst)
        Theme.isDesktop ? HQPalette.page : .clear
        #else
        .clear
        #endif
    }
}
