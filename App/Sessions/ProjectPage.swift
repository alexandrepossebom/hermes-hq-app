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
    /// A count tapped ("needs", "ready", "working"): the page narrows to those chats, or back to all of them.
    var onJump: (String) -> Void
    /// [page-count-chips] The counts the page is narrowed to (lit): New's narrowing lights Needs You and New.
    var lit: Set<String> = []
    /// [project-header-card] The section stands on a soft card already (Soft Cards, the page's picture showing): no card
    /// of its own.
    var onSoftCard = false
    /// [project-default-bot] Optional bot actions in the header's ⋯; coding settings are always available.
    var menu: BotMenu? = nil
    var coding = false
    var prCounts: [SessionPRStatus.State: Int] = [:]
    var selectedPR: SessionPRStatus.State? = nil
    var onPRPick: (SessionPRStatus.State) -> Void = { _ in }
    var onCodingChange: (Bool) -> Void = { _ in }

    /// [project-default-bot] Owner 2026-11-17: "a project should be able to have a default bot". The bar's Compose
    /// starts the chat with it at once; this menu says which bot that is, changes it, and starts a chat with another.
    struct BotMenu {
        var bots: [(id: String, name: String)]
        /// The default bot; nil asks.
        var usual: String?
        /// A bot's profile, or `ProjectDefaultBot.ask`.
        var onPick: (String) -> Void
        var onNewChatWith: () -> Void
    }

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

    /// Count verified answers once per project chat, including archived chats.
    static func pullRequestCounts(_ rows: [SessionSummary], project: String,
                                  projects: [String: [SessionProject]]) -> [SessionPRStatus.State: Int] {
        var seen = Set<String>()
        var counts: [SessionPRStatus.State: Int] = [:]
        for row in rows {
            guard SessionProjects.key(cwd: row.cwd, profile: row.profile, projectsByProfile: projects) == project,
                  let state = row.pullRequest?.state, state != .unknown,
                  seen.insert(SessionListPipeline.key(row)).inserted else { continue }
            counts[state, default: 0] += 1
        }
        return counts
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

    /// The same, as a colour that follows the look (light, dark, the skin, Increase Contrast). Every project card's too
    /// (`ProjectCard.fill`).
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
        if DeviceWord.isMac { macBody } else { phoneBody }
    }

    /// [mac-pane] Owner 2026-11-18, of this header on the Mac: "I don't think it's sized properly. I don't think it's
    /// designed right … doesn't feel like it belongs on a Mac application, like it does on my iPhone." The Mac draws
    /// the same parts without the phone's card and capsules: the name, then one grey line with the folder, the bots,
    /// how many chats, and each count that isn't zero as words that narrow the page with a click (a zero is left out;
    /// a lit one stays, as the way back).
    private var macBody: some View {
        let meta = Self.meta(folder: folder, branch: branch, bots: bots)
        let line = ([meta] + [total > 0 ? "\(total) \(total == 1 ? "chat" : "chats")" : ""]).filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(name)
                    .font(Font.hq(.headline))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let menu { moreButton(menu) }
            }
            .frame(height: HQFont.scaled(24))
            HStack(spacing: 0) {
                Text(line)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("sessions.projectPage.place")
                macCount(needs, "needs you", spoken: "Needs You", id: "needs", ink: .hqOrange)
                macCount(ready, "new", spoken: "New", id: "ready", ink: .hqTintText)
                macCount(working, "working", spoken: "Working", id: "working", ink: .hqLabel2)
                Spacer(minLength: 0)
            }
            .font(Font.hq(.footnote))
            .foregroundStyle(Color.hqLabel2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, lead)
        .padding(.trailing, lead - 4)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder private func macCount(_ count: Int, _ word: String, spoken: String, id: String, ink: Color) -> some View {
        if count > 0 || isLit(id, count) {
            Text(" · ")
            Button { onJump(id) } label: {
                Text("\(count) \(word)")
                    .fontWeight(isLit(id, count) ? .semibold : .regular)
                    .underline(isLit(id, count))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .fixedSize()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(spoken), \(count) \(count == 1 ? "chat" : "chats")")
            .accessibilityAddTraits(isLit(id, count) ? .isSelected : [])
            .accessibilityIdentifier("sessions.projectPage.\(id)")
        }
    }

    private var phoneBody: some View {
        let meta = Self.meta(folder: folder, branch: branch, bots: bots)
        return VStack(alignment: .leading, spacing: carded ? 5 : 6) {
            // [sessions-ux] Owner 2026-11-10 ("There should be one go-to"): no New Chat here. The bar's Compose, a thumb
            // away, starts the chat in this project (and says so: "New Chat in <project>"); the capsule beside the
            // name was a second button for the same thing.
            HStack(spacing: 4) {
                Text(name)
                    .font(Font.hq(.title3).weight(.bold))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                moreButton(menu)
            }
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
            if coding {
                pullRequestCounts
                Text("Counts include only available PR statuses.")
                    .font(Font.hq(.caption))
                    .foregroundStyle(Color.hqLabel2)
            }
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

    /// [project-default-bot] The ⋯ at the name's end: its glyph stands on the card's inner edge, its touch 44 pt across.
    private func moreButton(_ menu: BotMenu?) -> some View {
        HeaderMoreButton(label: "Actions for \(name)", identifier: "sessions.projectPage.more", glyph: Theme.isDesktop ? 14 : 17,
                         cap: 22, height: HQFont.scaled(carded ? 26 : 30), above: 8) {
            Toggle(isOn: Binding(get: { coding }, set: onCodingChange)) {
                Label("Coding Project", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .accessibilityHint("Shows pull request status instead of timestamps in this project")
            .accessibilityIdentifier("sessions.projectPage.coding")
            if let menu {
                Button(action: menu.onNewChatWith) { Label("New Chat With…", systemImage: "square.and.pencil") }
                Picker(selection: Binding(get: { menu.usual ?? ProjectDefaultBot.ask }, set: { menu.onPick($0) })) {
                    ForEach(menu.bots, id: \.id) { bot in Text(bot.name).tag(bot.id) }
                    Divider()
                    Text("Ask Every Time").tag(ProjectDefaultBot.ask)
                } label: {
                    Label("Default Bot", systemImage: "person.crop.circle.badge.checkmark")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("sessions.projectPage.defaultBot")
            }
        }
        .padding(.trailing, -13)
    }

    private var pullRequestCounts: some View {
        HStack(spacing: 12) {
            ForEach([SessionPRStatus.State.none, .draft, .open, .merged, .closed], id: \.self) { state in
                let count = prCounts[state, default: 0]
                let status = state == .none ? "No PR yet" : "\(SessionPRStatus(state: state).label) PR"
                let label = "\(status), \(count) loaded \(count == 1 ? "chat" : "chats")"
                Button { onPRPick(state) } label: {
                HStack(spacing: 3) {
                    Image(uiImage: SessionPRGlyph.image(state))
                        .renderingMode(.template)
                        .resizable().frame(width: 14, height: 14)
                        .foregroundStyle(Color(uiColor: SessionPRGlyph.color(state)))
                    Text("\(count)").font(Font.hq(.caption).weight(.medium)).monospacedDigit()
                }
                .padding(.horizontal, 4).frame(minHeight: 32)
                .overlay { if selectedPR == state { Capsule().strokeBorder(Color.hqTint, lineWidth: 1.5) } }
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(count == 0 && selectedPR != state)
                .opacity(count == 0 && selectedPR != state ? 0.45 : 1)
                .accessibilityLabel(label)
                .accessibilityHint(selectedPR == state ? "Clear pull request filter" : "Filter chats by pull request state")
                .accessibilityAddTraits(selectedPR == state ? .isSelected : [])
                .accessibilityIdentifier("sessions.projectPage.pr.\(state.rawValue)")
                .help(label)
            }
        }
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

    /// [page-count-chips] A count the page is narrowed to. New's narrowing lights New, and Needs You while it counts a chat.
    private func isLit(_ id: String, _ count: Int) -> Bool { lit.contains(id) && (count > 0 || id != "needs") }

    /// One count: its mark, the number and the word, in a small capsule. A zero is dimmed and takes no tap.
    private func chip<Mark: View>(_ count: Int, _ word: String, id: String, words: Bool = true,
                                  @ViewBuilder mark: () -> Mark) -> some View {
        Button {
            onJump(id)
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
            // [page-count-chips] Lit while the page is narrowed to it: the tint's ring, as a picked pill says "on".
            .overlay { if isLit(id, count) { Capsule().strokeBorder(Color.hqTint, lineWidth: 1.5) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A lit count takes the tap at zero too (its last chat read): the way back to every chat.
        .disabled(count == 0 && !isLit(id, count))
        .opacity(count == 0 && !isLit(id, count) ? 0.45 : 1)
        .accessibilityLabel("\(word), \(count) \(count == 1 ? "chat" : "chats")")
        .accessibilityAddTraits(isLit(id, count) ? .isSelected : [])
        .accessibilityIdentifier("sessions.projectPage.\(id)")
    }
}

extension SessionsViewController {
    /// Count the entire loaded project, not just the visible, folded, or filtered piles.
    func projectPRCounts(_ key: String) -> [SessionPRStatus.State: Int] {
        guard let store else { return [:] }
        let rows = (store.sessions + store.archivedSessions).map { row in
            var row = row
            row.pullRequest = store.pullRequest(profile: row.profile, id: row.id) ?? row.pullRequest
            return row
        }
        return ProjectPageHeader.pullRequestCounts(rows, project: key, projects: store.projectsByProfile)
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
