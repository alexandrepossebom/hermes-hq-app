// [tile-chats] A tile's own chat (owner 2026-11-21: "an easy way to be able to open the session attached to a Tile and I
// need to be sure that Tile sessions are hidden from everywhere else"): known by how the app's ask begins, left out of
// every list, hidden on the gateway once when an older app made it in the open, and the tile keeps the chat its bot last
// worked on it in.

import Foundation
import Testing
@testable import HermesHQNative

@Suite(.serialized) struct TileChatsTests {
    // MARK: Knowing a tile chat

    @Test func theAppsAsksForATileAreTileChats() {
        // Each ask the app makes for a tile starts with one of the openings the lists know (a prompt reworded here
        // without the openings following would leave its chats in every list).
        for prompt in [TileMaker.prompt("Revenue this week"),
                       TileMaker.changePrompt(path: "/home/h/dashboards/revenue.html", what: "make it a bar chart"),
                       TileMaker.rolledBackPrompt(path: "/home/h/dashboards/revenue.html", name: "Revenue", version: 2)] {
            #expect(TileChats.isTileChat(preview: prompt), "\(prompt.prefix(60))")
            // As the gateway shows it: the first message's head, one line, 60 characters and "...".
            let preview = String(prompt.replacingOccurrences(of: "\n", with: " ").prefix(60)) + "..."
            #expect(TileChats.isTileChat(preview: preview), "\(preview)")
        }
    }

    @Test func ordinaryChatsAreNot() {
        for preview in [nil, "", "   ", "hello", "Make me a dashboard for revenue", "Can you change my tile?",
                        "What's on my Hermes HQ Dashboard tile?", "Reply with exactly OK"] {
            #expect(!TileChats.isTileChat(preview: preview), "\(preview ?? "nil")")
        }
        #expect(TileChats.isTileChat(preview: "  Make me a live tile for my Hermes HQ Dashboard showing: x"), "spaces before")
    }

    @Test func noListShowsATileChat() {
        let tile = SidebarSessionRow(id: "t1", profile: "otto", title: "Weekly revenue dashboard",
                                     preview: "Make me a live tile for my Hermes HQ Dashboard showing: Rev...")
        let change = SidebarSessionRow(id: "t2", profile: "otto", title: "Add weekly tcv total",
                                       preview: "Change my Hermes HQ Dashboard tile /home/h/tcv.html: add the...")
        let plain = SidebarSessionRow(id: "c1", profile: "otto", title: "Revenue question", preview: "How was revenue this week?")
        #expect(SessionRules.isBotChat(tile) && SessionRules.isBotChat(change))
        #expect(!SessionRules.isBotChat(plain))
        // Bot Info's recent chats keep the same rule.
        #expect(BotStore.recentRows([tile, change, plain], profile: "otto", exclude: [], limit: 10).map(\.id) == ["c1"])
    }

    @Test func searchLeavesTileChatsOut() throws {
        // The gateway's search answers hidden chats too: a hit with a tile's first message (its row's preview) or the
        // gateway's hidden flag is left out; an ordinary hit stays.
        let data = try JSONValue.object(["results": .array([
            ["session_id": "t1", "title": "Weekly revenue", "snippet": "revenue", "preview": "Make me a live tile for my Hermes HQ Dashboard showing: Rev..."],
            ["session_id": "t2", "snippet": "revenue", "first_message": "Change my Hermes HQ Dashboard tile /home/h/rev.html: bars"],
            ["session_id": "h1", "snippet": "revenue", "hidden": true],
            ["session_id": "c1", "title": "Revenue question", "snippet": "revenue", "preview": "How was revenue this week?"],
        ])]).encoded()
        let hits = try SessionSearchHit.decode(data, profile: "otto")
        #expect(hits.count == 4)
        #expect(hits.filter { !SessionSearch.isHidden($0) }.map(\.sessionId) == ["c1"])
    }

    @Test func onlyListedTileChatsAreHiddenOnce() {
        var listed = SidebarSessionRow(id: "t1", profile: "otto", preview: "Make me a live tile for my Hermes HQ Dashboard showing: x")
        var hidden = SidebarSessionRow(id: "t2", profile: "otto", preview: "Change my Hermes HQ Dashboard tile /x.html: y")
        hidden.hidden = true
        listed.hidden = false
        let plain = SidebarSessionRow(id: "c1", profile: "otto", preview: "hello")
        #expect(TileChats.toHide([listed, hidden, plain, listed]).map(\.id) == ["t1"])
    }

    // MARK: The Sessions store

    nonisolated private static func srow(_ id: String, preview: String, lastActive: Double, hidden: Bool = false) -> JSONValue {
        ["id": .string(id), "profile": "otto", "title": .string("Chat \(id)"), "preview": .string(preview),
         "last_active": .number(lastActive), "started_at": .number(lastActive - 60), "message_count": 4, "source": "desktop",
         "pinned": false, "unread": false, "hidden": .bool(hidden)]
    }

    nonisolated private static func answer(_ rows: [JSONValue]) -> Data {
        let root: JSONValue = ["recents": ["sessions": .array(rows)], "cron": ["sessions": []], "messaging": ["sessions": []]]
        return try! root.encoded()
    }

