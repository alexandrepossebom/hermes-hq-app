// [tasks-colour] Pictures of the Tasks list for the review against the owner's pick (2026-11-22, A of
// artifacts/tasks-colour, "Colour means act"): Today, Upcoming and Inbox with lists, goals, priorities, a late task
// and a bot's question on the page at once. What a colour is on (a hidden mark's ink) is read from the pictures; the
// spoken row is checked here. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_ColourShots);
// HQN_TASKS_LOOK=dark for the dark ones.

import XCTest

extension PagesTests {
    @MainActor func testTasks_ColourShots() throws {
        try account.control("/__fixture/reset", [:])
        try account.control("/__fixture/tasks-mode", ["lists": true, "goals": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let name = Self.lookName
        let today = app.buttons["tasks.view.today"].firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 20), "the views sit under the bar")
        let cleaning = app.cells["task-row-Pick up dry cleaning"].firstMatch
        XCTAssertTrue(cleaning.waitForExistence(timeout: 15))
        // The mark before the name is drawn, not read out: the row says its priority and its list in words.
        let spoken = cleaning.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Medium priority")).firstMatch
        let said = spoken.exists ? spoken.label : cleaning.label
        XCTAssertTrue(said.contains("Medium priority"), "the row says its priority: \(said)")
        XCTAssertTrue(said.contains("in Home"), "and its list: \(said)")
        XCTAssertFalse(said.contains("!"), "the mark is not read out: \(said)")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("colour-1-today" + name)
        app.swipeUp(velocity: .slow)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        shot("colour-2-today-more" + name)

        for (view, shotName) in [("upcoming", "colour-3-upcoming"), ("inbox", "colour-4-inbox")] {
            let pill = app.buttons["tasks.view.\(view)"].firstMatch
            XCTAssertTrue(pill.waitForExistence(timeout: 5), view)
            pill.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            shot(shotName + name)
        }
    }
}
