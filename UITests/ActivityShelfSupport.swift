import XCTest

extension XCUIApplication {
    /// Explicitly enter the overview before querying a category. Does not open its detail or invoke an action.
    @MainActor func openActivityOverview(file: StaticString = #filePath, line: UInt = #line) {
        let summary = buttons["chat.shelf.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "the activity pill appears", file: file, line: line)
        if ["detail", "collapsed"].contains(summary.value as? String ?? "") { summary.tap() }
        XCTAssertEqual(summary.value as? String, "expanded", file: file, line: line)
    }

    @MainActor func activityCategory(_ kind: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        openActivityOverview(file: file, line: line)
        let row = descendants(matching: .any)["chat.shelf.\(kind)"].firstMatch
        // Accessibility text and a raised keyboard may require scrolling the overview itself.
        let scroll = scrollViews["chat.shelf.scroll"]
        for _ in 0..<6 {
            if row.waitForExistence(timeout: 1), row.isHittable { break }
            if scroll.exists {
                if row.exists, row.frame.minY < scroll.frame.minY {
                    scroll.swipeDown(velocity: .slow)
                } else {
                    scroll.swipeUp(velocity: .slow)
                }
            }
        }
        return row
    }

    @MainActor func revealActivityAction(_ action: XCUIElement, in kind: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let scroll = scrollViews["chat.shelf.detail.\(kind)"]
        for _ in 0..<8 {
            if action.exists, action.isHittable { break }
            if action.exists, action.frame.minY < scroll.frame.minY {
                scroll.swipeDown(velocity: .slow)
            } else {
                scroll.swipeUp(velocity: .slow)
            }
        }
        XCTAssertTrue(action.isHittable, "the scoped action is reachable in its detail", file: file, line: line)
    }
}
