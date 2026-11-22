// [goals] Goals step 1 (docs/goals.md; owner 2026-11-18: "an area for goals … things that I want to achieve over
// time"). The Goals pill heads the views row with its groups; a goal's page ticks a milestone's last task and offers the
// milestone (never ticks it), Update moves the ring, and a held card pauses a goal into Someday. New Goal reads "by"
// a date, the new goal's page takes a milestone and a task under it, and that task's page names its goal. An add-on
// without goals shows none of it. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_Goals,testTasks_NewGoal,
// testTasks_GoalsNeedTheAddOn); HQN_TASKS_LOOK=dark for the dark screens.

import XCTest

extension PagesTests {
    @MainActor func testTasks_Goals() throws {
        try account.control("/__fixture/tasks-mode", ["goals": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let name = Self.lookName
        let pill = app.buttons["tasks.view.goals"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 20), "Goals heads the views")
        let today = app.buttons["tasks.view.today"].firstMatch
        XCTAssertLessThan(pill.frame.minX, today.frame.minX, "the first pill")
        XCTAssertTrue((pill.label + " " + (pill.value as? String ?? "")).contains("3"), "its count is the active goals: \(pill.label)")
        pill.tap()

        // The groups: active cards, Someday with its count, Achieved folded.
        let testers = app.cells["goal-cell-1,000 public testers"].firstMatch
        XCTAssertTrue(testers.waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["goal-cell-Run a 10K"].exists && app.cells["goal-cell-Family trip to the coast"].exists)
        // VoiceOver: the card is one element (the cell is its container), its words and its next task in one label.
        let testersCard = app.descendants(matching: .any)["goal-card-1,000 public testers"].firstMatch
        XCTAssertTrue(testersCard.exists && testersCard.label.hasPrefix("1,000 public testers"), "a card is one element: \(testersCard.label)")
        XCTAssertEqual(testersCard.value as? String, "34 percent")
        XCTAssertTrue(testersCard.label.contains("next: Post the build notes to the forum"), testersCard.label)
        let someday = app.descendants(matching: .any)["tasks.section.Someday"].firstMatch
        for _ in 0..<4 where !someday.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(someday.waitForExistence(timeout: 5), "Someday holds the paused goal")
        XCTAssertTrue(app.cells["goal-cell-Learn conversational Spanish"].exists)
        let achievedFold = app.buttons["goals.fold.achieved"].firstMatch
        XCTAssertTrue(achievedFold.waitForExistence(timeout: 5), "Achieved, folded")
        XCTAssertFalse(app.cells["goal-cell-Read 12 books this year"].exists, "folded until shown")
        achievedFold.tap()
        XCTAssertTrue(app.cells["goal-cell-Read 12 books this year"].waitForExistence(timeout: 5))
        shot("goals-1-view-bottom" + name)
        for _ in 0..<4 where !testers.isHittable { app.swipeDown(velocity: .slow) }
        shot("goals-1-view" + name)

        // Open the goal: its number, date, milestones, and Launch week open with its tasks.
        testers.tap()
        let title = app.descendants(matching: .any)["goal.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the goal's page")
        XCTAssertEqual(title.value as? String, "34 percent")
        XCTAssertTrue(app.descendants(matching: .any)["goal.milestone.Launch week"].firstMatch.exists)
        let notes = app.descendants(matching: .any)["goal.task.Post the build notes to the forum"].firstMatch
        let reviews = app.descendants(matching: .any)["goal.task.Reply to the three beta reviews"].firstMatch
        let demo = app.descendants(matching: .any)["goal.task.Record the 60 second demo"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 5) && reviews.exists && demo.exists, "the open milestone's tasks")
        XCTAssertFalse(app.descendants(matching: .any)["goal.task.Write the launch email"].exists, "a done task stays off the page")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("goals-2-testers" + name)

        // Tick its tasks; the last one brings the offer, and the milestone stays open until you say.
        let patched = { (id: String) in
            self.requests().filter { $0.method == "PATCH" && $0.path.hasSuffix("/tasks/\(id)") && $0.body?["status"] != nil }
        }
        for row in [notes, reviews] {
            row.press(forDuration: 0.8)
            let done = app.buttons["Mark Done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 5), "Mark Done in the task's menu")
            done.tap()
            XCTAssertTrue(waitUntil(6) { !row.exists }, "a ticked task leaves the page")
        }
        // The last by its circle, as you would.
        demo.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 51, dy: demo.frame.height / 2)).tap()
        XCTAssertTrue(waitUntil(10) { !patched("t_g_demo").isEmpty }, "the circle ticks it")
        let offer = app.descendants(matching: .any)["goal.offer"].firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 8), "the milestone is offered")
        XCTAssertTrue(app.staticTexts["That was the last task in Launch week. Mark it done?"].firstMatch.exists)
        XCTAssertTrue(waitUntil(3) { self.requests().filter { $0.method == "PATCH" && $0.path.hasSuffix("/goals/g_testers") }.isEmpty },
                      "nothing is ticked by itself")
        shot("goals-3-offer" + name)
        let markDone = offer.buttons["Mark Done"].firstMatch.exists ? offer.buttons["Mark Done"].firstMatch : app.buttons["Mark Done"].firstMatch
        markDone.tap()
        XCTAssertTrue(waitUntil(10) {
            self.requests().contains { $0.method == "PATCH" && $0.path.hasSuffix("/goals/g_testers") && $0.body?["milestones"] != nil }
        }, "Mark Done saves the milestone")
        XCTAssertTrue(waitUntil(5) { !offer.exists }, "the offer goes")

        // Update the number: the ring's value follows.
        let update = app.buttons["goal.update"].firstMatch
        XCTAssertTrue(update.waitForExistence(timeout: 5))
        update.tap()
        let field = app.textFields["goal.update.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Update's one field")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        shot("goals-4-update" + name)
        field.typeOver("500")
        app.buttons["goal.update.save"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) {
            self.requests().contains { $0.method == "PATCH" && $0.path.hasSuffix("/goals/g_testers") && $0.body?["measure_now"] != nil }
        }, "Update saves the number")
        XCTAssertTrue(waitUntil(8) { title.value as? String == "50 percent" }, "the ring moved: \(title.value ?? "")")
        shot("goals-5-updated" + name)

        // Back on the list, hold the card › Pause: it waits under Someday.
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(testers.waitForExistence(timeout: 8))
        testers.press(forDuration: 0.9)
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "Pause in the card's menu")
        pause.tap()
        XCTAssertTrue(waitUntil(10) {
            self.requests().contains { $0.method == "PATCH" && $0.path.hasSuffix("/goals/g_testers") && $0.body?["status"] as? String == "paused" }
        }, "paused on the gateway")
        for _ in 0..<4 where !someday.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(someday.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(5) { testers.exists && testers.frame.minY > someday.frame.minY }, "under Someday now")
        XCTAssertTrue(testersCard.label.contains("Paused"), testersCard.label)
        shot("goals-6-paused" + name)
    }

    @MainActor func testTasks_NewGoal() throws {
        try account.control("/__fixture/tasks-mode", ["goals": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesTasksView", "goals"])
        let name = Self.lookName
        let newGoal = app.descendants(matching: .any)["goals.new"].firstMatch
        XCTAssertTrue(newGoal.waitForExistence(timeout: 20), "New Goal under the cards")
        newGoal.tap()

        // Quick add: the line's "by" date is read off it.
        let line = app.textViews["goals.new.title"].firstMatch.exists ? app.textViews["goals.new.title"].firstMatch : app.textFields["goals.new.title"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 8), "New Goal's line")
        line.typeText("Run a half marathon by may 3")
        let due = app.descendants(matching: .any)["goals.new.due"].firstMatch
        XCTAssertTrue(waitUntil(5) { due.label.contains("By May 3") }, "the date is read from the words: \(due.label)")
        XCTAssertTrue(app.descendants(matching: .any)["goals.new.read"].firstMatch.waitForExistence(timeout: 3), "the name it will take")
        shot("goals-7-new" + name)
        app.buttons["goals.new.add"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) {
            self.requests().contains { $0.method == "POST" && $0.path.hasSuffix("/goals") && $0.body?["title"] as? String == "Run a half marathon" }
        }, "the goal is added without its date words")
        let added = requests().last { $0.method == "POST" && $0.path.hasSuffix("/goals") }
        XCTAssertTrue((added?.body?["due"] as? String)?.hasSuffix("-05-03") == true, "by May 3: \(String(describing: added?.body?["due"]))")

        // Its page opens: add a milestone, then a task under it.
        let title = app.descendants(matching: .any)["goal.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the new goal's page")
        XCTAssertEqual(title.label, "Run a half marathon")
        XCTAssertEqual(title.value as? String, "No plan yet")
        shot("goals-8-new-page" + name)
        let firstMilestone = app.buttons["goal.milestones.first"].firstMatch
        (firstMilestone.exists ? firstMilestone : app.buttons["goal.milestones.add"].firstMatch).tap()
        let milestoneField = app.textFields["goal.milestones.field"].firstMatch
        XCTAssertTrue(milestoneField.waitForExistence(timeout: 5))
        milestoneField.typeText("Run 10 miles\n")
        XCTAssertTrue(waitUntil(10) {
            self.requests().contains { $0.method == "PATCH" && $0.path.contains("/goals/") && $0.body?["milestones"] != nil }
        }, "the milestone is saved")
        let milestone = app.descendants(matching: .any)["goal.milestone.Run 10 miles"].firstMatch
        XCTAssertTrue(milestone.waitForExistence(timeout: 8))
        if app.textFields["goal.milestones.field"].exists { app.buttons["goal.edit-done"].firstMatch.tap() }
        let addTask = app.buttons["goal.add-task"].firstMatch   // the open milestone's comes first
        if !addTask.waitForExistence(timeout: 3) { milestone.tap() }
        XCTAssertTrue(addTask.waitForExistence(timeout: 5), "Add a task under the milestone")
        addTask.tap()
        let taskField = app.textFields["goal.add-task.field"].firstMatch
        XCTAssertTrue(taskField.waitForExistence(timeout: 5))
        taskField.typeText("Buy real running shoes\n")
        XCTAssertTrue(waitUntil(10) {
            self.requests().contains { $0.method == "POST" && $0.path.hasSuffix("/tasks") && $0.body?["title"] as? String == "Buy real running shoes"
                && $0.body?["goal"] != nil && $0.body?["milestone"] != nil }
        }, "the task starts in the goal, under the milestone")
        if app.buttons["goal.edit-done"].exists { app.buttons["goal.edit-done"].firstMatch.tap() }
        let row = app.descendants(matching: .any)["goal.task.Buy real running shoes"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(5) { title.value as? String == "0 percent" }, "a milestone now drives the ring: \(title.value ?? "")")
        shot("goals-9-milestone-task" + name)

        // Its page names the goal and the milestone.
        row.tap()
        let goalRow = app.descendants(matching: .any)["task.goal"].firstMatch
        XCTAssertTrue(goalRow.waitForExistence(timeout: 10), "the task's goal row")
        XCTAssertTrue(goalRow.label.contains("Run a half marathon") && goalRow.label.contains("Run 10 miles"), goalRow.label)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        shot("goals-10-task-goal-row" + name)
    }

    @MainActor func testTasks_GoalsNeedTheAddOn() throws {
        try account.control("/__fixture/tasks-mode", ["goals": true, "older_addon": true])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesTasksView", "goals"])
        let today = app.buttons["tasks.view.today"].firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(5) { today.isSelected }, "asked for Goals, an older add-on opens on Today")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(app.buttons["tasks.view.goals"].exists, "no Goals pill")
        let row = app.cells["task-row-Pick up dry cleaning"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Move To")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Add to Goal")).firstMatch.exists, "no Add to Goal")
        shot("goals-11-older-addon" + Self.lookName)
        XCTAssertTrue(requests().allSatisfy { !$0.path.contains("/goals") }, "nothing asks for goals")
    }
}

private extension XCUIElement {
    /// Deletes what the field holds (the caret lands at its end on focus), then types.
    func typeOver(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
