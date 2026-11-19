// [goals] Pictures of Goals step 1 for the review against the owner-approved boards (docs/goals.md): each seeded goal's
// page, New Goal, Update and Edit Goal, opened straight from the DEBUG launch arguments (App/Pages/PagesDebug.swift).
// Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_GoalsShots); HQN_TASKS_LOOK=dark for the dark ones.

import XCTest

extension PagesTests {
    @MainActor private func settleGoal() { RunLoop.current.run(until: Date().addingTimeInterval(1.5)) }

    @MainActor func testTasks_GoalsShots() throws {
        let name = Self.lookName
        let pages = [("1,000 public testers", "goals-page-testers", "34 percent"),
                     ("Run a 10K", "goals-page-10k", "25 percent"),
                     ("Family trip to the coast", "goals-page-trip", "66 percent"),
                     ("Learn conversational Spanish", "goals-page-spanish", "50 percent"),
                     ("Read 12 books this year", "goals-page-books", "100 percent")]
        for (index, (goal, shotName, value)) in pages.enumerated() {
            try account.control("/__fixture/reset", [:])
            try account.control("/__fixture/tasks-mode", ["goals": true])
            app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", goal])
            let title = app.descendants(matching: .any)["goal.title"].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 20), "\(goal)'s page")
            XCTAssertEqual(title.label, goal)
            XCTAssertEqual(title.value as? String, value, "\(goal)'s ring")
            settleGoal(); shot(shotName + name)
            if index == 0 {
                // The rest of a long page.
                app.swipeUp(velocity: .slow)
                settleGoal(); shot(shotName + "-foot" + name)
            }
            app.terminate()
        }

        // Update and Edit Goal over the first goal's page; New Goal over the list.
        for (sheet, id, shotName) in [("update", "goal.update.field", "goals-sheet-update"), ("edit", "goal.edit.name", "goals-sheet-edit")] {
            app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenGoal", "1,000 public testers",
                                              "-HQPagesGoalSheet", sheet])
            let field = app.textFields[id].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 25), "\(sheet) opens over the page")
            settleGoal(); shot(shotName + name)
            app.terminate()
        }
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesNewGoal", "YES"])
        let line = app.descendants(matching: .any)["goals.new.title"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 20), "New Goal")
        settleGoal(); shot("goals-sheet-new" + name)
    }
}
