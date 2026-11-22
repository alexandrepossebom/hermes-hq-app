// [desktop-density] Density in the Desktop Look (owner 2026-11-22): the look keeps its own rows (Compact) until
// Standard is picked on Appearance, by a tap as the owner would. Run with
// HQN_E2E_ONLY=testL22_DensityInTheLookIsCompactUntilStandardIsPicked scripts/e2e-desktoplook.sh <udid>.

import XCTest

extension DesktopLookEndToEndTests {
    @MainActor func testL22_DensityInTheLookIsCompactUntilStandardIsPicked() throws {
        let app = launchSignedIn(["-HQDebugSkin", "midnight", "-HQDebugDesktopLook", "YES"])
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the Bots list shows")
        XCTAssertEqual(row.frame.height, 60, accuracy: 1.5, "the look's rows are as they were until Density is changed")

        openSettings(app)
        let standard = app.buttons["Standard"].firstMatch, compact = app.buttons["Compact"].firstMatch
        _ = app.hqAppearance(standard)
        XCTAssertTrue(standard.waitForExistence(timeout: 5), "Density shows in the Desktop Look")
        XCTAssertTrue(compact.isSelected && !standard.isSelected, "Compact is the look's Density until another is picked")
        // The words have room: two equal halves, each far wider than its word (about 60 pt at this size).
        XCTAssertEqual(standard.frame.width, compact.frame.width, accuracy: 1.5, "the two halves are equal")
        XCTAssertGreaterThanOrEqual(standard.frame.width, 96, "each word has room beside it")
        shot(app, "density-look-compact")

        standard.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { standard.isSelected && !compact.isSelected }, "Standard is picked")
        shot(app, "density-look-standard")
        app.tabButton(id: "tab-bots", label: "Bots").tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Bots list shows again")
        XCTAssertTrue(waitUntil(timeout: 5) { row.frame.height >= 73 }, "Standard gives the look's rows more room (\(row.frame.height))")
        XCTAssertTrue(app.otherElements["desktop-tab-bar"].exists, "still the Desktop Look")
        shot(app, "density-bots-standard")
        stop(app)
    }
}
