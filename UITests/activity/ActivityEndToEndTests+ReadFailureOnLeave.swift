import XCTest

extension ActivityEndToEndTests {
    /// Leaving the chat also leaves the result: reading must not require an extra fold first.
    @MainActor func test42_ReadingFailureThenLeavingChatAcknowledgesResult() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let app = launch(account)
        openChat(app)
        try event(account, "subagent.start", ["goal": "Check the notes", "task_count": 1, "task_index": 0,
                                              "subagent_id": "sa_read_then_leave", "status": "running"])
        try event(account, "subagent.complete", ["goal": "Check the notes", "task_count": 1, "task_index": 0,
                                                 "subagent_id": "sa_read_then_leave", "status": "failed",
                                                 "summary": "The notes need another check"])
        let summary = app.buttons["chat.shelf.summary"]
        XCTAssertTrue(waitUntil(timeout: 5) { summary.exists && summary.label.contains("failed") })
        summary.tap()
        let result = labelled(app, containing: "The notes need another check")
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        XCTAssertTrue(result.isHittable, "the failed result was actually on screen")
        // Deliberately do not fold the detail before leaving.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openChat(app)
        shot("minimal-activity-read-then-reopened")
        XCTAssertFalse(summary.waitForExistence(timeout: 3), "a viewed result must not re-pin after leaving the chat")
        try reset(account)
    }

    @MainActor func test43_LeavingAnotherHelperDoesNotReadAnUnseenFailure() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let app = launch(account)
        openChat(app)
        let goals = ["Read the notes", "Check the links", "Review the changes"]
        for (index, goal) in goals.enumerated() {
            try event(account, "subagent.start", ["goal": goal, "task_count": 3, "task_index": index,
                                                  "subagent_id": "sa_leave_\(index)", "status": "running"])
        }
        for index in [0, 1] {
            try event(account, "subagent.complete", ["goal": goals[index], "task_count": 3, "task_index": index,
                                                     "subagent_id": "sa_leave_\(index)", "status": "failed",
                                                     "summary": index == 0 ? "The notes were unavailable" : "The links need another check"])
        }
        let summary = app.buttons["chat.shelf.summary"]
        XCTAssertTrue(waitUntil(timeout: 5) { summary.exists && summary.label.contains("2 helpers failed") })
        // Leaving the collapsed pill must not mark either result read.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openChat(app)
        XCTAssertTrue(waitUntil(timeout: 5) { summary.exists && summary.label.contains("2 helpers failed") })
        summary.tap()
        XCTAssertTrue(labelled(app, containing: "The notes were unavailable").waitForExistence(timeout: 3))
        element(app, "chat.subagent.back").tap()
        labelled(app, containing: goals[2]).tap()
        XCTAssertTrue(element(app, "chat.subagent.steer-field").waitForExistence(timeout: 3))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openChat(app)
        XCTAssertTrue(waitUntil(timeout: 5) { summary.exists && summary.label.contains("1 helper failed") },
                      "leaving another helper must not acknowledge the unseen failed result")
        summary.tap()
        XCTAssertTrue(labelled(app, containing: "The links need another check").waitForExistence(timeout: 3))
        shot("minimal-activity-unseen-failure-after-leaving-another-helper")
        try reset(account)
    }
}
