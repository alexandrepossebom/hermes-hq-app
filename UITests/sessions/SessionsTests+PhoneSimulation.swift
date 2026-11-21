// Phone Calls (Beta) acceptance against loopback fakes only (scripts/e2e-phone-simulation.sh): the app talks to a
// fake samplehost (scripts/fixtures/fake-samplehost.py) through the DEBUG-only HQ_SAMPLEHOST_BASE_URL. No provider, no real key
// (the synthetic KEYTEST), no real calls. The gateway serves chats and two logins only; it has no phone routes.
import XCTest

extension SessionsTests {
    /// The fake samplehost's base (TEST_RUNNER_HQN_SAMPLEHOST_URL), reached for its `/__fixture/…` hooks.
    func samplehostFixture() throws -> FixtureAccount {
        guard let url = ProcessInfo.processInfo.environment["HQN_SAMPLEHOST_URL"], !url.isEmpty else {
            throw XCTSkip("Run scripts/e2e-phone-simulation.sh (it starts the fake samplehost).")
        }
        return FixtureAccount(url: url, username: "", password: "")
    }

    func samplehostRequests(_ samplehost: FixtureAccount) throws -> [[String: Any]] {
        try samplehost.control("/__fixture/state")["requests"] as? [[String: Any]] ?? []
    }

    /// Every request carried the key in its header only.
    func assertKeyOnlyInHeader(_ samplehost: FixtureAccount, file: StaticString = #filePath, line: UInt = #line) throws {
        for request in try samplehostRequests(samplehost) {
            XCTAssertEqual(request["auth_ok"] as? Bool, true, "\(request)", file: file, line: line)
            XCTAssertEqual(request["key_in_url"] as? Bool, false, "\(request)", file: file, line: line)
            XCTAssertEqual(request["key_in_body"] as? Bool, false, "\(request)", file: file, line: line)
        }
    }

    /// More › Settings › Phone Calls (Beta), from wherever the More tab was left (a second tap on More pops it to its
    /// first page, so a page another account left open is never reused).
    @MainActor func openPhoneSettings(_ app: XCUIApplication) {
        let more = app.tabButton(id: "tab-more", label: "More")
        more.tap()
        let settings = app.cells["more-row-settings"]
        for _ in 0..<3 where !settings.waitForExistence(timeout: 3) { more.tap() }
        if !settings.exists { shot(app, "phone-more-not-found") }
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let phoneSettings = app.buttons["settings.phone-calls"]
        for _ in 0..<6 where !phoneSettings.isHittable { app.swipeUp() }
        XCTAssertTrue(phoneSettings.waitForExistence(timeout: 10)); phoneSettings.tap()
        XCTAssertTrue(app.staticTexts["phone.settings.status"].waitForExistence(timeout: 10))
    }

