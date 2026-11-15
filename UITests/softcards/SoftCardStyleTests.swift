// [soft-card-style] Theme › Backgrounds › App Background › Soft Cards › Style (owner 2026-11-15: "pick from similar
// background types like we have for the text bubbles"): Solid, Glass and Tinted, picked on the App Background page and
// drawn at once by that page's cards and by the tabs' lists, with no relaunch.
// Run against any stand-in gateway:
//   TEST_RUNNER_HQN_UI_CREDENTIALS=<creds.json> TEST_RUNNER_HQN_SHOTS_DIR=<dir> xcodebuild … test
//     -only-testing:HermesHQNativeUITests/SoftCardStyleTests
// TEST_RUNNER_HQN_SOFT_MODE (dark|light), _PIC (a picture id), _SKIN.

import XCTest

final class SoftCardStyleTests: XCTestCase {
    private var app: XCUIApplication!
    private let environment = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor private func launch(account: FixtureAccount) {
        let app = XCUIApplication()
        let mode = environment["HQN_SOFT_MODE"] ?? "dark"
        app.launchEnvironment["HQN_SIGNIN_URL"] = account.url
        app.launchEnvironment["HQN_SIGNIN_USERNAME"] = account.username
        app.launchEnvironment["HQN_SIGNIN_PASSWORD"] = account.password
        app.launchArguments = ["-HQDebugNoSwipePeek", "YES", "-HQDebugTalkIntroSeen", "YES", "-HQDebugResetTheme", "YES",
                               "-HQDebugSkin", environment["HQN_SOFT_SKIN"] ?? "nous", "-HQDebugDesktopLook", "NO",
                               "-HQDebugAppearance", mode, "-hqn.appearance", mode,
                               "-HQDebugAppBackground", environment["HQN_SOFT_PIC"] ?? "doodleTravel",
                               "-HQDebugAppBackgroundCards", "YES", "-HQDebugAppBackgroundCardStyle", "tinted"]
        app.launch()
        self.app = app
    }

    @MainActor private func tab(_ name: String) -> XCUIElement {
        let system = app.tabBars.buttons[name]
        return system.exists ? system : app.tabButton(id: "tab-\(name.lowercased())", label: name)
    }

    @MainActor private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = environment["HQN_SHOTS_DIR"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("softcard-\(name).png"))
        }
    }

    @MainActor private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    @MainActor func testStylesPickAndDrawLive() throws {
        let account = try FixtureAccount.load()
        launch(account: account)
        XCTAssertTrue(tab("Bots").waitForExistence(timeout: 30), "signed in")
        Thread.sleep(forTimeInterval: 2)
        declineSavePassword()
        shot("bots-tinted")

        // More › Settings › Appearance › Backgrounds › App Background, on the More tab's own stack (on the picture).
        let more = tab("More")
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        let settingsRow = app.cells["more-row-settings"]
        for _ in 0..<4 {
            declineSavePassword()
            more.tap()
            if settingsRow.waitForExistence(timeout: 2), settingsRow.isHittable { break }
        }
        settingsRow.tap()
        let backgroundsRow = app.buttons["settings.backgrounds-row"]
        scrollTo(backgroundsRow)
        XCTAssertTrue(backgroundsRow.waitForExistence(timeout: 10), "Backgrounds in Settings")
        backgroundsRow.tap()
        let appRow = app.descendants(matching: .any)["theme.background.app"]
        XCTAssertTrue(appRow.waitForExistence(timeout: 5))
        appRow.tap()
        XCTAssertTrue(app.navigationBars["App Background"].waitForExistence(timeout: 5), "App Background opens")

        let picker = app.descendants(matching: .any)["theme.backgroundCardStyle"]
        scrollTo(picker)
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Style sits under Soft Cards while it is on")
        let line = app.staticTexts["theme.backgroundCardStyleLine"]
        XCTAssertTrue(line.exists && line.label.hasPrefix("Tinted:"), "Tinted, the first cards, until another is picked")
        let segments = app.segmentedControls.firstMatch
        XCTAssertEqual(segments.buttons.allElementsBoundByIndex.map(\.label), ["Solid", "Glass", "Tinted"], "Chat Bubbles' three, in its order")
        shot("settings-tinted")

        for style in ["Solid", "Glass", "Tinted"] {
            segments.buttons[style].tap()
            XCTAssertTrue(segments.buttons[style].isSelected, "\(style) is picked")
            XCTAssertTrue(line.waitForExistence(timeout: 3) && line.label.hasPrefix("\(style):"), "the note names \(style)")
            Thread.sleep(forTimeInterval: 1)
            shot("settings-\(style.lowercased())")
            // The tabs' lists take it at once, with no relaunch.
            tab("Bots").tap()
            Thread.sleep(forTimeInterval: 1.5)
            shot("bots-\(style.lowercased())")
            tab("More").tap()
            XCTAssertTrue(app.navigationBars["App Background"].waitForExistence(timeout: 5), "back on the page it was left on")
        }

        // Soft Cards off: no Style row.
        let cards = app.switches["theme.backgroundCards"]
        scrollTo(cards)
        cards.switches.firstMatch.exists ? cards.switches.firstMatch.tap() : cards.tap()
        XCTAssertTrue(waitFor { !picker.exists }, "Style goes with the switch")
    }

    /// iOS's Save Password sheet after the stand-in sign-in.
    @MainActor private func declineSavePassword() {
        for host in [app!, XCUIApplication(bundleIdentifier: "com.apple.springboard"), XCUIApplication(bundleIdentifier: "com.apple.Passwords")] {
            let notNow = host.buttons["Not Now"]
            guard notNow.exists else { continue }
            notNow.tap()
            _ = waitFor(timeout: 5) { !notNow.exists }
            Thread.sleep(forTimeInterval: 0.6)
            return
        }
    }

    private func waitFor(timeout: TimeInterval = 4, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }
}
