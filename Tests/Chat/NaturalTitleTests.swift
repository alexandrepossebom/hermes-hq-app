import Synchronization
import Testing
@testable import HermesHQNative

@Suite struct NaturalTitleTests {
    nonisolated static let naturalNames = [
        "How to write a CV", "The cost of a repair", "Light and dark mode", "Do not erase logs",
        "État de la commande", "カメラの設定を確認", "C# and C++",
        "iOS settings", ".NET setup", "npm packages", "Yahoo!", "iPhone setup", "*.swift files",
    ]

    @Test(arguments: naturalNames)
    func fittingModelNamesKeepTheirGrammar(title: String) {
        #expect(ShortTitle.accepted(title, message: "An unrelated opening request") == title)
    }

    @Test(arguments: naturalNames)
    func fittingGatewayNamesAreNotTurnedIntoKeywords(title: String) {
        #expect(ShortTitle.compact(title) == title)
    }

    @Test(arguments: naturalNames)
    func shortOpeningRequestsRemainWhole(title: String) {
        #expect(ShortTitle.fallback(for: title) == title)
        #expect(!ShortTitle.isPlaceholder(title, firstMessage: title))
    }

    @Test(arguments: [
        "Look at the spacing of form fields and review their alignment.",
        "Can you please check why the Postgres pool keeps running out?",
        "I just added another Acme ceiling light in the spare room. Set it up.",
        "Plan a day at the beach for my friends and family",
        "Please check why the local cache is not updating",
        "Compare tea and coffee before choosing a drink",
    ])
    func offlineExcerptsPreserveGrammarAndRemainEligibleForNaming(message: String) {
        let title = ShortTitle.fallback(for: message)
        #expect(title.count <= ShortTitle.excerptCharacters)
        #expect(title.hasSuffix("…"))
        #expect(ShortTitle.normalized(message).hasPrefix(ShortTitle.normalized(title)))
        #expect(ShortTitle.isPlaceholder(title, firstMessage: message))
        #expect(ShortTitle.fallback(for: "Look at the spacing of form fields") == "Look at the spacing of form fields")
        #expect(ShortTitle.fallback(for: "Look at the spacing of form fields and review their alignment.")
                == "Look at the spacing of form fields and…")
    }

    /// The on-device model answers in lowercase. Its name takes each word's spelling from the message and starts
    /// with a capital; a gateway's name is already written and keeps its own case.
    @Test(arguments: [
        ("ios app crash", "My iOS settings app crashes when I open Wi-Fi.", "iOS app crash"),
        ("cv for first job", "Explain how to write a CV for a first job.", "CV for first job"),
        ("quick question", "Hi! Quick question, are you there?", "Quick question"),
        ("my account locked", "Why can I no longer sign into this account?", "My account locked"),
        ("wi-fi crash in .net app", "My .NET app drops Wi-Fi.", "Wi-Fi crash in .NET app"),
        ("Form layout review", "look at the form", "Form layout review"),
        ("ßtraße", "ßtraße", "ßtraße"),
        // The model's own spelling is kept when it isn't all lowercase, and a shouted message lends no spelling.
        ("iOS app crash", "My Ios app keeps crashing", "iOS app crash"),
        ("iPhone won't charge", "MY IPHONE WON'T CHARGE", "iPhone won't charge"),
        ("phone won't charge", "MY PHONE WON'T CHARGE", "Phone won't charge"),
        ("cv fix", "Fix CV", "CV fix"),
        // Short acronyms are not shouting.
        ("aws iam sso setup", "Set up AWS IAM SSO", "AWS IAM SSO setup"),
        ("aws iam fix", "Fix AWS IAM", "AWS IAM fix"),
        // An all-caps message of short words is still shouting.
        ("mac won't boot", "MY MAC WON'T BOOT", "Mac won't boot"),
        ("cv fix", "FIX MY CV NOW", "Cv fix"),
    ])
    func modelNamesGetTheMessagesSpelling(name: String, message: String, expected: String) {
        #expect(ShortTitle.restoringCase(name, from: message) == expected)
    }

    @Test func modelNameIsCasedAfterItIsAccepted() async {
        let name = await ShortTitle.modelName(for: "My iOS settings app crashes.", using: { _, _ in "ios app crash" })
        #expect(name == "iOS app crash")
    }

    @Test func gatewayNamesAreKeptWholeAtAnyLength() {
        #expect(ShortTitle.compact("How to write a CV and build a portfolio") == "How to write a CV and build a portfolio")
        #expect(ShortTitle.compact("App permissions and privacy controls") == "App permissions and privacy controls")
        #expect(ShortTitle.compact("My account has been locked again") == "My account has been locked again")
        #expect(ShortTitle.compact("The man I have been lately") == "The man I have been lately")
        let long = "Migrating the Postgres connection pool to PgBouncer for the staging and production clusters"
        #expect(ShortTitle.compact(long) == long)
        #expect(ShortTitle.compact("How to write a CV and build a portfolio...") == "How to write a CV and build a portfolio…")
        #expect(ShortTitle.compact("\"Title: ‘Title: How to write a CV’\"") == "How to write a CV")
        #expect(ShortTitle.compact("Title: **iOS settings**.") == "iOS settings")
        #expect(ShortTitle.compact("\".NET setup\".") == ".NET setup")
        #expect(ShortTitle.compact("\"Yahoo!\".") == "Yahoo!")
        #expect(ShortTitle.isPlaceholder("\"Please check…", firstMessage: "\"Please check the form labels\""))
    }

    @Test func aCompleteModelNameMayShareTheOpeningWords() {
        #expect(ShortTitle.accepted("How to write a CV", message: "How to write a CV for my first job?") == "How to write a CV")
    }

    @Test(arguments: ["Please check...", "\"Please check...\"", "“Please check...”", "Please check…",
                      "\"Please check...\".", "“Please check…”.", "Title: **Please check...**."])
    func cutModelAnswersAreNotMadeToLookComplete(title: String) {
        #expect(ShortTitle.accepted(title, message: "Please check the spacing around these form labels") == nil)
    }

    @Test func multilineFallbacksDoNotHideTheCut() {
        let message = "Please investigate\nthe database connection problem now"
        let title = ShortTitle.fallback(for: message)
        #expect(title.hasSuffix("…"))
        #expect(ShortTitle.isPlaceholder(title, firstMessage: message))
        #expect(ShortTitle.fallback(for: "Light\nand dark mode") == "Light and dark mode")
    }

    @Test(arguments: ["Please investigate…", "Please investigate...", "\"Please investigate...\"",
                      "\"Please investigate...\".", "“Please investigate…”.", "Title: **Please investigate...**."])
    func cutTitlesRemainProvisionalBeforeHistoryLoads(title: String) {
        #expect(ShortTitle.isPlaceholder(title, firstMessage: ""))
        let compact = ShortTitle.compact(title)
        #expect(compact == "Please investigate…")
        #expect(ShortTitle.isPlaceholder(compact, firstMessage: ""))
    }

    @Test(arguments: [
        "\"Please check the spacing around these form labels\"",
        "“Please check the spacing around these form labels”",
        "Title: Please check the spacing around these form labels",
        "\"Title: Please check the spacing around these form labels\"",
        "ß" + String(repeating: "a", count: 50),
    ])
    func cleanedExcerptsAreStillRecognizable(message: String) {
        let title = ShortTitle.fallback(for: message)
        #expect(ShortTitle.isPlaceholder(title, firstMessage: message))
    }
}

