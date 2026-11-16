import XCTest

extension SessionsTests {
    @MainActor func testNameLimit_GatewayTitleIsShortAndSurvivesReopen() throws {
        try checkShortName(desktop: false)
    }

    @MainActor func testNameLimit_DesktopTitleIsShortAndSurvivesReopen() throws {
        try checkShortName(desktop: true)
    }

    @MainActor private func checkShortName(desktop: Bool) throws {
        let raw = "Database connection pool troubleshooting guide"
        let short = "Database connection…"
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
        XCTAssertTrue(waitUntil(8) { self.rpc("session.title").contains { $0["title"] as? String == short } },
                      "the short name is stored, not merely clipped for display")
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
