// [goals set-up] A plan that sets up its goal (docs/goals.md "Set-up"): a waiting plan says "Plan to look at" on Today's
// shelf; its card shows "Built on" and the four rows it also sets (Name, Why, Number, By), as does the whole-offer
// sheet; Use This Plan renames the goal and sets its why, number and date, and tells the lead once in a hidden turn
// (the lead's reply writes where it stands); Undo puts all four back; a plan with neither looks as before.
//
// Against the stand-in in goal-bots mode: a plain goal led by Hermes, named as a sentence, with no why, number or
// date, and a plan offered on it through /__fixture/goal-offer. Every name is invented.
// Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_GoalPlanSetUp); TEST_RUNNER_HQN_TASKS_LOOK=dark for the dark screens.

import Vision
import XCTest

extension PagesTests {
    private static let setupGoal = "I want to post a drawing every day so I get better"

    /// The plan-taken turns sent for a goal.
    @MainActor func planTakenTurns(_ title: String) -> [String] {
        promptTexts().filter { $0.hasPrefix("I took your plan for") && $0.contains("“\(title)”") }
    }

    /// Bubbles in the chat with the lead's scripted reply (one bubble can surface as itself and as its text: distinct
    /// rows by where they stand).
    @MainActor func replyBubbles() -> Int {
        let found = app.tables["chat.table"].descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Started on my two")).allElementsBoundByIndex
        return Set(found.map { Int($0.frame.minY) }).count
    }