    /// Types the synthetic key and connects. The fake account has one number (preselected) and no AI Assistant, so the
    /// page offers Create Assistant; one tap makes it, selects it and saves (the owner's 2026-11-20 "I can't select an agent").
    @MainActor func connectsamplehost(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Not connected"].waitForExistence(timeout: 10))
        let key = app.secureTextFields["samplehost API key"]
        XCTAssertTrue(key.waitForExistence(timeout: 15)); key.tap(); key.typeText("KEYTEST")
        XCTAssertFalse((key.value as? String ?? "").contains("KEYTEST"), "the key stays masked")
        shot(app, "phone-masked-key")
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.staticTexts["Connected, choose a number and assistant"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.secureTextFields["samplehost API key"].exists, "the key is never shown again")
        XCTAssertTrue(app.buttons["From number, +15550100001"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Voice connection, Simulated connection"].exists)
        let create = app.buttons["phone.settings.create-assistant"]
        XCTAssertTrue(create.waitForExistence(timeout: 10), "an account with no assistant is offered one")
        shot(app, "phone-no-assistant")
        create.tap()
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Disconnect"].exists)
        shot(app, "phone-ready")
    }

    /// From a chat: open the sheet, fill the confirm form, check nothing dialed before confirming, confirm.
    @MainActor func placeSimulatedCall(_ app: XCUIApplication, _ callButton: XCUIElement, _ samplehost: FixtureAccount) throws {
        let to = app.textFields["phone.to"]
        for _ in 0..<3 where !to.exists {
            callButton.tap(); if to.waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(to.waitForExistence(timeout: 10)); to.tap(); to.typeText("+15550100002")
        let purpose = app.textFields["phone.purpose"].exists ? app.textFields["phone.purpose"] : app.textViews["phone.purpose"]
        purpose.tap(); purpose.typeText("Discuss simulated appointment")
        app.buttons["Review call"].tap()
        let confirm = app.buttons["Place call (billed to samplehost)"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertEqual((try samplehost.control("/__fixture/state")["calls"] as? [[String: Any]])?.count, 0, "review alone must not dial")
        shot(app, "phone-confirm")
        confirm.tap()
    }

    @MainActor func testPhoneCallsSimulatedAcceptance() throws {
        let samplehost = try samplehostFixture()
        try samplehost.control("/__fixture/reset", [:])
        let app = launch(fresh: true, environment: ["HQ_SAMPLEHOST_BASE_URL": samplehost.url + "/v2"])
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 20)); garden.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["chat.phone-calls"].waitForExistence(timeout: 3), "no key: no calling")
        shot(app, "phone-no-key")
        XCTAssertTrue(try samplehostRequests(samplehost).isEmpty, "nothing talks to samplehost before a key is connected")
        app.navigationBars.buttons["BackButton"].firstMatch.tap()

        openPhoneSettings(app)
        connectsamplehost(app)
        let setupRequests = try samplehostRequests(samplehost).map { "\($0["method"] ?? "") \($0["path"] ?? "")" }
        XCTAssertEqual(Set(setupRequests), ["GET /v2/phone_numbers", "GET /v2/ai/assistants", "POST /v2/ai/assistants"],
                       "setup reads and creates only the assistant")
        XCTAssertEqual(setupRequests.filter { $0 == "POST /v2/ai/assistants" }.count, 1, "one assistant made")

        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(garden.waitForExistence(timeout: 15)); garden.tap()
        let callButton = app.buttons["chat.phone-calls"]
        XCTAssertTrue(callButton.waitForExistence(timeout: 20))
        try placeSimulatedCall(app, callButton, samplehost)

        XCTAssertTrue(app.staticTexts["Which simulated time works?"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Hello from the simulated agent."].exists)
        XCTAssertTrue(app.staticTexts["The simulated recipient has a question."].exists)
        XCTAssertTrue(app.staticTexts["Live"].exists)
        shot(app, "phone-question")
        let morning = app.buttons["Morning"]
        for _ in 0..<3 where !morning.isHittable { app.swipeUp() }
        XCTAssertTrue(morning.waitForExistence(timeout: 10)); morning.tap()
        XCTAssertTrue(app.staticTexts["Simulated answer received: Morning"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Which simulated time works?"].exists, "an answered question goes away")
        let answers = try XCTUnwrap(try samplehost.control("/__fixture/state")["answers"] as? [[String: Any]])
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?["tool_call_id"] as? String, "call_ask_1")
        XCTAssertEqual(answers.first?["answer"] as? String, "Morning")
        XCTAssertEqual(answers.first?["roles"] as? [String], ["tool", "system"])
        shot(app, "phone-answered")

        let hangup = app.buttons["Hang up"]
        for _ in 0..<3 where !hangup.isHittable { app.swipeUp() }
        hangup.tap()
        XCTAssertTrue(app.staticTexts["Ended · you hung up"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Hang up"].exists)
        XCTAssertEqual(try samplehost.control("/__fixture/state")["hangups"] as? Int, 1)
        shot(app, "phone-ended")

        app.buttons["phone.close"].tap()
        XCTAssertTrue(app.buttons["phone.close"].waitForNonExistence(timeout: 10), "sheet must actually close before reopening")
        XCTAssertTrue(callButton.waitForExistence(timeout: 10))
        callButton.tap()
        XCTAssertTrue(app.buttons["phone.close"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Ended · you hung up"].waitForExistence(timeout: 10), "the ended call is still shown after reopening")
        XCTAssertTrue(app.staticTexts["Simulated answer received: Morning"].exists)
        shot(app, "phone-reopened")

        let state = try samplehost.control("/__fixture/state")
        XCTAssertEqual(state["problems"] as? [String], [], "every request matched samplehost's documented shape")
        XCTAssertEqual((state["calls"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(state["hangups"] as? Int, 1, "a reopened sheet never hangs up or dials again")
        try assertKeyOnlyInHeader(samplehost)
    }

    /// Account A's key never shows on account B: B has no call button, its settings say Not connected, and B never
    /// talks to samplehost. Back on A, calling works with A's key.
    @MainActor func testPhoneCallsAccountSwitch() throws {
        let samplehost = try samplehostFixture()
        try samplehost.control("/__fixture/reset", [:])
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["HQN_PHONE_B"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let b = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        let original = try XCTUnwrap(account)
        let other = FixtureAccount(url: try XCTUnwrap(b["url"]), username: try XCTUnwrap(b["username"]), password: try XCTUnwrap(b["password"]))
        XCTAssertEqual(original.url, other.url, "same gateway, two independently signed-in logins")
        let app = launch(fresh: true, environment: ["HQ_SAMPLEHOST_BASE_URL": samplehost.url + "/v2"])
        let garden = row(app, "s-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 20))
        openPhoneSettings(app)
        connectsamplehost(app)

        // Sign in as B (More › Settings › gateway card › Add).
        let settingsBack = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(settingsBack.waitForExistence(timeout: 10)); settingsBack.tap()
        let gatewayCard = app.buttons["settings.gateway-card"]
        for _ in 0..<8 where !gatewayCard.exists { app.swipeDown() }
        XCTAssertTrue(gatewayCard.waitForExistence(timeout: 10)); gatewayCard.tap()
        let addGateway = app.buttons["gateway.add"]
        XCTAssertTrue(addGateway.waitForExistence(timeout: 10)); addGateway.tap()
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 10))
        let before = try samplehostRequests(samplehost).count
        account = other; signIn(app); account = original
        XCTAssertTrue(app.tabBars.buttons["Sessions"].waitForExistence(timeout: 30)); app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(garden.waitForExistence(timeout: 20)); garden.tap()
        XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["chat.phone-calls"].waitForExistence(timeout: 5), "B has no key: no calling")
        shot(app, "phone-switch-b-chat")
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        openPhoneSettings(app)
        XCTAssertTrue(app.staticTexts["Not connected"].waitForExistence(timeout: 10), "B never sees A's key")
        XCTAssertFalse(app.staticTexts["Ready"].exists)
        XCTAssertFalse(app.buttons["Disconnect"].exists)
        XCTAssertEqual((app.secureTextFields["samplehost API key"].value as? String ?? "").contains("•"), false, "the field starts empty")
        shot(app, "phone-switch-b-settings")
        XCTAssertEqual(try samplehostRequests(samplehost).count, before, "B never talks to samplehost")

        // Back to A: its key is still there and calling works.
        app.tabBars.buttons["Bots"].tap()
        let switcher = app.buttons["gateway-switcher"].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 15)); switcher.tap()
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'gateway-menu-' AND identifier != 'gateway-menu-cloud'"))
        XCTAssertGreaterThanOrEqual(items.count, 2)
        // Saved gateways are newest first: B is the current first row, A is the second.
        items.element(boundBy: 1).tap()
        XCTAssertTrue(app.tabBars.buttons["Sessions"].waitForExistence(timeout: 20)); app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(garden.waitForExistence(timeout: 20)); garden.tap()
        let callButton = app.buttons["chat.phone-calls"]
        XCTAssertTrue(callButton.waitForExistence(timeout: 20), "A's key is still connected")
        try placeSimulatedCall(app, callButton, samplehost)
        XCTAssertTrue(app.staticTexts["Which simulated time works?"].waitForExistence(timeout: 20))
        let morning = app.buttons["Morning"]
        for _ in 0..<3 where !morning.isHittable { app.swipeUp() }
        XCTAssertTrue(morning.waitForExistence(timeout: 10)); morning.tap()
        XCTAssertTrue(app.staticTexts["Simulated answer received: Morning"].waitForExistence(timeout: 15))
        let hangup = app.buttons["Hang up"]
        for _ in 0..<3 where !hangup.isHittable { app.swipeUp() }
        hangup.tap()
        XCTAssertTrue(app.staticTexts["Ended · you hung up"].waitForExistence(timeout: 10))
        shot(app, "phone-switch-a-ended")
        XCTAssertEqual(try samplehost.control("/__fixture/state")["problems"] as? [String], [])
        try assertKeyOnlyInHeader(samplehost)
    }
}
