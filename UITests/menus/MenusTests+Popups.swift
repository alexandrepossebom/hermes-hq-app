// [popup-consistency] Owner: "Look at all pop ups like plus button, commands, model, and anything similar. Not designed
// the same, X buttons differ." Every chat pop-up on the iPhone closes with the same ✕: the same glyph on the same
// disc, the same size and tap target, in the same place under the sheet's top edge, with the title on the same line.
// Run with scripts/e2e-menus.sh (HQN_MENUS_ONLY=test40_PopupsCloseAlike; HQN_MENUS_DARK=1 and HQN_MENUS_DESKTOPLOOK=1
// for the other appearances). Each pop-up is photographed (`popup-<name>-<appearance>.png`) and its close control's
// measures written to `popup-metrics-<appearance>.txt` in the shots folder.

import XCTest

extension MenusTests {
    /// One pop-up's close control as XCTest sees it.
    struct PopupClose {
        var name: String
        var label: String
        var identifier: String
        var frame: CGRect
        /// The pop-up's own top edge (the first point of its surface under the close control).
        var sheetTop: CGFloat
        var title: CGRect?
        /// The ✕'s ink in the screenshot (its drawn glyph, whatever the control's accessibility frame says).
        var ink: CGRect
        var line: String {
            func r(_ v: CGFloat) -> String { String(format: "%.1f", v) }
            let head = title.map { "title midY \(r($0.midY)) minX \(r($0.minX))" } ?? "title -"
            return "\(name): label \"\(label)\" id \(identifier) frame x \(r(frame.minX)) y \(r(frame.minY)) w \(r(frame.width)) "
                + "h \(r(frame.height)) sheet-top \(r(sheetTop)) ink w \(r(ink.width)) h \(r(ink.height)) "
                + "center x \(r(ink.midX)) below-top \(r(ink.midY - sheetTop)) \(head)"
        }
    }

