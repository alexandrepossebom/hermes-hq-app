// [popup-consistency] Owner: "Look at all pop ups like plus button, commands, model … Not designed the same, X buttons
// differ." Every chat pop-up's ✕ on the iPhone is the system bar's ✕: Commands and Models (`MenusSheet.wrap`), Chat
// Info and its siblings (`ChatSheet.wrap`), and the two sheets that draw their own header (Add context, the model
// sheet) through `SheetCloseDisc`, the same glyph, disc, size and place. No network.

import SwiftUI
import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct SheetCloseDiscTests {
    /// The bar's own ✕ as UIKit draws it in a sheet's navigation bar: its image view inside the bar. `size`: the text
    /// size the window is at.
    private func systemCloseGlyph(_ navigation: UINavigationController = ChatSheet.wrap(UIViewController(), title: "Chat Info"),
                                  size: UIContentSizeCategory = .large) -> UIImageView? {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.traitOverrides.preferredContentSizeCategory = size
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        navigation.view.layoutIfNeeded()
        navigation.navigationBar.layoutIfNeeded()
        defer { window.isHidden = true }
        func find(_ view: UIView) -> UIImageView? {
            if let image = view as? UIImageView, image.image?.isSymbolImage == true, image.bounds.width > 4 { return image }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return find(navigation.navigationBar)
    }

    /// The disc's ✕ is drawn as the bar draws its own (iOS 26: Body, medium, large scale, 22.7 × 21.3 pt at the default
    /// text size), at every text size: it grows as the bar's does and stops where the bar's stops (28 × 26 pt from XXL).
    @Test func theDiscsGlyphIsTheSystemBarsClose() throws {
        for size in [UIContentSizeCategory.extraSmall, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge, .accessibilityMedium, .accessibilityExtraExtraExtraLarge] {
            let system = try #require(systemCloseGlyph(size: size), "the bar's ✕ glyph at \(size.rawValue)")
            let config = String(describing: system.preferredSymbolConfiguration)
            #expect(config.contains("weight=Medium") && config.contains("scale=Large"), "the bar's glyph: \(config)")
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            window.traitOverrides.preferredContentSizeCategory = size
            let host = UIViewController()
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            let button = SheetCloseButton(.close, action: nil)
            host.view.addSubview(button)
            button.frame = SheetCloseDisc.frame(width: 402)
            button.layoutIfNeeded()
            let glyph = try #require(button.imageView, "the disc's glyph")
            #expect(abs(glyph.bounds.width - system.bounds.width) < 0.5 && abs(glyph.bounds.height - system.bounds.height) < 0.5,
                    "the disc's ✕ is the bar's size at \(size.rawValue) (\(glyph.bounds.size) against \(system.bounds.size))")
        }
    }

    /// Commands and Models close with the system ✕ named Close, as Chat Info does, not a ✕ that VoiceOver calls Cancel.
    @Test func pickerSheetsCloseWithTheSystemsCloseNamedClose() throws {
        let chatInfo = try #require(systemCloseGlyph()?.image)
        for navigation in [MenusSheet.wrap(UIViewController(), title: "Commands", closeWord: .done),
                           MenusSheet.wrap(UIViewController(), title: "Models"),
                           ChatSheet.wrap(UIViewController(), title: "Chat Info")] {
            let item = try #require(navigation.viewControllers.first?.navigationItem.leftBarButtonItem, "a leading close")
            #expect(item.accessibilityLabel == "Close", "\(navigation.viewControllers.first?.title ?? ""): named Close")
            #expect(item.accessibilityIdentifier == SheetCloseDisc.identifier || item.accessibilityIdentifier == "sheet.cancel")
            let glyph = try #require(systemCloseGlyph(navigation)?.image, "a ✕ drawn in the bar")
            #expect(glyph.size == chatInfo.size, "\(navigation.viewControllers.first?.title ?? ""): Chat Info's ✕")
        }
    }

    /// The model sheet's ✕ is the shared disc, 16 pt in from the sheet's top-leading corner, as the bar's ✕ sits.
    @Test func theModelSheetsCloseIsTheSharedDisc() {
        for width: CGFloat in [320, 375, 402, 440] {
            let (panel, _) = ModelPanelView.debugSheet(ModelPanelModel.debugSample, width: width)
            let close = panel.debugSheetPieces.close
            #expect(close == SheetCloseDisc.frame(width: width), "at \(width): \(close)")
            #expect(panel.debugCloseButton is SheetCloseButton, "the shared disc, not a button of its own")
        }
    }

    /// The Add context sheet's ✕ is the same UIKit disc, in the same place, in its SwiftUI header.
    @Test func theAddContextSheetsCloseIsTheSharedDisc() throws {
        let sheet = ComposerContextSheet(tiles: [], rows: [UIAction(title: "Link…") { _ in }], canAttach: false) { _ in }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = sheet
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        sheet.view.frame = window.bounds
        for _ in 0..<4 { sheet.view.setNeedsLayout(); sheet.view.layoutIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        func find(_ view: UIView) -> SheetCloseButton? {
            if let button = view as? SheetCloseButton { return button }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        let button = try #require(find(sheet.view), "the shared disc in the header")
        let frame = button.convert(button.bounds, to: sheet.view)
        let top = sheet.view.safeAreaInsets.top   // full screen here; a sheet has none
        #expect(abs(frame.minX - SheetCloseDisc.inset) < 0.5 && abs(frame.minY - top - SheetCloseDisc.inset) < 0.5, "16 pt in: \(frame) in \(sheet.view.bounds) safe \(sheet.view.safeAreaInsets)")
        #expect(abs(frame.width - SheetCloseDisc.side) < 0.5 && abs(frame.height - SheetCloseDisc.side) < 0.5, "44 pt: \(frame)")
        #expect(button.accessibilityLabel == "Close" && button.accessibilityIdentifier == SheetCloseDisc.identifier)
    }

    /// The disc in each look: Liquid Glass in the iOS look; in the Desktop Look the glyph alone, as the look's bars draw
    /// their ✕ (no outlined box, no grey disc). Both keep the 44 pt target, the label ink and the large content viewer.
    @Test func theDiscFollowsTheLook() {
        let button = SheetCloseButton(.close, action: UIAction { _ in })
        for desktop in [false, true] {
            let config = SheetCloseDisc.configuration(.close, desktop: desktop)
            #expect(config.background.backgroundColor == nil || config.background.backgroundColor == .clear || !desktop)
            #expect(config.cornerStyle == .capsule)
            #expect(config.image != nil && config.contentInsets == .zero)
        }
        #expect(button.showsLargeContentViewer && button.largeContentTitle == "Close")
        let back = SheetCloseButton(.back, action: UIAction { _ in })
        #expect(back.accessibilityLabel == "Back")
    }
}
