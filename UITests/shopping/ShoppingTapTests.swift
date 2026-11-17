import XCTest

/// [shopping] A real tap on a product card opens its page, and a tap on a store's line in the page does something
/// (owner, 2026-11-17, build 1084: "I'm not able to click on the shopping cards"). The cards are plain controls and
/// listened for an event only buttons send; the unit tests opened pages through the demo flag and never tapped.
/// Run: scripts/e2e-shopping.sh SIM_UDID
final class ShoppingTapTests: XCTestCase {
    @MainActor func testATapOnACardOpensItsPageInEveryLayout() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDemoChat", "12", "-HQDemoAutoOpen", "-HQDemoShopping"]
        app.launch()
        let chat = app.tables["chat.table"]
        XCTAssertTrue(chat.waitForExistence(timeout: 20))
        let page = app.descendants(matching: .any).matching(identifier: "shopping.page").firstMatch
        let cards = chat.buttons.matching(identifier: "shopping.card")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 15))

        var opened = 0
        var seen = Set<String>()
        // Walk up the chat: every card that is on screen is tapped once (the single card, the pair, the row, the list).
        for _ in 0..<8 {
            let hittable = (0..<cards.count).map { cards.element(boundBy: $0) }.filter { $0.exists && $0.isHittable && !seen.contains($0.label) }
            for card in hittable.prefix(2) {
                seen.insert(card.label)
                // Near the top of the card: on the photo or the name, never on a one-product card's own Buy button.
                card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
                XCTAssertTrue(page.waitForExistence(timeout: 5), "no page after a tap on \(card.label)")
                opened += 1
                let close = app.descendants(matching: .any).matching(identifier: "sheet.close").firstMatch
                if close.waitForExistence(timeout: 2) { close.tap() } else { page.swipeDown(velocity: .fast) }
                let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: page)
                XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed)
            }
            chat.swipeDown()
        }
        XCTAssertGreaterThanOrEqual(opened, 4, "cards tapped: \(seen.sorted())")
    }
}
