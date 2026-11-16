// Unread failure results belong to a bound chat, not to a particular screen or live roster.
import Testing
@testable import HermesHQNative

@MainActor
@Suite("Activity · unread helper failures", .serialized)
struct ActivityFailureRetentionTests {
    let client = FakeGatewayClient()
    let store: ActivityStore
    let rid = "5cc537d1"

    init() {
        store = ActivityStore(client: client, frameMode: .manual)
        store.start()
        store.bind(runtimeId: rid, profile: "default", storedId: "s1")
    }

    func event(_ type: String, _ payload: JSONValue, sid: String? = nil) {
        store.handle(GatewayEvent(type: type, sessionId: sid ?? rid, seq: nil, payload: payload))
    }

    func failedHelper() {
        event("subagent.start", ["goal": "Read the notes", "task_count": 1, "task_index": 0,
                                 "subagent_id": "sa_failed", "status": "running"])
        event("subagent.complete", ["goal": "Read the notes", "task_count": 1, "task_index": 0,
                                    "subagent_id": "sa_failed", "status": "failed", "summary": "The notes could not be read"])
    }

    @Test func unreadFailuresSurviveTurnsStoredLookupsAndRemints() {
        failedHelper()
        #expect(store.activity(rid).unreadHelperFailures.map(\.id) == ["sa_failed"])
        #expect(!store.hasLiveWork(profile: "default"))
        event("message.start", .null)
        #expect(store.activity(rid).subagents.isEmpty, "the live roster is still turn-scoped")
        #expect(store.activity(storedIds: ["s1"], profile: "default").unreadHelperFailures.count == 1)
        #expect(store.activity(storedIds: ["s1"], profile: "default").runtimeId == rid)
        #expect(store.activity(storedIds: ["s1"], profile: "other").unreadHelperFailures.isEmpty)
        store.bind(runtimeId: "aaaa0001", profile: "default", storedId: "s1")
        #expect(!store.isBound(rid))
        #expect(store.activity("aaaa0001").unreadHelperFailures.first?.summary == "The notes could not be read")
        store.acknowledgeHelperFailure(runtimeId: "aaaa0001", subagentId: "sa_failed")
        #expect(store.activity("aaaa0001").unreadHelperFailures.isEmpty)
        store.shutdown()
    }

    @Test func acknowledgmentsSurviveARosterRefreshAndStayChatScoped() async {
        failedHelper()
        store.acknowledgeHelperFailure(runtimeId: rid, subagentId: "sa_failed")
        #expect(store.activity(rid).unreadHelperFailures.isEmpty)
        #expect(store.activity(rid).subagents.first?.status == .failed, "reading never rewrites the result")
        client.onCall { method, _ in
            switch method {
            case "subagent.list": return ["subagents": [
                ["subagent_id": "sa_failed", "goal": "Read the notes", "status": "failed", "summary": "Refreshed result"],
                ["subagent_id": "sa_refresh", "goal": "Check the roster", "status": "completed", "summary": "Roster refreshed"]
            ], "delegations": []]
            case "session.control.read": throw RPCError(code: -32601, message: "Method not found", data: nil)
            default: return .object([:])
            }
        }
        store.bind(runtimeId: "aaaa0001", profile: "default", storedId: "s1")
        store.setVisible(runtimeId: "aaaa0001", openSubagent: nil)
        // Terminal rows are frozen, and pruning retires their IDs. A new completed row proves the response applied
        // without depending on a terminal result changing or an already-retired failure being reinserted.
        #expect(await waitUntil { store.activity("aaaa0001").subagents.contains { $0.id == "sa_refresh" && $0.summary == "Roster refreshed" } })
        #expect(client.calls("subagent.list").first?.params == ["session_id": "aaaa0001", "profile": "default"])
        #expect(store.activity("aaaa0001").subagents.first { $0.id == "sa_failed" }?.summary == "The notes could not be read")
        #expect(store.activity("aaaa0001").unreadHelperFailures.isEmpty)
        store.bind(runtimeId: "bbbb0002", profile: "other", storedId: "s2")
        event("subagent.start", ["goal": "Another chat", "task_count": 1, "task_index": 0,
                                 "subagent_id": "sa_failed", "status": "failed"], sid: "bbbb0002")
        #expect(store.activity("bbbb0002").unreadHelperFailures.count == 1)
        store.shutdown()
    }

