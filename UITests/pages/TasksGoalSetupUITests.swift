// [goals set-up] A plan that sets up its goal (docs/goals.md "Set-up"): a waiting plan says "Plan to look at" on Today's
// shelf; its card shows "Built on" and the four rows it also sets (Name, Why, Number, By), as does the whole-offer
// sheet; Use This Plan renames the goal and sets its why, number and date, and tells the lead once in a hidden turn
// (the lead's reply writes where it stands); Undo puts all four back; a plan with neither looks as before.
//
// Against the stand-in in goal-bots mode: a plain goal led by Hermes, named as a sentence, with no why, number or
// date, and a plan offered on it through /__fixture/goal-offer. Every name is invented.
// Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_GoalPlanSetUp); TEST_RUNNER_HQN_TASKS_LOOK=dark for the dark screens.

import XCTest

extension PagesTests {
    private static let setupGoal = "I want to post a drawing every day so I get better"

    /// The plan-taken turns sent for a goal.
    @MainActor func planTakenTurns(_ title: String) -> [String] {
        promptTexts().filter { $0.hasPrefix("I took your plan for") && $0.contains("“\(title)”") }
    }

    @MainActor func testTasks_GoalPlanSetUp() throws {
        try goalMode(["goal_bots": true, "plain_goals": [["title": Self.setupGoal, "lead": "default"]]])
        try account.control("/__fixture/goal-offer", [
            "bot": "default", "session_id": "", "kind": "plan",
            "args": ["goal": Self.setupGoal, "name": "Draw every day", "why": "To get my hand back after years off.",
                     "due": "2027-03-31", "measure": ["unit": "drawings", "start": 0, "target": 100],
                     "built_on": ["Your notes from the sketching course, 8 units", "Twenty minutes a day after work"],
                     "milestones": [["title": "A week of drawings"], ["title": "Thirty in a row"], ["title": "Fifty posted"],
                                    ["title": "A hundred posted"]],
                     "tasks": [["title": "Pick one sketchbook for the month", "who": "me"],
                               ["title": "Find five short daily prompts", "who": "bot", "bot": "default"]]] as [String: Any],
        ])
        let name = Self.lookName

        // Today's shelf: the goal's next step is the plan to look at.
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let shelf = app.buttons["goal-shelf-\(Self.setupGoal)"].firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 20), "the goal on Today's shelf")
        XCTAssertTrue(shelf.label.contains("plan to look at"), shelf.label)
        shot("goals5-0-shelf-plan-waits" + name)

        // The goal's page: the plan's card with Built on and the four rows.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQDebugHapticsProbe", "YES", "-HQPagesTab", "4", "-HQPagesMore", "tasks",
                                          "-HQPagesOpenGoal", Self.setupGoal])
        let card = app.descendants(matching: .any)["goal.offer-card.plan"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the waiting plan on the goal's page")
        let builtOn = app.descendants(matching: .any)["goal.offer-card.built-on"].firstMatch
        XCTAssertTrue(builtOn.exists, "Built on")
        XCTAssertTrue(builtOn.label.contains("Your notes from the sketching course"), builtOn.label)
        let rows = ["name": "Name: Draw every day", "why": "Why: To get my hand back after years off.",
                    "measure": "Number: 0 of 100 drawings", "due": "By: Wed, Mar 31, 2027"]
        for (key, label) in rows {
            let row = app.descendants(matching: .any)["goal.offer-card.setup.\(key)"].firstMatch
            XCTAssertTrue(row.exists, "the \(key) row")
            XCTAssertEqual(row.label, label)
        }
        // VoiceOver reads them in order: Built on, then Name, Why, Number, By, above the milestones.
        let order = ["goal.offer-card.built-on", "goal.offer-card.setup.name", "goal.offer-card.setup.why",
                     "goal.offer-card.setup.measure", "goal.offer-card.setup.due"].map { app.descendants(matching: .any)[$0].firstMatch.frame.minY }
        XCTAssertEqual(order, order.sorted(), "top to bottom in reading order")
        XCTAssertLessThan(order.last ?? 0, card.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "A week of drawings")).firstMatch.frame.minY,
                          "the set-up rows sit above the milestones")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let before = card.frame.height
        shot("goals5-1-plan-card-waiting" + name)

        // The whole offer: the same sections first.
        let more = app.buttons["goal.offer-card.more"].firstMatch
        XCTAssertTrue(more.exists, "4 milestones, 3 shown: more ›")
        more.tap()
        let all = app.descendants(matching: .any)["goal.offer-all.setup.name"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 8), "the whole offer shows the set-up rows")
        XCTAssertTrue(app.descendants(matching: .any)["goal.offer-all.built-on"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["goal.offer-all.setup.due"].firstMatch.exists)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        shot("goals5-2-whole-offer" + name)
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitUntil(8) { !all.exists }, "the whole offer closes")

        // Use This Plan: renamed, why, number and date, in the one answer; the lead is told once.
        let cues = goalCues()
        app.buttons["goal.offer-card.Use This Plan"].firstMatch.tap()
        XCTAssertGreaterThan(goalCues(), cues, "the tap is felt")
        let title = app.descendants(matching: .any)["goal.title"].firstMatch
        XCTAssertTrue(waitUntil(10) { title.label == "Draw every day" }, "renamed: \(title.label)")
        XCTAssertTrue(waitUntil(5) { self.app.descendants(matching: .any)["goal.why"].firstMatch.label == "Why: To get my hand back after years off." })
        XCTAssertTrue(app.descendants(matching: .any)["goal.number"].firstMatch.label.contains("0 of 100"),
                      app.descendants(matching: .any)["goal.number"].firstMatch.label)
        XCTAssertTrue(app.descendants(matching: .any)["goal.date"].firstMatch.label.contains("Mar 31"),
                      app.descendants(matching: .any)["goal.date"].firstMatch.label)
        XCTAssertTrue(waitUntil(15) { self.planTakenTurns("Draw every day").count == 1 }, "the lead is told: \(promptTexts())")
        let turn = planTakenTurns("Draw every day").first ?? ""
        XCTAssertTrue(turn.contains("4 milestones and 2 tasks are on it now"), turn)
        XCTAssertTrue(turn.contains("goals_update with stands"), turn)
        let submit = ((try? account.control("/__fixture/state"))?["rpc"] as? [[String: Any]] ?? []).last {
            ($0["method"] as? String) == "prompt.submit" && (($0["params"] as? [String: Any])?["text"] as? String)?.hasPrefix("I took your plan for") == true }
        XCTAssertEqual((submit?["params"] as? [String: Any])?["display_kind"] as? String, "hidden", "a hidden turn")
        XCTAssertTrue(app.buttons["goal.offer-card.undo"].firstMatch.waitForExistence(timeout: 5), "answered: Undo")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(card.frame.height, before, accuracy: 1, "the card keeps one height")
        shot("goals5-3-plan-card-accepted" + name)
        // The chat shows the lead's reply.
        app.descendants(matching: .any)["task.message"].firstMatch.tap()
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Started on my two")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "the lead's reply in the goal's chat")
        let hidden = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "I took your plan")).firstMatch
        XCTAssertFalse(hidden.exists, "the app's turn has no bubble")
        shot("goals5-4-lead-reply" + name)
        app.descendants(matching: .any)["goal.tucked-bar"].firstMatch.tap()

        // Undo: all four back, and nobody is told again.
        let undo = app.buttons["goal.offer-card.undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 8))
        undo.tap()
        XCTAssertTrue(waitUntil(10) { title.label == Self.setupGoal }, "the old name: \(title.label)")
        func shows(_ id: String, _ words: String) -> Bool {
            let row = app.descendants(matching: .any)[id].firstMatch
            return row.exists && row.label.contains(words)
        }
        XCTAssertTrue(waitUntil(5) { !shows("goal.why", "hand back") }, "no why")
        XCTAssertFalse(shows("goal.number", "0 of 100"), "no number")
        XCTAssertFalse(shows("goal.date", "Mar 31"), "no date")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(planTakenTurns("Draw every day").count, 1, "Undo tells nobody")

        // A relaunch never tells it again.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", Self.setupGoal])
        XCTAssertTrue(app.descendants(matching: .any)["goal.title"].firstMatch.waitForExistence(timeout: 20))
        // The lead's reply wrote where it stands (goals_update); read again, the page shows it.
        XCTAssertTrue(app.descendants(matching: .any)["goal.stands.text"].firstMatch.waitForExistence(timeout: 20),
                      "where it stands, from the lead's turn")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(promptTexts().filter { $0.hasPrefix("I took your plan for") }.count, 1, "once")

        // A plan with neither (the seeded tomatoes plan): no Built on, no set-up rows.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "Grow our own tomatoes"])
        let plain = app.descendants(matching: .any)["goal.offer-card.plan"].firstMatch
        XCTAssertTrue(plain.waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["goal.offer-card.built-on"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "goal.offer-card.setup.")).firstMatch.exists)

        // New Goal: its placeholder and the lead's line.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesForgetGoalPlanWith", "YES", "-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesNewGoal", "YES"])
        let field = app.descendants(matching: .any)["goals.new.title"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "New Goal")
        XCTAssertTrue(field.placeholderValue == "What do you want to reach?" || (field.value as? String) == "What do you want to reach?",
                      "\(field.placeholderValue ?? "") / \(field.value ?? "")")
        XCTAssertEqual(app.staticTexts["goals.new.who.note"].firstMatch.label, "Hermes asks up to three questions, then offers a plan.")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        shot("goals5-5-new-goal" + name)
    }
}
