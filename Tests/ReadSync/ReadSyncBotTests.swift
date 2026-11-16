import Foundation
import Testing
@testable import HermesHQNative

/// [read-sync] A bot's unread dot travels between a person's devices through the read watermark of the bot's chat: two
/// Bots stores (a Mac and a phone) against one stand-in Hermes.
@Suite(.serialized) struct ReadSyncBotTests {
    private static let t0 = ReadSyncGateway.t0

    private func store(_ hermes: ReadSyncGateway, readsTail: Bool = false, sweepGap: Duration = .zero) -> BotStore {
        var timing = BotStoreTiming.fast
        timing.sharesReads = true
        timing.readLearnGap = .milliseconds(20)
        timing.readSweepGap = sweepGap
        timing.readsBotSaid = readsTail
        return BotStore(client: hermes.device(), account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: timing)
    }

    private func gateway(readAt: Double? = nil, messages: [JSONValue] = []) -> ReadSyncGateway {
        let hermes = ReadSyncGateway()
        hermes.add(.init(id: "reg", profile: "herald", lastActive: Self.t0, count: max(2, messages.count), readAt: readAt, botChat: true,
                         messages: messages))
        return hermes
    }

    private func herald(_ store: BotStore) -> Bot { store.bot(named: "herald")! }

    private func settled(_ stores: BotStore...) async {
        for store in stores {
            #expect(await BotsTest.waitUntil { store.phase == .full && store.readLearnsOut.isEmpty && store.readLearnQueue.isEmpty })
        }
    }

    @Test func aReadOnOneDeviceClearsTheDotOnTheOther() async throws {
        let hermes = gateway()
        let mac = store(hermes), phone = store(hermes)
        await settled(mac, phone)
        #expect(!herald(mac).unread && !herald(phone).unread, "first sight: nothing is unread")

        hermes.activity("reg")
        await mac.refresh(); await phone.refresh()
        #expect(herald(mac).unread && herald(phone).unread)

        // Read on the Mac: its watermark is written, the gateway says its chats changed, and the phone reads the
        // watermark of the bot it shows a dot for.
        mac.markRead(herald(mac))
        #expect(!herald(mac).unread)
        #expect(await BotsTest.waitUntil { hermes.patches("reg") == 1 })
        #expect(hermes.patches.first?.unread == false)
        #expect(await BotsTest.waitUntil { !herald(phone).unread }, "the phone's dot goes without a roster read")
        #expect(phone.unreadCount == 0)

        // The roster's activity time trails the reply by up to a minute; when it catches up, still below the read,
        // the phone doesn't take it for something new.
        await phone.refresh()
        #expect(!herald(phone).unread)

        // A newer reply is unread on both again, and a read on the phone clears the Mac.
        hermes.activity("reg")
        await mac.refresh(); await phone.refresh()
        #expect(herald(mac).unread && herald(phone).unread)
        phone.markRead(herald(phone))
        #expect(await BotsTest.waitUntil { !herald(mac).unread })
        #expect(hermes.patches("reg") == 2)
        mac.stop(); phone.stop()
        RosterDiskWriter.shared.flush()
    }

    @Test func markAsUnreadShowsOnTheOtherDevice() async throws {
        let hermes = gateway()
        let mac = store(hermes), phone = store(hermes)
        await settled(mac, phone)
        mac.markUnread(herald(mac))
        #expect(herald(mac).unread)
        #expect(await BotsTest.waitUntil { hermes.patches.last?.unread == true })
        #expect(await BotsTest.waitUntil { herald(phone).unread }, "found by the read of every bot's watermark")

        // Read on the phone on a gateway that takes no writes (the testing switch): the mark, already seen, isn't news
        // again at the next read of the watermark.
        phone.readOnlyGateway = true
        phone.markRead(herald(phone))
        hermes.changed()
        try await Task.sleep(for: .milliseconds(120))
        #expect(!herald(phone).unread)
        #expect(herald(mac).unread)

        // Read for real on the phone: the Mac's dot goes.
        phone.readOnlyGateway = false
        phone.markUnread(herald(phone))
        phone.markRead(herald(phone))
        #expect(await BotsTest.waitUntil { hermes.patches.last?.unread == false })
        #expect(await BotsTest.waitUntil { !herald(mac).unread })
        mac.stop(); phone.stop()
        RosterDiskWriter.shared.flush()
    }

    /// A reply that landed after the other device's read stays unread here.
    @Test func whatCameAfterTheOtherDevicesReadStaysUnread() async throws {
        let hermes = gateway()
        let mac = store(hermes), phone = store(hermes)
        await settled(mac, phone)
        hermes.activity("reg")
        await mac.refresh()
        mac.markRead(herald(mac))
        #expect(await BotsTest.waitUntil { hermes.patches("reg") == 1 })
        hermes.activity("reg")
        await phone.refresh()
        await settled(phone)
        try await Task.sleep(for: .milliseconds(80))
        #expect(herald(phone).unread)
        mac.stop(); phone.stop()
        RosterDiskWriter.shared.flush()
    }

