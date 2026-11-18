import XCTest

// [appearance-groups] Settings › Appearance is a page of its own behind one row of the Settings list (owner
// 2026-11-18). Its rows (Theme, Chat Bubbles, Backgrounds, Chats Under Bots, Working Ring, Tabs, App Icon, and the
// Light or Dark, Desktop Look, UI Scale, Density and Top Edge controls) were on the Settings list or the Theme page.

extension XCUIApplication {
    /// Opens Appearance from the Settings list on show; does nothing when its page is already up.
    @MainActor @discardableResult func hqOpenAppearance(timeout: TimeInterval = 20) -> Bool {
        let list = descendants(matching: .any).matching(identifier: "settings.appearance-list").firstMatch
        let row = buttons["settings.appearance-row"]
        let deadline = Date().addingTimeInterval(timeout)
        while !(list.exists || row.exists), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if list.exists { return true }
        for _ in 0..<6 where !(row.exists && row.isHittable) { swipeDown() }
        guard row.exists else { return false }
        row.tap()
        return list.waitForExistence(timeout: 8)
    }

    /// A row or control of Appearance, scrolled into view on its page.
    @MainActor func hqAppearance(_ element: XCUIElement) -> XCUIElement {
        hqOpenAppearance()
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            if element.exists, element.frame.midY < frame.midY { swipeDown() } else { swipeUp() }
        }
        return element
    }
}