    nonisolated private static let rows: [JSONValue] = [
        srow("c1", preview: "How was revenue this week?", lastActive: 1_791_000_300),
        srow("t1", preview: "Make me a live tile for my Hermes HQ Dashboard showing: Revenue", lastActive: 1_791_000_200),
        srow("t2", preview: "Change my Hermes HQ Dashboard tile /home/h/rev.html: bars", lastActive: 1_791_000_100),
    ]

    private func hides(_ client: BotsFakeGatewayClient) -> [(id: String, body: JSONValue?)] {
        client.restCalls.filter { $0.method == "PATCH" && $0.path.hasPrefix("/api/sessions/") }
            .map { (String($0.path.dropFirst("/api/sessions/".count)), $0.body.flatMap { try? JSONValue.parse($0) }) }
    }

    @Test func theStoreLeavesTileChatsOutAndHidesThemOnTheGatewayOnce() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { method, _, _, _ in
            method == "PATCH" ? try! JSONValue.object(["ok": true]).encoded() : Self.answer(Self.rows)
        }
        let store = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast)
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.sessions.map(\.id) == ["c1"], "the tile chats are in no list")
        #expect(await BotsTest.waitUntil { self.hides(client).count == 2 })
        let sent = hides(client)
        #expect(Set(sent.map(\.id)) == ["t1", "t2"])
        for hide in sent {
            #expect(hide.body?["hidden"]?.bool == true, "hidden on the gateway: \(String(describing: hide.body))")
            #expect(hide.body?["profile"]?.string == "otto")
        }
        // A read again (the gateway hasn't caught up yet): each is asked once a run.
        await store.refresh()
        try await Task.sleep(for: .milliseconds(150))
        #expect(hides(client).count == 2)
        store.stop()
    }

    @Test func aReadOnlyGatewayIsNotWrittenTo() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.answer(Self.rows) }
        let store = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast)
        store.readOnlyGateway = true
        #expect(await BotsTest.waitUntil { store.loadState == .ready })
        #expect(store.sessions.map(\.id) == ["c1"], "still left out of the list")
        try await Task.sleep(for: .milliseconds(150))
        #expect(hides(client).isEmpty)
        store.stop()
    }

    // MARK: The tile keeps its chat

    private func record(_ value: String, session: String, at: Double) -> ArtifactRecord {
        ArtifactRecord(id: "\(session):\(value)", kind: .file, value: value, href: ArtifactCollector.href(value),
                       label: ArtifactCollector.label(value, kind: .file), sessionId: session, profile: "otto",
                       sessionTitle: "Chat \(session)", timestamp: at)
    }

    @MainActor @Test func aChangeMovesTheTilesChatAndAnOlderListedChatDoesNotTakeItBack() {
        let pins = ArtifactPins(fileURL: nil)
        pins.pin(ArtifactPin(record("/home/h/rev.html", session: "made", at: 1_000_000)))
        let id = pins.pins[0].id
        // The Change… ran in a new (hidden) chat at t = 2000 s.
        pins.noteChat(id: id, sessionId: "change", title: "Make it bars", at: Date(timeIntervalSince1970: 2000))
        #expect(pins.pins[0].sessionId == "change" && pins.pins[0].sessionTitle == "Make it bars")
        // The Artifacts listing (no hidden chats) still names the file in the chat that made it, earlier.
        pins.follow([record("/home/h/rev.html", session: "made", at: 1_000_000)])
        #expect(pins.pins[0].sessionId == "change", "an older listed chat doesn't take the tile back")
        // A chat that names the file later than the change does.
        pins.follow([record("/home/h/rev.html", session: "later", at: 3_000_000)])
        #expect(pins.pins[0].sessionId == "later")
        // The same chat again changes nothing.
        pins.noteChat(id: id, sessionId: "later", title: "")
        #expect(pins.pins[0].sessionTitle == "Chat later")
    }

    @MainActor @Test func aPinWithChatAtSyncsAndOldPinsStillDecode() throws {
        let pins = ArtifactPins(fileURL: nil)
        pins.pin(ArtifactPin(record("/home/h/rev.html", session: "made", at: 1_000_000)))
        pins.noteChat(id: pins.pins[0].id, sessionId: "change", title: "Bars", at: Date(timeIntervalSince1970: 2000))
        let other = ArtifactPins(fileURL: nil)
        other.adoptSynced(pins.syncValue(), merge: .replace, base: nil)
        #expect(other.pins.first?.sessionId == "change" && other.pins.first?.chatAt == 2000)
        // A pin from before tile chats (no chatAt) decodes as before.
        var old = try #require(pins.syncValue().object)
        let stripped = (old["pins"]?.array ?? []).map { pin -> JSONValue in
            var o = pin.object ?? [:]
            o["chatAt"] = nil
            return .object(o)
        }
        old["pins"] = .array(stripped)
        let third = ArtifactPins(fileURL: nil)
        third.adoptSynced(.object(old), merge: .replace, base: nil)
        #expect(third.pins.count == 1 && third.pins.first?.chatAt == nil)
    }
}
