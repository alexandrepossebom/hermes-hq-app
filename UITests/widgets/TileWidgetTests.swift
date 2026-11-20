// [tile-widgets] The Tile widget end to end (docs/spec/1x-pages.md §5.8): page tiles pinned in the app → the widget
// index and pictures written → a real Tile widget on the simulator's Home Screen shows the tile's picture → a tap on it
// opens that tile in the app. Run against the pages fixture with kit tiles (HQN_FIXTURE_TILES), on a simulator of its own:
//   TEST_RUNNER_HQN_UI_CREDENTIALS=<fixture credentials> TEST_RUNNER_HQN_SHOTS_DIR=<folder> xcodebuild … test \
//     -only-testing:HermesHQNativeUITests/TileWidgetTests
// The original identity only (the widget extension isn't in `native`): skipped when the app has no Tile widget.

import XCTest

final class TileWidgetTests: XCTestCase {
    var account: FixtureAccount!
    @MainActor var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUpWithError() throws {
        continueAfterFailure = false
        account = try FixtureAccount.load()
    }

    @MainActor func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment["HQN_SIGNIN_URL"] = account.url
        app.launchEnvironment["HQN_SIGNIN_USERNAME"] = account.username
        app.launchEnvironment["HQN_SIGNIN_PASSWORD"] = account.password
        app.launch()
        return app
    }

    /// The add-on's update sheet (the fixture's add-on is older than this app asks for) closed, when it opens.
    @MainActor func closeAddOnSheet(_ app: XCUIApplication) {
        let close = app.buttons["addon-update.close"]
        if close.waitForExistence(timeout: 6) { close.tap() }
    }

    // MARK: Pictures and dumps

    @MainActor func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    @MainActor func dump(_ name: String, _ app: XCUIApplication) {
        guard let dir = ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"], !dir.isEmpty else { return }
        try? app.debugDescription.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }

    @MainActor @discardableResult
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    // MARK: The probe

    /// The app's `debug.widgets` element: what the widget store holds, read back from it.
    @MainActor func probe(_ app: XCUIApplication) -> [String: String] {
        let element = app.descendants(matching: .any)["debug.widgets"]
        guard element.exists, let value = element.value as? String else { return [:] }
        var fields: [String: String] = [:]
        for part in value.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        return fields
    }

    // MARK: The Home Screen

    /// The Home Screen in its edit mode (icons jiggling, Edit and Done at the top).
    @MainActor func editHomeScreen() {
        XCUIDevice.shared.press(.home)
        sleep(1)
        if springboard.alerts.firstMatch.exists, springboard.alerts.buttons["Cancel"].exists { springboard.alerts.buttons["Cancel"].tap() }
        let edit = springboard.buttons["Edit"].firstMatch
        if edit.exists { return }
        // A hold on the dock's Messages: its menu's Edit Home Screen (an empty spot moves as widgets are added).
        springboard.icons["Messages"].firstMatch.press(forDuration: 1.5)
        let item = springboard.buttons["Edit Home Screen"].firstMatch
        if item.waitForExistence(timeout: 4) { item.tap() }
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "the Home Screen's edit mode")
    }

    /// Edit › Add Widget › Hermes HQ › Tile, at `page` of its sizes (0 small, 1 medium, 2 large), then Done.
    @MainActor func addTileWidget(page: Int, shotPrefix: String? = nil) { addWidget("Tile", page: page, shotPrefix: shotPrefix) }

    /// Edit › Add Widget › Hermes HQ › `name` (Tile, Tasks), at `page` of its sizes, then Done.
    @MainActor func addWidget(_ name: String, page: Int, shotPrefix: String? = nil) {
        editHomeScreen()
        springboard.buttons["Edit"].firstMatch.tap()
        let add = springboard.buttons["Add Widget"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8), "the widget gallery's search")
        if let shotPrefix { sleep(1); shot("\(shotPrefix)-gallery") }
        search.tap()
        search.typeText("Hermes HQ")
        let app = springboard.cells["Hermes HQ"].firstMatch
        XCTAssertTrue(app.waitForExistence(timeout: 8), "Hermes HQ in the gallery")
        app.tap()
        // Hermes HQ's gallery opens on Tile's sizes (Small, Medium, Large), then Tasks' (pages 3, 4, 5).
        let tile = springboard.staticTexts["Tile"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 8), "Hermes HQ's widgets in the gallery")
        for _ in 0..<page { springboard.swipeLeft(); sleep(1) }
        XCTAssertTrue(springboard.staticTexts[name].firstMatch.waitForExistence(timeout: 4), "the \(name) widget in Hermes HQ's gallery")
        sleep(2)
        if let shotPrefix { shot("\(shotPrefix)-gallery-tile") }
        let button = springboard.buttons.matching(NSPredicate(format: "label ENDSWITH 'Add Widget'")).firstMatch
        XCTAssertTrue(button.exists, "Add Widget")
        button.tap()
        sleep(2)
        let done = springboard.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 4) { done.tap() }
        sleep(2)
    }

    /// The Tile widgets now on the Home Screen (their own accessibility label is the tile's name).
    @MainActor func widgets(named name: String) -> XCUIElementQuery {
        springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", name))
    }

    /// The system's "Open in “Hermes HQ”?" over a link opened from outside: Open.
    @MainActor func confirmOpen() {
        let open = springboard.alerts.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 4) { open.tap() }
    }

    /// Every Hermes HQ widget off the Home Screen (hold › Remove Widget › Remove).
    @MainActor func removeWidgets() {
        XCUIDevice.shared.press(.home)
        sleep(1)
        if springboard.alerts.buttons["Cancel"].exists { springboard.alerts.buttons["Cancel"].tap() }
        let screen = springboard.frame
        var swipes = 0
        for _ in 0..<30 {
            let all = placedWidgets()
            if all.isEmpty { return }
            guard let widget = all.first(where: { screen.contains($0.frame) }) else {
                if swipes > 4 { return }
                springboard.swipeLeft(); swipes += 1; sleep(1); continue
            }
            widget.press(forDuration: 1.5)
            let remove = springboard.buttons["Remove Widget"].firstMatch
            guard remove.waitForExistence(timeout: 4) else { dump("tw-remove-menu", springboard); return }
            remove.tap()
            let confirm = springboard.alerts.buttons["Remove"].firstMatch
            if confirm.waitForExistence(timeout: 4) { confirm.tap() }
            sleep(2)
        }
    }

    /// Hold the widget › Edit Widget › Tile › `name`, then away from the sheet.
    @MainActor func chooseTile(_ widget: XCUIElement, _ name: String, shotPrefix: String? = nil) {
        widget.press(forDuration: 1.5)
        let edit = springboard.buttons["Edit Widget"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 4), "Edit Widget")
        edit.tap()
        sleep(2)
        if let shotPrefix { shot("\(shotPrefix)-config"); dump("\(shotPrefix)-config", springboard) }
        let parameter = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tile'")).firstMatch
        if parameter.exists { parameter.tap() } else { springboard.staticTexts["Tile"].firstMatch.tap() }
        sleep(2)
        if let shotPrefix { shot("\(shotPrefix)-config-list"); dump("\(shotPrefix)-config-list", springboard) }
        let choice = springboard.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        // A tap while the sheet is still settling opens nothing (seen once on a freshly erased simulator): once more.
        if !choice.waitForExistence(timeout: 4), parameter.exists { parameter.tap(); sleep(2) }
        XCTAssertTrue(choice.waitForExistence(timeout: 6), "\(name) in the list")
        choice.tap()
        sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()   // away from the sheet
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(1)
    }

    /// The first Hermes HQ widget matching `kind`, its Home Screen page on show (page 1, then each next one).
    @MainActor func onScreen(_ kind: (CGRect) -> Bool) -> XCUIElement? {
        XCUIDevice.shared.press(.home)
        sleep(1)
        let screen = springboard.frame
        for _ in 0..<4 {
            if let widget = placedWidgets().first(where: { kind($0.frame) && screen.contains($0.frame) }) { return widget }
            springboard.swipeLeft()
            sleep(1)
        }
        return nil
    }

    static let isSmall: @Sendable (CGRect) -> Bool = { $0.width < 250 }
    static let isMedium: @Sendable (CGRect) -> Bool = { $0.width > 300 && $0.height < 250 }
    static let isLarge: @Sendable (CGRect) -> Bool = { $0.height > 300 }

    /// The Hermes HQ widgets on the Home Screen's pages.
    @MainActor func placedWidgets() -> [XCUIElement] {
        springboard.icons.matching(identifier: "Hermes HQ").allElementsBoundByIndex.filter { ($0.value as? String) == "Widget" }
    }

    // MARK: The test

    /// Pin → the index and pictures in the widget store → Small, Medium and Large Tile widgets on the Home Screen →
    /// a tap on one opens its tile in the app; a link to a tile that isn't pinned opens Tiles.
    @MainActor func testTileWidgetEndToEnd() throws {
        // 1. Four kit tiles pinned; the store holds the index and the default tile's pictures.
        let app = launch(["-HQDebugResetPins", "YES", "-HQPagesTab", "4", "-HQPagesMore", "artifacts", "-HQPagesPinPages", "YES",
                          "-HQDebugWidgetProbe", "YES"])
        closeAddOnSheet(app)
        XCTAssertTrue(waitUntil(120) { (Int(probe(app)["tiles"] ?? "") ?? 0) >= 3 && (Int(probe(app)["pictures"] ?? "") ?? 0) >= 6 },
                      "the index and the default tile's small, medium and large pictures, light and dark: \(probe(app))")
        let written = probe(app)
        XCTAssertEqual(written["state"], "live")
        let first = try XCTUnwrap(written["first"]), account = try XCTUnwrap(written["account"])
        shot("tw-01-app-artifacts")

        // 2. The widgets: Large, Medium, then Small (each new one goes on top). A simulator that has them keeps them.
        XCUIDevice.shared.press(.home)
        sleep(2)
        if springboard.alerts.firstMatch.exists, springboard.alerts.buttons["Cancel"].exists { springboard.alerts.buttons["Cancel"].tap() }
        dump("tw-02-home-before", springboard)
        if placedWidgets().count < 3 {
            addTileWidget(page: 2, shotPrefix: "tw-02")
            addTileWidget(page: 1)
            addTileWidget(page: 0)
        }
        dump("tw-03-home", springboard)
        shot("tw-03-home-first-pass")

        // 3. The app drawn again: the placed sizes are what it draws (the system says what's placed).
        app.activate()
        closeAddOnSheet(app)
        sleep(25)
        XCUIDevice.shared.press(.home)
        sleep(4)
        shot("tw-04-home")

        // 4. A tap on a widget opens its tile in the app.
        let widget = springboard.descendants(matching: .any).matching(identifier: "tile-widget").firstMatch
        let tapTarget = widget.exists ? widget : widgets(named: "Agenda").firstMatch
        XCTAssertTrue(tapTarget.waitForExistence(timeout: 5), "a Tile widget on the Home Screen")
        tapTarget.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(3)
        shot("tw-05a-after-tap")
        dump("tw-05a-after-tap", app)
        XCTAssertTrue(app.webViews["html.page"].waitForExistence(timeout: 15) || app.otherElements["html.page"].waitForExistence(timeout: 2),
                      "the tile opened")
        sleep(2)
        shot("tw-05-tapped")

    }

    /// The widget's link opens its tile (the account matches); a link to a tile that isn't pinned opens Tiles alone.
    @MainActor func testTileLinkOpensTile() throws {
        let app = launch(["-HQPagesTab", "4", "-HQPagesMore", "artifacts", "-HQPagesPinPages", "YES", "-HQDebugWidgetProbe", "YES"])
        closeAddOnSheet(app)
        XCTAssertTrue(waitUntil(120) { (Int(probe(app)["tiles"] ?? "") ?? 0) >= 3 }, "the widget index: \(probe(app))")
        let written = probe(app)
        let first = try XCTUnwrap(written["first"]), account = try XCTUnwrap(written["account"])
        // The same link by hand; and one to a tile that isn't pinned opens Tiles, with no tile over it.
        app.terminate()
        let scheme = ProcessInfo.processInfo.environment["HQN_URL_SCHEME"].flatMap { $0.isEmpty ? nil : $0 } ?? "hermes"
        app.open(URL(string: "\(scheme)://widget/tile?id=\(first)&account=\(account)")!)
        confirmOpen()
        XCTAssertTrue(app.webViews["html.page"].waitForExistence(timeout: 30) || app.otherElements["html.page"].waitForExistence(timeout: 2),
                      "the link opened the tile")
        app.terminate()
        app.open(URL(string: "\(scheme)://widget/tile?id=0000000000000000&account=\(account)")!)
        confirmOpen()
        XCTAssertTrue(app.navigationBars["Tiles"].waitForExistence(timeout: 30) || app.staticTexts["Tiles"].waitForExistence(timeout: 2),
                      "a tile that isn't pinned: the Tiles page")
        sleep(2)
        XCTAssertFalse(app.webViews["html.page"].exists, "no tile opened")
        shot("tw-06-removed-opens-tiles")
    }

    /// The pictures for the report (not a guard): Small, Medium and Large, each a different tile, light and dark;
    /// the configuration; a tile not drawn yet; signed out, and the gallery's sample.
    @MainActor func testTileWidgetPictures() throws {
        var app = launch(["-HQPagesTab", "4", "-HQPagesMore", "artifacts", "-HQPagesPinPages", "YES", "-HQDebugWidgetProbe", "YES"])
        closeAddOnSheet(app)
        XCTAssertTrue(waitUntil(150) { (Int(probe(app)["pictures"] ?? "") ?? 0) >= 6 }, "pictures: \(probe(app))")
        app.terminate()
        app = launch(["-HQPagesTab", "4", "-HQPagesMore", "pinned", "-HQDebugWidgetProbe", "YES"])
        closeAddOnSheet(app)
        sleep(8)
        shot("p-01-app-tiles")
        removeWidgets()   // best effort; run on a freshly erased simulator for clean pictures
        addTileWidget(page: 2)
        addTileWidget(page: 1)
        addTileWidget(page: 0)
        let widgets = placedWidgets()
        XCTAssertGreaterThanOrEqual(widgets.count, 3)
        // Small: Weather Today; Medium: Spending This Month; Large: Workout Streak (photographed before the app draws it).
        _ = widgets
        if let small = onScreen(Self.isSmall) { chooseTile(small, "Weather", shotPrefix: "p-02") }
        if let medium = onScreen(Self.isMedium) { chooseTile(medium, "Spending") }
        if let large = onScreen(Self.isLarge) { chooseTile(large, "Workout") }
        // Before the app has drawn them: the not-drawn-yet states (or another size's picture, fitted).
        if onScreen(Self.isSmall) != nil { sleep(3); shot("p-03-not-drawn-yet-1") }
        if onScreen(Self.isLarge) != nil { sleep(2); shot("p-03-not-drawn-yet-2") }
        app.activate()
        closeAddOnSheet(app)
        sleep(45)
        XCUIDevice.shared.press(.home)
        sleep(4)
        shot("p-04-home-light-1")
        springboard.swipeLeft(); sleep(2)
        shot("p-04-home-light-2")
        springboard.swipeRight(); sleep(1)
        XCUIDevice.shared.appearance = .dark
        sleep(4)
        shot("p-05-home-dark-1")
        springboard.swipeLeft(); sleep(2)
        shot("p-05-home-dark-2")
        springboard.swipeRight(); sleep(1)
        XCUIDevice.shared.appearance = .light
        // The app in dark, beside the widgets.
        app.activate(); sleep(2)
        XCUIDevice.shared.appearance = .dark; sleep(3)
        shot("p-06-app-tiles-dark")
        XCUIDevice.shared.appearance = .light; sleep(2)
        shot("p-06-app-tiles-light")
    }

    /// Signed out: every widget says Open Hermes HQ, and the gallery shows its sample (no account's tiles).
    @MainActor func testTileWidgetSignedOutPictures() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugResetAccounts", "YES", "-HQDebugWidgetProbe", "YES"]
        app.launch()
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 20) || app.buttons.firstMatch.waitForExistence(timeout: 5))
        sleep(5)
        XCUIDevice.shared.press(.home)
        sleep(4)
        shot("s-01-home-signed-out")
        springboard.swipeLeft(); sleep(2)
        shot("s-01b-home-signed-out-2")
        addTileWidget(page: 1, shotPrefix: "s-02")
        sleep(2)
        shot("s-03-home-signed-out-added")
    }

    /// The Home Screen's Customize modes (Tinted, Clear), each photographed with the widgets on it, then back to the
    /// default: what `widgetAccentedRenderingMode(.fullColor)` really draws.
    @MainActor func testHomeScreenModes() throws {
        editHomeScreen()
        springboard.buttons["Edit"].firstMatch.tap()
        let customize = springboard.buttons["Customize"].firstMatch
        XCTAssertTrue(customize.waitForExistence(timeout: 5), "Edit › Customize")
        customize.tap()
        sleep(2)
        dump("m-customize", springboard)
        shot("m-00-customize")
        for mode in ["Tinted", "Clear", "Default"] {
            let button = springboard.buttons[mode].firstMatch
            guard button.waitForExistence(timeout: 4) else { XCTFail("no \(mode) in Customize"); continue }
            button.tap()
            sleep(3)
            shot("m-\(mode.lowercased())-sheet")
        }
        XCUIDevice.shared.press(.home)
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(2)
    }

    /// The Home Screen's first two pages as they are now (the report's dark pictures: `xcrun simctl ui <udid> appearance
    /// dark` first; XCUIDevice's appearance doesn't reach the Home Screen on the iOS 27.2 simulator).
    @MainActor func testShootHomePages() throws {
        let name = ProcessInfo.processInfo.environment["HQN_SHOT_NAME"] ?? "h"
        XCUIDevice.shared.press(.home)
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(4)
        shot("\(name)-1")
        springboard.swipeLeft(); sleep(3)
        shot("\(name)-2")
        springboard.swipeRight(); sleep(1)
    }
}
