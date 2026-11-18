import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite("Request helper disclosure", .serialized)
struct HelperStatusSheetTests {
    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func fixture() -> HelperDisclosureSession {
        let session = HelperDisclosureSession()
        let start = Date().addingTimeInterval(-100)
        func batch(_ id: String, _ goal: String, completed: Bool) -> ToolCall {
            var call = ToolCall(id: id, name: "delegate_task", title: "Delegate", argsText: #"{"goal":"\#(goal)"}"#,
                                summary: nil, state: .done, durationSeconds: 1)
            call.card = .delegate(goals: [goal], results: completed ? [DelegateResult(status: "completed", summary: "Cedar count is twelve.")] : nil,
                                  dispatchedGoals: completed ? nil : [goal])
            return call
        }
        session.messages = [
            ChatMessage(id: "fixture-request", role: .user, parts: [.text("Compare the invented tree samples.")], timestamp: start, rowId: 1),
            ChatMessage(id: "fixture-batch-one", role: .assistant,
                        parts: [.tool(batch("fixture-call-one", "Inventory cedar samples", completed: true)), .text("The first count is recorded.")],
                        timestamp: start + 1, rowId: 2),
            ChatMessage(id: "fixture-report", role: .system, parts: [.text("Subagent Task Completed: Inventory cedar samples")],
                        timestamp: start + 2, rowId: 3, report: "The invented ledger contains twelve cedar samples, including two narrow specimens."),
            ChatMessage(id: "fixture-batch-two", role: .assistant,
                        parts: [.tool(batch("fixture-call-two", "Measure birch samples", completed: false))],
                        timestamp: start + 3, rowId: 4),
        ]
        let finished = SubagentProgress(id: "fixture-done", goal: "Inventory cedar samples", status: .completed,
                                       taskCount: 1, taskIndex: 0, startedAt: (start + 1).timeIntervalSince1970,
                                       updatedAt: (start + 2).timeIntervalSince1970, durationSeconds: 1,
                                       filesRead: ["invented/cedar.txt"],
                                       stream: [.init(at: (start + 1).timeIntervalSince1970, isError: false, kind: .tool, text: "Count cedar samples")],
                                       summary: "Cedar count is twelve.")
        let live = SubagentProgress(id: "fixture-live", goal: "Measure birch samples", status: .running,
                                   taskCount: 1, taskIndex: 0, startedAt: (start + 3).timeIntervalSince1970,
                                   updatedAt: (start + 4).timeIntervalSince1970)
        session.activity.subagents = [finished, live]
        session.activity.tails[finished.id] = SubagentTail(available: true, text: "Twelve cedar samples counted.", truncated: false)
        return session
    }

    @Test func terminalDetailsSurviveRosterPruningAndStayOutOfLegacyCardInputs() throws {
        let session = fixture()
        let chat = ChatViewController(session: session)
        let before = chat.activity.rowsInput()
        let finished = try #require(before.subagents.first { $0.id == "fixture-done" })
        session.activity.subagents.removeAll { !$0.isLive }
        session.activity.tails = [:]
        let after = chat.activity.rowsInput()
        #expect(after.subagents.map(\.id) == ["fixture-live"])
        #expect(after.retainedSubagents.first { $0.id == finished.id } == finished)
        let group = try #require(HelperStatusRows.Plan(chat.input()).group(requestID: "fixture-request"))
        #expect(group.helpers.count == 2)
        #expect(group.helpers.first { $0.id == finished.id }?.filesRead == ["invented/cedar.txt"])
        #expect(group.helpers.first { $0.id == finished.id }?.stream.first?.text == "Count cedar samples")
    }

    @Test func shelfKeepsOnlyUnrepresentedHelpersAndUnrelatedTasks() {
        let session = fixture()
        var unrelated = session.activity.subagents[1]
        unrelated.id = "fixture-unrelated"
        unrelated.goal = "Check an independent greenhouse"
        session.activity.subagents.append(unrelated)
        session.activity.liveTodos = [TodoItem(id: "fixture-task", content: "Water an independent fern", status: .inProgress)]
        let chat = ChatViewController(session: session)
        chat.loadViewIfNeeded()
        chat.activity.updateShelf(animated: false)
        let entries = chat.activity.shelf.summary.entries
        #expect(Set(entries.map(\.kind)) == [.subagents, .tasks])
        #expect(entries.first { $0.kind == .subagents }?.words == "1 helper")
    }

