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

    /// Owner 2026-11-18: in Dark the sheet "looks awful: the buttons are black and the pop up is light". Then
    /// 2026-11-19, of + / the model sheet / Commands side by side in Dark: every pop-up is "lighter grey glass, like
    /// Commands". So the sheet is Commands' own glass, its tiles Commands' frosted cards (no black buttons on a light
    /// sheet), over a plain chat and over a white picture at Dim 0 (the worst case), in Dark and Light.
    @MainActor func testContextSheetIsCommandsGlassOverABrightPicture() throws {
        let picture = FileManager.default.temporaryDirectory.appendingPathComponent("context-sheet-background.png")
        let white = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 120)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 120))
        }
        try XCTUnwrap(white.pngData()).write(to: picture)
        for (mode, pictured) in [("dark", true), ("light", true), ("dark", false)] {
            let background = pictured ? ["-HQDebugChatBackground", picture.path, "-HQDebugChatBackgroundDim", "0"] : []
            let (_, app) = try start(arguments: background + ["-HQDebugAppearance", mode])
            app.buttons["composer.plus"].tap()
            let title = app.staticTexts["Add context"]
            XCTAssertTrue(title.waitForExistence(timeout: 8))
            let privacyOK = app.buttons["OK"]
            if privacyOK.waitForExistence(timeout: 5) { privacyOK.tap() }
            Thread.sleep(forTimeInterval: 2)
            let name = "\(mode)\(pictured ? " over a white picture" : "")"
            let plusClose = app.buttons["Close"].frame
            let shot = app.screenshot()
            IPad.shot(app, "composer-add-context-\(pictured ? "white-picture" : "no-picture")-\(mode)", in: self)
            let plus = Self.medianLuminance(shot, in: Self.besideClose(plusClose))
            // A tile beside the sheet between two tiles (the glass darkens down the sheet, so the gap next to it).
            let files = app.buttons["composer.plus.files"].frame, memo = app.buttons["composer.plus.memo"].frame
            let tile = Self.medianLuminance(shot, in: CGRect(x: files.minX + 8, y: files.minY + 6, width: files.width - 16, height: 12))
            let gap = Self.medianLuminance(shot, in: CGRect(x: files.maxX + 2, y: files.minY + 6, width: max(2, memo.minX - files.maxX - 4), height: 12))
            app.buttons["Close"].tap()
            XCTAssertTrue(IPad.waitUntil(timeout: 5) { !title.exists })
            Thread.sleep(forTimeInterval: 0.8)

            app.buttons["composer.commands"].tap()
            let commandsClose = app.buttons["Close"]
            XCTAssertTrue(commandsClose.waitForExistence(timeout: 8), "the Commands sheet")
            Thread.sleep(forTimeInterval: 1.5)
            let commands = Self.medianLuminance(app.screenshot(), in: Self.besideClose(commandsClose.frame))
            XCTAssertEqual(plus, commands, accuracy: 0.04, "\(name): + is Commands' glass (+ \(plus), Commands \(commands))")
            if mode == "dark" {
                XCTAssertGreaterThan(tile, gap, "\(name): the tiles are frosted cards lifted off the glass, not black buttons (tile \(tile), glass beside it \(gap))")
            }
            app.terminate()
        }
    }

    /// A strip of the sheet right of its ✕, left of every title: the sheet's own surface.
    private static func besideClose(_ close: CGRect) -> CGRect {
        CGRect(x: close.maxX + 8, y: close.midY - 5, width: 20, height: 10)
    }

    /// The median relative luminance (0…1) of the screenshot inside `rect` (points): the words on it don't move it.
    private static func medianLuminance(_ shot: XCUIScreenshot, in rect: CGRect) -> Double {
        let image = shot.image
        guard let cg = image.cgImage, rect.width > 4, rect.height > 4 else { return -1 }
        let scale = image.scale
        let box = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let crop = cg.cropping(to: box) else { return -1 }
        let w = crop.width, h = crop.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        func linear(_ v: UInt8) -> Double { let c = Double(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        var values: [Double] = []
        for i in stride(from: 0, to: bytes.count, by: 16) {
            values.append(0.2126 * linear(bytes[i]) + 0.7152 * linear(bytes[i + 1]) + 0.0722 * linear(bytes[i + 2]))
        }
        values.sort()
        return values.isEmpty ? -1 : values[values.count / 2]
    }
}
