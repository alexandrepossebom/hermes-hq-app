// [favorites] More › Favorites (docs/spec/3x-morepages.md §24) against the morepages stand-in.
// Run: HQN_MOREPAGES_ONLY="FavoritesUITests" scripts/e2e-morepages.sh <udid>

import XCTest

final class FavoritesUITests: MorePagesCase {
    @MainActor private func row(_ id: String) -> XCUIElement { app.cells["favorites-row-\(id)"] }
    @MainActor private func pick(_ id: String) -> XCUIElement { app.cells["favorites-pick-\(id)"] }

    /// The cells the Favorites list shows, top to bottom.
    @MainActor private var shownIDs: [String] {
        app.collectionViews["favorites.list"].cells.allElementsBoundByIndex.map(\.identifier)
            .filter { $0.hasPrefix("favorites-row-") }.map { String($0.dropFirst("favorites-row-".count)) }
    }

    /// Empty at first; + adds pages from every More group; they open from Favorites; a swipe removes one; the choice
    /// survives a relaunch; Favorites never offers itself or the gateway card.
    @MainActor func testFavorites_AddOpenRemoveKeep() throws {
        launchSignedIn(["-HQDebugResetFavorites", "YES"])
        tab("More")
        XCTAssertTrue(app.cells["more-row-favorites"].waitForExistence(timeout: 8), "Favorites is in More")
        shot("favorites-more-row")
        openMore("favorites")
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 10), "More › Favorites opens its page")
        XCTAssertTrue(app.staticTexts["No Favorites"].waitForExistence(timeout: 5), "an empty list says how to start")
        XCTAssertFalse(app.buttons["favorites.edit"].exists, "nothing to edit yet")
        shot("favorites-empty")

        app.buttons["favorites.add"].tap()
        XCTAssertTrue(app.navigationBars["Add Pages"].waitForExistence(timeout: 5), "+ opens Add Pages")
        XCTAssertFalse(pick("favorites").exists, "Favorites is not offered as a favorite of itself")
        XCTAssertFalse(pick("gateway").exists, "nor the gateway card")
        for id in ["files", "review", "webhooks"] {   // More's order, top to bottom
            let cell = pick(id)
            if !cell.waitForExistence(timeout: 3) {
                for _ in 0..<6 where !cell.exists { app.swipeUp(velocity: .slow) }
                for _ in 0..<6 where !cell.exists { app.swipeDown(velocity: .slow) }
            }
            XCTAssertTrue(cell.waitForExistence(timeout: 5), "Add Pages lists \(id)")
            reach(cell)
            cell.tap()
            XCTAssertTrue(waitUntil(3) { (cell.value as? String) == "In Favorites" }, "\(id) is ticked")
        }
        shot("favorites-picker")
        app.navigationBars["Add Pages"].buttons["Done"].tap()

        XCTAssertTrue(row("files").waitForExistence(timeout: 5), "the picked pages are listed")
        XCTAssertEqual(shownIDs, ["files", "review", "webhooks"], "in the order they were added")
        XCTAssertTrue(app.buttons["favorites.edit"].exists, "Edit shows once there is a page")
        shot("favorites-list")

        row("webhooks").tap()
        XCTAssertTrue(app.navigationBars["Webhooks"].waitForExistence(timeout: 10), "a favorite opens its page")
        back()
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 5), "Back returns to Favorites")

        // The bar morphs Edit into Done, so for a moment both are in the tree: find each by its word.
        let edit = app.buttons.matching(identifier: "favorites.edit")
        edit.matching(NSPredicate(format: "label == 'Edit'")).firstMatch.tap()
        let done = edit.matching(NSPredicate(format: "label == 'Done'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 3), "Edit turns to Done")
        XCTAssertTrue(waitUntil(3) { !edit.matching(NSPredicate(format: "label == 'Edit'")).firstMatch.exists }, "and only Done stays")
        shot("favorites-editing")
        done.tap()
        XCTAssertTrue(edit.matching(NSPredicate(format: "label == 'Edit'")).firstMatch.waitForExistence(timeout: 3), "Done turns back to Edit")

        row("files").swipeLeft()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "a row swipes to Remove")
        remove.tap()
        XCTAssertTrue(waitUntil(5) { !self.row("files").exists }, "Files left Favorites")
        XCTAssertEqual(shownIDs, ["review", "webhooks"])

        relaunch()
        openMore("favorites")
        XCTAssertTrue(row("webhooks").waitForExistence(timeout: 10), "the choice survives a relaunch")
        XCTAssertEqual(shownIDs, ["review", "webhooks"])
    }

    /// Settings › Tabs can make Favorites a tab of its own; it then leaves More, and its pages open in that tab. (The
    /// launch arguments seed what is only read here.)
    @MainActor func testFavorites_AsATab() throws {
        launchSignedIn(["-hqn.favorites", "(review)", "-hqn.tabOrder", "(bots, sessions, \"page.favorites\")"])
        tab("Favorites")
        XCTAssertTrue(row("review").waitForExistence(timeout: 10), "the Favorites tab lists its pages")
        shot("favorites-tab")
        row("review").tap()
        XCTAssertTrue(app.navigationBars["Changes"].waitForExistence(timeout: 10), "a favorite opens in the tab")
        tab("More")
        XCTAssertFalse(app.cells["more-row-favorites"].waitForExistence(timeout: 2), "as a tab it leaves More")
    }
}
