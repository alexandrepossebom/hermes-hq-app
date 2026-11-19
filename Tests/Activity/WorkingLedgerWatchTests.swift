// [working-ledger] "The session is running and adding a skill from the marketplace but it isn't showing as running in
// the session list" (a tester, 2026-11-09): the Sessions rows say Working… for every chat the gateway runs a turn in,
// by the add-on's two routes, not only for the turns this app's sockets heard.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@Suite("Working ledger: the gateway's running chats reach the Sessions rows", .serialized)
@MainActor
struct WorkingLedgerWatchTests {
    private struct Answers: Sendable {
        var ledger: [String] = []
        var serve: [String] = []
        var ledgerStatus: Int? = nil
        var serveStatus: Int? = nil
    }

    nonisolated private final class Box: Sendable {
        let state: Mutex<Answers>
        init(_ answers: Answers) { state = Mutex(answers) }
        func withLock<R>(_ body: (inout Answers) -> R) -> R { state.withLock { body(&$0) } }
    }

    private func client(_ answers: Box) -> FakeGatewayClient {
        let client = FakeGatewayClient()
        client.onRest { path, _ in
            let a = answers.withLock { $0 }
            let (ids, status): ([String], Int?) = path == WorkingLedgerWatch.ledgerPath ? (a.ledger, a.ledgerStatus)
                : path == WorkingLedgerWatch.servePath ? (a.serve, a.serveStatus) : ([], 404)
            if let status { throw HTTPError(status: status, body: "{}") }
            return encodeJSON(["sessions": .array(ids.map { ["id": .string($0), "profile": "default"] })])
        }
        return client
    }

    @Test func readsIds() {
        let json: JSONValue = ["sessions": [["id": "a", "profile": "herald"], ["id": ""], ["runtime": "r"], ["id": "b"]]]
        #expect(WorkingLedgerWatch.ids(json) == ["a", "b"])
        #expect(WorkingLedgerWatch.ids(["sessions": []]).isEmpty)
        #expect(WorkingLedgerWatch.ids(.null).isEmpty)
    }

    /// Both routes count: the gateway's ledger (a Discord message, another bot) and `hermes serve`'s own turns (one
    /// typed on the desktop, or before the app was relaunched).
    @Test func unionOfBothRoutes() async {
        let answers = Box(Answers(ledger: ["gw"], serve: ["serve"]))
        let watch = WorkingLedgerWatch(client: client(answers))
        await watch.readOnce()
        #expect(watch.storedIds == ["gw", "serve"])
        answers.withLock { $0.ledger = [] }
        await watch.readOnce()
        #expect(watch.storedIds == ["serve"])
    }

    /// An older add-on (404), or `serve/working` outside the serving process (503): that route says nothing and isn't
    /// asked again for a while; the other still counts.
    @Test func missingRouteIsLeftAlone() async {
        let answers = Box(Answers(ledger: ["gw"], serveStatus: 404))
        let fake = client(answers)
        let watch = WorkingLedgerWatch(client: fake)
        await watch.readOnce()
        #expect(watch.storedIds == ["gw"])
        await watch.readOnce()
        #expect(fake.restLog.filter { $0.path == WorkingLedgerWatch.servePath }.count == 1, "asked once, then left alone")
        #expect(fake.restLog.filter { $0.path == WorkingLedgerWatch.ledgerPath }.count == 2)
    }

    /// A read that fails for another reason (no network) keeps what was read last: no flicker of Working….
    @Test func failedReadKeepsTheLastWord() async {
        let answers = Box(Answers(ledger: ["gw"], serve: ["serve"]))
        let watch = WorkingLedgerWatch(client: client(answers))
        await watch.readOnce()
        answers.withLock { $0.ledgerStatus = 500; $0.serveStatus = 500 }
        await watch.readOnce()
        #expect(watch.storedIds == ["gw", "serve"])
        answers.withLock { $0.ledgerStatus = nil; $0.ledger = [] }
        await watch.readOnce()
        #expect(watch.storedIds == ["serve"], "the ledger's fresh word, the serve route's last one")
    }

