// [tasks-widget] The Tasks widget end to end (docs/tasks.md item 12), against the pages fixture's made-up tasks: the
// app writes the page's first screen → Small, Medium and Large Tasks widgets on the simulator's Home Screen show it →
// Show offers the page's views → a row opens its task → the check circle ticks a task off in the app (saved, and put
// back when the gateway refuses). Run like TileWidgetTests (build/tw-ui.sh TileWidgetTests/testTasksWidget…).

import XCTest

extension TileWidgetTests {
    /// The probe's Tasks fields once the widget has a live Today.
    @MainActor func waitForTasks(_ app: XCUIApplication, _ timeout: TimeInterval = 60) -> [String: String] {
        XCTAssertTrue(waitUntil(timeout) { probe(app)["tasks"] == "live" && (Int(probe(app)["today"] ?? "") ?? -1) >= 0 },
                      "the Tasks widget's store: \(probe(app))")
        return probe(app)
    }

    @MainActor func tasksApp(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQDebugWidgetProbe", "YES"] + extra)
        closeAddOnSheet(app)
        return app
    }

    /// The gallery as it lists Hermes HQ's widgets (a look before the real test).
    @MainActor func testTasksGalleryLook() throws {
        let app = tasksApp()
        _ = waitForTasks(app)
        editHomeScreen()
        springboard.buttons["Edit"].firstMatch.tap()
        springboard.buttons["Add Widget"].firstMatch.tap()
        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("Hermes HQ")
        springboard.cells["Hermes HQ"].firstMatch.tap()
        sleep(3)
        shot("g-00")
        dump("g-00", springboard)
        for n in 1...7 {
            springboard.swipeLeft(); sleep(2)
            shot("g-\(n)")
        }
        dump("g-7", springboard)
        springboard.swipeUp(); sleep(2)
        shot("g-up")
        dump("g-up", springboard)
    }

    // MARK: The fixture

    @MainActor func tasksFixture(_ mode: [String: Any] = ["lists": true]) throws {
        try account.control("/__fixture/reset", [:])
        try account.control("/__fixture/tasks-mode", mode)
    }

    /// The logged REST calls with this method whose path starts with `prefix`.
    func requests(_ method: String, _ prefix: String) -> [[String: Any]] {
        let rest = ((try? account.control("/__fixture/state"))?["rest"] as? [[String: Any]]) ?? []
        return rest.filter { ($0["method"] as? String) == method && (($0["path"] as? String) ?? "").hasPrefix(prefix) }
    }

    /// The Tasks widgets placed: Large, Medium, then Small (each new one goes on top).
    @MainActor func placeTasksWidgets() {
        clearHome()
        addWidget("Tasks", page: 5)
        addWidget("Tasks", page: 4)
        addWidget("Tasks", page: 3)
    }

    /// Step 1: the page and the widgets beside it, light (the report's pictures; dark comes from testShootHomePages).
    @MainActor func testTasksWidgetPlace() throws {
        try tasksFixture()
        let app = tasksApp()
        let probed = waitForTasks(app)
        XCTAssertEqual(probed["tasks"], "live")
        sleep(3)
        shot("t-01-app-tasks-today")
        placeTasksWidgets()
        XCTAssertGreaterThanOrEqual(placedWidgets().count, 3, "three Tasks widgets placed")
        app.activate()
        closeAddOnSheet(app)
        sleep(8)
        shootHome("t-02-home-light")
    }

    // MARK: Taps on the widget

    static let taskPath = "/api/plugins/hermes-hq-push/tasks/"

    /// The Large Tasks widget's face (the icon's frame less its name under it), on the Home Screen's page on show.
    @MainActor func largeFace() throws -> CGRect {
        let large = try XCTUnwrap(onScreen(Self.isLarge), "the Large Tasks widget on the Home Screen")
        let f = large.frame
        return CGRect(x: f.minX + 2, y: f.minY + 2, width: f.width - 4, height: 365)
    }

