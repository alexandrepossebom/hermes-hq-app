import XCTest

/// [project-pins] Owner 2026-11-20: "if you pin a session in that view, the pin doesn't reflect everywhere else … it was
/// just an internally pinned session." A project's ⋯ › Pins Stay in Project: Pin on its page pins the chat there alone.
extension SessionsTests {
    /// Website's page, ⋯ › Pins Stay in Project on; Pin on Quarterly budget puts it in the page's Pinned with no write to
    /// the gateway; back on the list the chat is in no Pinned; on the page again it is still pinned, and Unpin there
    /// takes it out, still without a write.
    @MainActor func test40g_ProjectOnlyPins() throws {
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let toProjects = app.buttons["sessions.pills.projects"], toBots = app.buttons["sessions.pills.bots"]
        XCTAssertTrue(toProjects.waitForExistence(timeout: 15))
        func openWebsite() {
            tapSide(app, toProjects)
            let website = app.buttons["sessions.chip.project.0"]
            XCTAssertTrue(website.waitForExistence(timeout: 6))
            onScreen(app, website).tap()
            XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 6))
            XCTAssertTrue(app.staticTexts["Website"].exists, "Website's page")
        }
        openWebsite()
        let budget = row(app, "s-budget")
        XCTAssertTrue(budget.waitForExistence(timeout: 6), "Quarterly budget is Website's")
        XCTAssertFalse(header(app, "Pinned").exists, "nothing pinned here yet")

        // [project-settings] The switch is on the project's settings page now (⋯ › Project Settings…).
        let more = app.buttons["sessions.projectPage.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let settings = app.buttons["Project Settings…"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the ⋯ has Project Settings…")
        XCTAssertFalse(app.buttons["Pins Stay in Project"].exists, "the switch left the ⋯")
        shot(app, "PP1-project-menu")
        settings.tap()
        let local = app.switches["sessions.projectPage.localPins"]
        XCTAssertTrue(local.waitForExistence(timeout: 8), "Project Settings has Pins Stay in Project")
        XCTAssertEqual(local.value as? String, "0", "off until turned on")
        flipProjectSwitch(app, "sessions.projectPage.localPins", to: true)
        shot(app, "PP1b-project-settings")
        closeProjectSettings(app)
        Thread.sleep(forTimeInterval: 0.8)

        openMenu(app, budget, until: "Pin")
        app.buttons["Pin"].firstMatch.tap()
        XCTAssertTrue(header(app, "Pinned").waitForExistence(timeout: 6), "the page's Pinned")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(writes("PATCH", "/api/sessions/s-budget").contains { $0["pinned"] != nil }, "no pin sent to the gateway")
        shot(app, "PP2-pinned-in-project")

        // The list: Quarterly budget is in no Pinned (Ship the 2.4 release notes, pinned everywhere, still is).
        tapSide(app, toBots)
        XCTAssertTrue(waitUntil(6) { toBots.isSelected && !app.cells["sessions.projectPage"].exists }, "back on the list")
        XCTAssertTrue(row(app, "s-release").waitForExistence(timeout: 6))
        let listed = row(app, "s-budget")
        XCTAssertTrue(listed.waitForExistence(timeout: 6), "Quarterly budget on the list")
        XCTAssertTrue(waitUntil(4) { !self.labelOf(listed).isEmpty }, "its label is read")
        XCTAssertFalse(labelOf(listed).contains("Pinned"), "not pinned on the list (\(labelOf(listed)))")
        shot(app, "PP3-list-not-pinned")

        // The page again: still pinned there; the menu says Unpin, and Unpin takes it out with no write.
        openWebsite()
        XCTAssertTrue(header(app, "Pinned").waitForExistence(timeout: 6), "still pinned on Website's page")
        let again = row(app, "s-budget")
        XCTAssertTrue(waitUntil(4) { self.labelOf(again).contains("Pinned in project") }, "the row says so (\(labelOf(again)))")
        openMenu(app, again, until: "Unpin")
        app.buttons["Unpin"].firstMatch.tap()
        XCTAssertTrue(waitUntil(6) { !self.header(app, "Pinned").exists }, "out of the page's Pinned")
        XCTAssertFalse(writes("PATCH", "/api/sessions/s-budget").contains { $0["pinned"] != nil }, "still no pin write")
        shot(app, "PP4-unpinned")
    }

    /// [read-holds] Owner 2026-11-21: "sessions here move when you open them." Website's page: Quarterly budget (New)
    /// above a newer quiet chat; opened and read, it is still first back on the page. [project-sort] ⋯ › Sort › Newest
    /// puts the newer chat first.
    @MainActor func test40h_ReadingDoesNotMoveAChat() throws {
        let now = Date().timeIntervalSince1970
        fixture("/__fixture/rows", ["id": "s-copy", "set": ["profile": "default", "title": "Homepage copy", "cwd": "/home/hermes/site",
                                                           "last_active": now - 600, "unread": false]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let toProjects = app.buttons["sessions.pills.projects"]
        XCTAssertTrue(toProjects.waitForExistence(timeout: 15))
        tapSide(app, toProjects)
        let website = app.buttons["sessions.chip.project.0"]
        XCTAssertTrue(website.waitForExistence(timeout: 6))
        onScreen(app, website).tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 6))
        func pair() -> [String] { order(app).filter { $0 == "s-budget" || $0 == "s-copy" } }
        XCTAssertTrue(waitUntil(6) { pair() == ["s-budget", "s-copy"] }, "New first (\(pair()))")
        shot(app, "RH1-before-open")
        row(app, "s-budget").tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the chat opens")
        Thread.sleep(forTimeInterval: 1.5)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 6), "back on Website's page")
        XCTAssertTrue(waitUntil(4) { !self.labelOf(self.row(app, "s-budget")).contains("Unread") }, "it was read")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(pair(), ["s-budget", "s-copy"], "reading it moved nothing")
        shot(app, "RH2-after-open")
        app.buttons["sessions.projectPage.more"].tap()
        let sort = app.buttons["Sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 5), "⋯ › Sort")
        sort.tap()
        let newest = app.buttons["Newest"]
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        newest.tap()
        XCTAssertTrue(waitUntil(6) { pair() == ["s-copy", "s-budget"] }, "Newest first (\(pair()))")
        shot(app, "RH3-sort-newest")
    }

    /// [project-by-status] Owner 2026-11-22 (T3 Code's sidebar: "show if sessions are done and ready for you to
    /// view/reply"): ⋯ › Sort › By Status splits Website's page into Needs You, New, Working and Earlier, in that order,
    /// each chat under its state; Needs Me First puts the one Active run back.
    @MainActor func test40x_ByStatusSections() throws {
        let now = Date().timeIntervalSince1970
        for (id, title, ago) in [("s-ask", "Approve the pricing copy", 120.0), ("s-faq", "Build the FAQ section", 240.0),
                                 ("s-copy", "Homepage copy", 600.0)] {
            fixture("/__fixture/rows", ["id": id, "set": ["profile": "default", "title": title, "cwd": "/home/hermes/site",
                                                          "last_active": now - ago, "unread": false]])
        }
        fixture("/__fixture/mode", ["live": ["s-ask": "waiting"], "working": ["s-faq"]])
        defer { fixture("/__fixture/mode", ["live": [String: String](), "working": [String]()]) }
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let toProjects = app.buttons["sessions.pills.projects"]
        XCTAssertTrue(toProjects.waitForExistence(timeout: 15))
        toProjects.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        let website = app.buttons["sessions.chip.project.0"]
        XCTAssertTrue(website.waitForExistence(timeout: 6))
        onScreen(app, website).tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 6))
        shot(app, "BS1-needs-me-first")
        func pick(_ word: String) {
            app.buttons["sessions.projectPage.more"].tap()
            let sort = app.buttons["Sort"]
            XCTAssertTrue(sort.waitForExistence(timeout: 5), "⋯ › Sort")
            sort.tap()
            let choice = app.buttons[word]
            XCTAssertTrue(choice.waitForExistence(timeout: 5), word)
            choice.tap()
        }
        pick("By Status")
        func titles() -> [String] {
            headers(app).compactMap { label in ["Needs You", "New", "Working", "Earlier", "Active"].first { label.hasPrefix($0) } }
        }
        XCTAssertTrue(waitUntil(8) { Array(titles().prefix(4)) == ["Needs You", "New", "Working", "Earlier"] },
                      "state sections in order (\(headers(app)))")
        XCTAssertFalse(titles().contains("Active"))
        let ids = order(app)
        func at(_ id: String) -> Int { ids.firstIndex(of: id) ?? -1 }
        XCTAssertTrue(at("s-ask") >= 0 && at("s-ask") < at("s-budget") && at("s-budget") < at("s-faq") && at("s-faq") < at("s-copy"),
                      "Needs You › New › Working › Earlier (\(ids))")
        shot(app, "BS2-by-status")
        pick("Needs Me First")
        XCTAssertTrue(waitUntil(6) { titles().contains("Active") && !titles().contains("Needs You") },
                      "one Active run again (\(headers(app)))")
    }
}