@Suite(.serialized) @MainActor struct NaturalTitleFlowTests {
    nonisolated static let lockedOut = "Why can I no longer sign into this account?"

    /// A chat whose gateway name arrived cut by the gateway ("..."), saved with one ellipsis: "My account has been locked again…".
    private func cutGatewayChat() async -> MenusFixtureChat {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        f.session.messages = [ChatMessage(id: "u1", role: .user, parts: [.text(Self.lockedOut)], timestamp: nil, rowId: nil)]
        f.script.on("session.title") { p, _ in ["title": p["title"] ?? ""] }
        f.session.receiveAutomaticTitle("My account has been locked again...")
        await f.session.automaticTitleSave?.value
        return f
    }

    private func receiver(_ f: MenusFixtureChat, reopen: Bool) -> LiveChatSession {
        let r = reopen ? LiveChatSession(client: f.client, account: f.session.account, profile: f.session.profile,
            storedSessionId: f.session.storedSessionId, title: f.session.title, head: nil,
            cache: makeTempCache(), resolveSessionId: nil, frameMode: .manual) : f.session
        r.runtimeSessionId = f.rid1
        r.messages = f.session.messages
        r.shortTitleDelay = .zero
        return r
    }

    @Test(arguments: [false, true])
    func cutGatewayNameGetsAnOnDeviceNameWhenTheModelIsAvailable(reopen: Bool) async {
        let f = await cutGatewayChat()
        let r = receiver(f, reopen: reopen)
        let asked = Mutex<[String?]>([])
        r.titleModel = { _, long in asked.withLock { $0.append(long) }; return "Account locked" }
        r.hasOlder = true // the opening page isn't loaded: nothing to name from yet
        r.shortenTitleIfNeeded()
        #expect(!r.shortTitleTried)
        r.hasOlder = false
        r.shortenTitleIfNeeded()
        #expect(r.shortTitleTried)
        await r.shortTitleTask?.value
        await r.automaticTitleSave?.value
        #expect(r.title == "Account locked")
        #expect(f.params("session.title").last?["title"] == "Account locked")
        // The model is asked to restate the composed name (the full one when this instance received it).
        #expect(asked.withLock { $0 } == [reopen ? "My account has been locked again…" : "My account has been locked again..."])
        r.receiveAutomaticTitle("My account has been locked again…") // a late echo of the cut save
        #expect(r.title == "Account locked")
    }

