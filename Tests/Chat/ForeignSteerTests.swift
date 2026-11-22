// [foreign-steer] A message another device sent into a running reply shows while the reply still runs (a tester
// 2026-11-19: it showed on the sending iPhone at once, on the Mac only after the reply ended).

import Foundation
import Testing
@testable import HermesHQNative

private func texts(_ m: ChatMessage) -> String {
    m.parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
}

@MainActor @Suite("Chat · another device's message into a running reply", .serialized)
struct ForeignSteerTests {
    /// A chat whose reply to "first" is streaming "Working on it".
    private func busy(activate: @escaping @Sendable () -> JSONValue = { [:] }) async throws -> (ChatHarness, LiveChatSession) {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, params in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.redirect": return ["status": "redirected", "text": params["text"] ?? ""]
            case "session.activate": return activate()
            default: return [:]
            }
        }
        s.send("first")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Working on it"])])
        return (h, s)
    }

    private func tail(_ s: LiveChatSession, _ n: Int) -> [String] {
        s.messages.suffix(n).map { "\($0.role == .user ? "user" : "bot"): \(texts($0))" }
    }

    private func snapshot(_ steers: [String], queued: String? = nil) -> JSONValue {
        var root: [String: JSONValue] = ["running": true,
                                         "inflight": ["user": "first", "assistant": "Working on it",
                                                      "corrections": .array(steers.map { .string($0) })]]
        if let queued { root["queued"] = ["user": .string(queued)] }
        return .object(root)
    }

    @Test func theMessageShowsUnderTheReplyAndTheRestLandsBelowIt() async throws {
        let (h, s) = try await busy()
        s.applyForeignSteers(snapshot(["also check the README"]))
        #expect(tail(s, 3) == ["user: first", "bot: Working on it", "user: also check the README"])
        await h.emit([h.event("message.delta", ["text": "Checked the README too."])])
        #expect(tail(s, 4) == ["user: first", "bot: Working on it", "user: also check the README", "bot: Checked the README too."])
        // The same answer again draws nothing more.
        s.applyForeignSteers(snapshot(["also check the README"]))
        #expect(tail(s, 4) == ["user: first", "bot: Working on it", "user: also check the README", "bot: Checked the README too."])
        // A second message, and the same words sent again, are bubbles of their own.
        s.applyForeignSteers(snapshot(["also check the README", "and the tests", "and the tests"]))
        #expect(tail(s, 3) == ["bot: Checked the README too.", "user: and the tests", "user: and the tests"])
        #expect(s.isRunning)
    }

    @Test func aMessageThisDeviceSentIsNotDrawnTwice() async throws {
        let (h, s) = try await busy()
        s.send("also check the README")
        #expect(await waitUntil { h.client.calls("session.redirect").count == 1 })
        s.applyForeignSteers(snapshot(["also check the README"]))
        #expect(tail(s, 3) == ["user: first", "bot: Working on it", "user: also check the README"])
    }

    @Test func aMessageHermesHoldsForAfterTheReplyShowsToo() async throws {
        let (_, s) = try await busy()
        s.applyForeignSteers(snapshot([], queued: "then deploy it"))
        #expect(tail(s, 2) == ["bot: Working on it", "user: then deploy it"])
        s.applyForeignSteers(snapshot([], queued: "then deploy it"))
        #expect(tail(s, 2) == ["bot: Working on it", "user: then deploy it"])
    }

    @Test func aChangeOnTheGatewayWhileTheReplyRunsAsksForTheTurnsRecord() async throws {
        let (h, s) = try await busy { ["running": true, "inflight": ["user": "first", "assistant": "Working on it",
                                                                     "corrections": ["stop at the second file"]]] }
        await h.emit([h.event("sessions.changed", sid: "")])
        #expect(await waitUntil { s.messages.last.map(texts) == "stop at the second file" })
        #expect(h.client.calls("session.activate").last?.params["omit_messages"] == true)
        #expect(s.isRunning)
    }

    @Test func whichSteersAreMissing() {
        let c = InflightCorrections(["corrections": ["one", "two", "two"]])!
        #expect(ForeignSteerRules.missing(c, shown: []) == ["one", "two", "two"])
        #expect(ForeignSteerRules.missing(c, shown: ["one"]) == ["two", "two"])
        #expect(ForeignSteerRules.missing(c, shown: ["one", "two"]) == ["two"])
        #expect(ForeignSteerRules.missing(c, shown: ["one", "two", "two"]).isEmpty)
        // Hermes joined two steers into one stored row.
        let joined = "one\n\n\(InflightCorrections.joinMarker)\ntwo"
        let pair = InflightCorrections(["corrections": ["one", "two"]])!
        #expect(ForeignSteerRules.missing(pair, shown: [joined]).isEmpty)
        #expect(ForeignSteerRules.missing(pair, shown: ["something else", joined]).isEmpty)
    }
}
