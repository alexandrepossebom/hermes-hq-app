import XCTest

/// [updates] A group's line ("With Home · 3 messages") opens its sheet on a tap: the run's members, each on a card of
/// its own, and the chat behind it stays as it was (UpdatesSheet.swift). Until 2026-11-17 the members opened as rows
/// of a card in the chat itself, and this test tapped one of those rows (owner, 2026-10-29: "I can't click on the
/// 'from Otto' messages. When I do. Nothing happens.").
final class UpdateMemberTapTests: XCTestCase {
    @MainActor func testTapOpensTheLinesSheetAndClosingLeavesTheChat() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HQDemoChat", "1", "-HQDemoAutoOpen", "-HQDemoBotExchange"]
        app.launch()

        // The line is a button that says how many updates it holds and which ("3 updates: To Home, Hermes, From Home").
        let chat = app.tables["chat.table"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        let lines = chat.buttons.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ updates: .+"))
        XCTAssertTrue(lines.firstMatch.waitForExistence(timeout: 15))
        let line = try XCTUnwrap((0..<lines.count).lazy.map { lines.element(boundBy: $0) }.first { $0.isHittable })
        let label = line.label
        // It opens a sheet: it is not a row that folds open in place.
        let value = line.value as? String ?? ""
        XCTAssertFalse(["Expanded", "Collapsed"].contains(value), "the line says \(value)")
        let frame = line.frame

        line.tap()
        let list = app.descendants(matching: .any).matching(identifier: "updates.list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        // A card per member. The card's own identifier ("updates.member", set on a plain container view in
        // UpdateCardCell.configure) does not reach the accessibility tree, so the cards are counted as the list's
        // cells, each with its title; a message's card has its words ("updates.words").
        let members = list.cells
        XCTAssertTrue(members.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(members.count, 2)
        XCTAssertTrue(members.firstMatch.staticTexts.firstMatch.exists)
        XCTAssertGreaterThanOrEqual(list.staticTexts.matching(identifier: "updates.words").count, 2)
        // No member opened as a row of the chat.
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "chat.update.member").count, 0)

        let close = app.descendants(matching: .any).matching(identifier: "sheet.close").firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(waitForGone(list))
        // The chat is as it was: the same line, where it was.
        XCTAssertTrue(chat.exists)
        let same = chat.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(same.waitForExistence(timeout: 5))
        XCTAssertTrue(same.isHittable)
        XCTAssertEqual(same.frame.minY, frame.minY, accuracy: 1)
        XCTAssertEqual(same.frame.height, frame.height, accuracy: 1)
    }

    private func waitForGone(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: 5) == .completed
    }
}
