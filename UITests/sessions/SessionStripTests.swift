import XCTest

/// [session-strip] The bot's other chats as pills under a chat's bar, against the sessions fixture
/// (scripts/fixtures/sessions-gateway.py). On the default seed the main bot (Hermes) has Garden plan (2 min ago),
/// Quarterly budget (26 h ago, unread) and a tool's run (never shown). Run with the sessions fixture as
/// scripts/e2e-sessions.sh does: `HQN_SESSIONS_ONLY` doesn't reach this class; use
/// `-only-testing:HermesHQNativeUITests/SessionStripTests` with the same TEST_RUNNER_ variables.
/// HQN_STRIP_WORK / HQN_STRIP_OTHER may select alternative synthetic fixture rows.
final class SessionStripTests: XCTestCase {
    var account: FixtureAccount!
    nonisolated(unsafe) static var signedIn = false
    var env: [String: String] { ProcessInfo.processInfo.environment }
    var work: String { env["HQN_STRIP_WORK"] ?? "s-garden" }
    var other: String { env["HQN_STRIP_OTHER"] ?? "Quarterly budget" }

    @MainActor func testStripNew_SingleBotChat() throws {
        let app = launch()
        open(app, "s-trip")
        let bot = app.buttons["chat.strip.pill.0"]
        XCTAssertTrue(bot.waitForExistence(timeout: 10))
        bot.tap()
        XCTAssertTrue(waitUntil(10) { self.selected(app).first?.label.contains("Bot Chat") == true })
        try account.control("/__fixture/rows", ["id": "s-trip", "delete": true, "event": true])
        XCTAssertTrue(waitUntil(20) { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.strip.pill.'")).count == 1 })
        XCTAssertTrue(app.buttons["chat.strip.new"].exists)
        shot(app, "new-single-bot")
    }

    @MainActor func testStripNew_FixedAndReturnsToWorkingChat() throws {
        let app = launch()
        open(app, work)
        try account.control("/__fixture/mode", ["prompts": "hold"])
        let field = app.textViews["composer.text"]
        field.tap()
        field.typeText("Please check the garden plan.")
        app.buttons["composer.send"].tap()
        try account.control("/__fixture/mode", ["live": [work: "working"]])
        hideKeys(app)
        let plus = app.buttons["chat.strip.new"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(15) { self.pill(app, "Garden plan").label.contains("Working") })
        shot(app, "new-multiple-working")
        let x = plus.frame.midX
        app.otherElements["chat.strip"].swipeLeft()
        XCTAssertEqual(plus.frame.midX, x, accuracy: 1, "plus stays fixed as the pills move")
        plus.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(15) { (app.textViews["composer.text"].value(forKey: "hasKeyboardFocus") as? Bool) == true }, "fresh composer is focused")
        XCTAssertTrue(pill(app, "Garden plan").exists, "working chat remains available")
        shot(app, "new-fresh-focused")
        hideKeys(app)
        let working = pill(app, "Garden plan")
        if !working.isHittable { app.otherElements["chat.strip"].swipeRight() }
        working.tap()
        XCTAssertTrue(waitUntil(15) { self.selected(app).first?.label.hasPrefix("Garden plan") == true })
        shot(app, "new-returned-working")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        account = try FixtureAccount.load()
        try account.control("/__fixture/reset", [:])
    }

    override func tearDownWithError() throws {
        try? account.control("/__fixture/mode", ["prompts": "", "live": ""])
    }

    /// The strip, its pills and marks; a tap moves to another chat and to the bot's own chat, the bar staying put.
    @MainActor func testStrip1_PillsMoveBetweenChats() throws {
        let app = launch()
        open(app, work)
        let strip = app.otherElements["chat.strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "the strip under the bar")
        let pills = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.strip.pill.'"))
        XCTAssertTrue(waitUntil(10) { pills.count >= 3 }, "the bot's chat and its two active chats (\(pills.count))")
        let first = app.buttons["chat.strip.pill.0"]
        XCTAssertTrue(first.label.contains("Bot Chat"), "the bot's own chat comes first: \(first.label)")
        XCTAssertEqual(selected(app).count, 1)
        XCTAssertFalse(pills.allElementsBoundByIndex.map(\.label).contains { $0.contains("Nightly index run") }, "a tool's run isn't a pill")
        if env["HQN_STRIP_OTHER"] == nil {
            XCTAssertTrue(pill(app, other).label.contains("New reply"), "an unread chat says so: \(pill(app, other).label)")
        }
        shot(app, "strip-1-chat")

        pill(app, other).tap()
        XCTAssertTrue(waitUntil(10) { self.selected(app).first?.label.hasPrefix(self.other) == true }, "the other chat is open, its pill lit")
        XCTAssertTrue(app.otherElements["chat.strip"].exists, "the strip is there on the next chat too")
        shot(app, "strip-2-switched")

        app.buttons["chat.strip.pill.0"].tap()
        XCTAssertTrue(waitUntil(10) { self.selected(app).first?.label.contains("Bot Chat") == true }, "the bot's own chat is open")
        XCTAssertTrue(pill(app, other).exists, "a chat you just went through stays a pill")
        shot(app, "strip-3-bot-chat")

        // One step back leaves the chats: the strip replaces the chat on screen, it doesn't stack them.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 10), "Back goes to the list")
    }

    /// A chat left at work keeps its Working mark on the strip from the next chat.
    @MainActor func testStrip2_WorkingChatSaysSo() throws {
        let app = launch()
        open(app, work)
        try account.control("/__fixture/mode", ["prompts": "hold"])
        let field = app.textViews["composer.text"]
        field.tap()
        field.typeText("Can you check the strip spacing on the small phone?")
        app.buttons["composer.send"].tap()
        try account.control("/__fixture/mode", ["live": [work: "working"]])   // the gateway's live list, as Hermes says it
        hideKeys(app)
        pill(app, other).tap()
        XCTAssertTrue(waitUntil(10) { self.selected(app).first?.label.hasPrefix(self.other) == true })
        let left = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.strip.pill.' AND label CONTAINS 'Working'")).firstMatch
        XCTAssertTrue(left.waitForExistence(timeout: 15), "the chat at work is marked Working")
        shot(app, "strip-4-working")
        app.otherElements["chat.strip"].swipeRight()   // back to the strip's start, where the chat at work sits
        Thread.sleep(forTimeInterval: 1)
        shot(app, "strip-4b-working-start")
    }

    /// Settings › Chat › Other Chats at the Top off: no strip, the chat starts under the bar as before.
    @MainActor func testStrip3_SwitchedOff() throws {
        let app = launch(extra: ["-hqn.sessionStrip", "NO"])
        open(app, work)
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(app.buttons["chat.strip.pill.0"].exists, "no strip while it is off")
        shot(app, "strip-5-off")
    }

    // MARK: Helpers

    @MainActor func selected(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.strip.pill.' AND selected == true")).allElementsBoundByIndex
    }

    @MainActor func pill(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.strip.pill.' AND label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor func open(_ app: XCUIApplication, _ id: String) {
        let row = app.cells["session-row-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the chat's row")
        row.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 15), "the chat")
    }