    /// A turn this app saw end goes at once, and a read that went out before the end doesn't bring it back; a read
    /// after it does (another turn began).
    @Test func heardEndOutranksAnEarlierRead() async {
        let answers = Box(Answers(serve: ["chat"]))
        let watch = WorkingLedgerWatch(client: client(answers))
        var clock = Date(timeIntervalSince1970: 1_000)
        watch.now = { clock }
        var changes = 0
        watch.onChange = { changes += 1 }
        await watch.readOnce()
        #expect(watch.storedIds == ["chat"])
        clock += 1
        watch.turnEnded("chat")
        #expect(watch.storedIds.isEmpty)
        #expect(changes == 2)
        // A read that left before the end (its start is stamped with the clock as it goes out).
        clock -= 0.5
        await watch.readOnce()
        #expect(watch.storedIds.isEmpty, "the end outranks a read that went out before it")
        clock += 2
        await watch.readOnce()
        #expect(watch.storedIds == ["chat"], "a read after the end is believed: a new turn")
    }

    /// [roster-working] A chat whose turn ended but whose background build still runs says Working… on its row, from
    /// `subagent.roster` asked per bot (owner 2026-11-19: "it was working, but in my session list it did not say that
    /// it was working"). A turn's end doesn't clear it; the roster's next word does.
    @Test func backgroundWorkFromTheRoster() async {
        let busy = Mutex(true)
        let fake = client(Box(Answers()))
        fake.onCall { method, params in
            guard method == "subagent.roster" else { return .object([:]) }
            guard busy.withLock({ $0 }) else { return ["sessions": []] }
            return params["profile"]?.string == "hermes-hq"
                ? ["sessions": [["session_id": "desk", "subagents": 0, "background": 2],
                                ["session_id": "idle", "subagents": 0, "background": 0]]]
                : ["sessions": [["session_id": "kid", "subagents": 1, "background": 0]]]
        }
        let watch = WorkingLedgerWatch(client: fake)
        watch.profiles = { ["hermes-hq", "default", ""] }
        await watch.readOnce()
        #expect(watch.backgroundIds == ["desk", "kid"])
        #expect(watch.storedIds.isEmpty, "no turn runs")
        #expect(fake.calls("subagent.roster").count == 2, "one read per bot, the default once")
        #expect(fake.calls("subagent.roster").contains { $0.params == .object([:]) }, "the default bot asks with {}")
        watch.turnEnded("desk")
        #expect(watch.backgroundIds.contains("desk"), "the turn's end leaves its background work")
        busy.withLock { $0 = false }
        await watch.readOnce()
        #expect(watch.backgroundIds.isEmpty)
    }

    /// [roster-working] A gateway without `subagent.roster` is left alone for a while; a failed read keeps the last word.
    @Test func rosterMissingOrFailing() async {
        let mode = Mutex(0)
        let fake = client(Box(Answers()))
        fake.onCall { method, _ in
            guard method == "subagent.roster" else { return .object([:]) }
            switch mode.withLock({ $0 }) {
            case 0: return ["sessions": [["session_id": "desk", "background": 1]]]
            case 1: throw URLError(.timedOut)
            default: throw RPCError(code: -32601, message: "unknown method", data: nil)
            }
        }
        let watch = WorkingLedgerWatch(client: fake)
        watch.profiles = { ["default"] }
        await watch.readOnce()
        mode.withLock { $0 = 1 }
        await watch.readOnce()
        #expect(watch.backgroundIds == ["desk"], "a failed read keeps it")
        mode.withLock { $0 = 2 }
        await watch.readOnce()
        #expect(watch.backgroundIds.isEmpty)
        let asked = fake.calls("subagent.roster").count
        await watch.readOnce()
        #expect(fake.calls("subagent.roster").count == asked, "not asked again for a while")
    }

    /// Wanted: it reads now and keeps reading; not wanted: the reads stop, and stop clears.
    @Test func readsOnlyWhileWanted() async {
        let answers = Box(Answers(ledger: ["gw"]))
        let fake = client(answers)
        let watch = WorkingLedgerWatch(client: fake)
        watch.interval = Duration.milliseconds(30)
        watch.setWanted(true)
        #expect(await waitUntil { watch.storedIds == ["gw"] })
        #expect(await waitUntil { fake.restLog.count >= 6 }, "it keeps reading")
        watch.setWanted(false)
        try? await Task.sleep(for: Duration.milliseconds(80))
        let settled = fake.restLog.count
        try? await Task.sleep(for: Duration.milliseconds(120))
        #expect(fake.restLog.count == settled, "no reads while unwanted")
        #expect(watch.storedIds == ["gw"], "kept until it's read again")
        watch.stop()
        #expect(watch.storedIds.isEmpty)
    }
}
