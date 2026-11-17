// Paper (owner 2026-11-16): the same screens in Nous and in Paper, for the side-by-side, and the page measured as
// Claude's ivory. Run with HQN_E2E_ONLY=testL20_PaperBesideNous scripts/e2e-desktoplook.sh <udid> (HQN_SHOTS_DARK=1
// for dark). Paper is picked on the Theme page by a tap, as the owner would: `-HQDebugSkin` is overwritten by the
// synced settings once signed in.

import XCTest

extension DesktopLookEndToEndTests {
    /// Owner 2026-11-16 ("I don't like the dark mode background"): Paper's dark in each darkness, the same screens, for
    /// a side-by-side. Run with HQN_SHOTS_DARK=1.
    @MainActor func testL21_PaperDarkOptions() throws {
        for option in ["charcoal", "deep", "night", "black"] {
            let app = launchSignedIn(["-HQDebugPaperDark", option])
            openSettings(app)
            let row = app.buttons["settings.theme-row"]
            for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
            row.tap()
            XCTAssertTrue(themeOpens(app), "the Theme page opens")
            card(app, "paper").tap()
            XCTAssertTrue(waitUntil(timeout: 5) { self.card(app, "paper").isSelected }, "Paper is selected")
            app.navigationBars.buttons.firstMatch.tap()      // Back to Settings
            Thread.sleep(forTimeInterval: 0.8)
            shot(app, "paperdark-\(option)-settings")
            app.tabBars.buttons["Bots"].tap()
            XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 10), "the Bots list shows")
            shot(app, "paperdark-\(option)-bots")
            app.cells["bot-row-ivy"].tap()
            XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8), "the chat opens")
            Thread.sleep(forTimeInterval: 1.5)
            shot(app, "paperdark-\(option)-chat")
            stop(app)
        }
    }

    @MainActor func testL20_PaperBesideNous() throws {
        let dark = ProcessInfo.processInfo.environment["HQN_SHOTS_DARK"] == "1"
        let app = launchSignedIn()
        // [paper-solid] Nous, Paper, then Nous again: Paper's solid chrome comes and goes live, both ways.
        for (round, skin) in ["nous", "paper", "nous"].enumerated() {
            let tag = round == 2 ? "\(skin)-again" : skin
            openSettings(app)
            let row = app.buttons["settings.theme-row"]
            for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
            row.tap()
            XCTAssertTrue(themeOpens(app), "the Theme page opens")
            let picked = card(app, skin)
            XCTAssertTrue(picked.exists, "\(skin) is in the grid")
            picked.tap()
            XCTAssertTrue(waitUntil(timeout: 5) { self.card(app, skin).isSelected }, "\(skin) is selected")
            app.swipeDown(); app.swipeDown()
            shot(app, "paper-\(tag)-theme")
            app.navigationBars.buttons.firstMatch.tap()      // Back to Settings
            Thread.sleep(forTimeInterval: 0.8)
            shot(app, "paper-\(tag)-settings")

            // [paper-glass] Paper keeps iOS's glass tab bar, as every theme (owner 2026-11-17): never the solid stand-in.
            XCTAssertFalse(app.otherElements["paper-tab-bar"].exists, "the system's glass tab bar, not a solid one")
            let bots = app.tabButton(id: "tab-bots", label: "Bots")
            XCTAssertTrue(bots.waitForExistence(timeout: 5))
            bots.tap()
            XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 10), "the Bots list shows")
            shot(app, "paper-\(tag)-bots")
            app.cells["bot-row-ivy"].tap()
            XCTAssertTrue(app.textViews["composer.text"].waitForExistence(timeout: 8), "the chat opens")
            Thread.sleep(forTimeInterval: 1.5)
            shot(app, "paper-\(tag)-chat")
            if skin == "paper" {
                // The chat's page is Paper's own ivory (light) or black (dark), not pulled toward grey.
                XCTAssertEqual(gutter(app), dark ? "000000" : "F8F9F3", "Paper's page")
            }
            app.navigationBars.buttons.firstMatch.tap()      // Back to Bots
            XCTAssertTrue(app.cells["bot-row-ivy"].waitForExistence(timeout: 8))
        }
    }
}
