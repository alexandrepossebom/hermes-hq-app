// [coding-pr-review] Owner 2026-11-21 (option B, the board's fourth column: artifacts/coding-pr-review/mock1.html): the
// PR card. A coding row's PR mark opens it (instead of the chat), and so do Session Info's pull request rows. What it
// shows is `PullRequestCard`'s (HermesKit/Model/PullRequestCard.swift); this draws it in the settings list's look, as
// the Repository page does: the state line, the name, one quiet line with the repository and branch, then Actions and
// the chat's other pull requests. Ask <bot> to Merge… shows its exact words first; Send posts them to that chat.
// [pr-card-detail] Opened, it asks for that one chat with `detail: true` and `fresh: true`, shows what it has at once
// and fills in Checks and Changes when the answer comes (a quiet progress mark in the head, never a spinner in place
// of content).

import SwiftUI
import UIKit

/// [pr-card-detail] What one card sheet shows, shared by its pushed pages: the chat's status, refreshed once by the
/// card's own `detail: true` ask.
@MainActor final class PullRequestCardModel: ObservableObject {
    @Published var status: SessionPRStatus
    @Published var loading = false

    init(status: SessionPRStatus) { self.status = status }

    /// Asks once; the answer replaces what the card shows unless the chat's code is gone from it.
    func refresh(_ ask: @escaping () async -> SessionPRStatus?) {
        guard !loading else { return }
        loading = true
        Task { [weak self] in
            let fresh = await ask()
            guard let self else { return }
            self.status = PullRequestCard.refreshed(self.status, with: fresh)
            self.loading = false
        }
    }
}

struct PullRequestCardView: View {
    @ObservedObject var model: PullRequestCardModel
    let focus: PullRequestCard.Focus
    let chatTitle: String
    let botName: String
    /// The card as it stood when the page opened: kept if a fresh answer drops the item (the chat's code is gone).
    let opened: PullRequestCard
    var onOpen: (URL) -> Void = { _ in }
    var onAsk: (String, String) -> Void = { _, _ in }
    var onOther: (PullRequestCard.Focus) -> Void = { _ in }
    var onRuns: ([SessionPRChecks.Run]) -> Void = { _ in }
    var onFile: (PullRequestCard.FileRow) -> Void = { _ in }

    private var card: PullRequestCard {
        PullRequestCard(status: model.status, focus: focus, chatTitle: chatTitle, botName: botName) ?? opened
    }

