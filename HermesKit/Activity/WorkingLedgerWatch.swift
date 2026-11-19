// [working-ledger] Which chats run a turn right now, by the gateway's own word, for the Sessions list (tester,
// 2026-11-09: "The session is running and adding a skill from the marketplace but it isn't showing as running in the
// session list"). The list only knew the turns this app's sockets heard: a turn the messaging gateway runs (another
// bot's message, Telegram, Discord, a job's hand-off) said Working… only while its chat was open, and stopped saying it
// the moment you went back to the list; one started on the desktop, another phone, or before the app was relaunched
// never said it at all. The Hermes HQ add-on names them all: `GET sessions/working` (0.9.6+, the gateway's durable
// ledger) and `GET serve/working` (0.9.20+, the turns `hermes serve` runs in memory). While a list is on screen and the
// app is in front, both are read every few seconds; a route the add-on lacks is left alone for a while.

import Foundation

@MainActor final class WorkingLedgerWatch {
    nonisolated static let ledgerPath = ExternalTurn.ledgerPath
    nonisolated static let servePath = "/api/plugins/hermes-hq-push/serve/working"

    private let client: any GatewayClient
    /// How often the routes are read while wanted (tests shorten it).
    var interval: Duration = .seconds(5)
    /// A route that answered 404 (an older add-on) or 503 (`serve/working` outside the serving process) is asked again
    /// after this long.
    var missingRecheck: TimeInterval = 600
    var now: () -> Date = { Date() }
    /// The stored ids changed (the Sessions rows' Working… follows).
    var onChange: (() -> Void)?

    /// Stored ids the gateway runs a turn in, as last read.
    private(set) var storedIds: Set<String> = []
    /// [roster-working] The bots whose chats `subagent.roster` is asked about ("" or "default" = the default bot).
    var profiles: () -> [String] = { [] }
    /// [roster-working] Stored ids of chats holding a running background command or helper, by `subagent.roster`
    /// (Hermes core, the call Hermes Desktop's sidebar reads). A turn that ended leaves its background build running:
    /// the chat's own capsule said so, its row didn't (owner 2026-11-19, "it was working, but in my session list it
    /// did not say that it was working"). Not cut by `turnEnded`: the turn's end doesn't end its background work.
    private(set) var backgroundIds: Set<String> = []
    private var backgroundBy: [String: Set<String>] = [:]
    private var rosterMissingSince: Date?
    private var wanted = false
    private var loop: Task<Void, Never>?
    private var missingSince: [String: Date] = [:]
    /// Ids whose turn this app saw end, with when: a read that went out before then still names them, and is not believed.
    private var endedAt: [String: Date] = [:]

    init(client: any GatewayClient) { self.client = client }

    isolated deinit { loop?.cancel() }

    /// A list is on screen with the app in front (true), or not: the reads start at once, or stop. What was read is
    /// kept meanwhile and read again as soon as it is wanted again.
    func setWanted(_ on: Bool) {
        guard wanted != on else { return }
        wanted = on
        loop?.cancel()
        loop = nil
        guard on else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.wanted else { return }
                await self.readOnce()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    /// A turn of this app's ended in this chat (its own events said so): the row stops saying Working… now, not at the
    /// next read, and a read already in the air doesn't bring it back.
    func turnEnded(_ storedId: String) {
        endedAt[storedId] = now()
        if storedIds.remove(storedId) != nil { onChange?() }
    }

    func stop() {
        wanted = false
        loop?.cancel()
        loop = nil
        backgroundBy = [:]
        if !storedIds.isEmpty || !backgroundIds.isEmpty { storedIds = []; backgroundIds = []; onChange?() }
    }

    /// [roster-working] One `subagent.roster` read per bot: the chats holding a running background command or helper.
    /// A failed read keeps that bot's last word; a gateway without the call (-32601) is asked again after a while.
    private func readRoster() async {
        if let since = rosterMissingSince, now().timeIntervalSince(since) < missingRecheck { return }
        let names = Array(Set(profiles().map { $0.isEmpty ? "default" : $0 })).sorted()
        guard !names.isEmpty else { return }
        var next = backgroundBy.filter { names.contains($0.key) }
        for name in names {
            let params: JSONValue = name == "default" ? .object([:]) : .object(["profile": .string(name)])
            do {
                let answer = try await client.call("subagent.roster", params, timeout: .seconds(10))
                rosterMissingSince = nil
                next[name] = Self.rosterIds(answer)
            } catch let error as RPCError where error.code == -32601 {
                AppLog.trace("sessions", "working ledger: this gateway has no subagent.roster, asked again later")
                rosterMissingSince = now()
                next = [:]
                break
            } catch {
                continue
            }
            guard !Task.isCancelled else { return }
        }
        backgroundBy = next
        let ids = next.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        guard ids != backgroundIds else { return }
        AppLog.trace("sessions", "working ledger: \(ids.count) chat(s) with background work")
        backgroundIds = ids
        onChange?()
    }

    /// `{"sessions": [{"session_id", "subagents", "background"}]}` → the stored ids with either still running.
    nonisolated static func rosterIds(_ json: JSONValue) -> Set<String> {
        var out = Set<String>()
        for row in json["sessions"]?.array ?? [] {
            guard let id = row["session_id"]?.string, !id.isEmpty else { continue }
            let count = { (key: String) -> Double in if case .number(let n)? = row[key] { return n } else { return 0 } }
            if count("background") > 0 || count("subagents") > 0 { out.insert(id) }
        }
        return out
    }

    /// One read of both routes. Nil from a route means it wasn't read (missing, or failed): what it said last stays.
    func readOnce() async {
        let started = now()
        async let ledger = read(Self.ledgerPath)
        async let serve = read(Self.servePath)
        async let roster: Void = readRoster()
        let (fromLedger, fromServe, _) = await (ledger, serve, roster)
        guard !Task.isCancelled else { return }
        if fromLedger == nil && fromServe == nil { return }
        var next = (fromLedger ?? lastBy[Self.ledgerPath] ?? []).union(fromServe ?? lastBy[Self.servePath] ?? [])
        if let fromLedger { lastBy[Self.ledgerPath] = fromLedger }
        if let fromServe { lastBy[Self.servePath] = fromServe }
        // An end this app heard after the read went out outranks the read.
        endedAt = endedAt.filter { now().timeIntervalSince($0.value) < 60 }
        next = next.filter { id in endedAt[id].map { $0 < started } ?? true }
        guard next != storedIds else { return }
        AppLog.trace("sessions", "working ledger: \(next.count) chat(s) running")
        storedIds = next
        onChange?()
    }

    private var lastBy: [String: Set<String>] = [:]

    private func read(_ path: String) async -> Set<String>? {
        if let since = missingSince[path], now().timeIntervalSince(since) < missingRecheck { return nil }
        do {
            let json = try await PagesREST.json(client, "GET", path, timeout: 10)
            missingSince[path] = nil
            return Self.ids(json)
        } catch {
            let status = PagesREST.status(error)
            if status == 404 || status == 503 {
                if missingSince[path] == nil { AppLog.trace("sessions", "working ledger: \(path) answered \(status ?? 0), asked again later") }
                missingSince[path] = now()
                lastBy[path] = nil
                return []
            }
            return nil
        }
    }

    /// The stored ids a `{"sessions": [{"id": …}]}` answer names.
    nonisolated static func ids(_ json: JSONValue) -> Set<String> {
        Set((json["sessions"]?.array ?? []).compactMap { row in row["id"]?.string.flatMap { $0.isEmpty ? nil : $0 } })
    }
}