    /// Drags a sideways row (`along`) until `element` stands whole inside the window; false if it never does.
    @MainActor func bringIntoView(_ element: XCUIElement, along row: XCUIElement) -> Bool {
        let window = app.windows.firstMatch.frame
        for _ in 0..<8 {
            let frame = element.frame
            if frame.minX >= window.minX, frame.maxX <= window.maxX, !frame.isEmpty { return true }
            let gap = frame.maxX > window.maxX ? -(frame.maxX - window.maxX + 24) : window.minX - frame.minX + 24
            let step = max(-window.width * 0.4, min(window.width * 0.4, gap))
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: step < 0 ? 0.8 : 0.2, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: step, dy: 0)), withVelocity: .slow,
                        thenHoldForDuration: 0.3)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        let frame = element.frame
        return frame.minX >= window.minX && frame.maxX <= window.maxX
    }

    /// The words drawn on an element, read from its picture (text recognition): what is on screen, not its label.
    @MainActor func seenWords(_ element: XCUIElement) -> String {
        guard let image = element.screenshot().image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
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
        // [goals set-up 6] The card is further along the shelf than the screen shows: bring it into view, then read
        // the words drawn on it (the card is one element for VoiceOver, so its words are read from the picture).
        XCTAssertTrue(bringIntoView(shelf, along: app.descendants(matching: .any)["goals.shelf.cards"].firstMatch),
                      "the card in view: \(shelf.frame) in \(app.windows.firstMatch.frame)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let drawn = seenWords(shelf)
        XCTAssertTrue(drawn.contains("Plan to look at"), "the card's words: \(drawn)")
        XCTAssertTrue(drawn.contains("I want to post"), "the goal's name on the card: \(drawn)")
        shot("goals6-0-shelf-plan-waits" + name)

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
        shot("goals6-1-plan-card-waiting" + name)

        // The whole offer: the same sections first.
        let more = app.buttons["goal.offer-card.more"].firstMatch
        XCTAssertTrue(more.exists, "4 milestones, 3 shown: more ›")
        more.tap()
        let all = app.descendants(matching: .any)["goal.offer-all.setup.name"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 8), "the whole offer shows the set-up rows")
        XCTAssertTrue(app.descendants(matching: .any)["goal.offer-all.built-on"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["goal.offer-all.setup.due"].firstMatch.exists)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        shot("goals6-2-whole-offer" + name)
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitUntil(8) { !all.exists }, "the whole offer closes")

        // Use This Plan: renamed, why, number and date, in the one answer; the lead is told once.
        let cues = goalCues()
        app.buttons["goal.offer-card.Use This Plan"].firstMatch.tap()
        XCTAssertGreaterThan(goalCues(), cues, "the tap is felt")
        let renamed = app.descendants(matching: .any)["goal.title"].firstMatch
        XCTAssertTrue(waitUntil(10) { renamed.label == "Draw every day" }, "renamed: \(renamed.label)")
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
        // [goals set-up 6] The taken lines were added, not done: VoiceOver says "added".
        for words in ["A week of drawings", "Pick one sketchbook for the month"] {
            let line = card.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
            XCTAssertEqual(line.value as? String, "added", "\(words): \(line.label) / \(String(describing: line.value))")
            XCTAssertFalse(line.label.localizedCaseInsensitiveContains("done") || (line.value as? String ?? "").contains("done"))
        }
        shot("goals6-3-plan-card-accepted" + name)
        // The whole offer, once taken: its lines say "added" too.
        app.buttons["goal.offer-card.more"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["goal.offer-all.setup.name"].firstMatch.waitForExistence(timeout: 8), "the whole offer opens")
        // The sheet opens half high, its milestones below the fold: scrolled to them.
        app.collectionViews["goal.offer-all"].firstMatch.swipeUp()
        let sheetLine = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@",
                                                                             "goal.offer-all.line", "A hundred posted")).firstMatch
        let found = sheetLine.waitForExistence(timeout: 8)
        if !found { shot("debug-whole-offer-taken" + name) }
        XCTAssertTrue(found, "the whole offer, taken: " + app.debugDescription.split(separator: "\n")
            .filter { $0.contains("offer-all") || $0.contains("hundred") || $0.contains("week of") }.joined(separator: "\n"))
        XCTAssertEqual(sheetLine.value as? String, "added", sheetLine.debugDescription)
        // Scrolled, the first swipe takes the list back to its top; the next closes the sheet.
        for _ in 0..<3 where app.collectionViews["goal.offer-all"].firstMatch.exists {
            app.swipeDown(velocity: .fast)
            _ = waitUntil(3) { !self.app.collectionViews["goal.offer-all"].firstMatch.exists }
        }
        XCTAssertFalse(app.collectionViews["goal.offer-all"].firstMatch.exists, "the whole offer closes")
        // The chat shows the lead's reply, once, under the goal's new name.
        app.descendants(matching: .any)["task.message"].firstMatch.tap()
        // Asked of the app as it is now (it is launched again below).
        var reply: XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Started on my two")).firstMatch }
        var header: XCUIElement { app.descendants(matching: .any)["chat.title"].firstMatch }
        var title: XCUIElement { app.descendants(matching: .any)["goal.title"].firstMatch }
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "the lead's reply in the goal's chat")
        XCTAssertTrue(waitUntil(5) { header.label.hasPrefix("Draw every day") }, "the chat's bar has the new name: \(header.label)")
        XCTAssertTrue(header.label.contains("Hermes"), "its bot under it: \(header.label)")
        // [goals set-up 6] One bubble: the streamed reply and the stored one are the same message. Watched past the
        // turn-end read and the goal's change that the reply brings.
        XCTAssertTrue(waitUntil(6) { self.replyBubbles() == 1 }, "one bubble with the reply: \(replyBubbles())")
        for _ in 0..<8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            XCTAssertEqual(replyBubbles(), 1, "still one bubble with the reply")
        }
        let hidden = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "I took your plan")).firstMatch
        XCTAssertFalse(hidden.exists, "the app's turn has no bubble")
        shot("goals6-4-lead-reply" + name)

        // Reopened: the chat's bar still has the goal's name now, and the stored reply shows once.
        app.terminate()
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "Draw every day"])
        XCTAssertTrue(app.descendants(matching: .any)["task.message"].firstMatch.waitForExistence(timeout: 20), "the goal's page again")
        app.descendants(matching: .any)["task.message"].firstMatch.tap()
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "the reply, read from the chat")
        XCTAssertTrue(waitUntil(5) { header.label.hasPrefix("Draw every day") && header.label.contains("Hermes") }, "reopened: \(header.label)")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(replyBubbles(), 1, "reopened: one bubble with the reply")
        app.descendants(matching: .any)["goal.tucked-bar"].firstMatch.tap()

        // Undo: all four back, and nobody is told again.
        let undo = app.buttons["goal.offer-card.undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 8))
        undo.tap()
        XCTAssertTrue(waitUntil(10) { title.label == Self.setupGoal }, "the old name: \(title.label)")
        // Undo renames it back: the chat's bar follows that too.
        app.descendants(matching: .any)["task.message"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { header.label.hasPrefix("I want to post") }, "the chat's bar has the old name again: \(header.label)")
        app.descendants(matching: .any)["goal.tucked-bar"].firstMatch.tap()
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
        XCTAssertTrue(field.placeholderValue == "What's your goal? Like “Run a 5K”" || (field.value as? String) == "What's your goal? Like “Run a 5K”",
                      "\(field.placeholderValue ?? "") / \(field.value ?? "")")
        XCTAssertEqual(app.staticTexts["goals.new.who.note"].firstMatch.label, "Hermes asks up to three questions, then offers a plan.")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        shot("goals6-5-new-goal" + name)
    }
}
