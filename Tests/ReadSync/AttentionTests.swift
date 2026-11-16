import Foundation
import Testing
@testable import HermesHQNative

/// The rows' "waits for you" and "working" cues for chats this device isn't attached to, and for requests that were
/// already open when it attached (a tester, 2026-11-15: "a bot waiting for an action approval sometimes has no
/// attention dot … a blue dot sometimes appears next to a bot that is still working").
@Suite(.serialized) struct AttentionTests {
    private static let t0 = ReadSyncGateway.t0

    // MARK: The gateway's live statuses

    @Test func liveStatusesAreReadByStoredId() {
        let answer: JSONValue = ["sessions": [
            ["id": "rt1", "session_key": "chat-a", "status": "working"],
            ["id": "rt2", "session_key": "chat-b", "status": "waiting"],
            ["id": "rt3", "session_key": "chat-b", "status": "idle"],          // a second viewer's runtime of the same chat
            ["id": "rt4", "session_key": "chat-c", "status": "idle"],
            ["id": "rt5", "session_key": "", "status": "working"],
            ["id": "rt6", "status": "working"],
        ]]
        #expect(LiveStatusWatch.statuses(answer) == ["chat-a": "working", "chat-b": "waiting", "chat-c": "idle"])
        #expect(LiveStatusWatch.statuses(["sessions": .null]).isEmpty)
    }

    /// "waiting" is any open request, the ones a client answers by itself in milliseconds too: a chat waits on a
    /// person once two reads in a row say so. A waiting chat is still working (its turn is held, not over).
    @Test func aChatWaitsOnAPersonOnceTwoReadsSaySo() {
        let watch = LiveStatusWatch(client: BotsFakeGatewayClient())
        var changes = 0
        watch.onChange = { changes += 1 }
        watch.apply(["a": "working", "b": "waiting"])
        #expect(watch.working == ["a", "b"] && watch.waiting.isEmpty)
        watch.apply(["a": "working", "b": "waiting"])
        #expect(watch.waiting == ["b"] && watch.working == ["a", "b"])
        #expect(changes == 2)
        watch.apply(["a": "working", "b": "waiting"])
        #expect(changes == 2, "the same answer tells nobody")
        // A machine's own read, gone by the next look: never shown.
        watch.apply(["a": "waiting", "b": "waiting"])
        watch.apply(["a": "working", "b": "waiting"])
        #expect(watch.waiting == ["b"])
        // Answered: working again, then done.
        watch.apply(["a": "working", "b": "working"])
        #expect(watch.waiting.isEmpty && watch.working == ["a", "b"])
        watch.apply(["a": "idle"])
        #expect(watch.working.isEmpty)
    }

    @Test func aTurnThisAppSawEndIsNotBroughtBackByAnOlderRead() {
        let watch = LiveStatusWatch(client: BotsFakeGatewayClient())
        watch.apply(["a": "working"])
        let asked = ContinuousClock.now
        watch.turnEnded("a")
        #expect(watch.working.isEmpty)
        watch.apply(["a": "working"], started: asked - .seconds(1))
        #expect(watch.working.isEmpty)
        watch.apply(["a": "working"], started: .now + .milliseconds(1))
        #expect(watch.working == ["a"], "a read asked after the end is believed: a new turn")
    }

    @Test func theWatchReadsOnChangesAndStopsWhenNotWanted() async throws {
        let hermes = ReadSyncGateway()
        let watch = LiveStatusWatch(client: hermes.device())
        watch.changeGap = .milliseconds(20); watch.busyGap = .milliseconds(40); watch.idleGap = .seconds(3600)
        watch.confirmGap = .milliseconds(20)
        hermes.live = ["chat-b": "waiting"]
        watch.setWanted(true)
        // The first sight, then the confirming read: waiting on a person.
        #expect(await BotsTest.waitUntil { watch.waiting == ["chat-b"] })
        hermes.live = [:]
        #expect(await BotsTest.waitUntil { watch.working.isEmpty && watch.waiting.isEmpty }, "the busy pace finds the end")
        let quiet = hermes.liveReads
        try await Task.sleep(for: .milliseconds(120))
        #expect(hermes.liveReads == quiet, "nothing works: the idle pace")
        hermes.live = ["chat-a": "working"]
        watch.sessionsChanged()
        #expect(await BotsTest.waitUntil { watch.working == ["chat-a"] })
        watch.setWanted(false)
        let stopped = hermes.liveReads
        watch.sessionsChanged()
        try await Task.sleep(for: .milliseconds(120))
        #expect(hermes.liveReads == stopped)
        #expect(watch.working == ["chat-a"], "what was read is kept for the way back")
    }

    @Test func aGatewayWithoutTheCallIsLeftAlone() async throws {
        let client = BotsFakeGatewayClient()           // answers -32601 to everything
        let watch = LiveStatusWatch(client: client)
        watch.changeGap = .milliseconds(10); watch.idleGap = .milliseconds(10); watch.busyGap = .milliseconds(10)
        watch.setWanted(true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(client.calls("session.active_list").count == 1)
        watch.stop()
    }

    // MARK: The bots' rows

    private func bots(_ hermes: ReadSyncGateway) -> BotStore {
        BotStore(client: hermes.device(), account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast)
    }

    /// A turn nobody on this device started: the bot says Working… (so the unread circle waits for the turn's end,
    /// `BotList.showsUnread`), and "Waiting for you" when its chat waits on a person. A side chat's wait is not the bot's.
    @Test func aBotWorksAndWaitsByTheGatewaysWord() async throws {
        let hermes = ReadSyncGateway()
        hermes.add(.init(id: "reg", profile: "herald", lastActive: Self.t0, count: 2, botChat: true))
        let store = bots(hermes)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        let herald = { store.bot(named: "herald")! }
        #expect(!herald().isWorking && herald().needsInput == nil)

        store.setLiveStatus(working: ["reg"], waiting: [])
        #expect(herald().isWorking && herald().needsInput == nil)
        // Its turn's steps move the chat: marked, but no unread circle while it works.
        hermes.activity("reg", rows: 3)
        await store.refresh()
        #expect(herald().unread && !BotList.showsUnread(herald()))

        store.setLiveStatus(working: ["reg"], waiting: ["reg"])
        #expect(herald().needsInput == .waiting)
        #expect(BotList.rowStatus(herald()) == .needsInput)
        #expect(BotList.secondLine(herald()).text == "Waiting for you")
        #expect(!BotList.showsArc(herald(), ring: true), "the orange cue is the louder one")
        // What this device's own request centre knows is more exact, and wins.
        store.setNeedsInput("herald", .approval)
        #expect(herald().needsInput == .approval)
        store.setNeedsInput("herald", nil)
        #expect(herald().needsInput == .waiting)

        store.setLiveStatus(working: ["side-chat"], waiting: ["side-chat"])
        #expect(!herald().isWorking && herald().needsInput == nil)
        #expect(BotList.showsUnread(herald()), "the turn is over: the circle shows")
        store.stop()
        RosterDiskWriter.shared.flush()
    }
}
