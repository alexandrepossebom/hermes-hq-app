// [quick-actions] More › Quick Actions (docs/spec/3x-morepages.md §25) against the morepages stand-in: the starter
// set, Add Action and Set Up, rename, Wide, reorder, remove, a tile whose bot isn't there, and the list kept across a
// relaunch. Run: HQN_MOREPAGES_ONLY="QuickActionsUITests" scripts/e2e-morepages.sh <udid>

import XCTest

final class QuickActionsUITests: MorePagesCase {
    @MainActor private func tile(_ id: String) -> XCUIElement { app.cells["quick-tile-\(id)"] }
    @MainActor private var grid: XCUIElement { app.collectionViews["quick-actions.grid"] }

    /// The tiles top to bottom, left to right (by where they are drawn).
    @MainActor private var shownIDs: [String] {
        grid.cells.allElementsBoundByIndex.filter { $0.identifier.hasPrefix("quick-tile-") && $0.exists }
            .sorted { ($0.frame.minY.rounded(), $0.frame.minX) < ($1.frame.minY.rounded(), $1.frame.minX) }
            .map { String($0.identifier.dropFirst("quick-tile-".count)) }
    }

    @MainActor private func edit(_ word: String) {
        let button = app.buttons.matching(identifier: "quick-actions.edit").matching(NSPredicate(format: "label == %@", word)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the bar's \(word)")
        button.tap()
    }

    /// A debug hook word on the running app (App/Intents/IntentsDebugHooks.swift), as the intents tests send them.
    @MainActor private func hook(_ word: String) {
        let scheme = ProcessInfo.processInfo.environment["HQN_UI_SCHEME"] ?? "hermeshq-native"
        XCUIDevice.shared.system.open(URL(string: "\(scheme)://debug-intent/\(word)")!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 4) { open.tap() }
        Thread.sleep(forTimeInterval: 0.8)
    }

    @MainActor func testQuickActions_AddRenameWideReorderRemoveKeep() throws {
        launchSignedIn(["-HQDebugResetQuickActions", "YES"])
        tab("More")
        XCTAssertTrue(revealMore("quick-actions").exists, "Quick Actions is in More, beside Favorites")
        openMore("quick-actions")
        XCTAssertTrue(app.navigationBars["Quick Actions"].waitForExistence(timeout: 10), "More › Quick Actions opens its page")
        // The starter set, from the roster's first bot.
        XCTAssertTrue(tile("starter-memo").waitForExistence(timeout: 10), "the starter set")
        XCTAssertEqual(shownIDs, ["starter-memo", "starter-talk", "starter-new-chat", "starter-add-task", "starter-search"])
        XCTAssertEqual(tile("starter-memo").label, "Memo, to Hermes")
        XCTAssertEqual(tile("starter-new-chat").label, "New Chat, with Hermes")
        XCTAssertGreaterThan(tile("starter-new-chat").frame.width, tile("starter-memo").frame.width * 1.6, "New Chat is Wide")
        shot("quick-actions-seeded")

        // Edit: the + tile, then Add Action › Open a Chat › Set Up, renamed and recoloured.
        edit("Edit")
        let add = app.cells["quick-actions.add-tile"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Edit shows ＋ Add Action")
        shot("quick-actions-editing")
        reach(add)
        add.tap()
        XCTAssertTrue(app.navigationBars["Add Action"].waitForExistence(timeout: 5), "＋ opens Add Action")
        for id in ["new-chat", "memo", "talk", "send", "open-chat", "add-task", "run-job"] {
            XCTAssertTrue(app.buttons["quick.add.\(id)"].waitForExistence(timeout: 2), "Add Action lists \(id)")
        }
        shot("quick-actions-add-action")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3), "a search field")
        XCTAssertEqual(search.placeholderValue, "Search actions and pages")
        search.tap()
        search.typeText("open a")
        let openChat = app.buttons["quick.add.open-chat"]
        XCTAssertTrue(openChat.waitForExistence(timeout: 5), "the search finds Open a Chat")
        XCTAssertFalse(app.buttons["quick.add.memo"].exists, "and only what matches")
        openChat.tap()
        XCTAssertTrue(app.navigationBars["Set Up"].waitForExistence(timeout: 5), "a choice opens Set Up")
        let name = app.textFields["quick.setup.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Hermes", "the name starts as the bot's")
        shot("quick-actions-setup")
        name.tap()
        name.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        name.typeText(XCUIKeyboardKey.delete.rawValue)
        name.typeText("Ping Hermes")
        let purple = app.buttons["quick.setup.color.indigo"]
        for _ in 0..<5 where !purple.isHittable { app.swipeUp(velocity: .slow) }
        purple.tap()
        app.buttons["quick.setup.save"].tap()
        XCTAssertTrue(waitUntil(6) { self.shownIDs.count == 6 }, "the tile is added: \(shownIDs)")
        let added = shownIDs.last ?? ""
        XCTAssertEqual(tile(added).label, "Ping Hermes, chat with Hermes")

        // Rename: a tap on a tile while editing reopens Set Up with Save.
        tile("starter-talk").tap()
        XCTAssertTrue(app.navigationBars["Edit Action"].waitForExistence(timeout: 5), "Edit Action")
        let rename = app.textFields["quick.setup.name"]
        rename.tap()
        rename.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        rename.typeText(XCUIKeyboardKey.delete.rawValue)
        rename.typeText("Talk Now")
        // Size (owner 2026-11-21: "There isn't a way to change the size of the card."): Set Up's Size picks Wide.
        let size = app.segmentedControls["quick.setup.size"]
        for _ in 0..<5 where !size.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(size.isHittable, "Set Up shows Size")
        XCTAssertTrue(app.segmentedControls["quick.setup.height"].exists, "and Height (Tall / Short)")
        size.buttons["Wide"].tap()
        shot("quick-actions-setup-size")
        app.buttons["quick.setup.save"].tap()
        XCTAssertTrue(waitUntil(5) { self.tile("starter-talk").label == "Talk Now, with Hermes" }, tile("starter-talk").label)
        XCTAssertTrue(waitUntil(5) { self.tile("starter-talk").frame.width > self.tile("starter-memo").frame.width * 1.6 },
                      "Size › Wide makes Talk Wide")
        shot("quick-actions-editing-resize")
        // Edit's corner arrows (bottom right) flip it back to Small.
        let talk = tile("starter-talk")
        talk.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -6, dy: -6)).tap()
        XCTAssertTrue(waitUntil(5) { abs(self.tile("starter-talk").frame.width - self.tile("starter-memo").frame.width) < 2 },
                      "the corner arrows make Talk Small again")

        // Reorder: Search Chats dragged to the front.
        tile("starter-search").press(forDuration: 0.9, thenDragTo: tile("starter-memo"))
        XCTAssertTrue(waitUntil(5) { self.shownIDs.first == "starter-search" }, "dragged first: \(shownIDs)")
        XCTAssertTrue(waitUntil(3) { self.tile("starter-new-chat").frame.width > self.tile("starter-talk").frame.width * 1.6 },
                      "New Chat stays Wide after the drag (the widths follow their tiles)")

        // Remove: the − badge.
        let task = tile("starter-add-task")
        task.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 6, dy: 6)).tap()
        XCTAssertTrue(waitUntil(5) { !task.exists }, "− removes Add Task")
        edit("Done")
        XCTAssertFalse(add.exists, "Done ends editing")

        // Wide: holding a tile offers Small, Wide, Edit… and Remove.
        tile("starter-memo").press(forDuration: 1.2)
        for word in ["Small", "Wide", "Tall", "Short", "Edit…", "Remove"] {
            XCTAssertTrue(app.buttons[word].waitForExistence(timeout: 3), "the hold menu offers \(word)")
        }
        shot("quick-actions-hold-menu")
        app.buttons["Wide"].tap()
        XCTAssertTrue(waitUntil(5) { self.tile("starter-memo").frame.width > self.tile("starter-talk").frame.width * 1.6 }, "Memo is Wide")

        // Short (owner 2026-11-21: "I also want to be able to change the height to make them shorter."): Talk sits
        // alone in its row (New Chat after it is Wide), so its own height shows.
        let tallHeight = tile("starter-talk").frame.height
        tile("starter-talk").press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Short"].waitForExistence(timeout: 3))
        app.buttons["Short"].tap()
        XCTAssertTrue(waitUntil(5) { self.tile("starter-talk").frame.height < tallHeight * 0.75 },
                      "Short makes Talk shorter: \(tile("starter-talk").frame.height) vs \(tallHeight)")
        shot("quick-actions-short-tile")

        // A tile whose bot isn't on this gateway: drawn switched off, and a tap says why.
        hook("quick-tile-add:talk:juno")
        let missing = tile("debug-talk-juno")
        XCTAssertTrue(missing.waitForExistence(timeout: 8), "the tile is on the page")
        XCTAssertEqual(missing.value as? String, "Unavailable")
        reach(missing)
        shot("quick-actions-disabled-tile")
        missing.tap()
        let notice = app.descendants(matching: .any)["pages.notice"]
        XCTAssertTrue(waitUntil(5) { notice.exists && notice.label.contains("Juno isn’t on this gateway.") }, "one sentence")
        XCTAssertTrue(grid.exists, "and the page stays")

        let order = shownIDs
        relaunch()
        openMore("quick-actions")
        XCTAssertTrue(tile("starter-search").waitForExistence(timeout: 10), "the list survives a relaunch")
        XCTAssertEqual(shownIDs, order, "in its order, never seeded again")
        XCTAssertEqual(tile("starter-talk").label, "Talk Now, with Hermes")
        XCTAssertTrue(tile("starter-memo").frame.width > tile("starter-talk").frame.width * 1.6, "Memo stays Wide")
        XCTAssertLessThan(tile("starter-talk").frame.height, tile("starter-memo").frame.height * 0.75, "Talk stays Short")
        XCTAssertFalse(app.cells["quick-tile-starter-add-task"].exists, "Add Task stays removed")
    }

    /// The page's looks for the report: as the shortcut opens it (a sheet over the top), the setup form, and under
    /// Desktop Look. Run alone with HQN_TEXT_SIZE for the largest text (one column, icons beside the words).
    @MainActor func testQuickActions_Looks() throws {
        launchSignedIn(["-HQDebugResetQuickActions", "YES", "-HQDebugDesktopLook", "NO"])
        hook("quick-actions-intent")
        XCTAssertTrue(app.otherElements["quick-actions.sheet"].waitForExistence(timeout: 10) || grid.waitForExistence(timeout: 2),
                      "the intent opens the page as a sheet")
        XCTAssertTrue(tile("starter-memo").waitForExistence(timeout: 10), "the starter set")
        shot("quick-actions-sheet")
        tile("starter-search").tap()
        XCTAssertTrue(grid.waitForNonExistence(timeout: 8), "a foreground tile closes the page and goes")

        // Desktop Look has no tab bar for `launchSignedIn` to wait on: the same sign-in, relaunched, and the shortcut.
        // `relaunch` drops HQN_TEXT_SIZE, so it is passed again here.
        let size = ProcessInfo.processInfo.environment["HQN_TEXT_SIZE"].flatMap { $0.isEmpty ? nil : $0 }
        relaunch(["-HQDebugDesktopLook", "YES"] + (size.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []))
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        hook("quick-actions-intent")
        XCTAssertTrue(tile("starter-memo").waitForExistence(timeout: 15), "the page under Desktop Look")
        shot("quick-actions-desktop-look")
        edit("Edit")
        XCTAssertTrue(app.cells["quick-actions.add-tile"].waitForExistence(timeout: 5))
        shot("quick-actions-desktop-look-editing")
        edit("Done")
        relaunch(["-HQDebugDesktopLook", "NO"])
    }

    /// Settings › Tabs can make Quick Actions a tab of its own; it then leaves More.
    @MainActor func testQuickActions_AsATab() throws {
        launchSignedIn(["-HQDebugResetQuickActions", "YES", "-hqn.tabOrder", "(bots, sessions, \"page.quick-actions\")"])
        tab("Quick Actions")
        XCTAssertTrue(tile("starter-memo").waitForExistence(timeout: 10), "the tab shows the page")
        tab("More")
        XCTAssertFalse(app.cells["more-row-quick-actions"].waitForExistence(timeout: 2), "as a tab it leaves More")
    }
}
