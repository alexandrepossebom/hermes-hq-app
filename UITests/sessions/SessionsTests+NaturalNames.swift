import XCTest

extension SessionsTests {
    @MainActor func testNaturalName_FittingPhraseIOS() throws {
        try checkNaturalName(desktop: false, opening: false)
    }

    @MainActor func testNaturalName_FittingPhraseDesktop() throws {
        try checkNaturalName(desktop: true, opening: false)
    }

    @MainActor func testNaturalName_OfflinePhraseIOS() throws {
        try checkNaturalName(desktop: false, opening: true)
    }

    @MainActor func testNaturalName_OfflinePhraseDesktop() throws {
        try checkNaturalName(desktop: true, opening: true)
    }

    @MainActor private func checkNaturalName(desktop: Bool, opening: Bool) throws {
        let message = "Look at the spacing of form fields and review their alignment."
        let raw = opening ? "Look at the spacing of form…" : "The cost of a repair"
        var expected = opening ? "Look at the spacing of form fields and…" : raw
        setRow("s-trip", ["title": "New Chat", "messages": [
            ["role": "user", "content": message, "id": 1],
            ["role": "assistant", "content": "The labels and inputs are ready for review.", "id": 2],
        ]])
        let extra = desktop ? ["-HQDebugDesktopLook", "YES"] : []
        let app = launch(fresh: true, extra: extra)
        openChat(app, "s-trip")
        let openingMessage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", message)).firstMatch
        XCTAssertTrue(openingMessage.waitForExistence(timeout: 8), "the opening message has loaded before its title event")
        let title = app.descendants(matching: .any)["chat.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        setRow("s-trip", ["title": raw])
        fixture("/__fixture/emit", ["type": "session.title", "session_id": "s-trip", "payload": ["title": raw]])
        let named = waitUntil(8) { title.label.hasPrefix(expected + ",") || title.label == expected }
        shot(app, "natural-name-\(opening ? "offline" : "grammar")-\(desktop ? "desktop" : "ios")")
        XCTAssertTrue(named, title.label)
        if opening {
            XCTAssertFalse(waitUntil(3) { self.rpc("session.title").contains { $0["title"] as? String == expected } },
                           "the opening words are shown, never stored: the gateway would take them as a rename")
            expected = "Form layout review"
            setRow("s-trip", ["title": expected])
            fixture("/__fixture/emit", ["type": "session.title", "session_id": "s-trip", "payload": ["title": expected]])
            XCTAssertTrue(waitUntil(8) { title.label.hasPrefix(expected + ",") || title.label == expected }, title.label)
            shot(app, "natural-name-summary-\(desktop ? "desktop" : "ios")")
        }
        backToList(app)
        XCTAssertTrue(waitUntil(8) { self.labelOf(self.row(app, "s-trip")).hasPrefix(expected) })
        app.terminate()
        let reopened = launch(keepView: true, extra: extra)
        openChat(reopened, "s-trip")
        let restored = reopened.descendants(matching: .any)["chat.title"].firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertTrue(restored.label.hasPrefix(expected + ",") || restored.label == expected, restored.label)
    }
}
