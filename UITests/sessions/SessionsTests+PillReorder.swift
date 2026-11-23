import XCTest

extension SessionsTests {
    /// [pill-reorder] A hold that moves carries the pill past one in another state and saves the order; a swipe only
    /// scrolls; a hold that stays offers Archive, and one that then moves takes the pill along instead; a tap opens.
    @MainActor func testPillReorderDragArchiveTapAndPersistence() throws {
        fixture("/__fixture/mode", ["working": ["s-trip"]])
        defer { fixture("/__fixture/mode", ["working": [String]()]) }
        var app = launch(drag: true, projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let switcher = app.buttons["sessions.pills.projects"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 15))
        tapSide(app, switcher)
        func labels(_ app: XCUIApplication) -> [String] {
            (0..<3).map { index in
                let pill = app.buttons["sessions.chip.project.\(index)"]
                return pill.exists ? pill.label : ""
            }
        }
        XCTAssertTrue(waitUntil(10) { labels(app).count == 3 && labels(app)[1] == "Reading project, Working" && labels(app)[2] == "App project" }, "initial cross-tier order: \(labels(app))")
        let rail = app.scrollViews["sessions.chips"]
        let reading = app.buttons["sessions.chip.project.2"]
        let target = app.buttons["sessions.chip.project.1"]
        onScreen(app, reading)
        XCTAssertTrue(reading.isHittable && target.isHittable, "both pills visible for a real drag")
        shot(app, "pill-reorder-before")
        reading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        let moved = waitUntil(8) { labels(app)[1].hasPrefix("App project") && labels(app)[2].hasPrefix("Reading project") }
        shot(app, "pill-reorder-after-drag")
        XCTAssertTrue(moved, "drag changes order: \(labels(app)); \(rail.debugDescription)")
        guard moved else { return }
        XCTAssertFalse(app.buttons["sessions.chip.project.archive"].exists, "moving hold must not open Archive")
        XCTAssertFalse(app.cells["sessions.projectPage"].exists, "a drag is not a tap")
        // A swipe along the rail scrolls it and moves no pill.
        let before = labels(app)
        app.buttons["sessions.chip.project.2"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.buttons["sessions.chip.project.1"].coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertEqual(labels(app), before, "a swipe does not reorder")
        // Held until Archive shows, then moved: the choice goes and the pill comes along (and back to where it was).
        let again = app.buttons["sessions.chip.project.1"]
        onScreen(app, again).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.1, thenDragTo: app.buttons["sessions.chip.project.2"].coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(waitUntil(8) { labels(app)[1].hasPrefix("Reading project") && labels(app)[2].hasPrefix("App project") }, "held, then dragged: \(labels(app))")
        XCTAssertFalse(app.buttons["sessions.chip.project.archive"].exists, "the choice went when the pill moved")
        shot(app, "pill-reorder-after-menu-drag")
        onScreen(app, app.buttons["sessions.chip.project.2"]).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: app.buttons["sessions.chip.project.1"].coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(waitUntil(8) { labels(app)[1].hasPrefix("App project") && labels(app)[2].hasPrefix("Reading project") }, "dragged back: \(labels(app))")
        app.terminate()
        app = launch(keepView: true, drag: true, projectPages: true)
        XCTAssertTrue(waitUntil(15) { labels(app)[1].hasPrefix("App project") && labels(app)[2].hasPrefix("Reading project") }, "order survives relaunch: \(labels(app))")
        let movedPill = app.buttons["sessions.chip.project.1"]
        onScreen(app, movedPill).tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 8), "tap opens the project page")
        XCTAssertTrue(app.staticTexts["App"].exists)
        onScreen(app, movedPill).tap()
        XCTAssertTrue(waitUntil(6) { !app.cells["sessions.projectPage"].exists }, "tap selected pill returns to all")
        onScreen(app, movedPill).press(forDuration: 1.0)
        let archive = app.buttons["sessions.chip.project.archive"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5), "stationary hold offers Archive Project")
        shot(app, "pill-reorder-stationary-menu")
        archive.tap()
        XCTAssertTrue(waitUntil(8) { labels(app)[1].hasPrefix("Reading project") && !app.buttons["sessions.chip.project.2"].exists }, "archive removes App")
    }
}
