import XCTest

extension ComposerUITests {
    @MainActor func testContextSheetShowsActionsAndPreservesDraft() throws {
        let (_, app) = try start()
        let field = app.textViews["composer.text"]
        field.typeText("draft stays here")
        app.buttons["composer.plus"].tap()
        XCTAssertTrue(app.staticTexts["Add context"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["composer.plus.photos"].exists)
        // The quick tiles sit in one row under the photos; Link is a row below them.
        let camera = app.buttons["composer.plus.camera"], files = app.buttons["composer.plus.files"]
        XCTAssertTrue(camera.exists && files.exists)
        XCTAssertEqual(camera.frame.midY, files.frame.midY, accuracy: 1, "Camera and Files are tiles in one row")
        XCTAssertGreaterThan(app.buttons["composer.plus.link"].frame.minY, files.frame.maxY, "Link is a row under the tiles")
        XCTAssertTrue(app.buttons["composer.plus.link"].isHittable, "the sheet fits its rows: Link is not under the edge")
        XCTAssertTrue(app.buttons["Close"].exists)
        // The out-of-process Photos picker loads asynchronously on a freshly booted simulator.
        Thread.sleep(forTimeInterval: 8)
        let privacyOK = app.buttons["OK"]
        if privacyOK.exists {
            privacyOK.tap()
            Thread.sleep(forTimeInterval: 2) // let the Photos privacy notice finish dismissing
        }
        IPad.shot(app, "composer-add-context", in: self)
        app.buttons["Close"].tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 5) { !app.staticTexts["Add context"].exists })
        XCTAssertEqual(field.value as? String, "draft stays here")
        app.buttons["composer.plus"].tap()
        XCTAssertTrue(app.buttons["composer.plus.link"].waitForExistence(timeout: 5))
        app.buttons["composer.plus.link"].tap()
        XCTAssertTrue(app.alerts["Add Link"].waitForExistence(timeout: 8), "the sheet dismisses before presenting the link dialog")
        app.alerts["Add Link"].buttons["Cancel"].tap()
        XCTAssertEqual(field.value as? String, "draft stays here")
    }

    /// A photo tapped in the sheet's recent row closes the sheet and lands in the tray (the simulator's library has
    /// photos: `xcrun simctl addmedia` before the run).
    @MainActor func testContextSheetRecentPhotoAttaches() throws {
        let (_, app) = try start()
        app.buttons["composer.plus"].tap()
        XCTAssertTrue(app.staticTexts["Add context"].waitForExistence(timeout: 8))
        let privacyOK = app.buttons["OK"]
        if privacyOK.waitForExistence(timeout: 6) { privacyOK.tap(); Thread.sleep(forTimeInterval: 2) }
        let strip = app.descendants(matching: .any)["composer.plus.recentPhotos"]
        XCTAssertTrue(strip.waitForExistence(timeout: 8), "the recent photos row")
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        if !photo.waitForExistence(timeout: 15) { print(app.debugDescription) }
        XCTAssertTrue(photo.exists, "a recent photo shows in the row")
        IPad.shot(app, "composer-add-context-photos", in: self)
        photo.tap()
        XCTAssertTrue(IPad.waitUntil(timeout: 8) { !app.staticTexts["Add context"].exists }, "the sheet closes on a pick")
        XCTAssertTrue(app.buttons["composer.tray.tile.0"].waitForExistence(timeout: 20), "the photo is in the tray")
        IPad.shot(app, "composer-recent-photo-in-tray", in: self)
    }
}
