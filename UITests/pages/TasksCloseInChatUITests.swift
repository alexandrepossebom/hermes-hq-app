// [chat-mark-done] A bot's offer to close your task, as a card in the chat (owner 2026-11-22: "When a bot knows that you
// are done with a task it needs to be able to give you an easy way to mark it as done."). The fixture's three chats come
// with `/__fixture/tasks-mode {"close": true}` (seed_task_close): Mark Done and its Undo, Keep Open, the title opening
// the task, and the card for a task the bot marked done because you said so. Run with scripts/e2e-pages.sh
// (HQN_PAGES_ONLY=testTasks_CloseInChat…); every look: TEST_RUNNER_HQN_TASKS_LOOK=dark | desktop | desktop-dark.

import XCTest

extension PagesTests {
    /// The fixture with its close offers, and the app opened on that chat. The run's first launch signs in first.
    @MainActor private func launchInCloseChat(_ session: String) throws -> XCUIApplication {
        if !Self.freshThisRun { launchSignedIn(Self.look).terminate() }
        try account.control("/__fixture/tasks-mode", ["close": true])
        let app = launchSignedIn(Self.look)
        tabButton("Sessions", in: app).tap()
        let row = app.cells["session-row-\(session)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the chat is listed")
        row.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 15), "the chat opens")
        return app
    }

    private func patched(_ task: String, _ key: String, _ value: Any) -> Bool {
        requests().contains { request in
            guard request.method == "PATCH", request.path.hasSuffix("/tasks/\(task)") else { return false }
            switch value {
            case let text as String: return request.body?[key] as? String == text
            case let flag as Bool: return request.body?[key] as? Bool == flag
            default: return false
            }
        }
    }

    /// Mark Done on the card: the task's done PATCH, the card says so, and Undo opens it again.
    @MainActor func testTasks_CloseInChatMarkDone() throws {
        app = try launchInCloseChat("s-close-done")
        let name = Self.lookName
        let any = app.descendants(matching: .any)
        let done = app.buttons["chat.task-close.t_c_tickets.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 20), "the bot's offer is a card under its reply")
        XCTAssertEqual(done.label, "Mark Done")
        XCTAssertEqual(app.buttons["chat.task-close.t_c_tickets.keep"].firstMatch.label, "Keep Open")
        let body = any["chat.task-close.t_c_tickets"].firstMatch
        XCTAssertTrue(body.label.contains("Hermes: looks done · You booked them this morning"), body.label)
        XCTAssertTrue(body.label.contains("Book the train tickets"), body.label)
        XCTAssertFalse(patched("t_c_tickets", "status", "done"), "nothing changes before a tap")
        let before = body.frame.height
        shot("tasks-close-1-offer" + name)

        done.tap()
        XCTAssertTrue(waitUntil(10) { self.patched("t_c_tickets", "status", "done") }, "the task's done PATCH")
        let status = any["chat.task-close.t_c_tickets.status"].firstMatch
        XCTAssertTrue(waitUntil(10) { status.exists && status.label == "Marked Done" }, "the card says so")
        XCTAssertTrue(waitUntil(5) { !done.exists }, "the buttons are gone")
        XCTAssertEqual(body.frame.height, before, accuracy: 1, "the card keeps its height")
        let undo = app.buttons["chat.task-close.t_c_tickets.undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "with Undo")
        shot("tasks-close-2-done" + name)

        undo.tap()
        XCTAssertTrue(waitUntil(10) { self.patched("t_c_tickets", "status", "open") }, "Undo opens it again")
        XCTAssertTrue(waitUntil(10) { status.label == "Back on the list" }, status.label)
        XCTAssertFalse(undo.exists, "nothing more to tap")
        shot("tasks-close-3-undone" + name)
    }

    /// Keep Open on the card: `keep_open` is sent, and the card reads Kept Open.
    @MainActor func testTasks_CloseInChatKeepOpen() throws {
        app = try launchInCloseChat("s-close-keep")
        let name = Self.lookName
        let keep = app.buttons["chat.task-close.t_c_plants.keep"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 20), "the offer made through the tool_call bridge is a card too")
        shot("tasks-close-4-offer-bridged" + name)
        keep.tap()
        XCTAssertTrue(waitUntil(10) { self.patched("t_c_plants", "keep_open", true) }, "Keep Open is sent")
        let status = app.descendants(matching: .any)["chat.task-close.t_c_plants.status"].firstMatch
        XCTAssertTrue(waitUntil(10) { status.exists && status.label == "Kept Open" }, "the card says so")
        XCTAssertFalse(app.buttons["chat.task-close.t_c_plants.done"].exists)
        XCTAssertFalse(patched("t_c_plants", "status", "done"), "the task stays open")
        shot("tasks-close-5-kept" + name)
    }

    /// The card's title opens the task, as a row of the "Added to Tasks" card does.
    @MainActor func testTasks_CloseInChatOpensTask() throws {
        app = try launchInCloseChat("s-close-done")
        let body = app.descendants(matching: .any)["chat.task-close.t_c_tickets"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 20))
        body.tap()
        XCTAssertTrue(app.buttons["task.close-offer.done"].firstMatch.waitForExistence(timeout: 15),
                      "the task opens, with the page's own offer card")
        shot("tasks-close-6-task" + Self.lookName)
    }

    /// The bot marked your task done because you told it to: the card already answered, with Undo.
    @MainActor func testTasks_CloseInChatAsked() throws {
        app = try launchInCloseChat("s-close-asked")
        let name = Self.lookName
        let status = app.descendants(matching: .any)["chat.task-close.t_c_cake.status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20), "a card under the reply")
        XCTAssertTrue(waitUntil(5) { status.label == "Marked Done" }, status.label)
        XCTAssertFalse(app.buttons["chat.task-close.t_c_cake.done"].exists, "no Mark Done: it is done")
        XCTAssertFalse(app.buttons["chat.task-close.t_c_cake.keep"].exists)
        let undo = app.buttons["chat.task-close.t_c_cake.undo"].firstMatch
        XCTAssertTrue(undo.exists)
        shot("tasks-close-7-asked" + name)
        undo.tap()
        XCTAssertTrue(waitUntil(10) { self.patched("t_c_cake", "status", "open") }, "Undo opens it again")
        XCTAssertTrue(waitUntil(10) { status.label == "Back on the list" }, status.label)
        XCTAssertFalse(undo.exists)
        shot("tasks-close-8-asked-undone" + name)
    }
}
