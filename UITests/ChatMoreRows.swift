// [menu-tidy] The chat's ⋯ on iPhone and iPad (owner 2026-11-15): Find · Pin · Archive tiles; Model, Prompts, Usage &
// Limits, Model Prices, Read Replies Aloud, Watch Browser and Rename… on the menu; Mark as Unread, Share and Info, the
// workspace rows and Delete Chat under its More ▸. A test finds a row wherever it lives now.

import XCTest

extension XCUIApplication {
    /// Any ⋯ row (`chat.more.<id>`): shows once the ⋯ menu is open.
    var anyChatMoreRow: XCUIElement {
        buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.more.'")).firstMatch
    }

    /// A ⋯ row on screen now, to scroll the menu by (at the largest text sizes some rows sit outside its frame).
    var visibleChatMoreRow: XCUIElement {
        let rows = buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.more.'")).allElementsBoundByIndex
        return rows.first { $0.isHittable } ?? anyChatMoreRow
    }

    /// The ⋯ row with this id, on the menu itself or under its More ▸, which this opens when the row isn't on the
    /// menu. Call with the ⋯ open.
    @MainActor func chatMoreRow(_ id: String, timeout: TimeInterval = 4) -> XCUIElement {
        let row = buttons["chat.more.\(id)"]
        _ = anyChatMoreRow.waitForExistence(timeout: timeout)
        if row.exists { return row }
        let more = buttons.matching(NSPredicate(format: "label == 'More' AND identifier != 'chat.more'"))
        // The menu's own More ▸, not a tab named More behind it: the menu is drawn last.
        if let submenu = more.allElementsBoundByIndex.last(where: { $0.isHittable }) { submenu.tap() }
        _ = row.waitForExistence(timeout: timeout)
        return row
    }
}