    /// A tap at a point of the Large widget's face (fractions of its width and height).
    @MainActor func tapLarge(_ face: CGRect, _ x: CGFloat, _ y: CGFloat) {
        springboard.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: face.minX + face.width * x, dy: face.minY + face.height * y)).tap()
    }

    /// The first row's circle and title on Large (under the top line and the first heading), and the "+".
    static let firstCircle = (x: 0.08, y: 0.21), firstTitle = (x: 0.30, y: 0.21), plus = (x: 0.914, y: 0.082)

    /// The PATCHes that marked `id` done.
    func doneSaves(_ id: String) -> [[String: Any]] {
        requests("PATCH", Self.taskPath + id).filter { (($0["body"] as? [String: Any])?["status"] as? String) == "done" }
    }

    /// The app at Tasks, the store written, then the Home Screen with the three widgets (placed once).
    @MainActor func tasksHome(_ extra: [String] = []) throws -> (app: XCUIApplication, first: String) {
        let app = tasksApp(extra)
        let probed = waitForTasks(app)
        let first = try XCTUnwrap(probed["firsttask"], "the first task's id: \(probed)")
        XCUIDevice.shared.press(.home)
        sleep(2)
        if onScreen(Self.isLarge) == nil { placeTasksWidgets() }
        XCUIDevice.shared.press(.home)
        sleep(3)
        return (app, first)
    }

    /// The circle ticks a task off in the app: drawn ticked at once, saved (the PATCH logged), then gone.
    @MainActor func testTasksWidgetCheckOffSaved() throws {
        try tasksFixture()
        let (app, first) = try tasksHome()
        let face = try largeFace()
        shot("c-01-before")
        try account.control("/__fixture/fail", ["method": "PATCH", "path": Self.taskPath + first, "delay": 8])
        tapLarge(face, Self.firstCircle.x, Self.firstCircle.y)
        let tapped = Date()
        for n in 0..<10 { usleep(400_000); shot(String(format: "c-02-%02d-%.1fs", n, Date().timeIntervalSince(tapped))) }
        // The Home Screen's page away and back: SpringBoard draws the widget's newest timeline again.
        repage()
        shot(String(format: "c-03-paged-%.1fs", Date().timeIntervalSince(tapped)))
        XCTAssertTrue(waitUntil(10) { !doneSaves(first).isEmpty }, "the check-off reached the gateway")
        sleep(4)
        shot("c-04-saved-gone")
        app.activate()
        XCTAssertTrue(waitUntil(20) { probe(app)["firsttask"] != first }, "the widget's first row is the next task: \(probe(app))")
        XCTAssertEqual(doneSaves(first).count, 1, "one save")
    }

    /// The gateway refuses: the row is drawn ticked, then put back.
    @MainActor func testTasksWidgetCheckOffRefused() throws {
        try tasksFixture()
        let (app, first) = try tasksHome()
        let face = try largeFace()
        try account.control("/__fixture/fail", ["method": "PATCH", "path": Self.taskPath + first, "status": 500, "count": 1])
        tapLarge(face, Self.firstCircle.x, Self.firstCircle.y)
        usleep(400_000); shot("r-01-ticked")
        XCTAssertTrue(waitUntil(10) { !doneSaves(first).isEmpty }, "the check-off was tried")
        sleep(5)
        repage()
        shot("r-02-put-back")
        app.activate()
        sleep(2)
        XCTAssertEqual(probe(app)["firsttask"], first, "still the first task: \(probe(app))")
    }

    /// With the app quit, the circle still ticks the task off: the intent runs in the app, launched for it.
    @MainActor func testTasksWidgetCheckOffAppQuit() throws {
        try tasksFixture()
        let (app, first) = try tasksHome()
        app.terminate()
        sleep(2)
        try account.control("/__fixture/fail", ["method": "PATCH", "path": Self.taskPath + first, "delay": 8])
        let face = try largeFace()
        tapLarge(face, Self.firstCircle.x, Self.firstCircle.y)
        sleep(4); repage(); shot("q-01-ticked-app-quit")
        XCTAssertTrue(waitUntil(30) { !doneSaves(first).isEmpty }, "the check-off reached the gateway with the app quit")
        sleep(4)
        repage()
        shot("q-02-saved-app-quit")
        XCTAssertNotEqual(app.state, .runningForeground, "the app never came forward")
    }

    /// A row opens its task; the "+" opens New Task; the top line opens Tasks.
    @MainActor func testTasksWidgetTaps() throws {
        try tasksFixture()
        let (app, _) = try tasksHome()
        var face = try largeFace()
        tapLarge(face, Self.firstTitle.x, Self.firstTitle.y)
        confirmOpen()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "the row opened the app")
        sleep(3)
        shot("o-01-row-opened")
        dump("o-01-row-opened", app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'dentist'")).firstMatch.waitForExistence(timeout: 10),
                      "the task opened")
        XCUIDevice.shared.press(.home)
        sleep(2)
        face = try largeFace()
        tapLarge(face, Self.plus.x, Self.plus.y)
        confirmOpen()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(3)
        shot("o-02-plus-new-task")
        dump("o-02-plus-new-task", app)
    }

    /// Show: hold the Medium › Edit Widget › Show lists the page's views; Work is chosen and shown.
    @MainActor func testTasksWidgetShow() throws {
        try tasksFixture()
        _ = try tasksHome()
        let medium = try XCTUnwrap(onScreen(Self.isMedium), "the Medium Tasks widget")
        medium.press(forDuration: 1.5)
        let edit = springboard.buttons["Edit Widget"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 4), "Edit Widget")
        edit.tap()
        sleep(2)
        shot("v-01-config")
        dump("v-01-config", springboard)
        showParameter().tap()
        XCTAssertTrue(springboard.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Upcoming'")).firstMatch
                        .waitForExistence(timeout: 8), "the Show list")
        sleep(1)
        shot("v-02-config-list")
        dump("v-02-config-list", springboard)
        for name in ["Today", "Upcoming", "Inbox", "Work", "Home"] {
            XCTAssertTrue(springboard.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.exists,
                          "\(name) under Show")
        }
        springboard.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Work'")).firstMatch.tap()
        sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(4)
        shot("v-03-medium-shows-work")
        // Back to Today for the next tests.
        setMediumShow("Today")
    }

    /// The quiet states: All Done (nothing left), Tasks off (Settings), then on again.
    @MainActor func testTasksWidgetQuietStates() throws {
        try tasksFixture(["lists": true, "empty": true])
        let app = tasksApp()
        XCTAssertTrue(waitUntil(60) { probe(app)["tasks"] == "live" && probe(app)["today"] == "0" }, "an empty Today: \(probe(app))")
        sleep(2)
        shot("e-00-app-empty")
        shootHome("e-01-home-all-done")
        // Tasks off.
        try account.control("/__fixture/reset", [:])
        app.terminate()
        let more = launch(["-HQPagesTab", "4", "-HQDebugWidgetProbe", "YES"])
        closeAddOnSheet(more)
        let settingsRow = more.cells["more-row-settings"]
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 20))
        settingsRow.tap()
        let toggle = more.switches["settings.tasks"].firstMatch
        let bar = more.tabBars.firstMatch
        let floor = { bar.exists ? bar.frame.minY - 12 : more.frame.height * 0.8 }
        for _ in 0..<6 where !(toggle.exists && toggle.isHittable && toggle.frame.maxY < floor()) { more.swipeUp(velocity: .slow) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Settings › Tasks")
        if toggle.value as? String == "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        XCTAssertTrue(waitUntil(20) { probe(more)["tasks"] == "off" }, "the widget store says off: \(probe(more))")
        shootHome("e-02-home-tasks-off")
        more.activate()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(30) { probe(more)["tasks"] == "live" }, "on again: \(probe(more))")
    }

    /// Signed out: the widgets say Open Hermes HQ (then signed in again by the next launch's credentials).
    @MainActor func testTasksWidgetSignedOut() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDebugResetAccounts", "YES", "-HQDebugWidgetProbe", "YES"]
        app.launch()
        XCTAssertTrue(waitUntil(30) { probe(app)["tasks"] == "signedOut" }, "signed out: \(probe(app))")
        sleep(3)
        shootHome("e-03-home-signed-out")
        app.terminate()
        let back = tasksApp()
        _ = waitForTasks(back)
    }

    /// The background path: the list changes while the app is in the background, and the widget follows without it
    /// coming forward (the debug hook runs the background refresh 3 s after the app leaves).
    @MainActor func testTasksWidgetBackgroundRefresh() throws {
        try tasksFixture()
        let (app, _) = try tasksHome(["-HQDebugWidgetRefreshInBackground", "YES"])
        app.activate()
        _ = waitForTasks(app)
        try account.control("/__fixture/tasks-mode", ["lists": true, "empty": true])
        XCUIDevice.shared.press(.home)
        sleep(12)
        shootHome("b-01-home-after-background-refresh")
        XCTAssertNotEqual(app.state, .runningForeground)
    }

    /// Every widget off this simulator's Home Screen pages, Hermes HQ's or not (a clean page for the pictures).
    @MainActor func clearHome() {
        XCUIDevice.shared.press(.home)
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(1)
        let screen = springboard.frame
        var swipes = 0
        for _ in 0..<20 {
            let all = springboard.icons.matching(NSPredicate(format: "value == 'Widget'")).allElementsBoundByIndex.filter { screen.contains($0.frame) }
            guard let widget = all.first else {
                if swipes >= 3 { break }
                springboard.swipeLeft(); swipes += 1; sleep(1); continue
            }
            widget.press(forDuration: 1.5)
            let remove = springboard.buttons["Remove Widget"].firstMatch
            guard remove.waitForExistence(timeout: 4) else { dump("tw-clear-menu", springboard); break }
            remove.tap()
            let confirm = springboard.alerts.buttons["Remove"].firstMatch
            if confirm.waitForExistence(timeout: 4) { confirm.tap() }
            sleep(2)
        }
        XCUIDevice.shared.press(.home)
        sleep(1)
    }

    /// The Home Screen's page away and back: on the iOS 27.2 simulator the page on show keeps the picture from before
    /// a tap on the widget until it's drawn again (the new timeline is read at once, the provider's log shows).
    @MainActor func repage() {
        springboard.swipeRight(); usleep(600_000); springboard.swipeLeft(); usleep(800_000)
    }

    /// Edit Widget's Show row: its button (named for the choice, Today with none made).
    @MainActor func showParameter() -> XCUIElement {
        let cell = springboard.cells.containing(.staticText, identifier: "Show").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "Show in Edit Widget")
        return cell.buttons.firstMatch
    }

    /// The Home Screen's first two pages photographed (Small and Medium on the first, Large on the second).
    @MainActor func shootHome(_ name: String) {
        XCUIDevice.shared.press(.home)
        sleep(1)
        XCUIDevice.shared.press(.home)   // on the Home Screen: back to its first page
        sleep(3)
        shot("\(name)-1")
        springboard.swipeLeft(); sleep(3)
        shot("\(name)-2")
        springboard.swipeRight(); sleep(1)
    }

    /// Hold the Medium › Edit Widget › Show › `name`, then away from the sheet.
    @MainActor func setMediumShow(_ name: String) {
        guard let medium = onScreen(Self.isMedium) else { XCTFail("the Medium Tasks widget"); return }
        medium.press(forDuration: 1.5)
        let edit = springboard.buttons["Edit Widget"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 4), "Edit Widget")
        edit.tap(); sleep(2)
        showParameter().tap()
        let choice = springboard.buttons[name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 6), "\(name) under Show")
        choice.tap(); sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(1)
    }

    @MainActor func testTasksWidgetShowToday() throws { setMediumShow("Today") }

    /// A look at the Lock Screen's editor (exploratory: can the simulator place a Lock Screen widget?).
    @MainActor func testTasksLockScreenLook() throws {
        if springboard.buttons["editing-done"].exists || springboard.buttons["close"].exists {
            dismissSheet()
            springboard.buttons["editing-cancel"].firstMatch.tap(); sleep(2)
        }
        XCUIDevice.shared.press(.home)
        sleep(1)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        // Wake it (the lock button again shows the Lock Screen).
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        shot("l-00-lock")
        dump("l-00-lock", springboard)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 2.0)
        sleep(3)
        shot("l-01-hold")
        dump("l-01-hold", springboard)
        springboard.buttons["posterboard-customize-button"].firstMatch.tap()
        sleep(3)
        shot("l-02-customize")
        dump("l-02-customize", springboard)
        let lock = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Lock Screen'")).firstMatch
        if lock.exists { lock.tap(); sleep(3) }
        shot("l-03-editor")
        dump("l-03-editor", springboard)
        springboard.buttons["grouped-widgets-reticle-view"].firstMatch.tap()
        sleep(3)
        shot("l-04-add-sheet")
        dump("l-04-add-sheet", springboard)
        let hq = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Hermes HQ'")).firstMatch
        if !hq.exists { springboard.swipeUp(); sleep(2) }
        if hq.exists { hq.tap(); sleep(3) }
        shot("l-05-hermes")
        dump("l-05-hermes", springboard)
        let placed = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Waiting' OR label CONTAINS 'Tasks,'")).count
        let sizes = springboard.buttons.matching(identifier: "Hermes HQ, Tasks")
        if sizes.count >= 2 {
            for i in 0..<2 { sizes.element(boundBy: i).tap(); sleep(2) }
        }
        _ = placed
        shot("l-06-added")
        dismissSheet()
        // The line above the clock: the inline family.
        let inline = springboard.buttons["inline-widget-reticle-view"].firstMatch
        if inline.waitForExistence(timeout: 4) {
            inline.tap(); sleep(3)
            dump("l-07-inline-sheet", springboard)
            let cell = springboard.cells["Hermes HQ, Tasks, Top Widget"].firstMatch
            for _ in 0..<3 where !(cell.exists && cell.isHittable) { springboard.swipeUp(); sleep(1) }
            if cell.exists { cell.tap(); sleep(2) }
            dump("l-08-inline-hermes", springboard)
            shot("l-08-inline-added")
            dismissSheet()
        }
        shot("l-09-editor-done")
        dump("l-09-editor-done", springboard)
        let done = springboard.buttons["editing-done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 4), "the editor's Done")
        done.tap()
        sleep(3)
        shot("l-10-after-done")
        dump("l-10-after-done", springboard)
        XCUIDevice.shared.press(.home); sleep(2)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton")); sleep(2)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton")); sleep(4)
        shot("l-11-lock-screen")
    }

    /// The Lock Screen editor's widget sheet away (dragged down by its grabber, else a tap above it).
    @MainActor func dismissSheet() {
        let close = springboard.buttons["close"].firstMatch
        if close.exists { close.tap(); sleep(2) }
        let grabber = springboard.buttons["Sheet Grabber"].firstMatch
        if grabber.exists {
            grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            sleep(2)
        }
        if springboard.buttons["Sheet Grabber"].exists {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap(); sleep(2)
        }
    }

    /// The Lock Screen editor left open by a run: the alert and sheets away, the extra circular widget removed, the
    /// inline Tasks line added, Done; then the Lock Screen with its three Tasks families.
    @MainActor func testTasksLockScreenFinish() throws {
        let ok = springboard.buttons["OK"].firstMatch
        if ok.exists && ok.isHittable { ok.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(1) }
        dismissSheet()
        dump("lf-01-editor", springboard)
        shot("lf-01-editor")
        let removes = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove'"))
        let all = removes.allElementsBoundByIndex.map { "\($0.label) \($0.frame)" }
        try? all.joined(separator: "\n").write(toFile: (ProcessInfo.processInfo.environment["HQN_SHOTS_DIR"] ?? "/tmp") + "/lf-removes.txt", atomically: true, encoding: .utf8)
        // Rightmost removal mark in the widget row (the second circular one).
        if let extra = removes.allElementsBoundByIndex.filter({ $0.frame.minY > 150 && $0.frame.minY < 260 }).max(by: { $0.frame.minX < $1.frame.minX }),
           removes.allElementsBoundByIndex.filter({ $0.frame.minY > 150 && $0.frame.minY < 260 }).count >= 3 {
            extra.tap(); sleep(2)
        }
        let inline = springboard.buttons["inline-widget-reticle-view"].firstMatch
        if inline.waitForExistence(timeout: 4) {
            inline.tap(); sleep(3)
            let cell = springboard.cells["Hermes HQ, Tasks, Top Widget"].firstMatch
            for _ in 0..<3 where !(cell.exists && cell.isHittable) { springboard.swipeUp(); sleep(1) }
            if cell.exists { cell.tap(); sleep(2) }
            if springboard.buttons["OK"].exists { springboard.buttons["OK"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(1) }
            dismissSheet()
        }
        shot("lf-02-editor")
        dump("lf-02-editor", springboard)
        let done = springboard.buttons["editing-done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 4), "the editor's Done")
        done.tap(); sleep(3)
        XCUIDevice.shared.press(.home); sleep(2)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton")); sleep(2)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton")); sleep(4)
        shot("l-12-lock-screen")
        XCUIDevice.shared.press(.home); sleep(2)
    }
}