    var body: some View {
        let card = self.card
        List { Group {
            Section { head(card) }
                .listRowBackground(Color.clear)
                // The words start where the section labels under them do, and clear of the cell's rounded corner
                // (at 4 pt the corner cut the first letter of the last line).
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
            if let checks = card.checksRow {
                Section {
                    checksRow(checks)
                } header: { HQSectionLabel { Text("Checks") } }
            }
            let files = card.fileRows
            if let label = card.changesLabel {
                Section {
                    ForEach(Array(files.enumerated()), id: \.offset) { place, file in
                        fileRow(file).accessibilityIdentifier("prcard.file.\(place)")
                    }
                    if let more = card.moreFilesWords {
                        Text(more)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .accessibilityIdentifier("prcard.moreFiles")
                    }
                } header: { HQSectionLabel { Text(verbatim: label) }.accessibilityIdentifier("prcard.changes") }
            }
            let actions = card.actions
            if !actions.isEmpty {
                Section {
                    ForEach(actions, id: \.self) { action in
                        switch action {
                        case .openOnGitHub(let url):
                            Button("Open on GitHub") { onOpen(url) }
                                .foregroundStyle(Color.hqTintText)
                                .accessibilityIdentifier("prcard.openOnGitHub")
                        case .askToFixChecks(let words):
                            Button(card.fixChecksTitle) { onAsk(words, card.fixChecksTitle) }
                                .foregroundStyle(Color.hqTintText)
                                .accessibilityIdentifier("prcard.askToFixChecks")
                        case .askToMerge(let words):
                            Button(card.mergeTitle) { onAsk(words, card.mergeTitle) }
                                .foregroundStyle(Color.hqTintText)
                                .accessibilityIdentifier("prcard.askToMerge")
                        }
                    }
                } header: { HQSectionLabel { Text("Actions") } }
            }
            let others = card.others
            if !others.isEmpty {
                Section {
                    ForEach(Array(others.enumerated()), id: \.offset) { place, other in
                        Button { onOther(other.focus) } label: {
                            HStack(spacing: 10) {
                                PullRequestGlyph(state: other.state, size: 16)
                                Text(other.label).foregroundStyle(Color.hqLabel).lineLimit(1)
                                Spacer(minLength: 8)
                                SettingsChevron()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("prcard.other.\(place)")
                    }
                } header: { HQSectionLabel { Text("Also in This Chat") } }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList()
        .accessibilityIdentifier("prcard")
    }

    /// The Checks row: its mark as on the row (red only when failing), its words; with runs, a chevron to them.
    @ViewBuilder private func checksRow(_ checks: PullRequestCard.ChecksRow) -> some View {
        let line = HStack(spacing: 10) {
            PullRequestCheckMark(state: checks.state)
                .frame(width: HQFont.scaled(14))
            Text(checks.words)
                .font(Font.hq(.body))
                .foregroundStyle(checks.state == .failed ? Color.hqRed : Color.hqLabel)
            Spacer(minLength: 8)
            if checks.runs != nil { SettingsChevron() }
        }
        .contentShape(Rectangle())
        if let runs = checks.runs {
            Button { onRuns(runs) } label: { line }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(checks.words)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("prcard.checks")
        } else {
            line
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(checks.words)
                .accessibilityIdentifier("prcard.checks")
        }
    }

    /// One file: its name in monospace, its folder quiet under it (or what stands in for its diff), "+96 −8" trailing;
    /// a patch pushes the diff.
    @ViewBuilder private func fileRow(_ file: PullRequestCard.FileRow) -> some View {
        let line = HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.name)
                    .font(Font.hq(.subheadline).monospaced())
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let second = [file.folder, file.note].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(verbatim: second)
                        .font(Font.hq(.caption))
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let counts = file.counts {
                Text(verbatim: counts)
                    .font(Font.hq(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize()
            }
            if case .patch = file.body { SettingsChevron() }
        }
        .contentShape(Rectangle())
        let spoken = ([file.path] + [file.counts.map { _ in Self.spokenCounts(file) }, file.note].compactMap { $0 }).joined(separator: ", ")
        if case .patch = file.body {
            Button { onFile(file) } label: { line }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityAddTraits(.isButton)
        } else {
            line
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
    }

    private static func spokenCounts(_ file: PullRequestCard.FileRow) -> String {
        let parts = (file.counts ?? "").split(separator: " ")
        let added = parts.first.map { String($0.dropFirst()) } ?? "0", removed = parts.dropFirst().first.map { String($0.dropFirst()) } ?? "0"
        return "\(added) added, \(removed) removed"
    }

    /// The state line, the name and the place, on the page (no card), as the board draws them.
    private func head(_ card: PullRequestCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                PullRequestGlyph(state: card.markState, size: 16)
                Text(card.stateWords)
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .foregroundStyle(Color(uiColor: PullRequestInk.text(card.markState)))
                if model.loading {
                    // [pr-card-detail] Asking for the checks and files: a quiet mark, the content stays.
                    ProgressView().controlSize(.mini).tint(Color.hqLabel3)
                        .accessibilityLabel("Loading")
                        .accessibilityIdentifier("prcard.loading")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("prcard.state")
            Text(card.name)
                .font(Font.hq(.title3).weight(.bold))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(2)
                .accessibilityIdentifier("prcard.name")
            if let place = card.place {
                Text(place)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("prcard.place")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A pull request state's glyph in its mark's colour (the row's mark, without its number).
struct PullRequestGlyph: View {
    var state: SessionPRStatus.State
    var size: CGFloat = 14
    var body: some View {
        Image(uiImage: SessionPRGlyph.image(state)).renderingMode(.template)
            .resizable().scaledToFit()
            .frame(width: HQFont.scaled(size), height: HQFont.scaled(size))
            .foregroundStyle(Color(uiColor: SessionPRGlyph.color(state)))
            .accessibilityHidden(true)
    }
}

/// [coding-pr-review] Words in a state's colour on the card: the mark's colour moved toward the theme's ink until it
/// reads at 4.5:1 on the list's card (the system green read at about 2:1 on white). The glyph keeps the mark's colour.
@MainActor enum PullRequestInk {
    private static var cache: [SessionPRStatus.State: UIColor] = [:]
    static func text(_ state: SessionPRStatus.State) -> UIColor {
        if let colour = cache[state] { return colour }
        let mark = SessionPRGlyph.color(state), ink = HQPalette.label, card = HQPalette.groupedCard
        let colour = UIColor { traits in
            ThemeMath.readable(rgba(mark.resolvedColor(with: traits)), text: rgba(ink.resolvedColor(with: traits)),
                               on: rgba(card.resolvedColor(with: traits))).uiColor
        }
        cache[state] = colour
        return colour
    }

    nonisolated private static func rgba(_ colour: UIColor) -> RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(unit: Double(r), Double(g), Double(b), Double(a))
    }
}

/// [coding-pr-review] The PR card as a sheet: built from a chat's status, its own pages pushed inside it (another of
/// the chat's pull requests), Ask to Merge confirmed in an alert, then handed to `send` once the sheet is gone.
@MainActor enum PullRequestCardSheet {
    struct Chat {
        var profile: String
        var id: String
        var title: String
        var botName: String
    }

    /// The card's sheet, or nil where there is no card (no mark). `send`: the confirmed words, after the sheet closed.
    /// `refresh`: the card's own ask for this chat (`detail: true`, `fresh: true`), made once as it opens.
    static func make(status: SessionPRStatus?, chat: Chat, focus: PullRequestCard.Focus = .lead,
                     refresh: (() async -> SessionPRStatus?)? = nil,
                     send: @escaping (String) -> Void) -> UINavigationController? {
        guard let status, let card = PullRequestCard(status: status, focus: focus, chatTitle: chat.title, botName: chat.botName) else { return nil }
        let model = PullRequestCardModel(status: status)
        weak var sheet: UINavigationController?
        let page = self.page(card, model: model, sheet: { sheet }, send: send)
        let wrapped = ChatSheet.wrap(page, title: card.title, detents: [.medium(), .large()])
        sheet = wrapped
        if let refresh { model.refresh(refresh) }
        return wrapped
    }

    private static func page(_ card: PullRequestCard, model: PullRequestCardModel, sheet: @escaping () -> UINavigationController?,
                             send: @escaping (String) -> Void) -> UIViewController {
        weak var host: UIViewController?
        let view = PullRequestCardView(model: model, focus: card.focus, chatTitle: card.chatTitle, botName: card.botName, opened: card,
                                       onOpen: { url in
            UIApplication.shared.open(url)
        }, onAsk: { words, title in
            guard let host else { return }
            confirm(words, title: title, from: host) {
                let nav = sheet()
                nav?.presentingViewController?.dismiss(animated: true) { send(words) } ?? send(words)
            }
        }, onOther: { focus in
            guard let next = PullRequestCard(status: model.status, focus: focus, chatTitle: card.chatTitle, botName: card.botName) else { return }
            let pushed = page(next, model: model, sheet: sheet, send: send)
            pushed.title = next.title
            pushed.navigationItem.largeTitleDisplayMode = .never
            sheet()?.pushViewController(pushed, animated: true)
        }, onRuns: { runs in
            let pushed = UIHostingController(rootView: PullRequestRunsPage(runs: runs))
            pushed.title = "Checks"
            pushed.navigationItem.largeTitleDisplayMode = .never
            sheet()?.pushViewController(pushed, animated: true)
        }, onFile: { file in
            guard case .patch(let patch) = file.body else { return }
            sheet()?.pushViewController(PullRequestDiffPage(name: file.name, path: file.path, patch: patch), animated: true)
        })
        let controller = UIHostingController(rootView: view)
        host = controller
        return controller
    }

    /// The exact words, then Cancel or Send. Nothing is sent without Send.
    static func confirm(_ words: String, title: String, from host: UIViewController, send: @escaping () -> Void) {
        let alert = UIAlertController(title: title.replacingOccurrences(of: "…", with: ""), message: words, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Send", style: .default) { _ in send() })
        alert.view.accessibilityIdentifier = "prcard.confirm"
        host.present(alert, animated: true)
    }

    /// Posts `words` to the chat as a normal message, opening it first when it isn't on show (`open`): the Shortcuts'
    /// first-message road (`NewChatRouter.deliver`, `ChatViewController.sendFromCard`).
    static func deliver(_ words: String, to chat: Chat, open: () -> Void) {
        guard let root = MainTabController.current else { return }
        let profile = chat.profile, id = chat.id
        // Not while the card (or anything else) still covers the chat: the words would go out under a closing sheet.
        // The Shortcuts' own first message keeps its rule: this wait is the card's alone.
        func wanted(_ controller: ChatViewController) -> Bool {
            controller.session.profile == profile && (controller.session as? LiveChatSession)?.storedSessionId == id
                && controller.presentedViewController == nil
        }
        if !(root.chatOnShow.map(wanted) ?? false) { open() }
        Task {
            let sent = await NewChatRouter.deliver(words, send: true, root: root, wanted: wanted)
            AppLog.note("sessions", "pr card: ask \(sent ? "sent" : "not sent, the chat never came up") (\(words.count) chars)")
        }
    }
}
