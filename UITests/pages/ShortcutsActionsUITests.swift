// [shortcuts] Add Task, Run Job and Talk to Bot (owner 2026-11-20): the real intents, run through the debug hook
// (`<scheme>://debug-intent/<word>`, App/Intents/IntentsDebugHooks.swift) against the pages fixture. Add Task and Run
// Job make their own connection, as they do from the Shortcuts app with no window. Run with scripts/e2e-pages.sh
// (HQN_PAGES_ONLY=testShortcuts_AddTaskRunJobAndTalk HQN_PAGES_SKIP_NOK=1).

import XCTest

extension PagesTests {
    @MainActor func testShortcuts_AddTaskRunJobAndTalk() throws {
        app = launchSignedIn()
        tab("Jobs")
        XCTAssertTrue(jobRow("inbox|j-triage").waitForExistence(timeout: 20), "the Jobs list is read (and stored for the picker)")
        let scheme = ProcessInfo.processInfo.environment["HQN_UI_SCHEME"] ?? "hermeshq-native"
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func hook(_ word: String) {
            XCUIDevice.shared.system.open(URL(string: "\(scheme)://debug-intent/\(word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)")!)
            let open = springboard.buttons["Open"]
            if open.waitForExistence(timeout: 4) { open.tap() }
        }
        let tasks = "/api/plugins/hermes-hq-push/tasks"

        // Add Task, your own.
        hook("shortcut-task:-:together:Renew the domain")
        XCTAssertTrue(waitUntil(15) { self.requests().contains { $0.method == "POST" && $0.path == tasks } },
                      "POST /tasks (\(userWrites().map { $0.method + " " + $0.path }))")
        // Add Task for a bot to do.
        hook("shortcut-task:inbox:bot:Draft the weekly post")
        XCTAssertTrue(waitUntil(15) { self.requests().filter { $0.method == "POST" && $0.path == tasks }.count == 2 }, "a second POST /tasks")
        let posted = requests().filter { $0.method == "POST" && $0.path == tasks }.compactMap(\.body)
        let mine = posted.first { $0["title"] as? String == "Renew the domain" }
        let theirs = posted.first { $0["title"] as? String == "Draft the weekly post" }
        XCTAssertEqual(mine?["who"] as? String, "me", "your own task (\(posted))")
        XCTAssertEqual(mine?["notes"] as? String, "From a shortcut")
        XCTAssertEqual(theirs?["who"] as? String, "bot")
        XCTAssertEqual(theirs?["bot"] as? String, "inbox")

        // Run Job: the job's state, Run Now's trigger for its owner, then its runs.
        hook("shortcut-job:inbox|j-triage")
        XCTAssertTrue(waitUntil(60) {
            self.requests().contains { $0.method == "GET" && $0.path == "/api/cron/jobs/j-triage/runs" }
        }, "the run's result is read (\(requests().filter { $0.path.hasPrefix("/api/cron") }.map { $0.method + " " + $0.path }))")
        let sent = requests().filter { $0.path.hasPrefix("/api/cron/jobs/j-triage") && $0.query["profile"] == "inbox" }.map { "\($0.method) \($0.path)" }
        XCTAssertEqual(Array(sent.suffix(3)), ["GET /api/cron/jobs/j-triage", "POST /api/cron/jobs/j-triage/trigger", "GET /api/cron/jobs/j-triage/runs"])

        // Talk to Bot: the Talk tile's road (`TalkWiring.startTalking`), which on a first Talk shows its intro; the
        // conversation itself is the Talk tests' (scripts/e2e-talk.sh), from the same call.
        hook("shortcut-talk:inbox")
        let intro = app.descendants(matching: .any)["talk.intro"]
        XCTAssertTrue(intro.waitForExistence(timeout: 20), "Talk starts (its first-time intro)")
        XCTAssertTrue(app.buttons["talk.intro.start"].exists, "with Start Talking")
        shot("shortcut-talk")
        app.buttons["talk.intro.not-now"].tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "in the bot's chat")
    }
}
