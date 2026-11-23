import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

/// [threads] §9: typed words a bot's own chat cannot take now go on in a thread instead of coming back.
@Suite("Threads: a busy chat's words go on in a thread (3x-threads §9)", .serialized)
@MainActor
struct ThreadBusySendTests {
    /// What the app model's hook was handed, and what it answers.
    private final class Taker {
        var took: [(text: String, localId: String)] = []
        var answer = true
    }

    private func chat(_ h: ChatHarness, _ taker: Taker) -> LiveChatSession {
        let s = h.make()
        s.threadAfter = .milliseconds(150)
        s.silenceTimeout = .milliseconds(50)       // the wait must not trip the silence watchdog
        s.onBusyThread = { text, localId in
            taker.took.append((text, localId))
            return taker.answer
        }
        return s
    }

    nonisolated private static func owned(_ method: String) -> JSONValue {
        method == "session.active_list" ? ["sessions": []] : [:]
    }

    @Test func wordsAnotherRunKeepsOutGoOnInAThread() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let taker = Taker()
        let s = chat(h, taker)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw LiveChatSessionTests.ownedRefusal("cli") }
            return Self.owned(method)
        }
        s.send("What time is the flight?")
        #expect(await waitUntil { s.ownerWaitNotice == .backgroundTask })   // it waits for the chat first
        let bubble = h.lastUser?.id
        #expect(await waitUntil(timeout: .seconds(3)) { !taker.took.isEmpty })
        #expect(taker.took.count == 1)
        #expect(taker.took.first?.text == "What time is the flight?")
        #expect(taker.took.first?.localId == bubble, "the thread's seed leaves this bubble out")
        #expect(!s.messages.contains { $0.role == .user && $0.plainText == "What time is the flight?" })
        #expect(h.drafts.isEmpty, "nothing is handed back")
        #expect(s.sendFailure == nil, "no Couldn’t Send card")
        #expect(s.ownerWaitNotice == nil)
        #expect(!s.isRunning)
        #expect(h.notices == [ThreadRules.busyNotice])
    }

    @Test func busyPastItsWindowGoesOnInAThread() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let taker = Taker()
        let s = chat(h, taker)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw RPCError(code: 4009, message: "session busy", data: nil) }
            return [:]
        }
        s.send("Are you there?")
        #expect(await waitUntil(timeout: .seconds(3)) { !taker.took.isEmpty })
        #expect(h.client.calls("prompt.submit").count >= 3, "the busy window is tried out first")
        #expect(taker.took.first?.text == "Are you there?")
        #expect(h.drafts.isEmpty)
        #expect(s.sendFailure == nil)
        #expect(!s.isRunning)
    }

    @Test func aChatThatLetsGoInTimeTakesTheWordsItself() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let taker = Taker()
        let s = chat(h, taker)
        s.threadAfter = .seconds(3)
        #expect(await h.open())
        let n = Mutex(0)
        h.client.onCall { method, _ in
            guard method == "prompt.submit" else { return Self.owned(method) }
            if n.withLock({ $0 += 1; return $0 }) <= 3 { throw LiveChatSessionTests.ownedRefusal("cli") }
            return ["status": "streaming", "user_row_id": 93]
        }
        let before = s.acceptedSends
        s.send("hi")
        #expect(await waitUntil(timeout: .seconds(3)) { h.lastUser?.rowId == 93 })
        #expect(taker.took.isEmpty)
        #expect(s.acceptedSends == before + 1)
        #expect(h.notices.isEmpty)
    }

    @Test func withNoThreadToTakeThemTheWordsComeBackAsBefore() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let taker = Taker()
        taker.answer = false
        let s = chat(h, taker)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw LiveChatSessionTests.ownedRefusal("cli") }
            return Self.owned(method)
        }
        s.send("hi")
        #expect(await waitUntil(timeout: .seconds(3)) { !h.drafts.isEmpty })
        #expect(taker.took.count == 1)
        #expect(h.drafts.first?.0 == "hi")
        #expect(s.sendFailure != nil)
        #expect(h.notices.isEmpty)
    }

    @Test func stopWhileItWaitsStartsNoThread() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let taker = Taker()
        let s = chat(h, taker)
        s.threadAfter = .seconds(2)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw LiveChatSessionTests.ownedRefusal("cli") }
            return Self.owned(method)
        }
        s.send("hi")
        #expect(await waitUntil { s.ownerWaitNotice == .backgroundTask })
        s.stop()
        #expect(await waitUntil(timeout: .seconds(3)) { !s.messages.contains { $0.role == .user && $0.plainText == "hi" } })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(taker.took.isEmpty)
    }

    /// A chat with no hook (Sessions, rooms, task chats) is unchanged: the long wait, then the words back.
    @Test func aChatWithNoThreadsWaitsAsBefore() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.threadAfter = .milliseconds(50)
        s.ownerWaitWindow = .milliseconds(600)
        s.silenceTimeout = .milliseconds(50)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw LiveChatSessionTests.ownedRefusal("cli") }
            return Self.owned(method)
        }
        s.send("hi")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.drafts.isEmpty, "still waiting well past threadAfter")
        #expect(h.lastUser?.isPending == true)
        #expect(await waitUntil(timeout: .seconds(3)) { !h.drafts.isEmpty })
    }

    @Test func theSameThreadTakesTheNextWordsUntilTheChatTakesASend() {
        #expect(ThreadRules.takesNextBusySend(heldAt: 4, accepted: 4, live: true, problem: false))
        #expect(!ThreadRules.takesNextBusySend(heldAt: 4, accepted: 5, live: true, problem: false), "the chat took a send since")
        #expect(!ThreadRules.takesNextBusySend(heldAt: 4, accepted: 4, live: false, problem: false))
        #expect(!ThreadRules.takesNextBusySend(heldAt: 4, accepted: 4, live: true, problem: true))
        #expect(!ThreadRules.takesNextBusySend(heldAt: nil, accepted: 0, live: true, problem: false))
    }

    /// Found in the app's walk: hung by time, the thread sat above the bot's last answer and folded when it finished.
    @Test func itHangsUnderTheNewestThingSaidAndStaysOpen() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let asked = ChatMessage(id: "u1", role: .user, parts: [.text("Morning. Anything for me?")], timestamp: t0, rowId: 1)
        let said = ChatMessage(id: "a1", role: .assistant, parts: [.text("Nothing urgent today.")], timestamp: t0 + 5, rowId: 2)
        let bubble = ChatMessage(id: "local-9", role: .user, parts: [.text("What time is the flight?")], timestamp: t0 + 60)
        let anchor = ThreadRules.busyAnchor(in: [asked, said, bubble], leavingOut: "local-9")
        #expect(anchor?.id == "a1", "under the bot's last answer, not the bubble that leaves and not your older message")
        #expect(ThreadRules.busyAnchor(in: [bubble], leavingOut: "local-9") == nil)

        let reply = ChatMessage(id: "t2", role: .assistant, parts: [.text("The flight leaves at 9:40.")], timestamp: t0 + 70)
        let thread = ChatThread(id: "th", storedId: "s-thread", title: nil, startedAt: t0 + 66, anchorMessageId: anchor?.id,
                                anchorRow: anchor?.rowId, messages: [bubble, reply], running: false, problem: nil, scope: "x")
        let main = [asked, said]            // the bubble has left the main chat
        let index = ThreadRules.anchorIndex(of: thread, in: main)
        #expect(index == 1)
        #expect(ThreadRules.isOpen(thread, anchor: index ?? 0, in: main), "finished, it is still the newest thing: open")
        // Hung by time it would be under "Morning…", with the bot's answer after it: folded.
        var byTime = thread
        byTime.anchorMessageId = nil
        byTime.anchorRow = nil
        let old = ThreadRules.anchorIndex(of: byTime, in: main)
        #expect(old == 0)
        #expect(!ThreadRules.isOpen(byTime, anchor: old ?? 0, in: main))
    }

    @Test func aThreadsRefusedWordsComeBackToTheChatTheyWereTypedIn() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        s.threadSendCameBack("What time is the flight?", reason: "Hermes is at the active session limit (4/4).")
        #expect(h.drafts.first?.0 == "What time is the flight?")
        #expect(h.drafts.first?.1 == "Hermes is at the active session limit (4/4).")
        #expect(s.sendFailure != nil)
    }
}
