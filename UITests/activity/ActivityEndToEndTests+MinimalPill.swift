import XCTest

extension ActivityEndToEndTests {
    @MainActor func test32_MinimalPillOverviewNeverAutoOpensDetails() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/control", ["profile": "default", "control": ["goal": Self.goal], "emit": false])
        let app = launch(account)
        openChat(app)
        try event(account, "subagent.start", ["goal": "Index the docs", "task_count": 1, "task_index": 0,
                                              "subagent_id": "sa_pill", "status": "running"])
        try event(account, "todo.updated", ["todos": [["id": "1", "content": "Read the docs", "status": "in_progress"],
                                                      ["id": "2", "content": "Draft notes", "status": "pending"]], "revision": 1])
        let summary = app.buttons["chat.shelf.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { summary.label.contains("Tasks 0/2") && summary.label.contains("1 helper") })
        XCTAssertEqual(summary.value as? String, "collapsed")
        XCTAssertEqual(summary.frame.height, 44, accuracy: 1)
        XCTAssertLessThan(summary.frame.width, app.frame.width)
        XCTAssertFalse(app.buttons["chat.shelf.tasks"].exists, "only the summary is exposed while collapsed")
        shot("minimal-activity-collapsed")

        let tasks = app.activityCategory("tasks")
        let overviewHeight = element(app, "chat.shelf").frame.height
        XCTAssertEqual(tasks.value as? String, "collapsed")
        XCTAssertTrue(app.buttons["chat.shelf.goal"].exists)
        XCTAssertTrue(app.buttons["chat.shelf.subagents"].exists)
        XCTAssertFalse(app.buttons["Goal Actions"].exists, "folded categories do not expose hidden action buttons")
        XCTAssertFalse(labelled(app, containing: "Draft notes, pending").exists)
        shot("minimal-activity-overview")
        try event(account, "todo.updated", ["todos": [["id": "1", "content": "Read the docs", "status": "completed"],
                                                      ["id": "2", "content": "Draft notes", "status": "pending"]], "revision": 2])
        XCTAssertTrue(waitUntil(timeout: 3) { tasks.label.contains("Tasks 1/2") })
        XCTAssertEqual(tasks.value as? String, "collapsed", "refreshing a plan never opens it")
        XCTAssertEqual(element(app, "chat.shelf").frame.height, overviewHeight, accuracy: 1)
        tasks.tap()
        XCTAssertTrue(labelled(app, containing: "Draft notes, pending").waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["chat.shelf.goal"].exists, "only one detail is on screen")
        XCTAssertLessThanOrEqual(tasks.frame.width, 300)
        shot("minimal-activity-task-detail")
        app.activityCategory("goal").tap()
        XCTAssertTrue(app.buttons["Goal Actions"].waitForExistence(timeout: 3))
        XCTAssertFalse(labelled(app, containing: "Draft notes, pending").exists)
        app.activityCategory("subagents").tap()
        XCTAssertTrue(labelled(app, containing: "Index the docs").waitForExistence(timeout: 3))
        app.buttons["chat.shelf.summary"].tap()
        app.buttons["chat.shelf.summary"].tap()
        XCTAssertEqual(summary.value as? String, "collapsed")
        try reset(account)
    }