    @MainActor func hideKeys(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        _ = waitUntil(3) { !app.keyboards.firstMatch.exists }
    }

    @MainActor func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugSessionsTab", "YES", "-HQDebugHUDSeconds", "5", "-HQDebugResetTheme", "YES",
                               "-dispatch.notifications.asked", "YES", "-HQDebugNoSwipePeek", "YES", "-HQDebugResetSessionsView", "YES",
                               "-HQDebugResetUnread", "YES", "-HQDebugNoDrag", "YES"]
            + (env["HQN_SESSIONS_DARK"] == "1" ? ["-HQDebugAppearance", "dark"] : [])
            + (extra.contains("-hqn.sessionStrip") ? [] : ["-hqn.sessionStrip", "YES"]) + extra
        if !Self.signedIn { app.launchArguments += ["-HQDebugResetAccounts", "YES"] }
        _ = addUIInterruptionMonitor(withDescription: "the app's own alerts") { _ in true }
        app.launch()
        let list = app.collectionViews["sessions.list"]
        let form = app.textFields["sign-in-address"]
        _ = waitUntil(20) { list.exists || form.exists }
        if !list.exists && form.exists {
            signIn(app)
            let tab = app.tabBars.buttons["Sessions"]
            if tab.waitForExistence(timeout: 15) { tab.tap() }
        }
        Self.signedIn = true
        XCTAssertTrue(list.waitForExistence(timeout: 20), "the Sessions list")
        return app
    }

    @MainActor func focus(_ field: XCUIElement) {
        for _ in 0..<4 {
            field.tap()
            if waitUntil(5, { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }) { return }
        }
    }

    @MainActor func signIn(_ app: XCUIApplication) {
        let address = app.textFields["sign-in-address"]
        focus(address)
        if let current = address.value as? String, !current.isEmpty, current != "my-mac.tail1234.ts.net" {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        address.typeText(account.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        focus(username)
        if let current = username.value as? String, !current.isEmpty, current != "Username" {
            username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        username.typeText(account.username)
        let password = app.secureTextFields["sign-in-password"]
        focus(password)
        password.typeText(account.password)
        app.buttons["sign-in-password-button"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notNow = [app.buttons["Not Now"], springboard.buttons["Not Now"]]
        if waitUntil(5, { notNow.contains { $0.exists } }), let candidate = notNow.first(where: { $0.exists }) { candidate.tap() }
    }

    @MainActor func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["HQN_SHOTS_DIR"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir)
                .appendingPathComponent("sessions-\(name)\(env["HQN_SESSIONS_DARK"] == "1" ? "-dark" : "").png"))
        }
    }

    @MainActor @discardableResult
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }
}
