// [project-pills] Owner 2026-11-15: a project pill opens its project as a page (`SessionListPipeline.projectPage`).
// This is the page's header, the list's first row. [projects-switch] Owner 2026-11-15 ("maximizing screen real estate
// and improving visual clarity … less visually stressful"): it is three short lines, not a block: the project's
// name; one quiet line with its folder, the newest chat's branch and the bots that work in it; and
// the three counts as small chips, always in the same places, a zero dimmed (Needs You, New, Working; a tap
// scrolls to that section). No faces here:
// the rows under it carry them (Show › Bot Faces). The chats follow in the list's own rows, by section.
// [project-header-card] Owner 2026-11-16 (a screenshot of a project's page, the header ringed): "This section up here
// needs to have something behind it, like not that takes up any more room, but just kind of makes it feel like that's
// more of its own space … like a card maybe. And it has to work for every theme properly and in every scenario." The
// three lines stand on a card in the project cards' colour (`ProjectCard.fill`, the theme's `groupedCard`), in the same
// height as before: the words keep their column (the rows' edge) and the card reaches out round them. On Soft Cards the
// section already stands on its own soft card, so it draws none (never a card on a card). Where a theme's card is too
// close to its page to part from it, the card steps toward the theme's ink until it does (`cardColour`); the Desktop
// Look outlines it too, as every card there.

import SwiftUI
import UIKit

struct ProjectPageHeader: View {
    var name: String
    /// The project's key: its folder (as the gateway's computer has it).
    var folder: String
    var branch: String?
    /// The bots that work in it, the one with the newest chat first.
    var bots: [String]
    var needs: Int
    var ready: Int
    var working: Int
    var total: Int
    /// A count's section id (`SessionListPipeline.statePrefix` + needs / ready / working).
    var onJump: (String) -> Void
    /// [project-header-card] The section stands on a soft card already (Soft Cards, the page's picture showing): no card
    /// of its own.
    var onSoftCard = false

