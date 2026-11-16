// [live-status] Which chats work and which wait on a person, by the gateway's own live-session registry
// (`session.active_list`, Hermes core: no add-on), for chats this device isn't attached to.
//
// The rows only knew what this app's own sockets heard. An approval or a question reaches a device only for a chat it
// has resumed, so a bot waiting for an approval asked on the person's other device (or before this app was opened)
// showed nothing on its row or on its chat's row; and a turn started elsewhere wasn't known to be running, so the
// activity it stored made its chat unread while it still worked (a tester, 2026-11-15: "a bot waiting for an action
// approval sometimes has no attention dot … a blue dot sometimes appears next to a bot that is still working"). Hermes
// Desktop reads the same call for its sidebar (`use-background-sync.ts`): on every `sessions.changed`, with a slow
// poll behind it. Here: on `sessions.changed` (at most every `changeGap`), every `busyGap` while something works or
// waits (a request opens without any stored change to announce it), and every `idleGap` otherwise.
//
// Each row is `{session_key: stored id, status: "waiting" | "working" | "starting" | "idle"}`. "waiting" is any open
// server→client request, the automatic ones too (a page or terminal read a client answers in milliseconds), so a chat
// counts as waiting on a person only once two reads in a row said so. What it asks isn't told: the row says
// "Waiting for you" (`NeedsInput.waiting`) until the chat is opened and its own card says more.

import Foundation

@MainActor final class LiveStatusWatch {
    private let client: any GatewayClient
    var changeGap: Duration = .seconds(3)
    var busyGap: Duration = .seconds(10)
    var idleGap: Duration = .seconds(30)
    /// How soon a first "waiting" is checked again.
    var confirmGap: Duration = .seconds(2)
    /// A gateway without the call is asked again after this long.
    var missingRecheck: Duration = .seconds(600)
    /// The sets changed.
    var onChange: (() -> Void)?

    /// Stored ids of chats running a turn (those waiting on a person included: their turn is held, not over).
    private(set) var working: Set<String> = []
    /// Stored ids of chats waiting on a person.
    private(set) var waiting: Set<String> = []

    private var wanted = false
    private var loop: Task<Void, Never>?
    private var reading = false
    private var dirty = false
    private var lastRead: ContinuousClock.Instant?
    private var missingSince: ContinuousClock.Instant?
    /// Ids the last read called waiting (one more read confirms them).
    private var waitingOnce: Set<String> = []
    /// Ids whose turn this app saw end, with when: a read that went out before then still names them.
    private var endedAt: [String: ContinuousClock.Instant] = [:]

    init(client: any GatewayClient) { self.client = client }

    isolated deinit { loop?.cancel() }

    /// The app is in front (true) or not: the reads start at once, or stop. What was read is kept meanwhile.
    func setWanted(_ on: Bool) {
        guard wanted != on else { return }
        wanted = on
        loop?.cancel()
        loop = nil
        guard on else { return }
        dirty = true
        arm()
    }

    /// The gateway said its chats changed: read again soon.
    func sessionsChanged() {
        guard wanted else { return }
        dirty = true
        arm()
    }

    /// A turn of this app's ended in this chat: its rows stop saying so now, and a read already in the air doesn't
    /// bring it back.
    func turnEnded(_ storedId: String) {
        endedAt[storedId] = .now
        waitingOnce.remove(storedId)
        let had = working.remove(storedId) != nil
        if waiting.remove(storedId) != nil || had { onChange?() }
    }

    func stop() {
        wanted = false
        loop?.cancel()
        loop = nil
        waitingOnce = []
        if !working.isEmpty || !waiting.isEmpty {
            working = []
            waiting = []
            onChange?()
        }
    }

    /// The next read: after the change gap when something changed, sooner to confirm a first "waiting", else at the
    /// busy or idle pace.
    private func arm() {
        loop?.cancel()
        loop = nil
        guard wanted else { return }
        let pace = !waitingOnce.subtracting(waiting).isEmpty ? confirmGap : dirty ? changeGap : (working.isEmpty ? idleGap : busyGap)
        let since = lastRead.map { ContinuousClock.now - $0 } ?? pace
        let wait = max(.zero, pace - since)
        loop = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.wanted else { return }
            self.loop = nil
            await self.readOnce()
            self.arm()
        }
    }

    /// One read. A failed one keeps what was known.
    func readOnce() async {
        guard !reading else { return }
        let started = ContinuousClock.now
        lastRead = started
        dirty = false
        if let since = missingSince, started - since < missingRecheck { return }
        reading = true
        defer { reading = false }
        let result: JSONValue
        do {
            result = try await client.call("session.active_list", .object([:]), timeout: .seconds(15))
        } catch let error as RPCError where error.code == -32601 {
            AppLog.trace("sessions", "live status: this gateway has no session.active_list, asked again later")
            missingSince = .now
            return
        } catch {
            return
        }
        missingSince = nil
        guard !Task.isCancelled else { return }
        apply(Self.statuses(result), started: started)
    }

    /// `{"sessions": [{session_key, status}]}` → stored id → status. A chat held by two runtimes takes the busier word.
    nonisolated static func statuses(_ result: JSONValue) -> [String: String] {
        let rank = ["waiting": 3, "working": 2, "starting": 1]
        var out: [String: String] = [:]
        for row in result["sessions"]?.array ?? [] {
            guard let id = row["session_key"]?.string, !id.isEmpty, let status = row["status"]?.string else { continue }
            if (rank[status] ?? 0) > (rank[out[id] ?? ""] ?? 0) || out[id] == nil { out[id] = status }
        }
        return out
    }

    func apply(_ statuses: [String: String], started: ContinuousClock.Instant = .now) {
        endedAt = endedAt.filter { ContinuousClock.now - $0.value < .seconds(60) }
        // An end this app heard after the read went out outranks the read.
        let live = statuses.filter { id, _ in endedAt[id].map { $0 < started } ?? true }
        let saidWaiting = Set(live.filter { $0.value == "waiting" }.keys)
        let nextWaiting = saidWaiting.intersection(waitingOnce.union(waiting))
        let nextWorking = Set(live.filter { $0.value == "working" || $0.value == "waiting" }.keys)
        waitingOnce = saidWaiting
        guard nextWaiting != waiting || nextWorking != working else { return }
        AppLog.trace("sessions", "live status: \(nextWorking.count) chat(s) working, \(nextWaiting.count) waiting on a person")
        waiting = nextWaiting
        working = nextWorking
        onChange?()
    }
}
