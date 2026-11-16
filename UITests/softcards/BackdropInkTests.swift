// [backdrop-ink] Owner 2026-11-15 (a screenshot of Sessions in Light on a night-sky picture, Dim turned down): "When you
// select a darker background, the text on the top … It's not automatically adjusting to the background type. So we need
// to make sure that happens every time." Words that stand straight on the app's picture (a tab's title and the line
// under it, a pushed page's title, and a plain list's rows with Soft Cards off) take the ink that reads on the picture
// as it is drawn (under Dim), whatever the mode: light words on a dark picture in Light, dark words on a pale one in
// Dark.
// Each test puts a photo of its own behind the app (made here: a dark one, a pale one), then reads the words' pixels
// off the screen: the ink against what is around it must measure 4.5:1.
// Run against any stand-in gateway:
//   TEST_RUNNER_HQN_UI_CREDENTIALS=<creds.json> TEST_RUNNER_HQN_SHOTS_DIR=<dir> xcodebuild … test
//     -only-testing:HermesHQNativeUITests/BackdropInkTests

import UIKit
import XCTest

final class BackdropInkTests: XCTestCase {
    private var app: XCUIApplication!
    private let environment = ProcessInfo.processInfo.environment
    /// What the words must measure against the picture around them (WCAG).
    private static let contrast = 4.5

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: Pictures

    /// A photo for the app's background: one tone from `top` to `bottom`, with a little grain so it isn't flat.
    private func photo(_ name: String, top: UIColor, bottom: UIColor) throws -> String {
        let size = CGSize(width: 600, height: 1300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colours = [top.cgColor, bottom.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            // Stars (or specks): small, sparse, the other tone.
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 33) / CGFloat(1 << 31)
            }
            var white: CGFloat = 0
            top.getWhite(&white, alpha: nil)
            context.cgContext.setFillColor(UIColor(white: white < 0.5 ? 1 : 0, alpha: 0.5).cgColor)
            for _ in 0..<160 { context.cgContext.fillEllipse(in: CGRect(x: next() * size.width, y: next() * size.height, width: 1.5, height: 1.5)) }
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hq-backdrop-ink-\(name).jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
        return url.path
    }

    private func nightSky() throws -> String {
        try photo("night", top: UIColor(red: 0.03, green: 0.04, blue: 0.10, alpha: 1), bottom: UIColor(red: 0.10, green: 0.09, blue: 0.20, alpha: 1))
    }

    private func paleSky() throws -> String {
        try photo("pale", top: UIColor(red: 0.93, green: 0.95, blue: 0.99, alpha: 1), bottom: UIColor(red: 0.99, green: 0.93, blue: 0.90, alpha: 1))
    }

    // MARK: The app