    @Test func aHelperTickRebuildsItsRequestAnchorOnlyOnceAcrossBatches() throws {
        let session = fixture()
        let chat = ChatViewController(session: session)
        var input = chat.input()
        let previous = ChatActivityController.CardKey(subagents: input.activity.subagents, turnAnchor: input.activity.turnAnchor)
        let live = try #require(input.activity.subagents.firstIndex { $0.id == "fixture-live" })
        input.activity.subagents[live].toolCount = 4
        input.activity.subagents[live].updatedAt += 1
        #expect(ChatActivityController.helperRebuildMessageIDs(input: input, previous: previous) == ["fixture-batch-one"])
        input.activity.subagents.removeAll { $0.id == "fixture-live" }
        #expect(ChatActivityController.helperRebuildMessageIDs(input: input, previous: previous) == ["fixture-batch-one"],
                "a removed live child updates the old request's disclosure")
    }

    @Test func prunedFallbackFailureKeepsItsDetailsWithoutRepeatingOnTheShelf() throws {
        let session = fixture()
        session.messages.removeAll { $0.id == "fixture-report" }
        var failed = session.activity.subagents[0]
        failed.id = "delegate-tool:fixture-call-one:0"
        failed.status = .failed
        failed.summary = "The invented cedar ledger was unavailable."
        session.activity.subagents = [failed]
        session.activity.unreadHelperFailures = [failed]
        let chat = ChatViewController(session: session)
        chat.loadViewIfNeeded()
        session.activity.subagents = []
        chat.activity.updateShelf(animated: false)
        let group = try #require(HelperStatusRows.Plan(chat.input()).group(requestID: "fixture-request"))
        #expect(group.helpers.contains { $0.id == failed.id && $0.summary == failed.summary && $0.status == .failed })
        #expect(!chat.activity.shelf.summary.entries.contains { $0.kind == .subagents })
    }

    @Test func disclosurePreservesReportsDraftsAndNativeHelperControls() async throws {
        let session = fixture()
        let client = FakeGatewayClient()
        client.onCall { method, _ in
            switch method {
            case "subagent.steer": return ["status": "queued"]
            case "subagent.interrupt": return ["found": true]
            default: return [:]
            }
        }
        let store = ActivityStore(client: client, frameMode: .manual)
        store.bind(runtimeId: "fixture-runtime", profile: session.profile, storedId: "fixture-stored")
        session.activityStore = store
        defer { store.shutdown() }
        let chat = ChatViewController(session: session)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = chat
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        chat.activity.presentHelpers(requestID: "fixture-request")
        let navigation = try #require(chat.presentedViewController as? UINavigationController)
        let page = try #require(navigation.viewControllers.first as? HelperStatusSheetViewController)
        page.loadViewIfNeeded()
        #expect(await waitUntil { page.isVisible })
        #expect(page.debugReports.debugMembers.flatMap(\.steps).map(\.id) == ["fixture-call-one", "fixture-call-two"])
        #expect(page.debugReports.debugMembers.contains { $0.messageId == "fixture-report" && $0.full.contains("two narrow specimens") })
        #expect(descendants(of: page.body).compactMap { $0 as? SubagentRowView }.count == 2)
        page.body.onSelect?("fixture-live")
        let detail = try #require(descendants(of: page.body).compactMap { $0 as? SubagentDetailView }.first)
        #expect(detail.field.isEnabled && detail.stop.isEnabled && !detail.stop.isHidden)
        detail.field.text = "Measure the narrow sample first."
        detail.field.sendActions(for: .editingChanged)
        page.body.onSelect?("fixture-done")
        #expect(detail.stop.isHidden)
        page.body.onSelect?("fixture-live")
        #expect(detail.field.text == "Measure the narrow sample first.")
        detail.send.sendActions(for: .touchUpInside)
        #expect(await waitUntil { client.calls("subagent.steer").count == 1 })
        #expect(client.calls("subagent.steer").first?.params["subagent_id"]?.string == "fixture-live")
        #expect(await waitUntil { detail.field.text == "" })
        detail.stop.sendActions(for: .touchUpInside)
        #expect(await waitUntil { client.calls("subagent.interrupt").count == 1 })
        #expect(client.calls("subagent.interrupt").first?.params["subagent_id"]?.string == "fixture-live")
        let reports = try #require(descendants(of: page.view).first { $0.accessibilityIdentifier == "chat.helpers.reports" } as? UIButton)
        reports.sendActions(for: .touchUpInside)
        #expect(navigation.topViewController === page.debugReports)
    }
}

@MainActor
private final class HelperDisclosureSession: ChatSessionModel, ChatActivityProviding {
    let title = "Invented samples"
    let profile = "helper-fixture"
    let head: JSONValue? = nil
    var messages: [ChatMessage] = []
    var isRunning = false
    var hasOlder = false
    var isLoadingOlder = false
    var connection: ConnectionState = .ready
    var statusText: String?
    var onChange: ((ChatChange) -> Void)?
    var activity = ChatActivity()
    var onActivityChange: (() -> Void)?
    var liveStep: ToolLine? { nil }
    var statusIsWorking: Bool { true }
    var providerWait: String? { nil }
    var displayFlags: DisplayFlags { DisplayFlags() }
    var activityStore: ActivityStore?
    var activityRuntimeId: String? { "fixture-runtime" }
    var hiddenTurnAnchor: String? { nil }
    var revealedSteps: Set<String> = []
    func start() {}
    func stopObserving() {}
    func loadOlder() {}
    func send(_ text: String) {}
    func stop() {}
    func sendHidden(_ text: String, display: String?) {}
    func reasoningSeconds(messageId: String) -> [Int: Double] { [:] }
    func setActivityVisible(_ visible: Bool, openSubagent: String?) {}
}