    /// The chat in front of the person: read as it moves, once per turn and not at each of its steps, and never again
    /// while nothing new lands (a chat left open all day writes nothing).
    @Test func theChatInFrontIsReadWhenItsTurnEnds() async throws {
        let hermes = gateway()
        let mac = store(hermes), phone = store(hermes)
        await settled(mac, phone)
        mac.setFocusedChat(profile: "herald", sessionId: "reg")
        mac.markRead(herald(mac))
        #expect(await BotsTest.waitUntil { hermes.patches("reg") == 1 })

        mac.setWorkingChats("herald", ["reg"])
        hermes.activity("reg", rows: 3)
        await mac.refresh(); await phone.refresh()
        #expect(herald(phone).unread, "the phone hasn't seen it")
        hermes.activity("reg", rows: 2)
        await mac.refresh()
        try await Task.sleep(for: .milliseconds(60))
        #expect(hermes.patches("reg") == 1, "no write while the turn runs")

        // The turn ends in front of the person.
        mac.setWorkingChats("herald", [])
        mac.noteReadOnScreen(profile: "herald", sessionId: "reg")
        #expect(await BotsTest.waitUntil { hermes.patches("reg") == 2 })
        #expect(await BotsTest.waitUntil { !herald(phone).unread })
        #expect(!herald(mac).unread)
        await mac.refresh(); await mac.refresh()
        mac.noteReadOnScreen(profile: "herald", sessionId: "reg")
        try await Task.sleep(for: .milliseconds(60))
        #expect(hermes.patches("reg") <= 3, "nothing new: at most the one write whose time the gateway's clock decides")
        let quiet = hermes.patches("reg")
        await mac.refresh(); await mac.refresh()
        try await Task.sleep(for: .milliseconds(60))
        #expect(hermes.patches("reg") == quiet)

        // Left: what was seen is covered already; a side chat of the bot never writes the bot's watermark.
        mac.setFocusedChat(profile: nil, sessionId: nil, seenThrough: Date(timeIntervalSince1970: hermes.chat("reg")!.lastActive))
        mac.setFocusedChat(profile: "herald", sessionId: "side")
        mac.noteReadOnScreen(profile: "herald", sessionId: "side")
        try await Task.sleep(for: .milliseconds(60))
        #expect(hermes.patches("reg") == quiet)
        mac.stop(); phone.stop()
        RosterDiskWriter.shared.flush()
    }

    @Test func aReadMadeOfflineIsOwedAndSentLater() async throws {
        let hermes = gateway()
        let mac = store(hermes), phone = store(hermes)
        await settled(mac, phone)
        hermes.activity("reg")
        await mac.refresh(); await phone.refresh()
        hermes.dropsWrites = true
        mac.markRead(herald(mac))
        #expect(await BotsTest.waitUntil { mac.readWritesOut.isEmpty && mac.readShare("herald").owed != nil })
        #expect(!herald(mac).unread && herald(phone).unread)
        hermes.dropsWrites = false
        await mac.refresh()                         // every roster sends what is owed
        #expect(await BotsTest.waitUntil { hermes.patches("reg") == 1 })
        #expect(await BotsTest.waitUntil { mac.readShare("herald").owed == nil })
        #expect(await BotsTest.waitUntil { !herald(phone).unread })

        // Owed again, but the chat moves before the link is back: "read now" would cover rows nobody saw.
        hermes.activity("reg")
        await mac.refresh()
        hermes.dropsWrites = true
        mac.markRead(herald(mac))
        #expect(await BotsTest.waitUntil { mac.readWritesOut.isEmpty && mac.readShare("herald").owed != nil })
        hermes.activity("reg")
        hermes.dropsWrites = false
        await mac.refresh()
        try await Task.sleep(for: .milliseconds(60))
        #expect(hermes.patches("reg") == 1)
        #expect(mac.readShare("herald").owed == nil)
        mac.stop(); phone.stop()
        RosterDiskWriter.shared.flush()
    }

    @Test func gatewaysThatCannotShareReadsAreLeftAlone() async throws {
        // A Hermes older than read state: its chat rows carry no watermark. One read finds out; none follows.
        let old = gateway()
        old.tracksReads = false
        let device = store(old)
        await settled(device)
        #expect(await BotsTest.waitUntil { device.readShareAbsent })
        let reads = old.rowReads.count
        old.activity("reg")
        await device.refresh()
        old.changed()
        try await Task.sleep(for: .milliseconds(100))
        #expect(old.rowReads.count == reads)
        #expect(herald(device).unread, "the dot is this device's own, as before")
        device.stop()

        // A gateway that refuses the write (an older Hermes while its gateway owns the profile): asked once.
        let refusing = gateway()
        refusing.refusesWrites = 409
        let other = store(refusing)
        await settled(other)
        refusing.activity("reg")
        await other.refresh()
        other.markRead(herald(other))
        #expect(await BotsTest.waitUntil { other.readShareRefused })
        #expect(!herald(other).unread)
        other.markUnread(herald(other))
        other.markRead(herald(other))
        #expect(other.readWritesOut.isEmpty && other.readShare("herald").owed == nil)
        other.stop()

        // A read-only gateway gets no write at all.
        let hermes = gateway()
        let readOnly = store(hermes)
        readOnly.readOnlyGateway = true
        await settled(readOnly)
        hermes.activity("reg")
        await readOnly.refresh()
        readOnly.markRead(herald(readOnly))
        readOnly.markUnread(herald(readOnly))
        try await Task.sleep(for: .milliseconds(60))
        #expect(hermes.patches.isEmpty)
        readOnly.stop()
        RosterDiskWriter.shared.flush()
    }

