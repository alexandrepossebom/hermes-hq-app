import Foundation
import Testing
@testable import HermesHQNative

/// [#440] A new chat shows under its bot (and in Sessions) as its first message goes out, not with the next list read,
/// which waits up to 150 s while a chat is on screen beside the Bots page (a tester, Mac).
@MainActor @Suite(.serialized) struct StartedChatRowTests {
    private static let t0 = ReadSyncGateway.t0

    private func store(_ hermes: ReadSyncGateway, settle: Duration = .seconds(5)) -> SessionStore {
        var timing = SessionStoreTiming.fast
        timing.startedRowSettle = settle
        return SessionStore(client: hermes.device(), account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(),
                            timing: timing)
    }

    private func gateway() -> ReadSyncGateway {
        let hermes = ReadSyncGateway()
        hermes.add(.init(id: "plan", profile: "ivy", lastActive: Self.t0 - 600, count: 4, readAt: nil))
        return hermes
    }

    private func underIvy(_ store: SessionStore) -> [String] {
        BotChatsUnder.pick(store.sessions, bot: "ivy", choice: BotChatsChoice(mode: .recent, count: 2)).shown.map(\.id)
    }

    @Test func aNewChatShowsUnderItsBotAsItsFirstMessageGoesOut() async throws {
        let hermes = gateway()
        let sessions = store(hermes)
        #expect(await BotsTest.waitUntil { sessions.loadState == .ready })
        #expect(underIvy(sessions) == ["plan"])

        sessions.listStartedChat(id: "fresh", profile: "ivy", firstMessage: "Sketch the garden beds", cwd: "/Users/me/garden")
        #expect(underIvy(sessions) == ["fresh", "plan"], "the newest chat first, at once")
        let row = try #require(sessions.sessions.first { $0.id == "fresh" })
        #expect(row.title == "Sketch the garden beds", "named by its first message until the gateway names it")
        #expect(!row.unread)
        #expect(row.cwd == "/Users/me/garden")

        // A read that began before the gateway stored the chat leaves it out: the row stays.
        await sessions.refresh()
        #expect(underIvy(sessions) == ["fresh", "plan"])
        #expect(sessions.startedRows.count == 1)

        // The gateway lists it: its row takes over, once.
        hermes.add(.init(id: "fresh", profile: "ivy", lastActive: Self.t0, count: 2, readAt: nil))
        await sessions.refresh()
        #expect(sessions.sessions.filter { $0.id == "fresh" }.count == 1)
        #expect(sessions.sessions.first { $0.id == "fresh" }?.title == "Chat", "the gateway's own row now")
        #expect(sessions.startedRows.isEmpty)
        #expect(underIvy(sessions) == ["fresh", "plan"])
        sessions.stop()
    }

    @Test func theChatsTitleEventNamesTheRowAndAReadWithoutItKeepsTheName() async throws {
        let hermes = gateway()
        let sessions = store(hermes)
        #expect(await BotsTest.waitUntil { sessions.loadState == .ready })
        sessions.listStartedChat(id: "fresh", profile: "ivy", firstMessage: "Sketch the garden beds")
        sessions.applyTitle(id: "fresh", title: "Garden beds")
        #expect(sessions.sessions.first { $0.id == "fresh" }?.title == "Garden beds")
        await sessions.refresh()
        #expect(sessions.sessions.first { $0.id == "fresh" }?.title == "Garden beds")
        sessions.stop()
    }

    @Test func aChatAlreadyListedOrForgottenIsNotListedAgain() async throws {
        let hermes = gateway()
        let sessions = store(hermes)
        #expect(await BotsTest.waitUntil { sessions.loadState == .ready })
        sessions.listStartedChat(id: "plan", profile: "ivy", firstMessage: "Again")
        #expect(sessions.sessions.filter { $0.id == "plan" }.count == 1)
        #expect(sessions.startedRows.isEmpty, "the gateway's row is there already")

        // A second turn in the started chat keeps one row.
        sessions.listStartedChat(id: "fresh", profile: "ivy", firstMessage: "One")
        sessions.listStartedChat(id: "fresh", profile: "ivy", firstMessage: "Two")
        #expect(sessions.sessions.filter { $0.id == "fresh" }.count == 1)

        // Archive or Delete Chat: it goes and a read doesn't bring it back.
        sessions.forget(id: "fresh", profile: "ivy")
        #expect(!sessions.sessions.contains { $0.id == "fresh" })
        await sessions.refresh()
        #expect(!sessions.sessions.contains { $0.id == "fresh" })
        sessions.stop()
    }

    @Test func aChatTheGatewayNeverListsGoesWithTheFirstReadAfterItsTurn() async throws {
        let hermes = gateway()
        let sessions = store(hermes, settle: .milliseconds(50))
        #expect(await BotsTest.waitUntil { sessions.loadState == .ready })
        sessions.listStartedChat(id: "refused", profile: "ivy", firstMessage: "Hello")
        sessions.startedChatSettled(id: "refused", profile: "ivy")
        await sessions.refresh()
        #expect(sessions.sessions.contains { $0.id == "refused" }, "a read right as the turn ended may predate its row")

        try await Task.sleep(for: .milliseconds(80))
        await sessions.refresh()
        #expect(!sessions.sessions.contains { $0.id == "refused" }, "a read well after the turn is believed")
        #expect(sessions.startedRows.isEmpty)

        // Another turn in a held chat waits for its own end.
        sessions.listStartedChat(id: "later", profile: "ivy", firstMessage: "Hi")
        sessions.startedChatSettled(id: "later", profile: "ivy")
        sessions.listStartedChat(id: "later", profile: "ivy", firstMessage: "Hi")   // the next turn starts
        try await Task.sleep(for: .milliseconds(80))
        await sessions.refresh()
        #expect(sessions.sessions.contains { $0.id == "later" })
        sessions.stop()
    }

    @Test func aStoppedStoreOrAnotherBotsListTakesNothing() async throws {
        let hermes = gateway()
        let sessions = store(hermes)
        #expect(await BotsTest.waitUntil { sessions.loadState == .ready })
        sessions.allBots = false                    // the list reads the routing bot's chats only
        sessions.listStartedChat(id: "other", profile: "ivy", firstMessage: "Hi")
        #expect(!sessions.sessions.contains { $0.id == "other" })
        sessions.allBots = true
        sessions.stop()
        sessions.listStartedChat(id: "late", profile: "ivy", firstMessage: "Hi")
        #expect(!sessions.sessions.contains { $0.id == "late" })
    }
}
