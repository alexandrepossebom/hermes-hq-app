// A skin's own paint for the iOS look and its own code colours, where the general rule (the desktop's chrome mix for
// the page, cards a step of ink, iOS's greys, your message the solid accent, GitHub's code colours) doesn't draw the
// theme as the theme draws itself. Rosé Pine: the owner's mockup of 2026-11-02 (the page its base, replies on its
// surface inside a faint line, your message a soft iris box with the theme's own text, tables with only their header
// row shaded, Rosé Pine code colours). Paper (owner 2026-11-16): Claude's ivory page exactly, not pulled toward grey,
// warm greys in place of iOS's cool ones, replies on the page with no bubble and your message a soft paper box, as
// Claude draws them.

import Foundation

/// One mode of a skin's own iOS look. Colours from the theme's own palette; nothing here is mixed at run time.
nonisolated struct SkinOwnLook: Sendable, Hashable {
    /// The chat's page and every page's background (instead of `ThemeResolver.chrome`).
    var page: RGBA
    /// Replies, cards, sheets' cards and the composer's box.
    var card: RGBA
    /// A row while pressed.
    var pressed: RGBA
    /// Your message's box; its words are the theme's text.
    var meBubble: RGBA
    /// A code card, opaque, in a reply.
    var codeFill: RGBA
    /// The grey of iOS's fills (120,120,128), separators and search fields, in the theme's own hue. Its alpha is
    /// ignored: the fills keep iOS's own shares.
    var grey: RGBA
    var fillAlphas: [Double]
    var separator: RGBA
    /// The faint line round a reply's bubble, as round its code and tables (owner 2026-11-02: "the chat bubbles have
    /// like a little faint line around them").
    var replyEdge: RGBA
    /// A table's header row; its other rows are the bubble's own colour.
    var tableHead: RGBA
    /// How much of the reply's colour lies over glass (replies otherwise take 55 %, which lifted Main's surface a step
    /// toward grey).
    var replyGlassTint: Double
    /// Secondary and tertiary words.
    var subtle: RGBA
    var muted: RGBA
    /// A reply's bubble, where it isn't `card`: Paper's replies lie on the page itself, as Claude's do.
    var reply: RGBA? = nil
    /// [paper-icons] The tile behind a Settings or More row's glyph, the glyph in the theme's own text, instead of iOS's
    /// coloured tiles with white glyphs (owner 2026-11-16, Paper "needs a lot of work"). nil: iOS's tiles.
    var iconTile: RGBA? = nil
    /// [paper-pills] Pills and chips on pages (Sessions' bots, Tasks' views, Tiles' pages, Kanban's statuses, New Job's
    /// picks) are drawn flat in this skin: unpicked on the card with a hairline, picked in the solid accent with its own
    /// ink, the same on every page. Otherwise iOS's Liquid Glass.
    var flatPills = false
    /// [Mac AAA 2026-11-16] What the Mac's chosen row is tinted with (`ThemeTokens.chosenRow`, drawn see-through by
    /// `MacSelection.accent`), where the skin's accent would shout: Paper's accent is its ink, so in dark the chosen row
    /// (sidebar, Settings' column, every list) was a light grey slab. nil: the accent, as every other skin.
    var chosenRow: RGBA? = nil

    nonisolated struct Pair: Sendable, Hashable {
        var light: SkinOwnLook
        var dark: SkinOwnLook
        func pick(_ dark: Bool) -> SkinOwnLook { dark ? self.dark : light }
    }
}

/// A skin's code colours by highlighter kind (`SyntaxPalette`), before they are made readable on the code card.
nonisolated struct SyntaxColours: Sendable, Hashable {
    var comment: RGBA
    var keyword: RGBA
    var string: RGBA
    var constant: RGBA
    var entity: RGBA
    var function: RGBA
    var tag: RGBA
    var invalid: RGBA

    func map(_ change: (RGBA) -> RGBA) -> SyntaxColours {
        SyntaxColours(comment: change(comment), keyword: change(keyword), string: change(string), constant: change(constant),
                      entity: change(entity), function: change(function), tag: change(tag), invalid: change(invalid))
    }

    nonisolated struct Pair: Sendable, Hashable {
        var light: SyntaxColours
        var dark: SyntaxColours
        func pick(_ dark: Bool) -> SyntaxColours { dark ? self.dark : light }
    }
}