    @MainActor func test40_PopupsCloseAlike() throws {
        let (_, app) = try start()
        openBotChat(app)
        var closes: [PopupClose] = []

        // + : Add context.
        app.buttons["composer.plus"].tap()
        XCTAssertTrue(labelled(app, "Add context").waitForExistence(timeout: 8), "the Add context sheet")
        let privacyOK = app.buttons["OK"]
        if privacyOK.waitForExistence(timeout: 3) { privacyOK.tap(); Thread.sleep(forTimeInterval: 1.5) }
        Thread.sleep(forTimeInterval: 1.2)
        closes.append(measure(app, "plus", title: labelled(app, "Add context")))
        shot(app, "popup-plus")
        closeAndConfirm(app) { !self.labelled(app, "Add context").exists }

        // Commands.
        app.buttons["composer.commands"].tap()
        XCTAssertTrue(app.cells["commands.row./status"].waitForExistence(timeout: 10), "the Commands sheet")
        Thread.sleep(forTimeInterval: 0.8)
        closes.append(measure(app, "commands", title: navTitle(app, "Commands")))
        shot(app, "popup-commands")
        closeAndConfirm(app) { !app.cells["commands.row./status"].exists }

        // ⋯ › Model: the model sheet.
        openModelPanel(app)
        Thread.sleep(forTimeInterval: 1.2)
        closes.append(measure(app, "model", title: app.buttons["model.panel.switch"]))
        shot(app, "popup-model")
        closeAndConfirm(app) { !app.descendants(matching: .any)["model.panel"].exists }

        // Switch Model › Search All Models: the Models catalog.
        openModelSheet(app)
        XCTAssertTrue(app.cells["models.row.anthropic::claude-sonnet-5"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.8)
        closes.append(measure(app, "models", title: navTitle(app, "Models")))
        shot(app, "popup-models")
        closeAndConfirm(app) { !app.navigationBars["Models"].exists }

        // ⋯ › More › Info: Chat Info (a sibling ChatSheet).
        openMore(app)
        app.chatMoreRow("info").tap()
        XCTAssertTrue(app.navigationBars["Chat Info"].waitForExistence(timeout: 6), "Chat Info")
        Thread.sleep(forTimeInterval: 0.8)
        closes.append(measure(app, "info", title: navTitle(app, "Chat Info")))
        shot(app, "popup-info")
        closeAndConfirm(app) { !app.navigationBars["Chat Info"].exists }

        writeMetrics(closes)
        assertAlike(closes)
    }

    /// The pop-ups' ✕ are one control: a glyph named Close (not the word Cancel), drawn as Chat Info's system ✕ is (the
    /// same ink size, the same place across and under the sheet's top edge), its title on the ✕'s line, and a 44 pt
    /// target where the app draws the control itself.
    @MainActor func assertAlike(_ closes: [PopupClose]) {
        guard let canonical = closes.first(where: { $0.name == "info" }) else { return XCTFail("Chat Info's ✕ was not measured") }
        for close in closes {
            XCTAssertEqual(close.label, "Close", "\(close.name): the ✕ is named Close for VoiceOver (was \"\(close.label)\")")
            XCTAssertEqual(close.ink.width, canonical.ink.width, accuracy: 1, "\(close.name): the ✕ glyph is Chat Info's width")
            XCTAssertEqual(close.ink.height, canonical.ink.height, accuracy: 1, "\(close.name): the ✕ glyph is Chat Info's height")
            XCTAssertEqual(close.ink.midX, canonical.ink.midX, accuracy: 1.5, "\(close.name): the ✕ sits where Chat Info's does across")
            XCTAssertEqual(close.ink.midY - close.sheetTop, canonical.ink.midY - canonical.sheetTop, accuracy: 2.5,
                           "\(close.name): the ✕ sits as far under the sheet's top edge as Chat Info's")
            if !["sheet.cancel", "sheet.close"].contains(close.identifier) || close.name == "plus" || close.name == "model" {
                // The control is 44 pt (`SheetCloseDiscTests`); XCTest reports a glass button's frame about 4 % smaller.
                XCTAssertGreaterThanOrEqual(min(close.frame.width, close.frame.height), 42, "\(close.name): a 44 pt tap target")
            }
            if let title = close.title, close.name != "model" {
                XCTAssertEqual(title.midY, close.ink.midY, accuracy: 2, "\(close.name): the title sits on the ✕'s line")
            }
        }
    }

    /// The ✕'s drawn glyph inside its control: the pixels far from the disc's own ground (dark ink on a light disc or
    /// light ink on a dark one; the bare glyph in the Desktop Look).
    @MainActor func ink(_ app: XCUIApplication, around frame: CGRect) -> CGRect {
        let shot = app.screenshot().image
        guard let cg = shot.cgImage else { return .zero }
        let scale = shot.scale
        let box = CGRect(x: (frame.midX - 15) * scale, y: (frame.midY - 15) * scale, width: 30 * scale, height: 30 * scale).integral
        guard let crop = cg.cropping(to: box) else { return .zero }
        let w = crop.width, h = crop.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        func luma(_ x: Int, _ y: Int) -> Double {
            let i = (y * w + x) * 4
            return 0.299 * Double(bytes[i]) + 0.587 * Double(bytes[i + 1]) + 0.114 * Double(bytes[i + 2])
        }
        var all: [Double] = []
        for y in stride(from: 0, to: h, by: 2) { for x in stride(from: 0, to: w, by: 2) { all.append(luma(x, y)) } }
        all.sort()
        let ground = all[all.count / 2]
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where abs(luma(x, y) - ground) > 90 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX else { return .zero }
        return CGRect(x: (box.minX + CGFloat(minX)) / scale, y: (box.minY + CGFloat(minY)) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// The close control on screen now: the shared ✕ (`sheet.close`), or what each pop-up had before.
    @MainActor func popupClose(_ app: XCUIApplication) -> XCUIElement {
        let ids = ["sheet.close", "sheet.cancel", "model.panel.close"]
        for id in ids {
            let match = app.buttons.matching(identifier: id).allElementsBoundByIndex.last { $0.exists && $0.isHittable }
            if let match { return match }
        }
        return app.buttons["Close"]
    }

    @MainActor func measure(_ app: XCUIApplication, _ name: String, title: XCUIElement?) -> PopupClose {
        let close = popupClose(app)
        XCTAssertTrue(close.waitForExistence(timeout: 5), "\(name): a close control")
        let frame = close.frame
        return PopupClose(name: name, label: close.label, identifier: close.identifier, frame: frame,
                          sheetTop: sheetTop(app, above: frame), title: title?.exists == true ? title?.frame : nil,
                          ink: ink(app, around: frame))
    }

    /// Where the sheet's surface starts: walking down a column right of the ✕ (left of every title) from under the
    /// chat's bar, the first rows that differ from the dimmed chat behind the sheet. The Desktop Look's dark sheet is only
    /// 6 levels lighter than the dim there, so the step is small and must hold for three rows.
    @MainActor func sheetTop(_ app: XCUIApplication, above frame: CGRect) -> CGFloat {
        let shot = app.screenshot().image
        guard let cg = shot.cgImage else { return 0 }
        let scale = shot.scale
        let x = Int(90 * scale)
        let from = Int(150 * scale), to = Int(frame.minY * scale)
        guard x < cg.width, to > from, let column = cg.cropping(to: CGRect(x: x, y: 0, width: 1, height: to)) else { return 0 }
        var bytes = [UInt8](repeating: 0, count: to * 4)
        let context = CGContext(data: &bytes, width: 1, height: to, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(column, in: CGRect(x: 0, y: 0, width: 1, height: to))
        func luma(_ row: Int) -> Double {
            let i = row * 4
            return 0.299 * Double(bytes[i]) + 0.587 * Double(bytes[i + 1]) + 0.114 * Double(bytes[i + 2])
        }
        let dim = luma(from)
        var row = from
        while row < to - 3, !(1...3).allSatisfy({ abs(luma(row + $0 - 1) - dim) >= 4 }) { row += 1 }
        return CGFloat(row) / scale
    }

    @MainActor func navTitle(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.navigationBars[text].staticTexts[text]
    }

    @MainActor func closeAndConfirm(_ app: XCUIApplication, _ gone: @escaping () -> Bool) {
        popupClose(app).tap()
        XCTAssertTrue(waitUntil(timeout: 5, gone), "the ✕ closes the pop-up")
        Thread.sleep(forTimeInterval: 0.8)
    }

    @MainActor func writeMetrics(_ closes: [PopupClose]) {
        let text = closes.map(\.line).joined(separator: "\n") + "\n"
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "popup-metrics"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["HQN_UI_SHOTS"], !dir.isEmpty else { return }
        let mode = XCUIDevice.shared.appearance == .dark ? "dark" : "light"
        let look = ProcessInfo.processInfo.environment["HQN_UI_DESKTOPLOOK"] == "1" ? "-desktop" : ""
        try? text.write(to: URL(fileURLWithPath: dir).appending(path: "popup-metrics-\(mode)\(look).txt"), atomically: true, encoding: .utf8)
    }
}
