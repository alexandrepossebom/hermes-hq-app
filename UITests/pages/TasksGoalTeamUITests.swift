// [goals step 6] A goal you make gets a bot planning it, and adding bots to a goal is one obvious tap (docs/goals.md
// "Step 6"): the goal page's Bots row (Just Me, Add Bots) and its team sheet (the first ticked leads, Make Lead, unticking
// the lead hands it on), Done on a goal with no plan opening its chat with the plan asked once, the card's hold menu's
// Add Bots…, New Goal's Who's helping? row (the root bot leading, a helper, Make Lead, Just Me remembered), Edit Goal giving a goal its first
// lead, and the page's "Ask <Bot> for a Plan".
//
// Against the stand-in in goal-bots mode, plus goals with no plan (tasks-mode "plain_goals", no milestones, no tasks).
// Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_GoalBotsRow,…); HQN_TASKS_LOOK=dark for the dark screens.

import XCTest

extension PagesTests {
    private static let teamGoalRoute = "/api/plugins/hermes-hq-push/goals"

    /// The plan asks sent for one goal (prompt.submit's text starts with the app's ask and names the goal).
    @MainActor func planAsks(_ title: String) -> [String] {
        promptTexts().filter { $0.hasPrefix("I just made this goal and want you to lead it.") && $0.contains("Goal: “\(title)”") }
    }

    /// A team sheet row: "Hermes, on this goal, leads" and so on.
    @MainActor func teamRow(_ id: String) -> XCUIElement { app.buttons["goal.team.row.\(id)"].firstMatch }

    // MARK: The Bots row and the team sheet