    /// The usual live order: the turn ends while the chat is still "New Chat", and the gateway's cut name arrives
    /// during the wait. That cut name must still get the model's name.
    @Test func cutGatewayNameArrivingDuringTheWaitGetsTheModelName() async {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        f.session.messages = [ChatMessage(id: "u1", role: .user, parts: [.text(Self.lockedOut)], timestamp: nil, rowId: nil)]
        f.script.on("session.title") { p, _ in ["title": p["title"] ?? ""] }
        let gate = MenusGate()
        let asked = Mutex<[String?]>([])
        f.session.shortTitleDelay = .milliseconds(200)
        f.session.titleModel = { _, long in asked.withLock { $0.append(long) }; await gate.wait(); return "Account locked" }
        f.session.shortenTitleIfNeeded()
        f.session.receiveAutomaticTitle("My account has been locked again...")
        await f.session.automaticTitleSave?.value
        #expect(f.session.title == "My account has been locked again…")
        gate.release()
        await f.session.shortTitleTask?.value
        await f.session.automaticTitleSave?.value
        #expect(f.session.title == "Account locked")
        #expect(asked.withLock { $0 } == ["My account has been locked again..."])
    }

    /// The gateway's cut name can also land while the model is still answering for the opening words.
    @Test func cutGatewayNameArrivingDuringTheModelCallStillGetsItsName() async {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        f.session.messages = [ChatMessage(id: "u1", role: .user, parts: [.text(Self.lockedOut)], timestamp: nil, rowId: nil)]
        f.script.on("session.title") { p, _ in ["title": p["title"] ?? ""] }
        let gate = MenusGate()
        let calls = Mutex(0)
        f.session.shortTitleDelay = .zero
        f.session.titleModel = { _, _ in calls.withLock { $0 += 1 }; await gate.wait(); return "Account locked" }
        f.session.shortenTitleIfNeeded()
        #expect(await waitUntil { calls.withLock { $0 } == 1 })
        f.session.receiveAutomaticTitle("My account has been locked again...")
        await f.session.automaticTitleSave?.value
        #expect(f.session.title == "My account has been locked again…")
        gate.release()
        await f.session.shortTitleTask?.value
        await f.session.automaticTitleSave?.value
        #expect(f.session.title == "Account locked")
        #expect(calls.withLock { $0 } == 1)
    }

