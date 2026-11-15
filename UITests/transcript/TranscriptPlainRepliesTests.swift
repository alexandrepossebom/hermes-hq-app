// [plain-replies] Chat Bubbles › Reply Bubbles (owner 2026-11-15: "turn off the bot's chat bubbles so that their
// responses show full width just plain in the chat. Just like how it works on Claude. This needs to be a toggle."). An
// extension of TranscriptEndToEndTests, so scripts/e2e-transcript.sh runs it against the transcript fixture.

import XCTest

extension TranscriptEndToEndTests {
    @MainActor func testT40_ReplyBubblesSwitch() throws {
        let account = try FixtureAccount.load()
        try preset(account, "text")
        // Bubbles, the default.
        let before = launch(account, args: ["-hqn.theme.plainReplies", "<false/>"])
        XCTAssertTrue(labelled(before, containing: "Install it for one user").waitForExistence(timeout: 10), "the reply shows")
        shot("reply-bubbles-on")
        before.terminate()

        // The switch, on Settings › Appearance › Chat Bubbles: on until turned off.
        let settings = XCUIApplication()
        settings.launchArguments = ["-HQDebugDesktopLook", "NO", "-HQDebugOpenSettings", "YES", "-dispatch.notifications.asked", "YES"]
        settings.launch()
        let bubblesRow = settings.buttons["settings.chat-bubbles-row"]
        XCTAssertTrue(settings.buttons["settings.theme-row"].waitForExistence(timeout: 20), "Settings opens")
        for _ in 0..<6 where !(bubblesRow.exists && bubblesRow.isHittable) { settings.swipeUp() }
        bubblesRow.tap()
        XCTAssertTrue(settings.navigationBars["Chat Bubbles"].waitForExistence(timeout: 5), "the row opens its page")
        let toggle = settings.switches["theme.replyBubbles"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Reply Bubbles is on the page")
        XCTAssertEqual(toggle.value as? String, "1", "on until turned off")
        shot("reply-bubbles-setting-on")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { toggle.value as? String == "0" }, "the switch turns off")
        XCTAssertTrue(settings.descendants(matching: .any)["theme.replyBubblesNote"].exists, "its note says what it does")
        shot("reply-bubbles-setting-off")
        settings.terminate()

        // Saved: the next launch's chat draws the reply plain, full width.
        let after = launch(account)
        XCTAssertTrue(labelled(after, containing: "Install it for one user").waitForExistence(timeout: 10), "the reply shows")
        shot("reply-bubbles-off")
        after.terminate()

        // A table and a dark chat too, plain.
        try preset(account, "table")
        let table = launch(account)
        XCTAssertTrue(labelled(table, containing: "Here are the plans").waitForExistence(timeout: 10), "the table reply shows")
        shot("reply-bubbles-off-table")
        table.terminate()
    }
}
