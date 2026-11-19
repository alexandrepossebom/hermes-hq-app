import SwiftUI

/// Uses the same marks as the project rows so the guide follows the current theme.
struct ProjectIconGuide: View {
    let coding: Bool

    var body: some View {
        List {
            if coding {
                Section {
                    ForEach([SessionPRStatus.State.none, .draft, .open, .merged, .closed, .unknown], id: \.self) { state in
                        entry(SessionPRStatus(state: state).label, explanation(state)) {
                            Image(uiImage: SessionPRGlyph.image(state)).renderingMode(.template)
                                .resizable().frame(width: 18, height: 18)
                                .foregroundStyle(Color(uiColor: SessionPRGlyph.color(state)))
                        }.accessibilityIdentifier("project.legend.\(state.rawValue)")
                    }
                } header: { HQSectionLabel { Text("Pull requests") } }
                  footer: { HQSectionFooter { Text("Counts include only available PR statuses.") } }
            }
            Section {
                entry("Needs You", "The chat is waiting for your input.") { ProjectStateMark(state: .needsYou) }
                entry("New", "There’s an unread update in the chat.") { ProjectStateMark(state: .ready) }
                entry("Working", "The bot is working in the chat.") { ProjectStateMark(state: .working) }
            } header: { HQSectionLabel { Text("Chat activity") } }
        }.settingsList()
    }

    private func entry<Mark: View>(_ title: String, _ detail: String, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            mark().frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel)
                Text(detail).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
            }
        }.accessibilityElement(children: .combine)
    }

    private func explanation(_ state: SessionPRStatus.State) -> String {
        switch state {
        case .none: "No pull request was found for this chat."
        case .draft: "A draft pull request exists. It isn’t ready for review yet."
        case .open: "The pull request is open for review."
        case .merged: "The changes were merged into the target branch."
        case .closed: "The pull request was closed without merging."
        case .unknown: "The status couldn’t be verified. A pull request may still exist."
        }
    }
}
