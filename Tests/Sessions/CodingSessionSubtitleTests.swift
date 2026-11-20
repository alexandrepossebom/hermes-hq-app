import Foundation
import Testing
@testable import HermesHQNative

@Suite struct CodingSessionSubtitleTests {
    private func row() -> SessionSummary {
        SessionSummary(id: "s", profile: "ivy", title: "Code", preview: nil, lastActive: nil,
                       source: nil, unread: false, isRunning: false)
    }

    @Test func pendingAndLiveWorkTakePrecedenceWithoutLeakingText() {
        var s = row()
        s.lastResult = "Tests passed"
        s.isRunning = true
        s.step = "running npm test --token=secret"
        #expect(CodingSessionSubtitle.line(s) == "Running tests…")
        s.pending = SessionPending(failed: false, text: "password=secret")
        #expect(CodingSessionSubtitle.line(s) == "Draft not sent")
        s.status = .needsInput
        #expect(CodingSessionSubtitle.line(s) == "Waiting for you in chat")
        s.pending = SessionPending(failed: true, text: "password=secret")
        #expect(CodingSessionSubtitle.line(s) == "Your message wasn’t delivered")
        s.pending = nil; s.status = .working; s.step = "reading latest.env"
        #expect(CodingSessionSubtitle.line(s) == "Reading a file…")
        s.step = "running curl https://example.com?key=secret"
        #expect(CodingSessionSubtitle.line(s) == "Running a command…")
    }

    @Test func onlyExplicitAssistantReportsAreNamed() {
        func result(_ text: String, _ role: String? = "assistant") -> String? {
            CodingSessionSubtitle.result(SessionLatestMessage(at: 1, text: text, role: role))
        }
        #expect(result("All tests passed.") == "All tests passed")
        #expect(result("12 UI tests passed.") == "12 UI tests passed")
        #expect(result("Tests failed") == "Tests failed")
        #expect(result("Command completed successfully") == "Replied in chat")
        #expect(result("Tests passed", "user") == "No reply yet")
        #expect(result("Tests passed", nil) == nil)
        #expect(result("Tests passed but the build failed") == "Tests passed · build failed")
        var s = row()
        #expect(CodingSessionSubtitle.line(s) == "No recent update")
        s.preview = "secret from the first message"
        // A sidebar preview can be the first request, not a confirmed reply.
        #expect(CodingSessionSubtitle.line(s) == "No recent update")
        #expect(result("Updated the token: ghp_" + String(repeating: "a1", count: 20)) == "Replied in chat")
        s.lastResult = result("Please review my notes")
        s.pullRequest = SessionPRStatus(state: .merged, number: 23)
        #expect(CodingSessionSubtitle.line(s) == "PR #23 merged")
    }
}

