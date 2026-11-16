import Foundation
import Testing
@testable import HermesHQNative

@Suite struct SessionNameLimitTests {
    @Test func namingBudgetIsTwentyCharactersNotThreeWords() {
        #expect(ShortTitle.maxCharacters == 20)
        #expect(ShortTitle.compact("The cost of a repair") == "The cost of a repair")
    }

    @Test(arguments: [
        "Please investigate the database connection pool timeout errors",
        "Hi there please help me",
        String(repeating: "é", count: 40),
        String(repeating: "界", count: 40),
        "ß" + String(repeating: "a", count: 40),
        "Review \(String(repeating: "x", count: 50)) tomorrow",
    ])
    func fallbackAlwaysFits(message: String) {
        let title = ShortTitle.fallback(for: message)
        #expect(title.count <= 20, "\(title)")
        #expect(!title.isEmpty)
    }

    @Test func modelHasNoExtraCharacterAllowance() {
        #expect(ShortTitle.accepted("Database connection pool troubleshooting", message: "Help debug my app") == nil)
        #expect(ShortTitle.accepted(String(repeating: "x", count: 21), message: "Help debug my app") == nil)
        #expect(ShortTitle.accepted("Database pool repair", message: "Help debug my app") == "Database pool repair")
    }

    @Test func compactUsesWholeWordsAndNormalizesModelDecoration() {
        #expect(ShortTitle.compact("Title: \"Database connection pool troubleshooting\"") == "Database connection…")
        #expect(ShortTitle.compact("Trip to Lisbon") == "Trip to Lisbon")
        #expect(ShortTitle.compact("  Database   pool\trepair  ") == "Database pool repair")
        #expect(ShortTitle.fallback(for: "Check database synchronization tomorrow") == "Check database…")
        #expect(ShortTitle.accepted("Database\rpool", message: "Debug the app") == nil)
        let exactlyTwenty = "ß" + String(repeating: "a", count: 19)
        #expect(ShortTitle.accepted(exactlyTwenty, message: "Debug the app") == exactlyTwenty)
        #expect(ShortTitle.accepted(exactlyTwenty + "a", message: "Debug the app") == nil)
        #expect(ShortTitle.isPlaceholder(String(repeating: "界", count: 21), firstMessage: String(repeating: "界", count: 21)))
    }
}

@Suite(.serialized) @MainActor struct SessionNameLimitFlowTests {
    private func event(_ f: MenusFixtureChat, _ title: String) {
        f.session.receive(GatewayEvent(type: "session.title", sessionId: f.rid1, seq: nil,
                                       payload: ["title": .string(title)]))
    }

    @Test func gatewayNameIsShortInTheBarAndSaved() async {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        f.script.on("session.title") { p, _ in ["title": p["title"] ?? ""] }
        event(f, "Database connection pool troubleshooting guide")
        #expect(f.session.title == "Database connection…")
        #expect(await waitUntil { f.params("session.title").last?["title"]?.string == "Database connection…" })
    }

    @Test func alreadyShortGatewayNameNeedsNoWrite() async {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        event(f, "Database pool repair")
        #expect(f.session.title == "Database pool repair")
        #expect(f.params("session.title").isEmpty)
    }

    @Test func manualAndBotNamesAreNotRewritten() async throws {
        let f = MenusFixtureChat()
        let typed = "My deliberately long database investigation name"
        f.script.on("session.title") { p, _ in ["title": p["title"] ?? ""] }
        _ = try await f.session.rename(to: typed)
        event(f, "Other generated title")
        #expect(f.session.title == typed)
        f.session.menus.isBotChat = true
        f.session.title = "Bot Chat"
        event(f, "Database connection pool troubleshooting guide")
        #expect(f.session.title == "Bot Chat")
    }

    @Test func gatewayModelStillImprovesTheInstantOpeningWords() async {
        let f = MenusFixtureChat()
        let message = "Please investigate the database connection pool timeout errors"
        f.session.title = "New Chat"
        f.session.messages = [ChatMessage(id: "u1", role: .user, parts: [.text(message)], timestamp: nil, rowId: nil)]
        f.script.on("session.title") { p, _ in ["title": p["title"] ?? ""] }
        let instant = ShortTitle.fallback(for: message)
        event(f, "Please investigate the database…")
        #expect(f.session.title == instant)
        event(f, "Database connection pool troubleshooting guide")
        #expect(f.session.title == "Database connection…")
        #expect(await waitUntil { f.params("session.title").last?["title"]?.string == "Database connection…" })
        event(f, instant) // a late echo of the first short-name save
        #expect(f.session.title == "Database connection…")
    }

