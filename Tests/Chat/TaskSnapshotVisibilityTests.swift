// Runtime task snapshots are context for the agent, not a second message from the person.
import Foundation
import Testing
@testable import HermesHQNative

@Suite("Internal task snapshots stay out of the conversation")
@MainActor
struct TaskSnapshotVisibilityTests {
    static let snapshot = """
    [Your active task list was preserved across context compression]
    - [>] update-layout. Simplify the activity display (in_progress)
    - [ ] verify-layout. Run the native checks (pending)
    """

    private func visibleRows(_ messages: [ChatMessage]) -> [ChatRow] {
        ChatRowBuilder.build(.init(messages: TimelineNotes.resolve(messages), isRunning: false,
                                   botName: "Ivy", expanded: []))
    }

    @Test func historyDoesNotDrawTheInternalReminder() throws {
        let rows: [JSONValue] = [
            ["id": 1, "role": "user", "content": "Simplify the activity display."],
            ["id": 2, "role": "assistant", "content": "I am checking the layout."],
            ["id": 3, "role": "user", "content": .string(Self.snapshot)],
            ["id": 4, "role": "assistant", "content": "The checks passed."],
        ]
        let page = Hydration.fold(rows, pageSeq: 1)
        let built = visibleRows(page.messages)
        #expect(!built.contains { $0.messageId == "stored-row-3-user" })
        #expect(built.contains { $0.messageId == "stored-row-1-user" })
        #expect(built.contains { $0.messageId == "stored-row-4-assistant" })
        #expect(rows[2]["content"]?.string == Self.snapshot, "the stored task context is not edited")
    }

    @Test func liveAndCachedMessagesStayHiddenWithoutChangingTheirPositions() {
        for role in [ChatMessage.Role.user, .system] {
            let messages = [ChatMessage(id: "live-snapshot", role: role, parts: [.text(Self.snapshot)])]
            let resolved = TimelineNotes.resolve(messages)
            #expect(resolved.map(\.id) == messages.map(\.id), "row ranges still index the original messages")
            #expect(visibleRows(messages).isEmpty)
            #expect(messages[0].plainText == Self.snapshot)
            #expect(TimelineNotes.resolve(resolved) == resolved, "the display pass is idempotent")
        }
    }

    @Test func historyHandlesTextPartsAndOlderNotificationKinds() {
        let contents: [JSONValue] = [.string(Self.snapshot), [["type": "text", "text": .string(Self.snapshot)]]]
        for content in contents {
            for kind: JSONValue in [.null, "internal_notification", "hidden"] {
                let page = Hydration.fold([["id": 3, "role": "user", "content": content, "display_kind": kind]])
                #expect(visibleRows(page.messages).isEmpty)
            }
        }
    }

    @Test func ordinaryMessagesAndQuotedExamplesStayVisible() {
        for text in ["What does this mean?\n" + Self.snapshot,
                     "> " + Self.snapshot,
                     "```\n" + Self.snapshot + "\n```",
                     "[Your active task list was preserved across context compression] What does this mean?",
                     "- [ ] My own checklist"] {
            let messages = [ChatMessage(id: "real-user", role: .user, parts: [.text(text)])]
            #expect(TimelineNotes.resolve(messages) == messages)
            #expect(!visibleRows(messages).isEmpty)
        }
        let answer = [ChatMessage(id: "explanation", role: .assistant, parts: [.text(Self.snapshot)])]
        #expect(TimelineNotes.resolve(answer) == answer, "an assistant can explain the marker")
    }

    @Test func displayContentRemainsAuthoritative() {
        let page = Hydration.fold([["id": 3, "role": "user", "content": .string(Self.snapshot),
                                   "display_content": "The person's actual words."]])
        #expect(TimelineNotes.resolve(page.messages).first?.plainText == "The person's actual words.")
        #expect(!visibleRows(page.messages).isEmpty)
    }

    @Test func sessionsPreviewSkipsSnapshotsToo() {
        let reply: JSONValue = ["id": 2, "role": "assistant", "content": "I am checking the layout."]
        let flattened = Self.snapshot.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for content: JSONValue in [.string(Self.snapshot), .string(flattened), [["type": "text", "text": .string(Self.snapshot)]]] {
            let snapshot: JSONValue = ["id": 3, "role": "user", "content": content]
            #expect(SessionLatestRules.latest([reply, snapshot]) == "I am checking the layout.")
            #expect(SessionLatestRules.latest([snapshot]) == nil)
        }
    }

    @Test func alreadyCachedSessionPreviewsDoNotResurfaceTheSnapshot() {
        let store = SessionStore(client: BotsFakeGatewayClient(), account: .botsTestAccount,
                                 cacheDirectory: BotsTest.tempDirectory(), timing: .fast)
        defer { store.stop(); RosterDiskWriter.shared.flush() }
        let row = SidebarSessionRow(id: "s1", profile: "ivy", title: "Chat", lastActive: 10)
        let key = SessionStore.writeKey(id: row.id, profile: row.profile)
        let flattened = Self.snapshot.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        store.device.latest[key] = SessionLatestMessage(at: 10, text: String(flattened.prefix(200)))
        #expect(store.latestText(row) == nil)
        store.device.latest[key] = SessionLatestMessage(at: 10, text: "I am checking the layout.")
        #expect(store.latestText(row) == "I am checking the layout.")
    }

    @Test func toolDiscoveryHasReadableProgressWords() {
        #expect(ToolNow.phrase("tool_describe", args: [:]) == "checking tool instructions")
        #expect(ToolNow.phrase("functions.tool_describe", args: ["names": ["process_manage"]]) == "checking tool instructions")
        #expect(ToolNow.phrase("hermes_tool_search", args: [:]) == "finding the right tool")
        #expect(ToolLines.line("tool_describe", args: ["name": "process_manage"]).text == "Checking tool instructions")
        #expect(ToolLines.done("Checking tool instructions") == "Checked tool instructions")
        #expect(ToolLines.line("hermes_tool_search", args: ["query": "process manage"]).text == "Finding the right tool")
    }
}