    @MainActor private func launch(mode: String, picture: String, dim: Int, cards: Bool, skin: String = "nous", more: [String] = []) throws {
        let account = try FixtureAccount.load()
        let app = XCUIApplication()
        app.launchEnvironment["HQN_SIGNIN_URL"] = account.url
        app.launchEnvironment["HQN_SIGNIN_USERNAME"] = account.username
        app.launchEnvironment["HQN_SIGNIN_PASSWORD"] = account.password
        // (Accounts reset: a gateway another suite left signed in, and since stopped, puts its notice over the Bots title.)
        app.launchArguments = ["-HQDebugResetAccounts", "YES",
                               "-HQDebugNoSwipePeek", "YES", "-HQDebugTalkIntroSeen", "YES", "-HQDebugResetTheme", "YES",
                               "-HQDebugSkin", skin, "-HQDebugDesktopLook", "NO",
                               "-HQDebugAppearance", mode, "-hqn.appearance", mode,
                               "-HQDebugAppBackground", picture, "-HQDebugAppBackgroundDim", "\(dim)",
                               "-HQDebugAppBackgroundCards", cards ? "YES" : "NO"] + more
        app.launch()
        self.app = app
        XCTAssertTrue(tab("Bots").waitForExistence(timeout: 30), "signed in")
        Thread.sleep(forTimeInterval: 2.5)   // the photo is read off the main thread
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
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ink-\(name).png"))
        }
    }

    // MARK: Reading the screen

    /// How the words in `element` measure against what is around them: its pixels' usual tone (what it stands on)
    /// against the tone furthest from that (the ink at the heart of a stroke).
    @MainActor private func contrast(of element: XCUIElement) -> Double {
        guard let image = element.screenshot().image.cgImage else { return 0 }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        func linear(_ value: UInt8) -> Double {
            let tone = Double(value) / 255
            return tone <= 0.04045 ? tone / 12.92 : pow((tone + 0.055) / 1.055, 2.4)
        }
        var tones: [Double] = []
        tones.reserveCapacity(width * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            tones.append(0.2126 * linear(pixels[index]) + 0.7152 * linear(pixels[index + 1]) + 0.0722 * linear(pixels[index + 2]))
        }
        let sorted = tones.sorted()
        let ground = sorted[sorted.count / 2]
        // The ink: the mean of the 2 % of pixels furthest from the ground.
        let far = tones.map { abs($0 - ground) }.enumerated().sorted { $0.element > $1.element }.prefix(max(1, tones.count / 50))
        let ink = far.map { tones[$0.offset] }.reduce(0, +) / Double(far.count)
        return (max(ink, ground) + 0.05) / (min(ink, ground) + 0.05)
    }

    /// Large text (a tab's title, bold and 17 pt or more) needs 3:1 (WCAG): what a title is held to over a list's soft
    /// edge, where the cards and the picture between them are blurred into one middle tone.
    private static let largeText = 3.0

    @MainActor private func expectReadable(_ element: XCUIElement, _ what: String, atLeast: Double = BackdropInkTests.contrast,
                                           file: StaticString = #filePath, line: UInt = #line) {
        guard element.waitForExistence(timeout: 6) else { return XCTFail("\(what): not on screen", file: file, line: line) }
        let measured = contrast(of: element)
        NSLog("[backdrop-ink] %@: %.2f:1", what, measured)
        XCTAssertGreaterThanOrEqual(measured, atLeast, "\(what) measures \(String(format: "%.2f", measured)):1 on the picture", file: file, line: line)
    }

    /// The tabs' titles, the line under Bots' title, and a pushed page's title.
    @MainActor private func checkBars(_ name: String) {
        for title in ["Bots", "Sessions"] {
            tab(title).tap()
            Thread.sleep(forTimeInterval: 1.0)
            shot("\(name)-\(title.lowercased())")
            expectReadable(app.navigationBars.staticTexts[title].firstMatch, "\(name): the \(title) title")
        }
        tab("More").tap()
        Thread.sleep(forTimeInterval: 1.0)
        shot("\(name)-more")
        expectReadable(app.navigationBars.staticTexts["More"].firstMatch, "\(name): the More title")
        let settings = app.cells["more-row-settings"]
        guard settings.waitForExistence(timeout: 6) else { return XCTFail("\(name): no Settings row") }
        settings.tap()
        Thread.sleep(forTimeInterval: 1.5)
        shot("\(name)-settings")
        expectReadable(app.navigationBars["Settings"].staticTexts["Settings"].firstMatch, "\(name): the Settings title")
    }

    // MARK: Tests

    /// The owner's screenshot: Light, a night sky, Dim down, Soft Cards on.
    @MainActor func testInk1_DarkPictureInLight() throws {
        try launch(mode: "light", picture: try nightSky(), dim: 0, cards: true)
        checkBars("dark-in-light")
    }

    /// The other way round: Dark, a pale picture, Dim down.
    @MainActor func testInk2_PalePictureInDark() throws {
        try launch(mode: "dark", picture: try paleSky(), dim: 0, cards: true)
        checkBars("pale-in-dark")
    }

    /// A picture of the mode's own tone keeps the mode's own ink (nothing flips that shouldn't).
    @MainActor func testInk3_OwnToneKeepsOwnInk() throws {
        try launch(mode: "light", picture: try paleSky(), dim: 0, cards: true)
        checkBars("pale-in-light")
    }

    /// Soft Cards off: a plain list's rows stand straight on the picture too.
    @MainActor func testInk4_RowsWithoutCards() throws {
        try launch(mode: "light", picture: try nightSky(), dim: 0, cards: false)
        // A plain list's rows: a chat's title (a bot's row is one element with its face, so its words can't be read alone).
        shot("dark-in-light-no-cards-bots-rows")
        tab("Sessions").tap()
        Thread.sleep(forTimeInterval: 1.0)
        expectReadable(app.staticTexts["Plan next week"].firstMatch, "no cards: a chat's title on Sessions")
        checkBars("dark-in-light-no-cards")
        // A grouped page's rows keep their cards; its section titles stand on the picture.
        expectReadable(app.staticTexts["Appearance"].firstMatch, "no cards: Settings' Appearance title")
        // And rows with no card of their own: a page's introduction.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 1.0)
        let composio = app.cells["more-row-composio"]
        guard composio.waitForExistence(timeout: 6) else { return XCTFail("no Composio row") }
        composio.tap()
        Thread.sleep(forTimeInterval: 1.5)
        shot("dark-in-light-no-cards-composio")
        expectReadable(app.staticTexts["Let your bots use your apps"].firstMatch, "no cards: Composio's introduction")
    }

    /// Dim turned up lays enough of the page colour over the picture for the mode's own ink: nothing is changed then.
    @MainActor func testInk5_DimKeepsOwnInk() throws {
        try launch(mode: "light", picture: try nightSky(), dim: 80, cards: true)
        checkBars("dark-in-light-dim80")
    }

    /// A skin with one look (Midnight: dark only) can't draw its rows in the other mode: on a pale photo with Soft
    /// Cards off the app lays on as much Dim as its words need.
    @MainActor func testInk7_OneLookSkin() throws {
        try launch(mode: "light", picture: try paleSky(), dim: 0, cards: false, skin: "midnight")
        shot("midnight-pale-bots")
        tab("Sessions").tap()
        Thread.sleep(forTimeInterval: 1.0)
        shot("midnight-pale-sessions")
        expectReadable(app.staticTexts["Plan next week"].firstMatch, "one look: a chat's title on Sessions")
        expectReadable(app.navigationBars.staticTexts["Sessions"].firstMatch, "one look: the Sessions title")
        tab("More").tap()
        Thread.sleep(forTimeInterval: 1.0)
        shot("midnight-pale-more")
    }

    /// Owner 2026-11-15 (build 1021, App Background's own page scrolled): "You missed some. Check out the text up top."
    /// On Soft Cards the cards are the page's colour, and once they scroll under the bar the title stands on them, not
    /// on the picture: white words chosen for the night sky sat on pale cards. Each page is scrolled and its title read.
    @MainActor func testInk8_ScrolledUnderTheBar() throws {
        try launch(mode: "light", picture: try nightSky(), dim: 0, cards: true)
        for title in ["Bots", "Sessions"] {
            tab(title).tap()
            Thread.sleep(forTimeInterval: 1.0)
            // A little (the cards under the bar's foot, the picture still behind the title), then well under.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(forDuration: 0.3, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58)), withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 1.0)
            shot("scrolled-\(title.lowercased())-a-little")
            expectReadable(app.navigationBars.staticTexts[title].firstMatch, "scrolled a little: the \(title) title")
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1.2)
            shot("scrolled-\(title.lowercased())")
            expectReadable(app.navigationBars.staticTexts[title].firstMatch, "scrolled: the \(title) title")
            app.swipeDown(); app.swipeDown()
            Thread.sleep(forTimeInterval: 1.2)
            expectReadable(app.navigationBars.staticTexts[title].firstMatch, "back at rest: the \(title) title")
        }
        tab("More").tap()
        Thread.sleep(forTimeInterval: 1.0)
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.2)
        shot("scrolled-more")
        expectReadable(app.navigationBars.staticTexts["More"].firstMatch, "scrolled: the More title")
        // The links at More's foot stand on the page, not on a card.
        for _ in 0..<3 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1.2)
        shot("more-foot")
        expectReadable(app.buttons["more.link.website"].firstMatch, "More's Website link")
        expectReadable(app.buttons["more.link.github"].firstMatch, "More's GitHub link")
        expectReadable(app.navigationBars.staticTexts["More"].firstMatch, "at the foot: the More title")
        app.swipeDown(); app.swipeDown()
        Thread.sleep(forTimeInterval: 1.0)
        let settings = app.cells["more-row-settings"]
        guard settings.waitForExistence(timeout: 6) else { return XCTFail("no Settings row") }
        settings.tap()
        Thread.sleep(forTimeInterval: 1.5)
        let bar = app.navigationBars["Settings"].staticTexts["Settings"].firstMatch
        // Part of the way, then well under: the title must read at both.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        Thread.sleep(forTimeInterval: 1.2)
        shot("scrolled-settings-a-little")
        expectReadable(bar, "scrolled a little: the Settings title")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.2)
        shot("scrolled-settings")
        expectReadable(bar, "scrolled: the Settings title")
        app.swipeDown(); app.swipeDown()
        Thread.sleep(forTimeInterval: 1.2)
        expectReadable(bar, "back at rest: the Settings title")
        // The owner's page: Settings › Appearance › Backgrounds › App Background.
        for label in ["Appearance", "Backgrounds", "App Background"] {
            let row = app.cells.containing(.staticText, identifier: label).firstMatch
            for _ in 0..<4 where !(row.exists && row.isHittable) { app.swipeUp(); Thread.sleep(forTimeInterval: 0.5) }
            guard row.exists, row.isHittable else { shot("no-\(label)"); return XCTFail("no \(label) row") }
            row.tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.2)
        shot("scrolled-app-background")
        expectReadable(app.navigationBars.staticTexts["App Background"].firstMatch, "scrolled: the App Background title")
    }

    /// For looking at: a chat on the same picture (chats use the app's background until they have their own), its Dim
    /// down too. Pictures of a chat at rest, scrolled up, and a new empty chat.
    @MainActor func testInk6_ChatLook() throws {
        let mode = environment["HQN_INK_MODE"] ?? "light"
        try launch(mode: mode, picture: mode == "light" ? try nightSky() : try paleSky(), dim: 0, cards: true,
                   more: ["-HQDebugChatBackgroundSame", "YES", "-HQDebugChatBackgroundDim", "0"])
        tab("Sessions").tap()
        Thread.sleep(forTimeInterval: 1.0)
        let row = app.staticTexts["Plan next week"].firstMatch
        guard row.waitForExistence(timeout: 6) else { return XCTFail("no chat to open") }
        row.tap()
        Thread.sleep(forTimeInterval: 2.5)
        shot("chat-\(mode)-1-rest")
        app.swipeDown()
        Thread.sleep(forTimeInterval: 1.0)
        shot("chat-\(mode)-2-scrolled")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 1.0)
        tab("Bots").tap()
        Thread.sleep(forTimeInterval: 1.0)
        app.cells.element(boundBy: 2).tap()
        Thread.sleep(forTimeInterval: 2.5)
        shot("chat-\(mode)-3-bot")
    }
}