    @Test func nestedDelegateResultsRetainOnlyTheFailedChild() {
        event("message.start", .null)
        let args: JSONValue = ["tasks": [["goal": "Read the notes"], ["goal": "Check the links"]]]
        event("tool.start", ["tool_id": "call_mixed", "name": "delegate_task", "args": args])
        event("tool.complete", ["tool_id": "call_mixed", "name": "delegate_task", "args": args,
                                "result": ["results": [
                                    ["status": "completed", "summary": "The notes were read"],
                                    ["status": "failed", "summary": "The links could not be checked"]]]])
        #expect(store.activity(rid).subagents.map(\.status) == [.completed, .failed])
        #expect(store.activity(rid).unreadHelperFailures.map(\.id) == ["delegate-tool:call_mixed:1"])
        #expect(store.activity(rid).unreadHelperFailures.first?.summary == "The links could not be checked")
        #expect(!store.hasLiveWork(profile: "default"))
        event("message.complete", .null)
        event("message.start", .null)
        #expect(store.activity(rid).unreadHelperFailures.count == 1)
        store.shutdown()
    }

    @Test func delegateResultsWithoutRepeatedArgsKeepEachChild() {
        event("message.start", .null)
        event("tool.start", ["tool_id": "call_no_args", "name": "delegate_task",
                             "args": ["tasks": [["goal": "Read the notes"], ["goal": "Check the links"]]]])
        event("tool.complete", ["tool_id": "call_no_args", "name": "delegate_task", "result": ["results": [
            ["status": "completed", "summary": "The notes were read"],
            ["status": "timeout", "summary": "The link check timed out"]]]])
        #expect(store.activity(rid).subagents.map(\.goal) == ["Read the notes", "Check the links"])
        #expect(store.activity(rid).subagents.map(\.status) == [.completed, .failed])
        #expect(store.activity(rid).unreadHelperFailures.map(\.id) == ["delegate-tool:call_no_args:1"])
        #expect(store.activity(rid).unreadHelperFailures.first?.summary == "The link check timed out")
        event("message.complete", .null)
        #expect(store.activity(rid).unreadHelperFailures.count == 1)
        store.shutdown()
    }

    @Test func nativeEventsSupersedeThisTurnsUnreadStandIns() {
        event("tool.complete", ["tool_id": "fallback", "name": "delegate_task",
                                "result": ["status": "failed", "summary": "Fallback result"]])
        #expect(store.activity(rid).unreadHelperFailures.count == 1)
        failedHelper()
        #expect(store.activity(rid).unreadHelperFailures.map(\.id) == ["sa_failed"])
        #expect(store.activity(rid).subagents.map(\.id) == ["sa_failed"])
        store.shutdown()
    }

    @Test func nativeEventsDoNotReadAStandInFromAnEarlierTurn() {
        event("tool.complete", ["tool_id": "earlier", "name": "delegate_task",
                                "result": ["status": "failed", "summary": "Earlier result"]])
        event("message.start", .null)
        failedHelper()
        #expect(Set(store.activity(rid).unreadHelperFailures.map(\.id)) == ["delegate-tool:earlier:0", "sa_failed"])
        store.shutdown()
    }

    @Test func failedDelegateStandInsRemainUnreadWithoutClaimingLiveWork() {
        event("message.start", .null)
        event("tool.start", ["tool_id": "call_fallback", "name": "delegate_task", "args": ["tasks": [["goal": "Read the notes"]]]])
        event("tool.complete", ["tool_id": "call_fallback", "name": "delegate_task", "error": true,
                                "result": ["status": "failed", "summary": "The helper failed"]])
        #expect(store.activity(rid).unreadHelperFailures.map(\.id) == ["delegate-tool:call_fallback:0"])
        #expect(!store.hasLiveWork(profile: "default"))
        event("message.start", .null)
        #expect(store.activity(rid).subagents.isEmpty)
        #expect(store.activity(rid).unreadHelperFailures.count == 1)
        store.acknowledgeHelperFailure(runtimeId: rid, subagentId: "delegate-tool:call_fallback:0")
        #expect(store.activity(rid).unreadHelperFailures.isEmpty)
        store.shutdown()
    }
}
