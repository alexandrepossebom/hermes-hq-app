// [read-sync] One stand-in Hermes for two devices: it keeps each chat's read watermark exactly as Hermes does
// (`hermes_state_sessions.py`: `PATCH unread:false` stamps `last_read_at` with the gateway's clock, `unread:true` sets
// 0, never touched is NULL; a row is unread when its activity is later than a watermark that exists), lists the
// ordinary chats in the sidebar with `unread` and `last_read_at`, keeps each bot's own chat out of every list (hidden)
// and describes it in the roster without the watermark, answers `GET /api/sessions/{id}` with the chat's own row, and
// tells every connected device `sessions.changed` when a watermark is written.

import Foundation
import Testing
@testable import HermesHQNative

nonisolated final class ReadSyncGateway: @unchecked Sendable {
    struct Chat: Sendable {
        var id: String
        var profile: String
        var lastActive: Double
        var count: Int
        /// `last_read_at`: nil = NULL.
        var readAt: Double?
        /// A bot's own chat ("Bot Chat", hidden): in the roster, never in the sidebar.
        var botChat = false
        var messages: [JSONValue] = []
    }

    private let lock = NSLock()
    private var chats: [String: Chat] = [:]
    private var order: [String] = []
    private var devices: [BotsFakeGatewayClient] = []
    private var now = ReadSyncGateway.t0
    private var patchLog: [(id: String, unread: Bool)] = []
    private var rowReadLog: [String] = []
    private var liveLog = 0

    static let t0 = 1_791_000_000.0

    /// PATCHes fail as an unreachable gateway does (the reads still answer).
    var dropsWrites: Bool { get { lock.withLock { _dropsWrites } } set { lock.withLock { _dropsWrites = newValue } } }
    private var _dropsWrites = false
    /// PATCHes are refused with this status (409: an older Hermes while its gateway owns the profile).
    var refusesWrites: Int? { get { lock.withLock { _refuses } } set { lock.withLock { _refuses = newValue } } }
    private var _refuses: Int?
    /// A Hermes older than read state: rows say neither `unread` nor `last_read_at`.
    var tracksReads: Bool { get { lock.withLock { _tracks } } set { lock.withLock { _tracks = newValue } } }
    private var _tracks = true
    /// `session.active_list`'s answer: stored id → status.
    var live: [String: String] { get { lock.withLock { _live } } set { lock.withLock { _live = newValue } } }
    private var _live: [String: String] = [:]

    // MARK: Scripting

    func add(_ chat: Chat) { lock.withLock { chats[chat.id] = chat; order.append(chat.id) } }

    func chat(_ id: String) -> Chat? { lock.withLock { chats[id] } }

    /// The gateway's clock moves on.
    func pass(_ seconds: Double) { lock.withLock { now += seconds } }

    /// New rows land in a chat: its activity is the gateway's clock, `seconds` later than before.
    func activity(_ id: String, rows: Int = 2, after seconds: Double = 60, messages: [JSONValue] = []) {
        lock.withLock {
            now += seconds
            chats[id]?.lastActive = now
            chats[id]?.count += rows
            chats[id]?.messages += messages
        }
    }

    var patches: [(id: String, unread: Bool)] { lock.withLock { patchLog } }
    func patches(_ id: String) -> Int { patches.filter { $0.id == id }.count }
    /// `GET /api/sessions/{id}` reads (the watermark reads), by chat.
    var rowReads: [String] { lock.withLock { rowReadLog } }
    var liveReads: Int { lock.withLock { liveLog } }

    func changed() {
        let all = lock.withLock { devices }
        for device in all { device.emit("sessions.changed") }
    }

    // MARK: A device

    func device() -> BotsFakeGatewayClient {
        let client = BotsFakeGatewayClient(latestReady: ["change_events": true])
        lock.withLock { devices.append(client) }
        client.on("profiles.list") { [weak self] _ in self?.roster() ?? BotsTest.profilesResult([]) }
        client.on("session.active_list") { [weak self] _ in
            guard let self else { return ["sessions": []] }
            let rows = self.lock.withLock { () -> [JSONValue] in
                self.liveLog += 1
                return self._live.sorted { $0.key < $1.key }.map { ["id": .string("rt-\($0.key)"), "session_key": .string($0.key), "status": .string($0.value)] }
            }
            return ["sessions": .array(rows)]
        }
        client.onREST { [weak self] method, path, _, body in
            guard let self else { throw HTTPError(status: 503, body: nil) }
            return try self.rest(method, path, body)
        }
        return client
    }

    private func roster() -> JSONValue {
        let rows = lock.withLock { () -> [JSONValue] in
            order.compactMap { chats[$0] }.filter(\.botChat).map { chat in
                BotsTest.row(chat.profile, canonical: BotsTest.session(chat.id, preview: "hello", lastActive: chat.lastActive, count: chat.count))
            }
        }
        return BotsTest.profilesResult(rows)
    }

    private func row(_ chat: Chat) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(chat.id), "profile": .string(chat.profile), "title": chat.botChat ? "Bot Chat" : "Chat",
                                      "preview": "hi", "last_active": .number(chat.lastActive), "started_at": .number(Self.t0 - 3600),
                                      "message_count": .number(Double(chat.count)), "source": "desktop", "pinned": false,
                                      "hidden": .bool(chat.botChat), "is_active": false]
        if _tracks {
            o["last_read_at"] = chat.readAt.map(JSONValue.number) ?? .null
            o["unread"] = .bool(chat.readAt.map { chat.lastActive > $0 } ?? false)
        }
        return .object(o)
    }

    private func rest(_ method: String, _ path: String, _ body: Data?) throws -> Data {
        if path == "/api/profiles/sessions/sidebar" {
            let rows = lock.withLock { order.compactMap { chats[$0] }.filter { !$0.botChat }.map(row) }
            let root: JSONValue = ["recents": ["sessions": .array(rows)], "cron": ["sessions": []], "messaging": ["sessions": []]]
            return try root.encoded()
        }
        guard path.hasPrefix("/api/sessions/") else { throw HTTPError(status: 404, body: nil) }
        let parts = path.dropFirst("/api/sessions/".count).split(separator: "/").map(String.init)
        guard let id = parts.first else { throw HTTPError(status: 404, body: nil) }
        if parts.count == 2, parts[1] == "mutation-snapshot" { throw HTTPError(status: 404, body: nil) }      // no revision fence
        if parts.count == 2, parts[1] == "messages" {
            let rows = lock.withLock { chats[id]?.messages ?? [] }
            return try (["messages": .array(rows)] as JSONValue).encoded()
        }
        guard parts.count == 1 else { throw HTTPError(status: 404, body: nil) }
        if method == "PATCH" {
            let unread = (try? JSONValue.parse(body ?? Data()))?["unread"]?.bool
            let (drops, refuses) = lock.withLock { (_dropsWrites, _refuses) }
            if drops { throw URLError(.notConnectedToInternet) }
            if let refuses { throw HTTPError(status: refuses, body: #"{"detail":"Exclusive maintenance refused"}"#) }
            guard let unread, lock.withLock({ chats[id] != nil }) else { throw HTTPError(status: 404, body: nil) }
            lock.withLock {
                chats[id]?.readAt = unread ? 0 : now
                patchLog.append((id, unread))
            }
            changed()
            return try (["ok": true, "unread": .bool(unread)] as JSONValue).encoded()
        }
        guard let chat = lock.withLock({ () -> Chat? in
            rowReadLog.append(id)
            return chats[id]
        }) else { throw HTTPError(status: 404, body: nil) }
        return try row(chat).encoded()
    }
}