    @MainActor func testTasks_GoalBotsRow() throws {
        let title = "Start a photo blog"
        try goalMode(["goal_bots": true, "plain_goals": [["title": title], ["title": "Learn to sketch faces"]]])
        app = launchSignedIn(Self.look + ["-HQDebugHapticsProbe", "YES", "-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", title])
        let name = Self.lookName

        // No bot: "Just Me", Add Bots at its end.
        let who = app.descendants(matching: .any)["goal.who"].firstMatch
        XCTAssertTrue(who.waitForExistence(timeout: 20), "the Bots row is always there")
        XCTAssertEqual(who.label, "Just Me")
        XCTAssertEqual(who.value as? String, "Add Bots")
        XCTAssertFalse(app.descendants(matching: .any)["goal.ask-plan"].exists, "no lead, no plan ask")
        shot("goals4-1-bots-row-none" + name)

        // A tap opens the team sheet: every bot, none ticked.
        var cues = goalCues()
        who.tap()
        let hermes = teamRow("default"), research = teamRow("research")
        XCTAssertTrue(hermes.waitForExistence(timeout: 8), "the team sheet")
        XCTAssertGreaterThan(goalCues(), cues, "the tap is felt")
        XCTAssertEqual(hermes.label, "Hermes, not on this goal")
        XCTAssertEqual(research.label, "Research, not on this goal")
        XCTAssertTrue(app.staticTexts["The lead plans and checks in each week. The others take tasks."].exists, "the one line")
        XCTAssertFalse(app.buttons["goal.team.review"].exists, "no check-in without a lead")

        // Two ticks: the first leads, the second helps. Each saves as you make it.
        cues = goalCues()
        hermes.tap()
        XCTAssertTrue(waitUntil(5) { hermes.label == "Hermes, on this goal, leads" }, hermes.label)
        XCTAssertGreaterThan(goalCues(), cues, "a tick is felt")
        research.tap()
        XCTAssertTrue(waitUntil(5) { research.label == "Research, on this goal" }, research.label)
        XCTAssertTrue(app.buttons["goal.team.make-lead.research"].waitForExistence(timeout: 3), "a helper's row has Make Lead")
        XCTAssertFalse(app.buttons["goal.team.make-lead.default"].exists, "the lead's row says Leads")
        XCTAssertTrue(app.descendants(matching: .any)["goal.team.leads.default"].exists)
        XCTAssertTrue(waitUntil(8) { self.goalPatches().contains { $0.body?["lead"] as? String == "default" } }, "PATCH lead")
        XCTAssertTrue(waitUntil(8) { self.goalPatches().contains { ($0.body?["helpers"] as? [String]) == ["research"] } }, "PATCH helpers")
        XCTAssertTrue(app.buttons["goal.team.review"].waitForExistence(timeout: 8), "the check-in comes with a lead")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        shot("goals4-2-team-sheet" + name)

        // Make Lead swaps them; unticking the lead hands it to the next ticked bot.
        app.buttons["goal.team.make-lead.research"].tap()
        XCTAssertTrue(waitUntil(5) { research.label == "Research, on this goal, leads" && hermes.label == "Hermes, on this goal" },
                      "\(research.label) / \(hermes.label)")
        XCTAssertTrue(waitUntil(8) { self.goalPatches().contains {
            $0.body?["lead"] as? String == "research" && ($0.body?["helpers"] as? [String]) == ["default"] } }, "PATCH the swap")
        research.tap()
        XCTAssertTrue(waitUntil(5) { hermes.label == "Hermes, on this goal, leads" && research.label == "Research, not on this goal" },
                      "\(hermes.label) / \(research.label)")
        XCTAssertTrue(waitUntil(8) { self.goalPatches().contains {
            $0.body?["lead"] as? String == "default" && ($0.body?["helpers"] as? [String]) == [] } }, "PATCH the hand-on")
        research.tap()
        XCTAssertTrue(waitUntil(5) { research.label == "Research, on this goal" }, research.label)
        XCTAssertTrue(waitUntil(8) { (self.goalPatches().last?.body?["helpers"] as? [String]) == ["research"] }, "the last save")

        // Done on a goal with no plan: its chat opens and Hermes is asked for a plan, once.
        app.buttons["goal.team.done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["goal.tucked-bar"].firstMatch.waitForExistence(timeout: 15), "the goal's chat opens")
        XCTAssertTrue(waitUntil(15) { self.planAsks(title).count == 1 }, "the plan ask: \(promptTexts())")
        XCTAssertTrue(app.cells.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.waitForExistence(timeout: 8)
                      || app.staticTexts[title].firstMatch.exists, "your bubble shows the goal's name")
        let card = app.descendants(matching: .any)["chat.goal-offer"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Hermes's plan card")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(planAsks(title).count, 1, "asked once")
        shot("goals4-3-reopened-chat" + name)

        // The goal over its chat: the Bots row with the team.
        app.descendants(matching: .any)["goal.tucked-bar"].firstMatch.tap()
        let led = app.descendants(matching: .any)["goal.who"].firstMatch
        XCTAssertTrue(waitUntil(10) { led.exists && led.label.hasPrefix("Led by Hermes, with Research") }, led.label)
        XCTAssertFalse(app.descendants(matching: .any)["goal.ask-plan"].exists, "hidden while the plan waits")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        shot("goals4-4-bots-row-team" + name)

        // The goal card's hold menu: Add Bots… first.
        app.buttons["sheet.close"].firstMatch.tap()
        let other = app.cells["goal-cell-Learn to sketch faces"].firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 10), "the other goal's card")
        other.press(forDuration: 0.9)
        let add = app.buttons["Add Bots…"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Add Bots… in the hold menu")
        XCTAssertTrue(app.buttons["Edit Goal…"].exists)
        XCTAssertLessThan(add.frame.minY, app.buttons["Edit Goal…"].firstMatch.frame.minY, "Add Bots… is the first row")
        shot("goals4-5-hold-menu" + name)
        add.tap()
        XCTAssertTrue(teamRow("default").waitForExistence(timeout: 8), "the same team sheet")
        app.buttons["goal.team.done"].tap()
        XCTAssertTrue(waitUntil(5) { !self.teamRow("default").exists })
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(app.descendants(matching: .any)["goal.tucked-bar"].exists, "no bot picked: nothing opens")
        XCTAssertTrue(planAsks("Learn to sketch faces").isEmpty)
        // A goal with bots says Bots… there.
        let led2 = app.cells["goal-cell-\(title)"].firstMatch
        XCTAssertTrue(led2.waitForExistence(timeout: 5))
        led2.press(forDuration: 0.9)
        XCTAssertTrue(app.buttons["Bots…"].firstMatch.waitForExistence(timeout: 5), "Bots… with bots on it")
    }

    // MARK: New Goal's Who's helping?

    /// A chip in New Goal's Who's helping? row: "Hermes, on this goal, leads" and so on.
    @MainActor func whoChip(_ id: String) -> XCUIElement { app.buttons["goals.new.who.\(id)"].firstMatch }

    @MainActor func whoNote() -> String { app.staticTexts["goals.new.who.note"].firstMatch.label }

    @MainActor func testTasks_NewGoalWhosHelping() throws {
        try goalMode(["goal_bots": true])
        app = launchSignedIn(Self.look + ["-HQDebugHapticsProbe", "YES", "-HQPagesForgetGoalPlanWith", "YES", "-HQPagesTab", "4",
                                          "-HQPagesMore", "tasks", "-HQPagesNewGoal", "YES"])
        let name = Self.lookName
        let field = app.descendants(matching: .any)["goals.new.title"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "New Goal")

        // The row, in the sheet: one chip per bot and Just Me. It starts on the root bot, leading.
        XCTAssertTrue(app.staticTexts["Who's helping?"].firstMatch.waitForExistence(timeout: 5), "the row's heading")
        let hermes = whoChip("default"), research = whoChip("research"), justMe = whoChip("just-me")
        XCTAssertTrue(hermes.exists && research.exists && justMe.exists, "a chip per bot, and Just Me")
        XCTAssertEqual(hermes.label, "Hermes, on this goal, leads", "the first time: the root bot leads")
        XCTAssertEqual(research.label, "Research, not on this goal")
        XCTAssertTrue(app.descendants(matching: .any)["goals.new.who.leads.default"].exists, "Leads under its name")
        XCTAssertEqual(whoNote(), "Hermes will offer a plan when you add this.")
        XCTAssertFalse(app.buttons["goals.new.plan"].exists, "no Plan With button")
        XCTAssertGreaterThan(justMe.frame.minX, research.frame.minX, "Just Me is the last chip")
        shot("goals4-6-new-goal" + name)

        // A second bot ticked helps.
        let cues = goalCues()
        research.tap()
        XCTAssertTrue(waitUntil(5) { research.label == "Research, on this goal" }, research.label)
        XCTAssertGreaterThan(goalCues(), cues, "a tick is felt")
        XCTAssertTrue(waitUntil(3) { self.whoNote() == "Hermes leads. Research helps." }, whoNote())
        XCTAssertTrue(app.buttons["goals.new.who.menu.research"].exists, "a helper's small menu")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        shot("goals4-7-new-goal-team" + name)

        // Make Lead (its small menu) swaps them; back again.
        app.buttons["goals.new.who.menu.research"].tap()
        let makeLead = app.buttons["Make Lead"].firstMatch
        XCTAssertTrue(makeLead.waitForExistence(timeout: 5), "Make Lead in the chip's menu")
        makeLead.tap()
        XCTAssertTrue(waitUntil(5) { research.label == "Research, on this goal, leads" && hermes.label == "Hermes, on this goal" },
                      "\(research.label) / \(hermes.label)")
        XCTAssertTrue(waitUntil(3) { self.whoNote() == "Research leads. Hermes helps." }, whoNote())
        app.buttons["goals.new.who.menu.default"].tap()
        XCTAssertTrue(app.buttons["Make Lead"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Make Lead"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { hermes.label == "Hermes, on this goal, leads" && research.label == "Research, on this goal" })

        // Add with a lead and a helper: the goal is made with both, and its chat opens with the plan asked once.
        field.tap()
        field.typeText("Write a short story")
        app.buttons["goals.new.add"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { self.goalPatches().contains {
            $0.body?["lead"] as? String == "default" && ($0.body?["helpers"] as? [String]) == ["research"] } }, "PATCH lead and helpers")
        XCTAssertTrue(app.descendants(matching: .any)["goal.tucked-bar"].firstMatch.waitForExistence(timeout: 15), "the goal's chat")
        XCTAssertTrue(waitUntil(15) { self.planAsks("Write a short story").count == 1 }, "\(promptTexts())")
        XCTAssertTrue(app.descendants(matching: .any)["chat.goal-offer"].firstMatch.waitForExistence(timeout: 20), "the plan card")

        // Next time it starts on that team, remembered. Just Me clears them.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesNewGoal", "YES"])
        XCTAssertTrue(whoChip("default").waitForExistence(timeout: 20))
        XCTAssertEqual(whoChip("default").label, "Hermes, on this goal, leads", "the last pick, remembered")
        XCTAssertEqual(whoChip("research").label, "Research, on this goal")
        whoChip("just-me").tap()
        XCTAssertTrue(waitUntil(5) { self.whoChip("default").label == "Hermes, not on this goal"
            && self.whoChip("research").label == "Research, not on this goal" }, "Just Me unticks them all")
        XCTAssertTrue(whoChip("just-me").isSelected, "Just Me is filled")
        XCTAssertTrue(waitUntil(3) { self.whoNote() == "No bot. You can add one later." }, whoNote())
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        shot("goals4-8-new-goal-just-me" + name)

        // Add with Just Me: a plain goal, no lead sent, no chat.
        let line = app.descendants(matching: .any)["goals.new.title"].firstMatch
        line.tap()
        line.typeText("Plant a herb garden")
        let patchesBefore = goalPatches().count
        app.buttons["goals.new.add"].firstMatch.tap()
        let title = app.descendants(matching: .any)["goal.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "the plain goal's page")
        XCTAssertFalse(app.descendants(matching: .any)["goal.tucked-bar"].exists, "no chat for a goal with no bot")
        XCTAssertEqual(app.descendants(matching: .any)["goal.who"].firstMatch.label, "Just Me")
        XCTAssertEqual(goalPatches().count, patchesBefore, "no lead sent")

        // And Just Me is remembered.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesNewGoal", "YES"])
        XCTAssertTrue(whoChip("just-me").waitForExistence(timeout: 20))
        XCTAssertTrue(whoChip("just-me").isSelected, "Just Me, remembered")
        XCTAssertEqual(whoChip("default").label, "Hermes, not on this goal")
        XCTAssertEqual(whoNote(), "No bot. You can add one later.")
    }

    // MARK: Edit Goal gives a goal its first lead

    @MainActor func testTasks_GoalEditGivesALead() throws {
        let title = "Read twelve books this year"
        try goalMode(["goal_bots": true, "plain_goals": [["title": title]]])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", title, "-HQPagesGoalSheet", "edit"])
        let bots = app.buttons["goal.edit.bots"].firstMatch
        XCTAssertTrue(bots.waitForExistence(timeout: 20), "Edit Goal's one Bots row")
        XCTAssertEqual(bots.label, "Bots, Just Me")
        XCTAssertFalse(app.buttons["goal.edit.lead"].exists || app.buttons["goal.edit.helpers"].exists, "no Led By or Helpers rows")
        bots.tap()
        let hermes = teamRow("default")
        XCTAssertTrue(hermes.waitForExistence(timeout: 8), "the team sheet over Edit Goal")
        hermes.tap()
        XCTAssertTrue(waitUntil(5) { hermes.label == "Hermes, on this goal, leads" })
        app.buttons["goal.team.done"].tap()
        XCTAssertTrue(waitUntil(8) { bots.label == "Bots, Led by Hermes" }, bots.label)
        XCTAssertTrue(app.buttons["goal.edit.review"].waitForExistence(timeout: 8), "the check-in row with a lead")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(planAsks(title).isEmpty, "not asked while Edit Goal is open")

        // Edit Goal closes: the goal reopens on its chat, and Hermes is asked for a plan once.
        let close = app.buttons["sheet.close"].firstMatch
        if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(app.descendants(matching: .any)["goal.tucked-bar"].firstMatch.waitForExistence(timeout: 15), "the goal's chat")
        XCTAssertTrue(waitUntil(15) { self.planAsks(title).count == 1 }, "\(promptTexts())")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(planAsks(title).count, 1, "asked once")

        // A goal that has a plan is not asked: Run a 10K (milestones) given a lead.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "Run a 10K", "-HQPagesGoalSheet", "edit"])
        let row = app.buttons["goal.edit.bots"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(teamRow("research").waitForExistence(timeout: 8))
        teamRow("research").tap()
        app.buttons["goal.team.done"].tap()
        XCTAssertTrue(waitUntil(8) { row.label == "Bots, Led by Research" }, row.label)
        let close2 = app.buttons["sheet.close"].firstMatch
        if close2.exists { close2.tap() } else { app.swipeDown(velocity: .fast) }
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(app.descendants(matching: .any)["goal.tucked-bar"].exists, "a goal with a plan stays on its page")
        XCTAssertTrue(planAsks("Run a 10K").isEmpty, "and is not asked")
    }

    // MARK: Ask <Bot> for a Plan

    @MainActor func testTasks_GoalAskForAPlan() throws {
        let title = "Make a family cookbook"
        let numbered = "Post 30 short videos"
        try goalMode(["goal_bots": true, "plain_goals": [["title": title, "lead": "default"], ["title": numbered, "lead": "research", "number": 30]]])
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", title])
        let name = Self.lookName
        let ask = app.buttons["goal.ask-plan"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 20), "a lead and no plan: the ask")
        XCTAssertEqual(ask.label, "Ask Hermes for a Plan")
        XCTAssertTrue(app.staticTexts["No plan yet"].firstMatch.exists, "No plan yet")
        XCTAssertFalse(app.descendants(matching: .any)["goal.no-plan"].exists, "said once: the bar's line already says it")
        XCTAssertTrue(app.descendants(matching: .any)["goal.who"].firstMatch.label.hasPrefix("Led by Hermes"))
        shot("goals4-9-ask-for-a-plan" + name)
        ask.tap()
        XCTAssertTrue(app.descendants(matching: .any)["goal.tucked-bar"].firstMatch.waitForExistence(timeout: 10), "the chat takes the screen")
        XCTAssertTrue(waitUntil(15) { self.planAsks(title).count == 1 }, "\(promptTexts())")
        XCTAssertTrue(app.descendants(matching: .any)["chat.goal-offer"].firstMatch.waitForExistence(timeout: 20), "the plan's card")
        // Back to the goal: the plan waits, so the ask is hidden.
        app.descendants(matching: .any)["goal.tucked-bar"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { !ask.exists }, "hidden while the plan waits")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(planAsks(title).count, 1, "asked once")

        // A goal with a number and no plan (as the owner's first one): its bar's line gives the number, so the ask says
        // "No plan yet" itself.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", numbered])
        let ask2 = app.buttons["goal.ask-plan"].firstMatch
        XCTAssertTrue(ask2.waitForExistence(timeout: 20), "a number is no plan")
        XCTAssertEqual(ask2.label, "Ask Research for a Plan")
        XCTAssertTrue(app.descendants(matching: .any)["goal.no-plan"].exists, "No plan yet over the button")
        shot("goals4-10-ask-for-a-plan-number" + name)
    }
}
