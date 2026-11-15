import XCTest

extension SettingsEndToEndTests {
    @MainActor func testIntroCardWithKeyboard() throws {
        let app = launchSignedIn(["-HQDebugChatBackground", "aurora"])
        let notes = app.cells["bot-row-notes"]
        m9ScrollTo(notes, in: app)
        XCTAssertTrue(notes.waitForExistence(timeout: 8))
        notes.tap()
        let composer = app.textViews["composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["No messages yet. Say hello."].waitForExistence(timeout: 8))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let tipClose = app.buttons["memo.tip.close"]
        if tipClose.waitForExistence(timeout: 3) { tipClose.tap() }
        shot(app, "intro-card-keyboard")
        let info = app.buttons["chat.intro.info"]
        XCTAssertTrue(info.exists && info.isHittable)
    }
}
