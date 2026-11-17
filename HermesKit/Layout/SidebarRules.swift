// [mac] The Mac sidebar's measuring rules as pure functions (App/Mac/MacSidebar.swift draws them), here so they are
// unit tested with the rest (Tests/MacPolish4Tests.swift). Mac polish round, 2026-11-07.

import CoreGraphics

nonisolated enum SidebarRules {
    /// How tall a list's fading edge grows (`MacSidebar.placeFade`).
    static let fadeHeight: CGFloat = 22

    /// Mac polish #51: where a list's mask turns solid from its top and starts to fade at its foot, as shares of its
    /// `height`, with `above` and `below` points of rows past its edges. A fade grows with the rows past it, up to
    /// `fadeHeight`, and never past half the list. nil: all in view, no mask.
    /// `footFade`: the foot fade's own height (`peekFade`), in place of `fadeHeight`.
    /// `headFade`: the top fade's own height (`peekHeadFade`) where it must reach past the rows above.
    static func fadeStops(above: CGFloat, below: CGFloat, height: CGFloat, footFade: CGFloat? = nil,
                          headFade: CGFloat? = nil) -> (top: CGFloat, bottom: CGFloat)? {
        guard height > 0, above > 1 || below > 1 else { return nil }
        let head = headFade.map { $0 > fadeHeight ? $0 : min(above, $0) } ?? min(above, fadeHeight)
        let top = above > 1 ? head / height : 0
        let bottom = below > 1 ? 1 - min(below, footFade ?? fadeHeight) / height : 1
        return (min(top, 0.5), max(bottom, 0.5))
    }

    /// [Mac AAA 2026-11-16] How tall a list's foot fade is so that it always shows there is more below. The list's
    /// foot often fell just past a row, cutting the next one near its top: the fade then lay over the blank room
    /// between them and the list looked finished (at 1280 × 800 three Tools hid under Usage with no sign of them; a
    /// bot's "2 more" under its last chat). Then the fade reaches up over the last whole row
    /// instead, so that row reads faded. `rows`: the list's rows top to bottom, in its visible part's points (0 its
    /// top); `below`: points of rows past its foot. `fadeHeight` when the cut row shows enough of itself (`peek`).
    static func peekFade(rows: [ListRow], height: CGFloat, below: CGFloat, peek: CGFloat = Self.peek) -> CGFloat {
        guard height > 0, below > 1 else { return fadeHeight }
        let cut = rows.first { $0.bottom > height + 0.5 && $0.top < height - 0.5 }
        if let cut, height - cut.top >= peek * (cut.bottom - cut.top) { return fadeHeight }
        guard let above = rows.last(where: { $0.bottom <= height + 0.5 && $0.bottom - $0.top >= 12 }) else { return fadeHeight }
        let start = above.top + (above.bottom - above.top) * peekStart
        return min(max(fadeHeight, height - start), height / 2)
    }
    /// [Mac AAA 2026-11-16] The same at the list's top (sidebar S3): scrolled to its end, the foot's list stopped part
    /// way into a row, right under the line, its words cut through their tops ("Terminal" at 640 pt tall). A row cut by
    /// the top is let go into the fade unless nearly all of it shows (`headPeek`), and the fade reaches down over the
    /// first whole row, so that row reads faded as more above. `above`: points of rows past the top. The rows
    /// mirrored, `peekFade`'s rule.
    /// `strict`: the foot's list (it moves on its own to show a place, and stops where its end puts it); the bots'
    /// list, scrolled by hand, keeps the foot's 40 % so its top does not fade two rows deep at every few points.
    static func peekHeadFade(rows: [ListRow], height: CGFloat, above: CGFloat, strict: Bool = true) -> CGFloat {
        let mirrored = rows.reversed().map { ListRow(top: height - $0.bottom, bottom: height - $0.top, heading: $0.heading) }
        return peekFade(rows: mirrored, height: height, below: above, peek: strict ? headPeek : peek)
    }
    /// The share of a row cut by the list's top that must show for the usual fade: its words are cut at their tops
    /// under the line above, which reads broken at any less.
    static let headPeek: CGFloat = 0.9
    /// Where on that row the longer fade starts: near its top, so its whole name reads faded (from its middle only
    /// the lower half of the letters lightened, too little to see).
    static let peekStart: CGFloat = 0.2
    /// The share of a row the foot must leave in view for its fade alone to show it (its name is in its middle).
    static let peek: CGFloat = 0.4

    /// A row of the bots' list for `headingFade`: its top and foot in the list, and whether it is a group's heading.
    struct ListRow: Equatable, Sendable {
        var top: CGFloat
        var bottom: CGFloat
        var heading: Bool
    }

    /// After Mac polish #33 (Marketplace made the Tools one row longer): a list shown from `top`, `height` tall, with
    /// `below` points of rows past its foot, that would stop on a group's heading, cut by the fade or with the group's
    /// first row cut or faded under it (Unassigned over a ghost of Notes read as an empty group). Where its foot fade
    /// starts and where it is clear, in the list's visible height: across the heading, so the list ends on the row
    /// above it. nil: the usual fade (the last clear row a bot's, or everything in view).
    static func headingFade(rows: [ListRow], top: CGFloat, height: CGFloat, below: CGFloat) -> (start: CGFloat, end: CGFloat)? {
        guard height > 0, below > 1 else { return nil }
        let foot = top + height
        let clear = foot - min(below, fadeHeight)
        guard let cut = rows.firstIndex(where: { $0.bottom > clear && $0.top < foot }) else { return nil }
        // The heading cut by the fade, or the one over the first row it cuts.
        let index = rows[cut].heading ? cut : cut > 0 && rows[cut - 1].heading ? cut - 1 : nil
        guard let index, rows[index].top - headingLead > top else { return nil }
        let heading = rows[index]
        return (heading.top - headingLead - top, min(height, heading.bottom - headingLead - top))
    }
    /// How far above a lone heading its fade starts (and above its foot it is clear): the heading's words read faint.
    static let headingLead: CGFloat = 6

    /// Mac polish #54: how far a name drawn at `pointSize` may shrink to fit (`minimumScaleFactor`): `least`, but never
    /// under `smallest` (the Mac's smallest text, `HQFont.macSmallest`).
    static func shrink(pointSize: CGFloat, least: CGFloat, smallest: CGFloat) -> CGFloat {
        min(1, max(least, smallest / max(pointSize, 1)))
    }

    /// Mac polish #56: whether a colour read past the sidebar's edge (0–255 a channel) is the window not drawn yet rather
    /// than a page: pure black beside any page that isn't black, and in light mode anything near it (the iOS look
    /// light's folded rail got a near-black frame). A light page with a picture behind it (App Background, dimmed with
    /// the page's colour) reads far lighter.
    /// `picture`: an App Background picture shows beside it, so a near-black read can be the picture itself (a very dark
    /// photo at low dimming), and only pure black still means not drawn (Mac polish #56's leftover: the strip went white).
    static func undrawn(red: UInt8, green: UInt8, blue: UInt8, light: Bool, pageIsBlack: Bool, picture: Bool = false) -> Bool {
        guard !pageIsBlack else { return false }
        let most = max(red, green, blue)
        return most == 0 || (light && !picture && most < 48)
    }
}
