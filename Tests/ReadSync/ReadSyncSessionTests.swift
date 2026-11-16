import Foundation
import Testing
@testable import HermesHQNative

/// [read-sync] Read and unread travel between a person's devices through the gateway's watermark: two Sessions stores
/// (a Mac and a phone) against one stand-in Hermes (a tester, 2026-11-16: "Reading a message on either device should
/// update the read/unread status on the other device").
@Suite(.serialized) struct ReadSyncSessionTests {
    private static let t0 = ReadSyncGateway.t0

    private func store(_ hermes: ReadSyncGateway) -> (SessionStore, BotsFakeGatewayClient) {
        let client = hermes.device()
        let store = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast)
        return (store, client)
    }

    private func gateway(_ ids: String..., readAt: Double? = nil) -> ReadSyncGateway {
        let hermes = ReadSyncGateway()
        for id in ids { hermes.add(.init(id: id, profile: "ivy", lastActive: Self.t0, count: 2, readAt: readAt)) }
        return hermes
    }

    private func row(_ store: SessionStore, _ id: String) -> SessionSummary { store.sessions.first { $0.id == id }! }

    @Test func aReadOnOneDeviceClearsTheDotOnTheOther() async throws {
        let hermes = gateway("plan")
        let (mac, _) = store(hermes), (phone, _) = store(hermes)
        #expect(await BotsTest.waitUntil { mac.loadState == .ready && phone.loadState == .ready })
        #expect(mac.unreadCount == 0 && phone.unreadCount == 0, "first sight: nothing is unread")

        // A reply lands. Nobody has ever read the chat on the gateway (no watermark), so each device's own count says unread.
        hermes.activity("plan")
        await mac.refresh(); await phone.refresh()
        #expect(row(mac, "plan").unread && row(phone, "plan").unread)

        // Read on the Mac: the dot goes there, and the gateway is told although it never called the chat unread.
        mac.markOpened(row(mac, "plan"))
        #expect(!row(mac, "plan").unread)
        #expect(await BotsTest.waitUntil { hermes.patches("plan") == 1 })
        #expect(hermes.patches.first?.unread == false)
        await phone.refresh()
        #expect(!row(phone, "plan").unread, "the phone's own dot goes: the gateway says the chat was read after its newest row")
        #expect(phone.unreadCount == 0)

        // Nothing new: opening it again, on either device, writes nothing.
        await mac.refresh()
        mac.markOpened(row(mac, "plan"))
        phone.markOpened(row(phone, "plan"))
        try await Task.sleep(for: .milliseconds(60))
        #expect(hermes.patches("plan") == 1)

        // A newer reply: unread again on both (the gateway's flag now), and a read on the phone clears the Mac.
        hermes.activity("plan")
        await mac.refresh(); await phone.refresh()
        #expect(row(mac, "plan").unread && row(phone, "plan").unread)
        phone.markOpened(row(phone, "plan"))
        #expect(await BotsTest.waitUntil { hermes.patches("plan") == 2 })
        await mac.refresh()
        #expect(!row(mac, "plan").unread)
        mac.stop(); phone.stop()
    }

    @Test func markAsUnreadShowsOnTheOtherDeviceAndAReadThereClearsBoth() async throws {
        let hermes = gateway("plan")
        let (mac, _) = store(hermes), (phone, _) = store(hermes)
        #expect(await BotsTest.waitUntil { mac.loadState == .ready && phone.loadState == .ready })
        mac.setUnread(row(mac, "plan"), true)
        #expect(row(mac, "plan").unread)
        #expect(await BotsTest.waitUntil { hermes.patches.last?.unread == true })
        await phone.refresh()
        #expect(row(phone, "plan").unread)

        // Mark as Read on the phone: the Mac's own marker goes too, because the watermark moved from "marked unread".
        phone.setUnread(row(phone, "plan"), false)
        #expect(await BotsTest.waitUntil { hermes.patches.last?.unread == false })
        await mac.refresh()
        #expect(!row(mac, "plan").unread)
        #expect(mac.unreadCount == 0 && phone.unreadCount == 0)
        mac.stop(); phone.stop()
    }

    /// Once a chat has a watermark, every row a turn stores makes the gateway call it unread: the open chat's too, and
    /// while its turn still runs. Neither device shows a dot for that, and the device showing the chat writes one read
    /// when the turn ends, not one per page.
    @Test func theChatOnScreenAndARunningTurnAreNotUnread() async throws {
        let hermes = gateway("plan", readAt: Self.t0 + 1)
        let (mac, _) = store(hermes), (phone, _) = store(hermes)
        #expect(await BotsTest.waitUntil { mac.loadState == .ready && phone.loadState == .ready })
        mac.markOpened(row(mac, "plan"))
        mac.setFocusedSession("plan")
        mac.setSessionOnScreen("plan")
        try await Task.sleep(for: .milliseconds(40))
        #expect(hermes.patches("plan") == 0, "already read through its newest row: opening it writes nothing")

        // The turn runs: its steps are stored.
        mac.setRunning(["plan"]); phone.setRunning(["plan"])
        hermes.activity("plan", rows: 3)
        await mac.refresh(); await phone.refresh()
        #expect(mac.row(for: "plan")?.unread == true && phone.row(for: "plan")?.unread == true, "the gateway's flag is up")
        #expect(!row(mac, "plan").unread && !row(phone, "plan").unread, "[unread-working] no dot while it works")
        hermes.activity("plan", rows: 2)
        await mac.refresh()
        try await Task.sleep(for: .milliseconds(40))
        #expect(hermes.patches("plan") == 0, "no write per page while the turn runs")

        // It ends in front of the person on the Mac: read there, once. The phone shows the reply as unread only until
        // its next page.
        mac.setRunning([])
        #expect(!row(mac, "plan").unread)
        #expect(await BotsTest.waitUntil { hermes.patches("plan") == 1 })
        phone.setRunning([])
        #expect(row(phone, "plan").unread)
        await phone.refresh()
        #expect(!row(phone, "plan").unread)
        await mac.refresh(); await mac.refresh()
        try await Task.sleep(for: .milliseconds(40))
        #expect(hermes.patches("plan") == 1)

        // Another client writes into the chat while the Mac shows it but the app is not in front: not seen, so the dot
        // shows, and the read is written when the person comes back.
        mac.appDidEnterBackground()
        hermes.activity("plan")
        await mac.refresh()
        #expect(row(mac, "plan").unread)
        try await Task.sleep(for: .milliseconds(40))
        #expect(hermes.patches("plan") == 1)
        mac.appDidBecomeActive()
        #expect(!row(mac, "plan").unread)
        #expect(await BotsTest.waitUntil { hermes.patches("plan") == 2 })

        // Left: the selection sticks, the chat is no longer in front. A reply that lands then is unread on both.
        mac.setSessionOnScreen(nil)
        hermes.activity("plan")
        await mac.refresh(); await phone.refresh()
        #expect(row(mac, "plan").unread && row(phone, "plan").unread)
        mac.stop(); phone.stop()
    }

    /// The person saw a chat through its newest message (a turn ended in front of them, or they left it): the gateway
    /// is told once, whatever the list's row still says. A chat marked unread is not read by that.
    @Test func whatWasSeenInAChatIsWrittenOnce() async throws {
        let hermes = gateway("plan", "kept", readAt: Self.t0 + 1)
        let (mac, _) = store(hermes), (phone, _) = store(hermes)
        #expect(await BotsTest.waitUntil { mac.loadState == .ready && phone.loadState == .ready })
        // The Mac's list hasn't been read since the reply landed (a chat on screen stretches its reads).
        hermes.activity("plan")
        await phone.refresh()
        #expect(row(phone, "plan").unread)
        let seen = hermes.chat("plan")!.lastActive
        mac.shareRead(id: "plan", profile: "ivy", through: seen)
        #expect(await BotsTest.waitUntil { hermes.patches("plan") == 1 })
        mac.shareRead(id: "plan", profile: "ivy", through: seen)            // leaving right after: the same activity
        mac.shareRead(id: "plan", profile: "ivy", through: seen - 30)
        try await Task.sleep(for: .milliseconds(40))
        #expect(hermes.patches("plan") == 1)
        await phone.refresh()
        #expect(!row(phone, "plan").unread)

        // Marked unread on the phone, then merely passed through on the Mac: it stays unread.
        phone.setUnread(row(phone, "kept"), true)
        #expect(await BotsTest.waitUntil { hermes.patches("kept") == 1 })
        await mac.refresh()
        mac.shareRead(id: "kept", profile: "ivy", through: Self.t0 + 500)
        try await Task.sleep(for: .milliseconds(40))
        #expect(hermes.patches("kept") == 1)
        #expect(row(mac, "kept").unread)
        // A chat the lists don't hold is left alone.
        mac.shareRead(id: "nowhere", profile: "ivy", through: Self.t0 + 500)
        try await Task.sleep(for: .milliseconds(40))
        #expect(hermes.patches.count == 2)
        mac.stop(); phone.stop()
    }

    @Test func aReadMadeOfflineIsOwedAndSentWhenTheLinkIsBack() async throws {
        let hermes = gateway("plan", "moved", readAt: Self.t0 + 1)
        let (mac, macClient) = store(hermes), (phone, _) = store(hermes)
        #expect(await BotsTest.waitUntil { mac.loadState == .ready && phone.loadState == .ready })
        hermes.activity("plan"); hermes.activity("moved")
        await mac.refresh(); await phone.refresh()
        #expect(row(mac, "plan").unread && row(mac, "moved").unread)

        hermes.dropsWrites = true
        mac.setUnread(row(mac, "plan"), false)
        mac.setUnread(row(mac, "moved"), false)
        #expect(await BotsTest.waitUntil { mac.device.unread.owed?.count == 2 })
        #expect(!row(mac, "plan").unread && !row(mac, "moved").unread, "read here stays read here")
        await mac.refresh()
        #expect(!row(mac, "plan").unread, "a page that still says unread doesn't bring the dot back")
        #expect(row(phone, "plan").unread)

        // "moved" gets a newer reply before the link is back: the read no longer covers it and is dropped.
        hermes.activity("moved")
        hermes.dropsWrites = false
        await mac.refresh()
        macClient.emit("gateway.ready", payload: ["change_events": true])
        #expect(await BotsTest.waitUntil { hermes.patches("plan") == 1 })
        #expect(await BotsTest.waitUntil { mac.device.unread.owed == nil })
        try await Task.sleep(for: .milliseconds(40))
        #expect(hermes.patches("moved") == 0)
        await phone.refresh()
        #expect(!row(phone, "plan").unread)
        #expect(row(phone, "moved").unread)
        mac.stop(); phone.stop()
    }

    @Test func writesStayFew() async throws {
        // Mark All as Read: one write per chat either side calls unread, none for the rest of the list.
        let hermes = gateway("local", "flagged", "quiet", "quiet2")
        let (mac, _) = store(hermes)
        #expect(await BotsTest.waitUntil { mac.loadState == .ready })
        hermes.activity("local")
        mac.setUnread(row(mac, "flagged"), true)
        #expect(await BotsTest.waitUntil { hermes.patches("flagged") == 1 })
        await mac.refresh()
        #expect(mac.unreadCount == 2)
        let failed = await mac.markAllRead()
        #expect(failed.isEmpty && mac.unreadCount == 0)
        #expect(hermes.patches("local") == 1 && hermes.patches("flagged") == 2)
        #expect(hermes.patches("quiet") == 0 && hermes.patches("quiet2") == 0)
        mac.stop()

        // A read-only gateway gets no write.
        let (readOnly, _) = store(hermes)
        readOnly.readOnlyGateway = true
        #expect(await BotsTest.waitUntil { readOnly.loadState == .ready })
        let before = hermes.patches.count
        readOnly.markOpened(row(readOnly, "quiet"))
        readOnly.shareRead(id: "quiet", profile: "ivy", through: Self.t0 + 900)
        try await Task.sleep(for: .milliseconds(40))
        #expect(hermes.patches.count == before)
        readOnly.stop()

        // A Hermes older than read state (its rows say neither `unread` nor `last_read_at`) gets none either.
        let old = gateway("plan")
        old.tracksReads = false
        let (device, _) = store(old)
        #expect(await BotsTest.waitUntil { device.loadState == .ready })
        old.activity("plan")
        await device.refresh()
        #expect(row(device, "plan").unread, "its own count still says unread")
        device.markOpened(row(device, "plan"))
        device.shareRead(id: "plan", profile: "ivy", through: Self.t0 + 900)
        try await Task.sleep(for: .milliseconds(40))
        #expect(old.patches.isEmpty)
        #expect(!row(device, "plan").unread)
        device.stop()
    }

    /// A gateway that refuses the write (an older Hermes while its gateway owns the profile) keeps Mark as Unread on
    /// the device; an older read watermark doesn't undo that mark.
    @Test func aMarkTheGatewayRefusedIsNotUndoneByAnOlderRead() async throws {
        let hermes = gateway("plan", readAt: Self.t0 + 1)
        let (mac, _) = store(hermes)
        #expect(await BotsTest.waitUntil { mac.loadState == .ready })
        hermes.refusesWrites = 409
        mac.setUnread(row(mac, "plan"), true)
        try await Task.sleep(for: .milliseconds(60))
        await mac.refresh(); await mac.refresh()
        #expect(row(mac, "plan").unread)
        mac.stop()
    }

    @Test func theWatermarkIsReadFromTheRow() throws {
        let read = try #require(SidebarSessionRow(json: ["id": "a", "profile": "ivy", "last_active": 100, "last_read_at": 100, "unread": false]))
        #expect(read.lastReadAt == 100 && read.readOnGateway && read.sharesReads)
        let behind = try #require(SidebarSessionRow(json: ["id": "a", "profile": "ivy", "last_active": 100, "last_read_at": 99, "unread": true]))
        #expect(!behind.readOnGateway)
        let marked = try #require(SidebarSessionRow(json: ["id": "a", "profile": "ivy", "last_active": 100, "last_read_at": 0, "unread": true]))
        #expect(marked.lastReadAt == 0 && !marked.readOnGateway)
        let never = try #require(SidebarSessionRow(json: ["id": "a", "profile": "ivy", "last_active": 100, "last_read_at": .null, "unread": false]))
        #expect(never.lastReadAt == nil && !never.readOnGateway && never.sharesReads)
        let old = try #require(SidebarSessionRow(json: ["id": "a", "profile": "ivy", "last_active": 100]))
        #expect(!old.sharesReads)
        // A saved list from before this build still loads.
        let saved = try JSONDecoder().decode(SidebarSessionRow.self, from: Data(#"{"id":"a","profile":"ivy","unread":true}"#.utf8))
        #expect(saved.lastReadAt == nil && saved.unread == true)

        // The chat in front of the person is not unread for the gateway's flag; Mark as Unread still shows there.
        let state = SessionUnreadState()
        #expect(state.isUnread(behind) && !state.isUnread(behind, onScreen: true))
        #expect(state.isUnread(marked, onScreen: true))
    }
}
