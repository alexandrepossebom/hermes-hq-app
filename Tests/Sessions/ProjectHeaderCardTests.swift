// [project-header-card] Owner 2026-11-16: a project's page header stands on a card that "has to work for every theme
// properly and in every scenario". The card is `ProjectCard.fill` (the theme's `groupedCard`) on the list's page
// (`page`): every skin, light and dark, both looks, with and without High Contrast, must part the two clearly enough to
// read as a card. [project-card-colour] 2026-11-17: an opened project's card is the same colour (`ProjectCard.fill`).

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite struct ProjectHeaderCardTests {
    /// WCAG relative luminance.
    private static func luminance(_ c: RGBA) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    static func ratio(_ a: RGBA, _ b: RGBA) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Every look a phone can draw Sessions in, with the page and the card it would get.
    static func cases() -> [(name: String, page: RGBA, card: RGBA, ink: RGBA)] {
        var out: [(String, RGBA, RGBA, RGBA)] = []
        for skin in SkinCatalog.all {
            for desktop in [false, true] {
                for high in [false, true] where desktop || !high {
                    let set = ThemeResolver.resolve(ThemeState(skinID: skin.id, desktopLook: desktop, highContrast: high, uiScalePercent: 100))
                    for dark in [false, true] {
                        let t = set.tokens(dark: dark)
                        out.append(("\(skin.id) \(desktop ? "desktop" : "ios") \(dark ? "dark" : "light")\(high ? " high" : "")", t.page, t.groupedCard, t.label))
                    }
                }
            }
        }
        return out
    }

    @Test func theCardStandsApartFromThePageInEveryLook() {
        let all = Self.cases()
        #expect(all.count >= 14 * 2 * 3)
        var stepped: [String] = []
        for look in all {
            let drawn = ProjectPageHeader.cardColour(page: look.page, card: look.card, ink: look.ink)
            let ratio = ProjectPageHeader.ratio(look.page.over(.white), drawn)
            #expect(ratio >= ProjectPageHeader.cardLeast, "\(look.name): the card stands \(ratio) from its page")
            // The name (bold Title 3: large text, 3 to 1 in WCAG) reads on the card, and nearly as well as on the page.
            // (Solarized's own dark card takes it from 4.7 to 4.2, the theme's choice for every card.)
            let onPage = ProjectPageHeader.ratio(look.page.over(.white), look.ink.over(look.page.over(.white)))
            let onCard = ProjectPageHeader.ratio(drawn, look.ink.over(drawn))
            #expect(onCard >= 3 && onCard >= min(4.5, onPage * 0.85), "\(look.name): the name reads \(onCard) on the card, \(onPage) on the page")
            if drawn != look.card.over(look.page.over(.white)) { stepped.append(look.name) }
            // A card that already stood apart is the theme's own, untouched.
            if Self.ratio(look.page.over(.white), look.card.over(look.page.over(.white))) >= ProjectPageHeader.cardLeast {
                #expect(drawn == look.card.over(look.page.over(.white)), "\(look.name): its own card")
            }
        }
        print("HEADER-CARD stepped \(stepped.count) of \(all.count): \(stepped)")
    }

    /// The step keeps the theme's hue: on a light page it darkens, on a dark one it lightens.
    @Test func theStepGoesTowardTheInk() {
        let light = ProjectPageHeader.cardColour(page: .white, card: .white, ink: .black)
        #expect(light.r < 1 && ProjectPageHeader.ratio(.white, light) >= ProjectPageHeader.cardLeast)
        let dark = ProjectPageHeader.cardColour(page: .black, card: .black, ink: .white)
        #expect(dark.r > 0 && ProjectPageHeader.ratio(.black, dark) >= ProjectPageHeader.cardLeast)
    }

    /// [project-card-colour] The colours as drawn: the project cards' fill, resolved in every skin, light and dark, both
    /// looks, stands apart from the page it is drawn on (Soft Cards off: on Soft Cards the card is the soft card's).
    @Test func theProjectCardsResolveApartFromThePageInEveryLook() {
        #expect(!ProjectCard.soft, "no app picture in the unit tests")
        var drawn = 0
        for skin in SkinCatalog.all {
            for desktop in [false, true] {
                let state = ThemeState(skinID: skin.id, desktopLook: desktop, highContrast: false, uiScalePercent: 100)
                ThemeTable.$testSet.withValue(ThemeResolver.resolve(state)) {
                    for style in [UIUserInterfaceStyle.light, .dark] {
                        let traits = UITraitCollection(userInterfaceStyle: style)
                        let page = HQPalette.page.resolvedColor(with: traits), card = ProjectCard.fill.resolvedColor(with: traits)
                        let ratio = ProjectPageHeader.ratio(Self.rgba(page), Self.rgba(card))
                        #expect(ratio >= ProjectPageHeader.cardLeast - 0.005, "\(skin.id) \(desktop ? "desktop" : "ios") \(style == .dark ? "dark" : "light"): \(ratio)")
                        drawn += 1
                    }
                }
            }
        }
        #expect(drawn == SkinCatalog.all.count * 4)
    }

    private static func rgba(_ colour: UIColor) -> RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(unit: Double(r), Double(g), Double(b), Double(a)).over(.white)
    }
}