    /// The read of every bot's watermark is rationed: bots without a dot are read at most once per `readSweepGap`,
    /// however often the gateway says its chats changed.
    @Test func watermarkReadsAreRationed() async throws {
        let hermes = gateway()
        let device = store(hermes, sweepGap: .seconds(3600))
        await settled(device)
        let first = hermes.rowReads.count
        #expect(first == 1, "one read of the bot's watermark at launch")
        for _ in 0..<5 { hermes.changed(); try await Task.sleep(for: .milliseconds(30)) }
        #expect(hermes.rowReads.count == first)
        // A bot showing a dot is read each time (that is how the dot learns it was read elsewhere).
        hermes.activity("reg")
        await device.refresh()
        await settled(device)
        let dotted = hermes.rowReads.count
        #expect(dotted > first)
        hermes.changed()
        #expect(await BotsTest.waitUntil { hermes.rowReads.count > dotted })
        device.stop()
        RosterDiskWriter.shared.flush()
    }

    /// A Mark as Unread made on the other device just after every bot was read is still found: the next read of
    /// every bot follows when it falls due, without waiting for anything else to change.
    @Test func aMarkMadeRightAfterASweepIsFoundWhenTheNextFallsDue() async throws {
        let hermes = gateway()
        let mac = store(hermes), phone = store(hermes, sweepGap: .milliseconds(400))
        await settled(mac, phone)
        mac.markUnread(herald(mac))
        #expect(await BotsTest.waitUntil { hermes.patches.last?.unread == true })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!herald(phone).unread, "not yet: every bot was read a moment ago")
        #expect(await BotsTest.waitUntil { herald(phone).unread })
        mac.stop(); phone.stop()
        RosterDiskWriter.shared.flush()
    }

    // MARK: First sight, and only what is written to you

    private static let seats = [DeliveryMessages.Seat(profile: "otto", name: "Otto", head: nil),
                                DeliveryMessages.Seat(profile: "herald", name: "Herald", head: nil)]

    private static var answered: [JSONValue] {
        [["id": 1, "role": "user", "content": "Are the porch lights on a timer?", "timestamp": .number(t0 - 600)],
         ["id": 2, "role": "assistant", "content": "Yes, the porch lights are on a timer again.", "timestamp": .number(t0 - 590)]]
    }

    private static var talk: [JSONValue] {
        [["id": 3, "role": "user", "display_kind": "internal_notification", "timestamp": .number(t0 - 300),
          "content": "Message from 🤖 otto (@otto): Your morning report flagged the side door as open. Please check it now."],
         ["id": 4, "role": "assistant", "content": "The side door is still open. It was last moved at four.", "timestamp": .number(t0 - 290)]]
    }

    /// A device that meets a bot for the first time (a fresh install) used to start with no dots at all. It takes the
    /// gateway's word now, and still only for something written to you.
    @Test func aNewDeviceTakesTheGatewaysWordForWhatIsWrittenToYou() async throws {
        let before = DeliveryRoster.seats
        DeliveryRoster.seats = Self.seats
        defer { DeliveryRoster.seats = before }

        // Read on some device before the bot's answer to you landed: unread, for you.
        let hermes = gateway(readAt: Self.t0 - 595, messages: Self.answered)
        let fresh = store(hermes, readsTail: true)
        #expect(await BotsTest.waitUntil { fresh.bot(named: "herald")?.unread == true })
        fresh.stop()

        // Read after your exchange; since then only another bot wrote to this one and it answered that bot: no dot.
        let quiet = gateway(readAt: Self.t0 - 500, messages: Self.answered + Self.talk)
        let second = store(quiet, readsTail: true)
        await settled(second)
        #expect(await BotsTest.waitUntil { second.device.unread.held("herald") == nil && second.botSaidOut.isEmpty && second.botSaidQueue.isEmpty })
        try await Task.sleep(for: .milliseconds(80))
        #expect(second.bot(named: "herald")?.unread == false)
        second.stop()

        // Never read anywhere, or read through its newest row: nothing, as before.
        for readAt in [nil, Self.t0 + 5] as [Double?] {
            let calm = gateway(readAt: readAt, messages: Self.answered)
            let third = store(calm, readsTail: true)
            await settled(third)
            try await Task.sleep(for: .milliseconds(80))
            #expect(third.bot(named: "herald")?.unread == false)
            third.stop()
        }
        RosterDiskWriter.shared.flush()
    }
}
