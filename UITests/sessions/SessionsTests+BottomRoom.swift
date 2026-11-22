// Owner 2026-11-21 (a screenshot of Sessions scrolled to its end, "Done 100" right on the tab bar): "Session pages need
// some room at the bottom so the last content isn't up against the menu." Run with HQN_SESSIONS_SEED=big so the list
// is longer than the screen.

import XCTest

extension SessionsTests {
    /// Scrolled to its end, the list's last row stands clear of the tab bar.
    @MainActor func testBottomRoomOverTheTabBar() throws {
        let app = launch()
        let list = app.collectionViews["sessions.list"]
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "the tab bar")
        XCTAssertTrue(waitUntil(20) { list.cells.count > 0 }, "rows")
        // To the end (and a little past it: the list settles back to its end).
        for _ in 0..<40 { list.swipeUp(velocity: .fast) }
        Thread.sleep(forTimeInterval: 1.5)
        // Rows and the words of a footer or fold (the Done link is not a row).
        let drawn = list.cells.allElementsBoundByIndex + list.staticTexts.allElementsBoundByIndex
        let lowest = drawn.filter { $0.exists && $0.frame.height > 0 && $0.frame.minY < bar.frame.minY }.map(\.frame.maxY).max() ?? 0
        let room = bar.frame.minY - lowest
        shot(app, "bottom-room")
        XCTAssertGreaterThanOrEqual(room, 20, "the last row clear of the tab bar (room \(room))")
    }
}