@Suite(.serialized) struct CodingSessionResultPersistenceTests {
    private func setup(_ client: BotsFakeGatewayClient, dir: URL, readsLatest: Bool = false) -> SessionStore {
        var timing = SessionStoreTiming.fast
        timing.readsLatest = readsLatest
        let store = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: dir, timing: timing, autoStart: false)
        var row = SidebarSessionRow(id: "s", profile: "ivy", title: "Code", lastActive: 100, messageCount: 2)
        row.cwd = "/code/example"
        store.recents = [row]
        store.rebuild()
        return store
    }

    @Test func confirmedReplySurvivesRefreshAndRelaunchButNotNewActivity() async throws {
        let client = BotsFakeGatewayClient(), dir = BotsTest.tempDirectory()
        let sidebar: JSONValue = ["recents": ["sessions": [["id": "s", "profile": "ivy", "title": "Code", "last_active": 100,
                                                              "message_count": 2, "cwd": "/code/example"]]],
                                  "cron": ["sessions": []], "messaging": ["sessions": []]]
        client.onREST { _, _, _, _ in try sidebar.encoded() }
        let store = setup(client, dir: dir)
        store.start()
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        store.noteConfirmedReply(profile: "ivy", sessionId: "s", text: "Tests failed")
        #expect(store.sessions.first?.lastResult == "Tests failed")
        await store.refresh()
        #expect(store.sessions.first?.lastResult == "Tests failed")
        RosterDiskWriter.shared.flush()
        let reopened = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: dir, timing: .fast, autoStart: false)
        #expect(reopened.sessions.first?.lastResult == "Tests failed")
        reopened.recents[0].lastActive = 101
        reopened.rebuild()
        #expect(reopened.sessions.first?.lastResult == nil)
        reopened.noteConfirmedReply(profile: "ivy", sessionId: "s", text: "Build passed")
        #expect(reopened.sessions.first?.lastResult == "Build passed")
        #expect(!client.restCalls.contains { $0.path.hasSuffix("/messages") })
        store.stop()
    }

    @Test func oldCacheDecodesAndNewerUserMessageIsNotAnOutcome() throws {
        let old = try JSONDecoder().decode(SessionLatestMessage.self, from: Data(#"{"at":100,"text":"Tests passed"}"#.utf8))
        #expect(old.role == nil)
        #expect(CodingSessionSubtitle.result(old) == nil)
        let rows: [JSONValue] = [["id": 1, "role": "assistant", "content": "Tests passed"],
                                 ["id": 2, "role": "user", "content": "Tests failed"]]
        let latest = try #require(SessionLatestRules.latestMessage(rows))
        #expect(latest.role == "user")
        #expect(CodingSessionSubtitle.result(SessionLatestMessage(at: 100, text: latest.text, role: latest.role)) == "No reply yet")
    }

    @Test func slowHistoryCannotOverwriteNewlyConfirmedReply() async throws {
        let client = BotsFakeGatewayClient(), dir = BotsTest.tempDirectory()
        client.onREST { _, _, _, _ in
            try await Task.sleep(for: .milliseconds(150))
            let body: JSONValue = ["messages": [["id": 1, "role": "assistant", "content": "Tests passed"]]]
            return try body.encoded()
        }
        let store = setup(client, dir: dir, readsLatest: true)
        store.refreshLatest()
        #expect(await BotsTest.waitUntil { client.restCalls.count == 1 })
        store.noteConfirmedReply(profile: "ivy", sessionId: "s", text: "Tests failed")
        try await Task.sleep(for: .milliseconds(250))
        #expect(store.sessions.first?.lastResult == "Tests failed")
        store.stop()
    }

    @Test func eventNeedsUnambiguousBindingAndCompletedReply() async throws {
        let client = BotsFakeGatewayClient(), dir = BotsTest.tempDirectory()
        let sidebar: JSONValue = ["recents": ["sessions": [["id": "s", "profile": "ivy", "title": "Code", "last_active": 100,
                                                              "message_count": 2, "cwd": "/code/example"]]],
                                  "cron": ["sessions": []], "messaging": ["sessions": []]]
        client.onREST { _, _, _, _ in try sidebar.encoded() }
        let store = setup(client, dir: dir)
        store.start()
        #expect(await BotsTest.waitUntil { client.subscriberCount > 0 && store.loadState == .ready })
        client.emit(GatewayEvent(type: "session.info", sessionId: "runtime", seq: 1, payload: ["session_key": "s"]))
        client.emit(GatewayEvent(type: "message.complete", sessionId: "runtime", seq: 2,
                                 payload: ["status": "complete", "text": "Tests passed"]))
        #expect(await BotsTest.waitUntil { store.sessions.first?.lastResult == "Tests passed" })
        client.emit(GatewayEvent(type: "message.complete", sessionId: "runtime", seq: 3,
                                 payload: ["status": "complete", "text": "Tests failed"], replayed: true))
        client.emit(GatewayEvent(type: "message.complete", sessionId: "other", seq: 4,
                                 payload: ["status": "complete", "text": "Tests failed"]))
        client.emit(GatewayEvent(type: "message.complete", sessionId: "runtime", seq: 5,
                                 payload: ["status": "error", "text": "Tests failed"]))
        // The same stored id in two profiles is not a binding without a profile.
        store.recents.append(SidebarSessionRow(id: "s", profile: "wren", title: "Other", lastActive: 100, messageCount: 2))
        store.rebuild()
        client.emit(GatewayEvent(type: "session.info", sessionId: "ambiguous", seq: 6, payload: ["session_key": "s"]))
        client.emit(GatewayEvent(type: "message.complete", sessionId: "ambiguous", seq: 7,
                                 payload: ["status": "complete", "text": "Build failed"]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.sessions.first { $0.profile == "ivy" }?.lastResult == "Tests passed")
        #expect(store.sessions.first { $0.profile == "wren" }?.lastResult == nil)
        store.stop()
    }
}
