// [working-ring] Settings › Appearance › Theme › Working Ring (owner 2026-11-15: "a toggle to be able to remove the animation
// that goes around a bot or session to show it's working"). Off, a working chat's row has no ring but still says
// "Working…"; on again, the ring is back, with no relaunch.

import UIKit
import XCTest

extension SessionsTests {
    /// The pixels on the ring's line (the iOS look: 5 pt in at the top and foot, 8 pt at the sides, 1.25 pt wide,
    /// `WorkingArc.rowInsets`) that differ from the row's own ground beside it, at the most lit of four looks a
    /// tenth of a lap apart (the lit spikes travel, so one look can catch a dim stretch).
    @MainActor func ringPixels(_ element: XCUIElement) -> Int {
        var most = 0
        for _ in 0..<4 {
            most = max(most, Self.litOnRing(element.screenshot().image))
            Thread.sleep(forTimeInterval: 0.22)
        }
        return most
    }

    private static func litOnRing(_ image: UIImage) -> Int {
        guard let cg = image.cgImage, cg.width > 40, cg.height > 30 else { return 0 }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let k = CGFloat(w) / image.size.width   // pixels per point
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }
        let ground = px(Int(3 * k), h / 2)
        func lit(_ x: Int, _ y: Int) -> Bool {
            let p = px(x, y)
            return max(abs(p.0 - ground.0), abs(p.1 - ground.1), abs(p.2 - ground.2)) > 40
        }
        let line0 = Int((8 * k).rounded(.down)), line1 = Int((9.25 * k).rounded(.up))
        let top0 = Int((5 * k).rounded(.down)), top1 = Int((6.25 * k).rounded(.up))
        var count = 0
        for y in Int(CGFloat(h) * 0.3)..<Int(CGFloat(h) * 0.7) {   // the sides, clear of the rounded corners
            for x in line0...line1 where lit(x, y) { count += 1 }
            for x in (w - 1 - line1)...(w - 1 - line0) where lit(x, y) { count += 1 }
        }
        for x in Int(30 * k)..<(w - Int(30 * k)) {                   // the top and the foot
            for y in top0...top1 where lit(x, y) { count += 1 }
            for y in (h - 1 - top1)...(h - 1 - top0) where lit(x, y) { count += 1 }
        }
        return count
    }

    /// Opens Settings › Theme from More and sets Working Ring to `on`; back on Sessions afterwards.
    @MainActor private func setWorkingRing(_ app: XCUIApplication, _ on: Bool, shot name: String? = nil) {
        let more = app.tabButton(id: "tab-more", label: "More")
        XCTAssertTrue(more.waitForExistence(timeout: 10), "More")
        let row = app.cells["more-row-settings"]
        for _ in 0..<4 {
            more.tap()
            if row.waitForExistence(timeout: 2), row.isHittable { break }
        }
        if !app.buttons["settings.gateway-card"].exists { row.tap() }
        XCTAssertTrue(app.buttons["settings.gateway-card"].waitForExistence(timeout: 8), "Settings opens")
        let themeRow = app.buttons["settings.theme-row"]
        for _ in 0..<6 where !(themeRow.exists && themeRow.isHittable) { app.swipeUp() }
        themeRow.tap()
        XCTAssertTrue(app.navigationBars["Theme"].waitForExistence(timeout: 8), "the Theme page opens")
        let toggle = app.switches["theme.workingRing"]
        for _ in 0..<10 where !(toggle.exists && toggle.isHittable) { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable, "Working Ring is on the Theme page")
        if (toggle.value as? String == "1") != on {
            toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        }
        XCTAssertTrue(waitUntil(5) { (toggle.value as? String == "1") == on }, "the switch is \(on ? "on" : "off")")
        if let name { shot(app, name) }
        // Back to Settings' root, so the next visit starts there.
        app.navigationBars["Theme"].buttons.firstMatch.tap()
        _ = app.buttons["settings.gateway-card"].waitForExistence(timeout: 5)
        app.tabBars.buttons["Sessions"].firstMatch.tap()
        XCTAssertTrue(app.collectionViews["sessions.list"].waitForExistence(timeout: 8), "back on Sessions")
        Thread.sleep(forTimeInterval: 0.8)
    }

    @MainActor func test28_WorkingRingSwitch() throws {
        fixture("/__fixture/mode", ["prompts": "hold"])
        let app = launch()
        setWorkingRing(app, true)

        // On, the default: the working row wears the ring.
        XCTAssertTrue(row(app, "s-trip").waitForExistence(timeout: 15))
        openChat(app, "s-trip")
        type(app, "Add a fourth hotel", send: true)
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 8), "the turn runs")
        backToList(app)
        XCTAssertTrue(waitUntil(8) { self.labelOf(self.row(app, "s-trip")).contains("Working") }, labelOf(row(app, "s-trip")))
        let ringOn = ringPixels(row(app, "s-trip"))
        let idle = ringPixels(row(app, "s-garden"))
        shot(app, "working-ring-on")
        XCTAssertGreaterThan(ringOn, 20, "the ring is drawn on the working row (lit \(ringOn), an idle row \(idle))")

        // Off: no ring, still "Working…", while the turn keeps running. No relaunch.
        setWorkingRing(app, false, shot: "working-ring-setting-off")
        XCTAssertTrue(labelOf(row(app, "s-trip")).contains("Working"), "the row still says it works")
        let ringOff = ringPixels(row(app, "s-trip"))
        shot(app, "working-ring-off")
        XCTAssertLessThanOrEqual(ringOff, idle + 4, "no ring on the working row (lit \(ringOff), an idle row \(idle))")
        app.buttons["Bots"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.2)
        shot(app, "working-ring-off-bots")
        app.buttons["Sessions"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.6)

        // On again: the ring is back on the same running row.
        setWorkingRing(app, true)
        let ringAgain = ringPixels(row(app, "s-trip"))
        XCTAssertGreaterThan(ringAgain, 20, "the ring comes back (lit \(ringAgain))")
        fixture("/__fixture/emit", ["type": "message.complete", "session_id": "s-trip", "payload": ["text": "Added the Ribeira Inn."]])
        XCTAssertTrue(waitUntil(8) { !self.labelOf(self.row(app, "s-trip")).contains("Working") })
    }
}
