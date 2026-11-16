import XCTest

extension TranscriptEndToEndTests {
    @MainActor func testT41_TaskSnapshotIsNotAUserMessage() throws {
        let account = try FixtureAccount.load()
        try preset(account, "task-snapshot")
        try account.control("/__fixture/todo-state", ["profile": "default", "revision": 1, "todos": [
            ["id": "update-layout", "content": "Simplify the activity display", "status": "in_progress"],
            ["id": "verify-layout", "content": "Run the native checks", "status": "pending"],
        ]])
        defer { _ = try? account.control("/__fixture/todo-state", ["profile": "default", "revision": 2, "todos": [Any]()]) }
        let app = launch(account)
        XCTAssertTrue(labelled(app, containing: "The layout is ready for review.").waitForExistence(timeout: 10))
        try account.control("/__fixture/event", ["profile": "default", "type": "todo.updated", "payload": ["revision": 2, "todos": [
            ["id": "update-layout", "content": "Simplify the activity display", "status": "in_progress"],
            ["id": "verify-layout", "content": "Run the native checks", "status": "pending"],
        ]]])
        let tasks = app.descendants(matching: .any)["chat.shelf.tasks"]
        let tasksExist = tasks.waitForExistence(timeout: 5)
        shot("task-snapshot-history")
        XCTAssertTrue(tasksExist, "the actual task list is still available")
        XCTAssertTrue(tasks.label.hasPrefix("Tasks 0/2"))
        XCTAssertFalse(labelled(app, containing: "preserved across context compression").exists)
        XCTAssertFalse(labelled(app, containing: "update-layout.").exists, "internal ids never become your words")
        XCTAssertTrue(labelled(app, containing: "I am checking the layout.").exists)

        // Old on-device cached rows go through the same display pass when the chat is reopened.
        app.terminate()
        app.launch()
        XCTAssertTrue(labelled(app, containing: "The layout is ready for review.").waitForExistence(timeout: 15))
        XCTAssertFalse(labelled(app, containing: "preserved across context compression").exists)
        shot("task-snapshot-reopened")
    }

    @MainActor func testT42_ToolDiscoveryProgressUsesPlainWords() throws {
        let account = try FixtureAccount.load()
        try preset(account, "task-snapshot")
        try account.control("/__fixture/todo-state", ["profile": "default", "revision": 0, "todos": [Any]()])
        let app = launch(account)
        try account.control("/__fixture/plan", ["plans": [["events": [
            ["type": "tool.start", "payload": ["tool_id": "instructions", "name": "tool_describe", "args": ["names": ["process_manage"]]]],
            ["after": 12, "type": "tool.complete", "payload": ["tool_id": "instructions", "name": "tool_describe", "result": ["ok": true]]],
            ["type": "message.delta", "payload": ["text": "Finished checking."]],
        ]]]])
        typeAndSend(app, "Continue checking.")
        XCTAssertTrue(labelled(app, containing: "is checking tool instructions").waitForExistence(timeout: 8))
        XCTAssertFalse(labelled(app, containing: "is using tool describe").exists)
        shot("tool-instructions-progress")
        XCTAssertTrue(labelled(app, containing: "Finished checking.").waitForExistence(timeout: 20))
    }
}
