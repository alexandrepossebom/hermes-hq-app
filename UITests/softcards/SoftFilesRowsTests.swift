// [soft-cards] More › Files on a picture with Soft Cards and a skin that paints its own cards (a tester, 2026-11-18:
// "That theme error is there in the files tab … also happens when I tap on something": the top rows of the list wore
// the skin's card colour, the rest the soft card's, one list in two colours). Pictures of the root list and a long
// folder, at rest and scrolled, for looking at. Run against the morepages stand-in:
//   TEST_RUNNER_HQN_UI_CREDENTIALS=<creds.json> TEST_RUNNER_HQN_SHOTS_DIR=<dir> xcodebuild … test
//     -only-testing:HermesHQNativeUITests/SoftFilesRowsTests
// TEST_RUNNER_HQN_SOFT_SKIN (default ember), _PIC (default aurora), _STYLE (default solid), _MODE (dark|light).

import XCTest

final class SoftFilesRowsTests: XCTestCase {
    private var app: XCUIApplication!
    private let environment = ProcessInfo.processInfo.environment

    @MainActor private func shot(_ name: String) {
        guard let dir = environment["HQN_SHOTS_DIR"], !dir.isEmpty else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    @MainActor func testSoftFiles_RowsOneColour() throws {
        let account = try FixtureAccount.load()
        let mode = environment["HQN_SOFT_MODE"] ?? "dark"
        let app = XCUIApplication()
        app.launchEnvironment["HQN_SIGNIN_URL"] = account.url
        app.launchEnvironment["HQN_SIGNIN_USERNAME"] = account.username
        app.launchEnvironment["HQN_SIGNIN_PASSWORD"] = account.password
        app.launchArguments = ["-HQDebugResetAccounts", "YES", "-HQDebugNoSwipePeek", "YES", "-HQDebugTalkIntroSeen", "YES",
                               "-HQDebugResetTheme", "YES", "-HQDebugSkin", environment["HQN_SOFT_SKIN"] ?? "ember",
                               "-HQDebugDesktopLook", "NO", "-HQDebugAppearance", mode, "-hqn.appearance", mode,
                               "-HQDebugAppBackground", environment["HQN_SOFT_PIC"] ?? "aurora", "-HQDebugAppBackgroundCards", "YES",
                               "-HQFilesForgetFolders", "YES",
                               "-HQDebugAppBackgroundCardStyle", environment["HQN_SOFT_STYLE"] ?? "solid"]
        app.launch()
        self.app = app
        let more = app.tabBars.buttons["More"].exists ? app.tabBars.buttons["More"] : app.tabButton(id: "tab-more", label: "More")
        XCTAssertTrue(more.waitForExistence(timeout: 30), "signed in")
        Thread.sleep(forTimeInterval: 2)
        more.tap()
        let files = app.cells["more-row-files"]
        for _ in 0..<5 where !(files.exists && files.isHittable) { app.swipeUp(); Thread.sleep(forTimeInterval: 0.6) }
        XCTAssertTrue(files.isHittable, "More › Files")
        files.tap()
        let many = app.cells["workspace.entry.many"]
        XCTAssertTrue(many.waitForExistence(timeout: 15), "the root's entries")
        Thread.sleep(forTimeInterval: 1.5)
        shot("files-1-root-rest")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.2)
        shot("files-2-root-scrolled")
        app.swipeDown()
        Thread.sleep(forTimeInterval: 1.0)
        many.tap()
        XCTAssertTrue(app.navigationBars["many"].waitForExistence(timeout: 10), "the folder opened")
        Thread.sleep(forTimeInterval: 1.5)
        shot("files-3-folder-rest")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.2)
        shot("files-4-folder-scrolled")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.2)
        shot("files-5-folder-scrolled-more")
    }
}
