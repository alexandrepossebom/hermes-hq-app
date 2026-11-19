// [tile-models] Settings › Tile Model and a tile's Updates › Model, end to end against the pages fixture (owner
// 2026-11-18: "a global setting and then an individual override"). Screens: e2e-tile-models-*.png (HQN_SHOTS_DIR).
//   HQN_PAGES_ONLY="testArt40_TileModel" HQN_PAGES_SKIP_NOK=1 scripts/e2e-pages.sh <SIM>

import XCTest

extension PagesTests {
    @MainActor func testArt40_TileModel() throws {
        app = launchSignedIn(["-HQDebugResetPins", "YES"])
        try account.control("/__fixture/append", ["session_id": "s-report", "role": "assistant", "text": "MEDIA:/home/hermes/site/tile.html"])
        try account.control("/__fixture/tile-job", [:])   // follows its bot's own model
        openArtifacts()
        let list = app.collectionViews["artifacts.list"]
        let row = list.cells["artifact-row-tile.html"]
        XCTAssertTrue(waitUntil(15) { row.exists || self.scrollTo(row, in: list) }, "tile.html is listed")
        row.swipeRight()
        app.buttons["Pin"].firstMatch.tap()
        list.swipeDown(); list.swipeDown()
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.open-page"].firstMatch.tap()
        let tile = app.collectionViews["pinned.list"].cells["pin-card-tile.html"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "the tile on Tiles")
        Thread.sleep(forTimeInterval: 2)

        // Settings › Bots & Tools › Tile Model: each bot's own until picked.
        tab("More")
        let settingsRow = app.cells["more-row-settings"]
        if !settingsRow.waitForExistence(timeout: 3) { tab("More") }
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5) || scrollTo(settingsRow, in: app.collectionViews.firstMatch))
        settingsRow.tap()
        let tileModel = app.buttons["settings.tile-model"].firstMatch
        let settingsList = app.collectionViews.firstMatch
        XCTAssertTrue(waitUntil(10) { tileModel.exists && tileModel.isHittable || { settingsList.swipeUp(); return false }() },
                      "Tile Model in Settings")
        XCTAssertTrue(tileModel.label.contains("Each Bot’s Own Model"), "each bot's own by default: \(tileModel.label)")
        tileModel.tap()
        XCTAssertTrue(app.buttons["tile-model.default.bots"].firstMatch.waitForExistence(timeout: 5))
        shot("tile-models-settings-default")

        // A default, picked with the app's model chooser (a model typed under the fixture's provider).
        pickInChooser(row: "tile-model.default.pick", model: "claude-sonnet-5")
        let status = app.staticTexts["tile-model.status"].firstMatch
        XCTAssertTrue(waitUntil(15) { status.exists && status.label.contains("changed") }, "the tile's job changed: \(status.label)")
        XCTAssertTrue(waitUntil(5) {
            self.requests().contains { request in
                guard request.method == "PUT", request.path == "/api/cron/jobs/j-tile",
                      let updates = request.body?["updates"] as? [String: Any] else { return false }
                return updates["model"] as? String == "claude-sonnet-5" && updates["provider"] as? String == "fixture"
                    && updates["fallback_providers"] == nil
            }
        }, "the tile's job is pinned to the default, no fallback field")

        // And a fallback: sent with the pin.
        pickInChooser(row: "tile-model.fallback.pick", model: "gpt-6.2-astra")
        XCTAssertTrue(waitUntil(15) {
            self.requests().contains { request in
                guard request.method == "PUT", request.path == "/api/cron/jobs/j-tile",
                      let updates = request.body?["updates"] as? [String: Any],
                      let fallback = updates["fallback_providers"] as? [[String: Any]] else { return false }
                return fallback.first?["model"] as? String == "gpt-6.2-astra"
            }
        }, "the fallback goes with the pin")
        XCTAssertTrue(app.staticTexts["tile-model.footer"].firstMatch.label.contains("won’t fall back"), "honest about older gateways")
        Thread.sleep(forTimeInterval: 1)
        shot("tile-models-settings-picked")

        // The tile's own menu: what runs it, by name, and a model of its own.
        tab("More")
        tab("More")
        openTiles()
        tile.press(forDuration: 1)
        let updates = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Updates")).firstMatch
        XCTAssertTrue(updates.waitForExistence(timeout: 5))
        shot("tile-models-hold-menu")
        updates.tap()
        let model = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Model")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 5), "Updates › Model")
        shot("tile-models-updates")
        model.tap()
        let useDefault = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Use Tile Default")).firstMatch
        XCTAssertTrue(useDefault.waitForExistence(timeout: 5), "Use Tile Default")
        XCTAssertTrue(app.buttons["Other Model…"].firstMatch.exists, "Other Model…")
        Thread.sleep(forTimeInterval: 1)
        shot("tile-models-model-submenu")
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture")).firstMatch
        let fixtureModel = option.exists ? option : app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "fixture")).firstMatch
        XCTAssertTrue(fixtureModel.exists, "a model from the account's list")
        fixtureModel.tap()
        XCTAssertTrue(waitUntil(10) {
            self.requests().contains { request in
                guard request.method == "PUT", request.path == "/api/cron/jobs/j-tile",
                      let updates = request.body?["updates"] as? [String: Any] else { return false }
                return updates["model"] as? String == "fixture-model"
            }
        }, "the tile's own model is put on its job")
        Thread.sleep(forTimeInterval: 2)
        tile.press(forDuration: 1)
        XCTAssertTrue(updates.waitForExistence(timeout: 5))
        updates.tap()
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.tap()
        XCTAssertTrue(useDefault.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        shot("tile-models-model-own")
    }

    /// A choice row's chooser: the fixture's provider, then a model typed by name.
    @MainActor private func pickInChooser(row id: String, model: String) {
        app.buttons[id].firstMatch.tap()
        let provider = app.buttons["model-chooser.provider"].firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 10), "the model chooser")
        provider.tap()
        let fixture = app.buttons["Fixture"].firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 5), "the fixture's provider")
        fixture.tap()
        let custom = app.textFields["model-chooser.custom"].firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 5) || scrollTo(custom, in: app.collectionViews.firstMatch))
        custom.tap()
        custom.typeText(model + "\n")
        XCTAssertTrue(app.buttons[id].firstMatch.waitForExistence(timeout: 5), "back on Tile Model")
    }

    @MainActor private func openTiles() {
        openArtifacts()
        app.buttons["pins.view"].firstMatch.tap()
        app.buttons["pins.open-page"].firstMatch.tap()
        XCTAssertTrue(app.collectionViews["pinned.list"].cells["pin-card-tile.html"].waitForExistence(timeout: 5), "the tile on Tiles")
    }
}
