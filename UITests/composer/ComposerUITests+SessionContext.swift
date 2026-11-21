// [session-context] The model panel's context card: what the chat holds of its window, a bar of how full it is, and a
// line only when it's almost full. The sample cases fill the window to 18%
// (-HQDebugModelPanelSample), 78% and 96% (-HQDebugModelPanelCase context-warm, context-full).

import XCTest

extension ComposerUITests {
    @MainActor func test33_TheContextCardSaysHowFullTheChatIs() throws {
        let cases: [(arguments: [String], shot: String, value: String)] = [
            (["-HQDebugModelPanelSample", "YES"], "context-tile-room", "184K of 1M tokens, 18% used"),
            (["-HQDebugModelPanelCase", "context-warm"], "context-tile-warm", "780K of 1M tokens, 78% used"),
            (["-HQDebugModelPanelCase", "context-full"], "context-tile-full", "Almost full"),
        ]
        for item in cases {
            let (_, app) = try start(arguments: item.arguments)
            _ = IPad.focusField(app)
            let bubble = app.buttons["composer.model"]
            XCTAssertTrue(bubble.waitForExistence(timeout: 10), "the model bubble shows")
            bubble.tap()
            let tile = app.descendants(matching: .any)["model.panel.context"]
            XCTAssertTrue(tile.waitForExistence(timeout: 8) && tile.isHittable, "the context card shows (\(item.shot))")
            let value = tile.value as? String ?? ""
            XCTAssertTrue(value.contains(item.value), "\(item.shot) reads \(value)")
            XCTAssertFalse(app.descendants(matching: .any)["model.panel.fact.context-window"].exists, "no window tile beside it")
            XCTAssertTrue(app.descendants(matching: .any)["model.panel.fact.price"].exists, "Price stays a tile")
            IPad.shot(app, item.shot, in: self)
            app.terminate()
        }
    }
}
