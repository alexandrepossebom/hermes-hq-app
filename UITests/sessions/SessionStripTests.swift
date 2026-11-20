import XCTest

/// Native mobile opt-in: an ordinary chat must never acquire its bot’s Live Tabs.
final class SessionStripTests: XCTestCase {
    var account: FixtureAccount!
    var env: [String: String] { ProcessInfo.processInfo.environment }
    override func setUpWithError() throws {
        continueAfterFailure = false
        account = try FixtureAccount.load()
        try account.control("/__fixture/reset", [:])
        try account.control("/__fixture/mode", ["working": ["s-garden"], "live": ["s-garden": "working"]])
        for (id, title, pinned) in [("s-launch", "Launch notes", true), ("s-dinner", "Dinner ideas", false), ("s-reading", "Reading list", false)] {
            try account.control("/__fixture/rows", ["id": id, "set": ["profile": "default", "title": title, "pinned": pinned, "last_active": Date().timeIntervalSince1970 - (id == "s-dinner" ? 900 : 260000)]])
        }
    }

    @MainActor func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugNoSwipePeek", "YES", "-HQDebugResetSessionsView", "YES", "-HQDebugResetUnread", "YES", "-dispatch.notifications.asked", "YES", "-HQDebugResetTheme", "YES", "-HQDebugResetAccounts", "YES", "-HQDebugNoDrag", "YES", "-HQDebugAppearance", env["HQN_SESSIONS_DARK"] == "1" ? "dark" : "light"]
        app.launchEnvironment["HQN_SIGNIN_URL"] = account.url
        app.launchEnvironment["HQN_SIGNIN_USERNAME"] = account.username
        app.launchEnvironment["HQN_SIGNIN_PASSWORD"] = account.password
        app.launch()
        return app
    }

    @MainActor func bot(_ app: XCUIApplication) {
        let bots = app.tabButton(id: "tab-bots", label: "Bots")
        if bots.isHittable { bots.tap() }
        let row = app.cells["bot-row-default"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "fixture bot")
        row.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 15))
    }

    @MainActor func back(_ app: XCUIApplication) { app.navigationBars.buttons.element(boundBy: 0).tap() }
    @MainActor func backToBot(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 8) && button.isHittable, "visible Back on the opened chat")
        button.tap()
        XCTAssertTrue(all(app).waitForExistence(timeout: 12), "Back returns directly to the originating bot chat")
    }
    @MainActor func all(_ app: XCUIApplication) -> XCUIElement { app.buttons["session-strip.all"] }

    /// Install default and real Settings toggle; run against a newly provisioned simulator. No preference launch override.
    @MainActor func testAcceptance_RealSettingsAndRelaunch() throws {
        let app = launch()
        bot(app)
        XCTAssertFalse(all(app).exists); XCTAssertFalse(app.buttons["chat.strip.new"].exists)
        shot(app, "01-default-off")
        back(app)
        settingsStrip(app, expected: "0", turnTo: "1")
        bot(app)
        let all = all(app)
        XCTAssertTrue(all.waitForExistence(timeout: 20), "opt-in shows the bot's live tabs")
        XCTAssertTrue(all.label.contains("5"), "count all five eligible chats: \(all.label)")
        let garden = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Garden plan")).firstMatch
        let budget = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Quarterly budget")).firstMatch
        XCTAssertTrue(garden.exists && budget.exists)
        XCTAssertGreaterThanOrEqual(garden.frame.height, 44)
        shot(app, "03-live-tabs")
        all.tap()
        XCTAssertTrue(app.staticTexts["Launch notes"].waitForExistence(timeout: 8) || app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Launch notes")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Nightly index run"].exists)
        shot(app, "04-all-chats")
        let done = app.buttons["phone-bot-chats.done"]
        XCTAssertTrue(done.exists); done.tap()
        budget.tap()
        XCTAssertTrue(waitUntil(10) { !all.exists })
        shot(app, "05-chat-open")
        backToBot(app)
        shot(app, "06-back-at-bot")
        all.tap()
        let pinned = app.cells["phone-bot-chats.chat.s-launch"]
        XCTAssertTrue(pinned.waitForExistence(timeout: 8)); pinned.tap()
        XCTAssertTrue(waitUntil(10) { !all.exists && app.textViews["composer.text"].exists })
        backToBot(app)
        all.tap()
        let newChat = app.cells["phone-bot-chats.new"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 8)); newChat.tap()
        XCTAssertTrue(waitUntil(10) { !all.exists && app.textViews["composer.text"].exists })
        backToBot(app)
        back(app)
        settingsStrip(app, expected: "1", turnTo: "0")
        app.terminate(); app.launch()
        bot(app)
        XCTAssertFalse(all.exists, "off sticks after a relaunch")
        shot(app, "07-off-again")
    }

    @MainActor func settingsStrip(_ app: XCUIApplication, expected: String, turnTo: String?) {
        let more = app.tabButton(id: "tab-more", label: "More")
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let row = app.cells["more-row-settings"]
        if !app.switches["settings.session-strip"].exists {
            if !row.waitForExistence(timeout: 3) { more.tap() }
            XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        }

        let toggle = app.switches["settings.session-strip"]
        for _ in 0..<14 {
            if toggle.exists && toggle.isHittable && toggle.frame.maxY < app.windows.firstMatch.frame.height - 100 { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(toggle.exists && toggle.isHittable, "actual Settings switch")
        XCTAssertEqual(toggle.value as? String, expected)
        shot(app, "acceptance-setting-\(expected)")
        if let turnTo {
            let inner = toggle.switches.firstMatch
            (inner.exists ? inner : toggle).tap()
            XCTAssertTrue(waitUntil(5) { toggle.value as? String == turnTo })
            shot(app, "setting-now-\(turnTo)")
        }
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
