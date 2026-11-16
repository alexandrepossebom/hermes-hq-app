import XCTest

/// [chat-refine] Real app + transcript fixture: its work line fits, opens, and keeps the full words inside.
final class ChatRefineUITests: XCTestCase {
    @MainActor func testCompactStepLineOpensAndKeepsItsDetails() throws {
        continueAfterFailure = false
        let account = try FixtureAccount.load()
        try account.control("/__fixture/preset", ["profile": "default", "name": "tools"])
        let app = XCUIApplication()
        app.launchEnvironment["HQN_SIGNIN_URL"] = account.url
        app.launchEnvironment["HQN_SIGNIN_USERNAME"] = account.username
        app.launchEnvironment["HQN_SIGNIN_PASSWORD"] = account.password
        app.launchArguments = ["-HQDebugResetAccounts", "YES", "-HQDebugOpenBot", "default",
                               "-hq.chat.toolCallStyle", "bottom", "-hq.chat.fewerTimestamps", "YES",
                               "-dispatch.notifications.asked", "YES"]
        app.launch()
        // The drawn title is "3 steps" (covered in ChatRefineTests); VoiceOver retains the full description.
        let compact = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                                                        "Checked how to use web search", "ran 1 command")).firstMatch
        XCTAssertTrue(compact.waitForExistence(timeout: 35), "the short line keeps the full spoken summary")
        // Sign-in, opening the chat and fresh-history replacement can move/reconfigure this bottom-anchored row.
        // Existence alone isn't readiness to tap. Reading `isHittable` directly records a failure ("activation point
        // invalid") while the row is still fading in, so wait for it through a predicate expectation instead, then
        // for its frame to stay put on screen for a settling window.
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: compact)
        XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: 15), .completed, "the disclosure becomes tappable")
        var previous = CGRect.null
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(10)
        var settled = false
        while Date() < deadline {
            let frame = compact.frame
            let onScreen = !frame.isEmpty && app.windows.firstMatch.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
            if frame != previous || !onScreen { previous = frame; stableSince = Date() }
            if Date().timeIntervalSince(stableSince) >= 0.8 { settled = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(settled, "the disclosure has settled before its first tap")
        let before = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: before); a.name = "chat-refine-collapsed"; a.lifetime = .keepAlways; add(a)
        compact.tap()
        let full = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Checked how to use web search")).firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 10), "the opened steps keep the friendly full description")
        let script = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Ran 1 command")).firstMatch
        XCTAssertTrue(script.waitForExistence(timeout: 10), "the command is still there once expansion has applied")
        let b = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); b.name = "chat-refine-expanded"; b.lifetime = .keepAlways; add(b)
        // The same disclosure closes again; it must not take the reader to another page.
        compact.tap()
        XCTAssertTrue(compact.exists)
        XCTAssertTrue(app.textViews["composer.text"].exists)
        app.terminate()
    }
}