    @Test(arguments: [nil, "Sure, I can help you get back into your locked account right away today", "Please check…",
                      "New Chat", "Why can I no longer…"])
    func cutGatewayNameIsKeptWhenTheModelGivesNoUsableName(answer: String?) async {
        let f = await cutGatewayChat()
        let writes = f.params("session.title").count
        let r = receiver(f, reopen: false)
        r.titleModel = { _, _ in answer }
        r.shortenTitleIfNeeded()
        await r.shortTitleTask?.value
        await r.automaticTitleSave?.value
        #expect(r.title == "My account has been locked again…", "no model, or no usable name: never the opening excerpt")
        #expect(f.params("session.title").count == writes)
    }

    @Test func renameDuringTheModelWaitWins() async throws {
        let f = await cutGatewayChat()
        let r = receiver(f, reopen: false)
        let gate = MenusGate()
        let calls = Mutex(0)
        r.titleModel = { _, _ in calls.withLock { $0 += 1 }; await gate.wait(); return "Account locked" }
        r.shortenTitleIfNeeded()
        // Rename only once the model is really running, so this covers the answer arriving after the rename.
        #expect(await waitUntil { calls.withLock { $0 } == 1 })
        _ = try await r.rename(to: "My own name")
        gate.release()
        await r.shortTitleTask?.value
        await r.automaticTitleSave?.value
        #expect(calls.withLock { $0 } == 1)
        #expect(r.title == "My own name")
        #expect(f.params("session.title").last?["title"] == "My own name")
    }

    @Test func openingExcerptStillGetsTheModelOrItsFallback() async {
        let f = MenusFixtureChat()
        let message = "Look at the spacing of form fields and review their alignment."
        f.session.title = "New Chat"
        f.session.messages = [ChatMessage(id: "u1", role: .user, parts: [.text(message)], timestamp: nil, rowId: nil)]
        f.script.on("session.title") { p, _ in ["title": p["title"] ?? ""] }
        f.session.shortTitleDelay = .zero
        let asked = Mutex<[String?]>([])
        f.session.titleModel = { _, long in asked.withLock { $0.append(long) }; return "Form layout review" }
        f.session.receiveAutomaticTitle("Look at the spacing of form…")
        f.session.shortenTitleIfNeeded()
        await f.session.shortTitleTask?.value
        await f.session.automaticTitleSave?.value
        #expect(f.session.title == "Form layout review")
        #expect(asked.withLock { $0 } == [nil], "an opening excerpt is named from the message alone")
    }

