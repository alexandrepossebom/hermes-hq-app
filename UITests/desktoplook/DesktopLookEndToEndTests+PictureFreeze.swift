// Owner 2026-11-15 (voice memo, build 1013): "My app just crashed when I was trying to change the theme to the desktop
// look. As soon as I clicked on the toggle, it just froze entirely." His phone's log: an app background photo, then
// More › Settings › Theme, Desktop Look on, the main thread stuck in BackdropPlates.restEdge under the Desktop tab bar's
// sync until iOS killed the app. Soft Cards' top-edge hold fought SwiftUI inside the one layout the switch forces.
// The Theme page must be the pushed one (More › Settings › Theme): the debug sheet has no picture behind it.

import XCTest

extension DesktopLookEndToEndTests {
    @MainActor func testL16_LookOnAndOffOverAPictureWithSoftCards() throws {
        let app = launchSignedIn(["-HQDebugDesktopLook", "NO", "-HQDebugAppBackground", "aurora",
                                  "-HQDebugAppBackgroundCards", "YES"])
        openSettings(app)
        openTheme(app)
        let look = app.switches["theme.desktopLook"]
        XCTAssertEqual(look.value as? String, "0", "the iOS look to start")
        shot(app, "picture-cards-theme-ios-look")

        flip(app, "theme.desktopLook")
        XCTAssertTrue(waitUntil(timeout: 10) { (app.switches["theme.desktopLook"].value as? String) == "1" },
                      "Desktop Look turns on over the picture and the app answers")
        XCTAssertTrue(app.otherElements["desktop-tab-bar"].waitForExistence(timeout: 5), "the look's tab bar is up")
        shot(app, "picture-cards-theme-desktop-look")

        flip(app, "theme.desktopLook")
        XCTAssertTrue(waitUntil(timeout: 10) { (app.switches["theme.desktopLook"].value as? String) == "0" },
                      "and off again, back over the picture")
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 5), "the system tab bar is back")
    }
}