    /// The folder as people write it: a home folder as "~".
    static func shortFolder(_ path: String) -> String {
        guard !path.hasPrefix("id:") else { return "" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if (path.hasPrefix("/Users/") || path.hasPrefix("/home/")), parts.count >= 2 {
            return (["~"] + parts.dropFirst(2)).joined(separator: "/")
        }
        return path
    }

    /// "~/site · main · Hermes, Otto": each part only when there is one; past three bots, "and N more".
    static func meta(folder: String, branch: String?, bots: [String]) -> String {
        let who = bots.count > 3 ? bots.prefix(2).joined(separator: ", ") + " and \(bots.count - 2) more" : bots.joined(separator: ", ")
        return [shortFolder(folder), branch ?? "", who].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var lead: CGFloat { Theme.isDesktop ? DesktopRows.gutter : 20 }

    // MARK: [project-header-card] The card

    /// Draws a card: not on a soft card.
    private var carded: Bool { !onSoftCard }
    /// From the card's edge to the words: the words stay on the rows' edge (`lead`), so the card stands this much
    /// outside it.
    static var cardPad: CGFloat { Theme.isDesktop ? 10 : 12 }
    /// Room inside the card over the name and under the counts.
    static var cardPadV: CGFloat { Theme.isDesktop ? 8 : 10 }
    static var cardRadius: CGFloat { HQShape.radius(18, .card) }
    /// The least contrast (WCAG ratio) between the card and its page: about what iOS's own grouped card has on a white
    /// page (#F2F2F7, 1.11), a little under it.
    nonisolated static let cardLeast = 1.08

    /// [project-header-card] The card's colour: the theme's card (as a project's card), or, where that card is too close
    /// to the page to read as one (14 of the 70 looks in the test, the Desktop Look's and Paper's among them), the card
    /// stepped toward the theme's own ink, a percent at a time, until it stands apart. It keeps the theme's hue.
    nonisolated static func cardColour(page: RGBA, card: RGBA, ink: RGBA) -> RGBA {
        let page = page.over(.white), card = card.over(page), ink = ink.over(page)
        var colour = card
        var step = 0.0
        while ratio(page, colour) < cardLeast, step < 40 {
            step += 1
            colour = ink.mix(step, card)
        }
        return colour
    }

    /// The same, as a colour that follows the look (light, dark, the skin, Increase Contrast).
    static let fill: UIColor = {
        let page = HQPalette.page, card = HQPalette.groupedCard, ink = HQPalette.label   // read here: resolved off the main thread
        return UIColor { @Sendable traits in
            cardColour(page: rgba(page.resolvedColor(with: traits)), card: rgba(card.resolvedColor(with: traits)),
                       ink: rgba(ink.resolvedColor(with: traits))).uiColor
        }
    }()

    nonisolated private static func rgba(_ colour: UIColor) -> RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(unit: Double(r), Double(g), Double(b), Double(a))
    }

    /// WCAG contrast ratio of two opaque colours.
    nonisolated static func ratio(_ a: RGBA, _ b: RGBA) -> Double {
        func luminance(_ c: RGBA) -> Double {
            func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
        }
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @ViewBuilder private var card: some View {
        if carded {
            let shape = RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
            shape
                .fill(Color(uiColor: Self.fill))
                .overlay { if Theme.isDesktop { shape.strokeBorder(Color(uiColor: HQPalette.stroke), lineWidth: 1) } }
                .accessibilityHidden(true)
        }
    }

    /// A count's capsule: on the card, a step off it (the page's colour in light, a raised grey in dark, as a project's
    /// folder box on its card); off it, the list's grey.
    private var chipFill: Color { Color(uiColor: carded ? ProjectCard.box : HQPalette.fill3) }

    var body: some View {
        let meta = Self.meta(folder: folder, branch: branch, bots: bots)
        VStack(alignment: .leading, spacing: carded ? 5 : 6) {
            // [sessions-ux] Owner 2026-11-10 ("There should be one go-to"): no New Chat here. The bar's Compose, a thumb
            // away, starts the chat in this project (and says so: "New Chat in <project>"); the capsule beside the
            // name was a second button for the same thing.
            Text(name)
                .font(Font.hq(.title3).weight(.bold))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .frame(height: HQFont.scaled(carded ? 26 : 30))
            if !meta.isEmpty {
                Text(meta)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("sessions.projectPage.place")
            }
            // Owner 2026-11-15 (picked from four drawings): the three counts always, in the same places, a zero dimmed.
            // [project-header-card] Where the three don't fit on one line (the largest text sizes: "0 Nee…", "1 N…") they
            // keep their marks and numbers and drop their words, which VoiceOver still says.
            ViewThatFits(in: .horizontal) {
                counts(words: true)
                counts(words: false)
            }
            .padding(.top, carded ? 1 : 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // [project-header-card] On the card the words keep their column and the header its height (measured: the first
        // heading under it stands where it stood): the card's room inside is the room that stood round the words.
        .padding(.leading, carded ? Self.cardPad : lead)
        .padding(.trailing, carded ? Self.cardPad : lead - 4)
        .padding(.top, carded ? Self.cardPadV : 0)
        .padding(.bottom, carded ? Self.cardPadV - 1 : 0)
        .background { card }
        .padding(.horizontal, carded ? lead - Self.cardPad : 0)
        .padding(.top, carded ? 2 : 8)   // [sessions-ux] the name stood 7 pt under the pills, closer than any heading under it
        .padding(.bottom, carded ? 0 : 6)
    }

    private func counts(words: Bool) -> some View {
        HStack(spacing: 6) {
            chip(needs, "Needs You", id: "needs", words: words) { Circle().fill(Color.hqOrange).frame(width: 7, height: 7) }
            chip(ready, "New", id: "ready", words: words) { Circle().fill(Color.hqTint).frame(width: 7, height: 7) }
            chip(working, "Working", id: "working", words: words) {
                ZStack {
                    Circle().stroke(Color.hqLabel.opacity(0.25), lineWidth: 2)
                    Circle().trim(from: 0, to: 0.25).stroke(Color.hqLabel, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }.frame(width: 9, height: 9)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// One count: its mark, the number and the word, in a small capsule. A zero is dimmed and takes no tap.
    private func chip<Mark: View>(_ count: Int, _ word: String, id: String, words: Bool = true,
                                  @ViewBuilder mark: () -> Mark) -> some View {
        Button {
            onJump(SessionListPipeline.statePrefix + id)
        } label: {
            HStack(spacing: 5) {
                mark()
                Text(words ? "\(count) \(word)" : "\(count)")
                    .font(Font.hq(.caption).weight(.medium)).monospacedDigit()
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: HQFont.scaled(24))
            .background(Capsule().fill(chipFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.45 : 1)
        .accessibilityLabel("\(word), \(count) \(count == 1 ? "chat" : "chats")")
        .accessibilityIdentifier("sessions.projectPage.\(id)")
    }
}

/// [project-sections] A project state's mark, as the page's count chips draw it: Needs You an orange dot, Ready the
/// tint's dot, Working the still quarter ring; nothing for quiet.
struct ProjectStateMark: View {
    var state: SessionProjectState

    var body: some View {
        switch state {
        case .needsYou: Circle().fill(Color.hqOrange).frame(width: 7, height: 7)
        case .ready: Circle().fill(Color.hqTint).frame(width: 7, height: 7)
        case .working:
            ZStack {
                Circle().stroke(Color.hqLabel.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: 0.25).stroke(Color.hqLabel, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }.frame(width: 9, height: 9)
        case .quiet: EmptyView()
        }
    }
}