    @MainActor func test34_FinishedOnlyHistoryDoesNotPinActivity() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        var goal = Self.goal
        goal["status"] = "done"
        goal["last_verdict"] = "done"
        try account.control("/__fixture/control", ["profile": "default", "control": ["goal": goal], "emit": false])
        try account.control("/__fixture/todo-state", ["profile": "default", "revision": 4, "todos": [
            ["id": "1", "content": "Read the notes", "status": "completed"]]])
        let app = launch(account)
        openChat(app)
        Thread.sleep(forTimeInterval: 6)
        XCTAssertFalse(app.buttons["chat.shelf.summary"].exists, "completed history is not pinned live work")
        shot("minimal-activity-finished-only")
        try reset(account)
    }

    @MainActor func test35_BlockedReasonAndActionsAppearOnFirstOpen() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        var goal = Self.goal
        goal["last_verdict"] = "blocked"
        goal["last_reason"] = "The publishing destination needs a decision"
        try account.control("/__fixture/control", ["profile": "default", "control": ["goal": goal], "emit": false])
        let app = launch(account)
        openChat(app)
        let summary = app.buttons["chat.shelf.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        summary.tap()
        XCTAssertTrue(labelled(app, containing: "The publishing destination needs a decision").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Goal Actions"].isHittable, "the blocking goal's actions are not behind another fold")
        shot("minimal-activity-blocked-first-open")
        try reset(account)
    }

    /// The step is the transcript's "<Bot> is …" line; the pill only counts categories (1043 showed it twice).
    @MainActor func test36_TheStepIsNotRepeatedInThePill() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/plan", ["plans": [["holdAfter": 40, "events": [
            ["type": "tool.start", "payload": ["tool_id": "call_pill_step", "name": "read_file", "args": ["path": "release-notes.md"]]],
            ["type": "todo.updated", "payload": ["todos": [["id": "1", "content": "Read the notes", "status": "pending"]], "revision": 1]]]]]])
        let app = launchAndSend(account, "Read the release notes")
        let summary = app.buttons["chat.shelf.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(timeout: 5) { summary.label.contains("Tasks 0/1") && summary.label.contains("running") },
                      "the parent's real run drives the spinner, not todo status")
        XCTAssertTrue(labelled(app, containing: "release-notes.md").waitForExistence(timeout: 5), "the transcript names the step")
        XCTAssertFalse(summary.label.contains("release-notes.md"), "collapsed, the pill doesn't repeat it: \(summary.label)")
        summary.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { summary.value as? String == "expanded" })
        XCTAssertFalse(summary.label.contains("release-notes.md"), "expanded, nor does its header: \(summary.label)")
        XCTAssertTrue(app.activityCategory("tasks").exists)
        shot("minimal-activity-current-step")
        app.buttons["composer.stop"].tap()
        try reset(account)
    }

    @MainActor func test37_ParentWithoutCategoriesHasNoPill() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/plan", ["plans": [["holdAfter": 40, "events": [
            ["type": "tool.start", "payload": ["tool_id": "call_pill_only", "name": "read_file", "args": ["path": "release-notes.md"]]]]]]])
        // At the Bottom, the default (the owner's report, 1043: "Inbox is using browser exec…" and the pill both named it).
        let app = launchAndSend(account, "Read just this file", args: ["-hq.chat.toolCallStyle", "bottom"])
        XCTAssertTrue(labelled(app, containing: "release-notes.md").waitForExistence(timeout: 8), "the transcript names the step")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(app.buttons["chat.shelf.summary"].exists, "no second copy of the step above the composer")
        let copies = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'release-notes.md'"))
            .allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
        // A row and its text can both carry the label; count places on screen, not elements.
        let places = Set(copies.map { "\(Int($0.frame.midY / 20))" })
        XCTAssertEqual(places.count, 1, "the step appears once: \(copies.map { "\($0.label) @\(Int($0.frame.midY))" })")
        shot("minimal-activity-step-only")
        app.buttons["composer.stop"].tap()
        try reset(account)
    }

    @MainActor func test38_HelperFailureStaysUntilItsResultIsRead() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let app = launch(account)
        openChat(app)
        try event(account, "subagent.start", ["goal": "Check the notes", "task_count": 1, "task_index": 0,
                                              "subagent_id": "sa_pill_failed", "status": "running"])
        try event(account, "subagent.complete", ["goal": "Check the notes", "task_count": 1, "task_index": 0,
                                                 "subagent_id": "sa_pill_failed", "status": "failed", "summary": "The notes could not be read"])
        let summary = app.buttons["chat.shelf.summary"]
        XCTAssertTrue(waitUntil(timeout: 5) { summary.exists && summary.label.contains("failed") })
        XCTAssertFalse(summary.label.contains("running"))
        try account.control("/__fixture/plan", ["plans": [["holdAfter": 0.1, "events": [
            ["type": "message.delta", "payload": ["text": "The next task is finished."]]]]]])
        send(app, "Do the next task", account)
        XCTAssertTrue(waitUntil(timeout: 5) { !app.buttons["composer.stop"].exists })
        XCTAssertTrue(summary.exists && summary.label.contains("failed"), "starting another turn does not acknowledge an unread failure")
        try account.control("/__fixture/subagents", ["subagents": []])
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openChat(app)
        XCTAssertTrue(waitUntil(timeout: 5) { summary.exists && summary.label.contains("failed") }, "unread results belong to the chat, not the screen instance")
        summary.tap()
        XCTAssertTrue(labelled(app, containing: "The notes could not be read").waitForExistence(timeout: 3))
        shot("minimal-activity-helper-failure")
        summary.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !summary.exists }, "read failure is retained in the conversation, not a pinned pill")
        try reset(account)
    }


    @MainActor func test40_FallbackHelperFailureRemainsActionable() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/plan", ["plans": [["holdAfter": 0.1, "events": [
            ["type": "tool.start", "payload": ["tool_id": "fallback_helper", "name": "delegate_task", "args": ["goal": "Check the notes"]]],
            ["type": "tool.complete", "payload": ["tool_id": "fallback_helper", "name": "delegate_task", "args": ["goal": "Check the notes"],
                                                    "result": ["results": [["task_index": 0, "status": "failed", "summary": "The fallback check failed"]]]]],
            ["type": "message.delta", "payload": ["text": "The check failed."]]]]]])
        let app = launchAndSend(account, "Check the notes with a helper")
        XCTAssertTrue(waitUntil(timeout: 5) { !app.buttons["composer.stop"].exists })
        let summary = app.buttons["chat.shelf.summary"]
        XCTAssertTrue(waitUntil(timeout: 5) { summary.exists && summary.label.contains("failed") })
        summary.tap()
        XCTAssertTrue(labelled(app, containing: "The fallback check failed").waitForExistence(timeout: 3))
        summary.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !summary.exists })
        try reset(account)
    }

    @MainActor func test41_ReadFailureDoesNotRepinAfterReopeningChat() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        let app = launch(account)
        openChat(app)
        try event(account, "subagent.start", ["goal": "Check the notes", "task_count": 1, "task_index": 0,
                                              "subagent_id": "sa_read_failure", "status": "running"])
        try event(account, "subagent.complete", ["goal": "Check the notes", "task_count": 1, "task_index": 0,
                                                 "subagent_id": "sa_read_failure", "status": "failed", "summary": "The check needs attention"])
        let summary = app.buttons["chat.shelf.summary"]
        XCTAssertTrue(waitUntil(timeout: 5) { summary.exists && summary.label.contains("failed") })
        summary.tap()
        XCTAssertTrue(labelled(app, containing: "The check needs attention").waitForExistence(timeout: 3))
        summary.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !summary.exists })
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openChat(app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(summary.exists, "reading the result survives a new screen and roster refresh")
        try reset(account)
    }
}
