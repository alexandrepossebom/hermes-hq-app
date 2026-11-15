// [project-pills] Owner 2026-11-15: a project pill opens its project as a page (`SessionListPipeline.projectPage`).
// This is the page's header, the list's first row: the project's name; its folder and the newest chat's branch; the
// bots that work in it; how many chats need the owner, are ready to review and are at work (a tap scrolls to that
// section); and New Chat in the project. The chats follow under it in the list's own rows, by section.

import SwiftUI

struct ProjectPageHeader: View {
    struct BotFace: Identifiable, Hashable {
        var id: String
        var name: String
        var head: Head
    }

    var name: String
    /// The project's key: its folder (as the gateway's computer has it).
    var folder: String
    var branch: String?
    var bots: [BotFace]
    var needs: Int
    var ready: Int
    var working: Int
    var total: Int
    /// A count's section id (`SessionListPipeline.statePrefix` + needs / ready / working).
    var onJump: (String) -> Void
    var onNewChat: (() -> Void)?

    /// The folder as people write it: a home folder as "~".
    static func shortFolder(_ path: String) -> String {
        guard !path.hasPrefix("id:") else { return "" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if (path.hasPrefix("/Users/") || path.hasPrefix("/home/")), parts.count >= 2 {
            return (["~"] + parts.dropFirst(2)).joined(separator: "/")
        }
        return path
    }

    private var place: String {
        [Self.shortFolder(folder), branch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(Font.hq(.title2).weight(.bold))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if !place.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: branch == nil ? "folder" : "arrow.triangle.branch")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                        Text(place).lineLimit(1).truncationMode(.middle)
                    }
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("sessions.projectPage.place")
                }
                if !bots.isEmpty {
                    HStack(spacing: 6) {
                        HStack(spacing: -6) {
                            ForEach(bots.prefix(4)) { bot in
                                HeadImage(head: bot.head, profile: bot.id, size: HQFont.scaled(20), working: false,
                                          phase: HeadView.phase(for: bot.id))
                            }
                        }
                        Text(botWords)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(botWords)
                }
            }
            HStack(spacing: 8) {
                tile(needs, "Needs You", id: "needs", mark: AnyView(Circle().fill(Color.hqOrange).frame(width: 8, height: 8)))
                tile(ready, "Ready", id: "ready", mark: AnyView(Circle().fill(Color.hqTint).frame(width: 8, height: 8)))
                tile(working, "Working", id: "working", mark: AnyView(
                    ZStack {
                        Circle().stroke(Color.hqLabel.opacity(0.25), lineWidth: 2)
                        Circle().trim(from: 0, to: 0.25).stroke(Color.hqLabel, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }.frame(width: 10, height: 10)))
            }
            if let onNewChat {
                Button(action: onNewChat) {
                    Label("New Chat in \(name)", systemImage: "square.and.pencil")
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(Color.hqOnTint)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Color.hqTint)
                .accessibilityIdentifier("sessions.projectPage.newChat")
            }
        }
        .padding(.horizontal, Theme.isDesktop ? DesktopRows.gutter : 20)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var botWords: String {
        let names = bots.map(\.name)
        guard names.count > 3 else { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
    }

    private func tile(_ count: Int, _ word: String, id: String, mark: AnyView) -> some View {
        Button {
            onJump(SessionListPipeline.statePrefix + id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    mark
                    Text("\(count)")
                        .font(Font.hq(.title3).weight(.semibold)).monospacedDigit()
                        .foregroundStyle(count == 0 ? Color.hqLabel3 : Color.hqLabel)
                }
                Text(word)
                    .font(Font.hq(.caption))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.isDesktop ? DesktopRows.radius : 14, style: .continuous).fill(Color.hqFill3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .accessibilityLabel("\(word), \(count) \(count == 1 ? "chat" : "chats")")
        .accessibilityIdentifier("sessions.projectPage.\(id)")
    }
}
