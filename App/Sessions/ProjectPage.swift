// [project-pills] Owner 2026-11-15: a project pill opens its project as a page (`SessionListPipeline.projectPage`).
// This is the page's header, the list's first row. [projects-switch] Owner 2026-11-15 ("maximizing screen real estate
// and improving visual clarity … less visually stressful"): it is three short lines, not a block: the project's
// name; one quiet line with its folder, the newest chat's branch and the bots that work in it; and
// the three counts as small chips, always in the same places, a zero dimmed (Needs You, New, Working; a tap
// scrolls to that section). No faces here:
// the rows under it carry them (Show › Bot Faces). The chats follow in the list's own rows, by section.

import SwiftUI

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

    var body: some View {
        let meta = Self.meta(folder: folder, branch: branch, bots: bots)
        VStack(alignment: .leading, spacing: 6) {
            // [sessions-ux] Owner 2026-11-10 ("There should be one go-to"): no New Chat here. The bar's Compose, a thumb
            // away, starts the chat in this project (and says so: "New Chat in <project>"); the capsule beside the
            // name was a second button for the same thing.
            Text(name)
                .font(Font.hq(.title3).weight(.bold))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .frame(height: HQFont.scaled(30))
            if !meta.isEmpty {
                Text(meta)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("sessions.projectPage.place")
            }
            // Owner 2026-11-15 (picked from four drawings): the three counts always, in the same places, a zero dimmed.
            HStack(spacing: 6) {
                chip(needs, "Needs You", id: "needs") { Circle().fill(Color.hqOrange).frame(width: 7, height: 7) }
                chip(ready, "New", id: "ready") { Circle().fill(Color.hqTint).frame(width: 7, height: 7) }
                chip(working, "Working", id: "working") {
                    ZStack {
                        Circle().stroke(Color.hqLabel.opacity(0.25), lineWidth: 2)
                        Circle().trim(from: 0, to: 0.25).stroke(Color.hqLabel, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }.frame(width: 9, height: 9)
                }
            }
            .padding(.top, 2)
        }
        .padding(.leading, lead)
        .padding(.trailing, lead - 4)
        .padding(.top, 8)   // [sessions-ux] the name stood 7 pt under the pills, closer than any heading under it
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One count: its mark, the number and the word, in a small capsule. A zero is dimmed and takes no tap.
    private func chip<Mark: View>(_ count: Int, _ word: String, id: String, @ViewBuilder mark: () -> Mark) -> some View {
        Button {
            onJump(SessionListPipeline.statePrefix + id)
        } label: {
            HStack(spacing: 5) {
                mark()
                Text("\(count) \(word)")
                    .font(Font.hq(.caption).weight(.medium)).monospacedDigit()
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: HQFont.scaled(24))
            .background(Capsule().fill(Color.hqFill3))
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