nonisolated extension SkinCatalog {
    /// Rosé Pine's palettes (rosepinetheme.com/en/palette): Dawn and Main.
    private enum Dawn {
        static let base = RGBA(hex: 0xFAF4ED), surface = RGBA(hex: 0xFFFAF3), overlay = RGBA(hex: 0xF2E9E1)
        static let muted = RGBA(hex: 0x9893A5), subtle = RGBA(hex: 0x797593)
        static let love = RGBA(hex: 0xB4637A), gold = RGBA(hex: 0xEA9D34), pine = RGBA(hex: 0x286983)
        static let foam = RGBA(hex: 0x56949F), iris = RGBA(hex: 0x907AA9)
    }
    private enum Main {
        static let base = RGBA(hex: 0x191724), surface = RGBA(hex: 0x1F1D2E), overlay = RGBA(hex: 0x26233A)
        static let muted = RGBA(hex: 0x6E6A86), subtle = RGBA(hex: 0x908CAA)
        static let love = RGBA(hex: 0xEB6F92), gold = RGBA(hex: 0xF6C177), pine = RGBA(hex: 0x31748F)
        static let foam = RGBA(hex: 0x9CCFD8), iris = RGBA(hex: 0xC4A7E7)
    }

    /// Paper's palettes: Claude's ivory (sampled from the owner's screenshots), and black with warm greys in dark.
    private enum Ivory {
        static let page = RGBA(hex: 0xF8F9F3), card = RGBA(hex: 0xFDFDFA), drawer = RGBA(hex: 0xF2F3EE)
        static let selected = RGBA(hex: 0xE4E5DD), box = RGBA(hex: 0xE9EAE2)
        static let grey = RGBA(hex: 0x86857B), subtle = RGBA(hex: 0x4A4A47), muted = RGBA(hex: 0x8A897F)
    }
    private enum Charcoal {
        /// (page, card, code, pressed row, your message's box) by darkness. Black (owner 2026-11-16, picked from these four
        /// after the charcoal: "I don't like the dark mode background"). DEBUG builds draw another with
        /// `-HQDebugPaperDark charcoal|deep|night|black`, to compare.
        private static let steps: [String: [UInt32]] = [
            "charcoal": [0x262624, 0x30302D, 0x1F1E1D, 0x3A3A37, 0x3D3C38],
            "deep": [0x1C1B19, 0x262523, 0x151413, 0x302F2C, 0x33322F],
            "night": [0x121211, 0x1C1C1A, 0x0B0B0A, 0x262624, 0x2A2A27],
            "black": [0x000000, 0x161615, 0x0E0E0D, 0x1E1E1C, 0x242422],
        ]
        private static let chosen: [UInt32] = {
            #if DEBUG
            if let pick = UserDefaults.standard.string(forKey: "HQDebugPaperDark"), let step = steps[pick] { return step }
            #endif
            return steps["black"]!
        }()
        static let page = RGBA(hex: chosen[0]), card = RGBA(hex: chosen[1]), deep = RGBA(hex: chosen[2])
        static let selected = RGBA(hex: chosen[3]), box = RGBA(hex: chosen[4])
        static let grey = RGBA(hex: 0x8E8D84), subtle = RGBA(hex: 0xB7B5AC), muted = RGBA(hex: 0x8A8980)
    }

    static let ownLooks: [String: SkinOwnLook.Pair] = [
        "paper": SkinOwnLook.Pair(
            light: SkinOwnLook(page: Ivory.page, card: Ivory.card, pressed: Ivory.selected, meBubble: Ivory.box,
                               codeFill: Ivory.drawer, grey: Ivory.grey, fillAlphas: [0.2, 0.16, 0.12, 0.08],
                               separator: Ivory.grey.alpha(0.3), replyEdge: RGBA(unit: 0, 0, 0, 0), tableHead: Ivory.drawer,
                               replyGlassTint: 0.85, subtle: Ivory.subtle, muted: Ivory.muted, reply: Ivory.page,
                               iconTile: Ivory.selected, flatPills: true, chosenRow: Ivory.grey),
            dark: SkinOwnLook(page: Charcoal.page, card: Charcoal.card, pressed: Charcoal.selected, meBubble: Charcoal.box,
                              codeFill: Charcoal.deep, grey: Charcoal.grey, fillAlphas: [0.36, 0.32, 0.24, 0.12],
                              separator: Charcoal.grey.alpha(0.3), replyEdge: RGBA(unit: 0, 0, 0, 0),
                              tableHead: Charcoal.grey.alpha(0.2), replyGlassTint: 0.85, subtle: Charcoal.subtle,
                              muted: Charcoal.muted, reply: Charcoal.page, iconTile: Charcoal.selected,
                              flatPills: true, chosenRow: Charcoal.grey)),
        "rose-pine": SkinOwnLook.Pair(
            // Your box: the mockup's lavender, iris leaning to love.
            light: SkinOwnLook(page: Dawn.base, card: Dawn.surface, pressed: Dawn.overlay, meBubble: RGBA(hex: 0xEADCEF),
                               codeFill: Dawn.overlay, grey: Dawn.muted, fillAlphas: [0.2, 0.16, 0.12, 0.08],
                               separator: Dawn.muted.alpha(0.35), replyEdge: Dawn.muted.alpha(0.35), tableHead: Dawn.overlay,
                               replyGlassTint: 0.85, subtle: Dawn.subtle, muted: Dawn.muted),
            // Code on the page's base, a shade under the reply, as in the mockup; lines and the table's header a fifth
            // to a third of the grey (iOS's strengths drew them a step brighter than the mockup).
            dark: SkinOwnLook(page: Main.base, card: Main.surface, pressed: Main.overlay, meBubble: RGBA(hex: 0x4D3357),
                              codeFill: Main.base, grey: Main.muted, fillAlphas: [0.36, 0.32, 0.24, 0.12],
                              separator: Main.muted.alpha(0.3), replyEdge: Main.muted.alpha(0.3), tableHead: Main.muted.alpha(0.2),
                              replyGlassTint: 0.85, subtle: Main.subtle, muted: Main.muted)),
    ]

    /// Keywords love, function names iris, constants pine, types gold (the mockup's), strings gold, comments subtle, tags
    /// foam, errors love. Pine is the light constant; it is made readable in dark with the rest.
    static let syntaxColours: [String: SyntaxColours.Pair] = [
        // [paper-code] Paper's code (owner 2026-11-16, "needs a lot of work"): muted and warm in place of GitHub's bright
        // blue, purple and red. Keywords terracotta, strings olive, constants and types amber-brown, functions the ink,
        // comments the warm grey. Each is taken just far enough to read at 4.5:1 on the code card (`ThemeTokens.syntax`).
        "paper": SyntaxColours.Pair(
            light: SyntaxColours(comment: RGBA(hex: 0x8A897F), keyword: RGBA(hex: 0x9C4A2E), string: RGBA(hex: 0x5C6B2F),
                                 constant: RGBA(hex: 0x8A5A00), entity: RGBA(hex: 0x7A5230), function: RGBA(hex: 0x3D3A35),
                                 tag: RGBA(hex: 0x9C4A2E), invalid: RGBA(hex: 0xB42318)),
            dark: SyntaxColours(comment: RGBA(hex: 0x8A8980), keyword: RGBA(hex: 0xD99A7A), string: RGBA(hex: 0xB5C28A),
                                constant: RGBA(hex: 0xD8B46A), entity: RGBA(hex: 0xC9A98A), function: RGBA(hex: 0xECEBE4),
                                tag: RGBA(hex: 0xD99A7A), invalid: RGBA(hex: 0xF07167))),
        "rose-pine": SyntaxColours.Pair(
            light: SyntaxColours(comment: Dawn.subtle, keyword: Dawn.love, string: Dawn.gold, constant: Dawn.pine,
                                 entity: Dawn.gold, function: Dawn.iris, tag: Dawn.foam, invalid: Dawn.love),
            dark: SyntaxColours(comment: Main.subtle, keyword: Main.love, string: Main.gold, constant: Main.pine,
                                entity: Main.gold, function: Main.iris, tag: Main.foam, invalid: Main.love)),
    ]
}