    @Test func manualRenameWinsOverAnAutomaticSaveAlreadyOnTheWire() async throws {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        let gate = MenusGate()
        f.script.on("session.title") { p, attempt in
            if attempt == 1 { await gate.wait() }
            return ["title": p["title"] ?? ""]
        }
        event(f, "Database connection pool troubleshooting guide")
        #expect(await waitUntil { f.params("session.title").count == 1 })
        let typed = "My deliberately long database investigation name"
        let rename = Task { try await f.session.rename(to: typed) }
        #expect(await waitUntil { f.session.title == typed })
        #expect(f.params("session.title").count == 1, "the explicit write waits for the automatic one")
        gate.release()
        #expect(try await rename.value == typed)
        #expect(f.params("session.title").last?["title"]?.string == typed)
        event(f, "Database connection…")
        #expect(f.session.title == typed)
    }

    @Test func explicitPlaceholderLikeNameAlsoWins() async throws {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        f.script.on("session.title") { p, _ in ["title": p["title"] ?? ""] }
        _ = try await f.session.rename(to: "New Chat")
        event(f, "Database connection pool troubleshooting guide")
        #expect(f.session.title == "New Chat")
        await f.session.performSlash("/title A deliberately long custom session title", recordInput: true)
        event(f, "Database connection pool troubleshooting guide")
        #expect(f.session.title == "A deliberately long custom session title")
    }

    @Test func lateGatewayNameIsSavedAfterLocalFallback() async {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        f.script.on("session.title") { p, _ in ["title": p["title"] ?? ""] }
        f.session.receiveAutomaticTitle("Repair database", alreadyStored: false)
        await f.session.automaticTitleSave?.value
        event(f, "Database connection pool troubleshooting guide")
        await f.session.automaticTitleSave?.value
        #expect(f.session.title == "Database connection…")
        #expect(f.params("session.title").last?["title"]?.string == "Database connection…")
        event(f, "Repair database") // a late echo of the local save
        #expect(f.session.title == "Database connection…")
    }

    @Test func shortGatewayNameIsReassertedAfterOlderInFlightSave() async {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        let message = "Please investigate the database connection pool timeout errors"
        f.session.messages = [ChatMessage(id: "u1", role: .user, parts: [.text(message)], timestamp: nil, rowId: nil)]
        let gate = MenusGate()
        f.script.on("session.title") { p, attempt in
            if attempt == 1 { await gate.wait() }
            return ["title": p["title"] ?? ""]
        }
        event(f, "Please investigate the database…")
        #expect(await waitUntil { f.params("session.title").count == 1 })
        event(f, "Database pool repair")
        gate.release()
        await f.session.automaticTitleSave?.value
        #expect(f.session.title == "Database pool repair")
        #expect(f.params("session.title").last?["title"]?.string == "Database pool repair")
    }

    @Test func manualNameSurvivesANewChatObject() async throws {
        let f = MenusFixtureChat()
        f.script.on("session.title") { p, _ in ["title": p["title"] ?? ""] }
        _ = try await f.session.rename(to: "New Chat")
        let reopened = LiveChatSession(client: f.client, account: f.session.account, profile: f.session.profile,
                                       storedSessionId: f.session.storedSessionId, title: "New Chat", head: nil,
                                       cache: makeTempCache(), resolveSessionId: nil, frameMode: .manual)
        reopened.runtimeSessionId = f.rid1
        reopened.receive(GatewayEvent(type: "session.title", sessionId: f.rid1, seq: nil,
                                       payload: ["title": "Database connection pool troubleshooting guide"]))
        #expect(reopened.title == "New Chat")
    }

    @Test(arguments: [false, true]) func failedManualWriteDoesNotDisableNaming(slash: Bool) async {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        f.script.on("session.title") { _, _ in throw RPCError(code: 5000, message: "unavailable", data: nil) }
        f.client.onRest { _, _ in throw HTTPError(status: 503, body: "unavailable") }
        if slash { await f.session.performSlash("/title My manual name", recordInput: true) }
        else { _ = try? await f.session.rename(to: "My manual name") }
        event(f, "Database pool repair")
        #expect(f.session.title == "Database pool repair")
    }
}
