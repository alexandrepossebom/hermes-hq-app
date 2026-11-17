import XCTest

extension SessionsTests {
    @MainActor func testNameLimit_LongGatewayTitleIsKeptWholeAndSurvivesReopen() throws {
        try checkWholeName(desktop: false)
    }

    @MainActor func testNameLimit_DesktopLongGatewayTitleIsKeptWholeAndSurvivesReopen() throws {
        try checkWholeName(desktop: true)
    }

    /// Session names have no character budget: a long gateway name is shown whole (the screen truncates it) and is
    /// never rewritten as a shorter stored name.
    @MainActor private func checkWholeName(desktop: Bool) throws {
        let raw = "Database connection pool troubleshooting guide for the staging cluster"
        let short = raw
        setRow("s-trip", ["title": "New Chat"])
        // The fixture reuses this stored ID; a preceding Rename test deliberately leaves manual-name provenance.
        let app = launch(fresh: true, extra: desktop ? ["-HQDebugDesktopLook", "YES"] : [])
        openChat(app, "s-trip")
        let title = app.descendants(matching: .any)["chat.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        // What a gateway does when its naming model finishes: store, then emit the name.
        setRow("s-trip", ["title": raw])
        fixture("/__fixture/emit", ["type": "session.title", "session_id": "s-trip", "payload": ["title": raw]])
        XCTAssertTrue(waitUntil(8) { title.label.hasPrefix(short + ",") || title.label == short }, title.label)
        XCTAssertFalse(waitUntil(3) { !self.rpc("session.title").isEmpty },
                       "the gateway's own name is kept as stored, not rewritten shorter (\(rpc("session.title")))")
        shot(app, "name-limit-\(desktop ? "desktop" : "ios")")
        backToList(app)
        XCTAssertTrue(waitUntil(8) { self.labelOf(self.row(app, "s-trip")).hasPrefix(short) })
        app.terminate()
        let reopened = launch(keepView: true, extra: desktop ? ["-HQDebugDesktopLook", "YES"] : [])
        openChat(reopened, "s-trip")
        let restored = reopened.descendants(matching: .any)["chat.title"].firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertTrue(restored.label.hasPrefix(short + ",") || restored.label == short, restored.label)
    }
}