    @Test(arguments: [false, true])
    func clippedGatewayNameCanImproveWithoutBecomingAnOpeningExcerpt(reopen: Bool) async {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        f.session.messages = [ChatMessage(id: "u1", role: .user,
            parts: [.text("Why can I no longer sign into this account?")], timestamp: nil, rowId: nil)]
        f.script.on("session.title") { p, _ in ["title": p["title"] ?? ""] }
        f.session.receiveAutomaticTitle("My account has been locked again...")
        await f.session.automaticTitleSave?.value
        #expect(f.session.title == "My account has been locked again…")
        #expect(f.params("session.title").last?["title"] == "My account has been locked again…")
        let receiver = reopen ? LiveChatSession(client: f.client, account: f.session.account, profile: f.session.profile,
            storedSessionId: f.session.storedSessionId, title: f.session.title, head: nil,
            cache: makeTempCache(), resolveSessionId: nil, frameMode: .manual) : f.session
        receiver.runtimeSessionId = f.rid1
        receiver.messages = f.session.messages
        // It is a cut composed name, not the opening: an unavailable local model must not replace it with that opening.
        receiver.shortTitleDelay = .zero
        receiver.titleModel = { _, _ in nil }
        receiver.shortenTitleIfNeeded()
        await receiver.shortTitleTask?.value
        #expect(receiver.title == "My account has been locked again…")
        for hasOlder in [false, true] {
            receiver.hasOlder = hasOlder
            receiver.receiveAutomaticTitle(ShortTitle.fallback(for: "Why can I no longer sign into this account?"))
            #expect(receiver.title == "My account has been locked again…", "an older opening excerpt must not displace a composed name")
        }
        receiver.receiveAutomaticTitle("Account locked") // the gateway already stored this better, fitting name
        await receiver.automaticTitleSave?.value
        #expect(receiver.title == "Account locked")
    }

    @Test(arguments: [false, true])
    func properNameCanArriveBeforeTheOpeningPage(hasOlder: Bool) async {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        f.session.hasOlder = hasOlder
        f.session.messages = hasOlder ? [ChatMessage(id: "u2", role: .user,
            parts: [.text("A recent message on a later page")], timestamp: nil, rowId: nil)] : []
        f.script.on("session.title") { p, _ in ["title": p["title"] ?? ""] }
        f.session.receive(GatewayEvent(type: "session.title", sessionId: f.rid1, seq: nil,
                                       payload: ["title": "Please investigate..."]))
        #expect(f.session.title == "Please investigate…")
        f.session.receive(GatewayEvent(type: "session.title", sessionId: f.rid1, seq: nil,
                                       payload: ["title": "Connection settings"]))
        await f.session.automaticTitleSave?.value
        #expect(f.session.title == "Connection settings")
        #expect(f.params("session.title").last?["title"] == "Connection settings")
    }

    @Test func aFittingGatewayPrefixIsNotRewrittenAsAnExcerpt() {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        f.session.messages = [ChatMessage(id: "u1", role: .user,
            parts: [.text("How to write a CV for my first job?")], timestamp: nil, rowId: nil)]
        f.session.receive(GatewayEvent(type: "session.title", sessionId: f.rid1, seq: nil,
                                       payload: ["title": "How to write a CV"]))
        #expect(f.session.title == "How to write a CV")
        #expect(f.params("session.title").isEmpty)
    }

    @Test func readableExcerptYieldsToAModelSummary() async {
        let f = MenusFixtureChat()
        let message = "Look at the spacing of form fields and review their alignment."
        f.session.title = "New Chat"
        f.session.messages = [ChatMessage(id: "u1", role: .user, parts: [.text(message)], timestamp: nil, rowId: nil)]
        f.script.on("session.title") { p, _ in ["title": p["title"] ?? ""] }
        f.session.receive(GatewayEvent(type: "session.title", sessionId: f.rid1, seq: nil,
                                       payload: ["title": "Look at the spacing of form…"]))
        #expect(f.session.title == "Look at the spacing of form fields and…")
        f.session.receive(GatewayEvent(type: "session.title", sessionId: f.rid1, seq: nil,
                                       payload: ["title": "Form layout review"]))
        await f.session.automaticTitleSave?.value
        #expect(f.session.title == "Form layout review")
    }

    @Test func fittingGatewayPhraseIsShownWithoutARewrite() {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        let title = "The cost of a repair"
        f.session.receive(GatewayEvent(type: "session.title", sessionId: f.rid1, seq: nil,
                                       payload: ["title": .string(title)]))
        #expect(f.session.title == title)
        #expect(f.params("session.title").isEmpty)
    }
}
