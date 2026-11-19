// [popup-consistency] Regression checks written against what the pop-ups draw, through APIs that predate the fix, so the
// same file runs on the baseline (where each fails) and after it: Commands and Models named their ✕ Cancel, the model
// sheet's ✕ sat 4 pt low with a smaller glyph, and Add context drew a 56 pt SwiftUI disc of its own. No network.

import SwiftUI
import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct PopupCloseRegressionTests {
    /// Where the system bar puts its ✕ in a sheet (16 pt in from the top and leading edges, 44 pt).
    private let barClose = CGRect(x: 16, y: 16, width: 44, height: 44)

    private func host(_ controller: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        for _ in 0..<4 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return window
    }

    private func buttons(in view: UIView) -> [UIButton] {
        ((view as? UIButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }

    private func symbolViews(in view: UIView) -> [UIImageView] {
        var found: [UIImageView] = []
        if let image = view as? UIImageView, image.image?.isSymbolImage == true, image.bounds.width > 4 { found.append(image) }
        for child in view.subviews { found += symbolViews(in: child) }
        return found
    }

    /// Chat Info's ✕ as the bar draws it.
    private func barGlyphSize() throws -> CGSize {
        let navigation = ChatSheet.wrap(UIViewController(), title: "Chat Info")
        let window = host(navigation)
        defer { window.isHidden = true }
        navigation.navigationBar.layoutIfNeeded()
        return try #require(symbolViews(in: navigation.navigationBar).first, "the bar's ✕").bounds.size
    }

    @Test func commandsAndModelsNameTheirCloseClose() throws {
        for (title, word) in [("Commands", UIBarButtonItem.SystemItem.done), ("Models", .cancel)] {
            let navigation = MenusSheet.wrap(UIViewController(), title: title, closeWord: word)
            let item = try #require(navigation.viewControllers.first?.navigationItem.leftBarButtonItem, "\(title): a leading close")
            #expect(item.accessibilityLabel == "Close", "\(title): VoiceOver hears Close for the ✕ (was \(item.accessibilityLabel ?? "the system's Cancel"))")
        }
    }

    @Test func theModelSheetsCloseSitsWhereTheBarsDoes() throws {
        let bar = try barGlyphSize()
        for width: CGFloat in [320, 402, 440] {
            let (panel, _) = ModelPanelView.debugSheet(ModelPanelModel.debugSample, width: width)
            #expect(panel.debugSheetPieces.close == barClose, "at \(width): \(panel.debugSheetPieces.close)")
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 874))
            window.addSubview(panel)
            window.isHidden = false
            defer { window.isHidden = true }
            let close = try #require(buttons(in: panel).first { $0.accessibilityIdentifier == "model.panel.close" })
            close.layoutIfNeeded()
            let glyph = try #require(close.imageView, "the ✕ glyph")
            #expect(abs(glyph.bounds.width - bar.width) < 0.5 && abs(glyph.bounds.height - bar.height) < 0.5,
                    "the bar's ✕ glyph (\(glyph.bounds.size) against \(bar))")
        }
    }

    @Test func addContextClosesWithTheBarsDiscInTheBarsPlace() throws {
        let bar = try barGlyphSize()
        let sheet = ComposerContextSheet(tiles: [], rows: [UIAction(title: "Link…") { _ in }], canAttach: false) { _ in }
        let window = host(sheet)
        defer { window.isHidden = true }
        let close = try #require(buttons(in: sheet.view).first { $0.accessibilityLabel == "Close" }, "a UIKit ✕ in the header")
        let frame = close.convert(close.bounds, to: sheet.view)
        let top = sheet.view.safeAreaInsets.top   // full screen in this window; a sheet has none
        #expect(frame == barClose.offsetBy(dx: 0, dy: top), "\(frame)")
        let glyph = try #require(close.imageView)
        #expect(abs(glyph.bounds.width - bar.width) < 0.5 && abs(glyph.bounds.height - bar.height) < 0.5)
    }

    /// Owner 2026-11-19: "The + has a solid background and the others are transparent." On the glass the Add context
    /// sheet's page lets the glass show, as the other sheets': clear in Light and Dark (Commands' `sheetPage`); off the
    /// glass, the same grouped page as theirs.
    @Test func addContextIsClearOnTheGlassAsTheOtherSheets() throws {
        let sheet = ComposerContextSheet(tiles: [], rows: [UIAction(title: "Link…") { _ in }], canAttach: false) { _ in }
        sheet.loadViewIfNeeded()
        let page = try #require(sheet.view.backgroundColor, "the sheet's page colour")
        for style in [UIUserInterfaceStyle.light, .dark] {
            for glass in [true, false] {
                let traits = UITraitCollection { t in
                    t.userInterfaceStyle = style
                    t[GlassSheetTrait.self] = glass
                }
                let mine = page.resolvedColor(with: traits)
                let name = "\(style == .dark ? "Dark" : "Light"), glass \(glass)"
                if !glass {
                    #expect(mine == HQPalette.sheetPage.resolvedColor(with: traits), "\(name): Commands' page")
                } else {
                    // Owner 2026-11-19: "Lighter grey glass, like Commands" — clear in Dark too, no page-colour wash.
                    #expect(mine.cgColor.alpha == 0, "\(name): clear, as Commands' (was \(mine))")
                }
            }
        }
    }

    /// Owner 2026-11-19, of + / the model sheet / Commands in Dark: "Lighter grey glass, like Commands". Their cards are
    /// the sheets' frosted card (`sheetCard`, Commands' rows), and none of the three shows a grabber.
    @Test func plusAndModelSheetsWearCommandsGlass() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for glass in [true, false] {
                let traits = UITraitCollection { t in
                    t.userInterfaceStyle = style
                    t[GlassSheetTrait.self] = glass
                }
                #expect(ModelCardSheet.cardFill.resolvedColor(with: traits) == HQPalette.sheetCard.resolvedColor(with: traits),
                        "\(style == .dark ? "Dark" : "Light"), glass \(glass): the model sheet's cards are Commands'")
            }
        }
        let plus = ComposerContextSheet(tiles: [], rows: [UIAction(title: "Link…") { _ in }], canAttach: false) { _ in }
        #expect(plus.sheetPresentationController?.prefersGrabberVisible == false, "+: no grabber, as Commands")
    }
}
