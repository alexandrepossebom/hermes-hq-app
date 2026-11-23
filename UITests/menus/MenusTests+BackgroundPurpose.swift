// [background] A Background row says what the job is FOR (owner 2026-11-22: "claude -p 'Read .goals-bri…" over "No output
// yet" for 1h 22m — "Is this what you thought would count as success?"). Three jobs against the menus fixture: one the
// bot introduced in its own words, a coding agent it didn't, and one named by a # comment that writes to a log.
// Run with HQN_MENUS_ONLY=test33b_BackgroundRowsSayWhatTheJobIsFor scripts/e2e-menus.sh <sim>.

import XCTest

extension MenusTests {
    @MainActor func test33b_BackgroundRowsSayWhatTheJobIsFor() throws {
        let (account, app) = try start()
        let worker = "cd ~/Projects/app-wt/goals-2 && claude -p 'Read .goals-brief.md in this directory and carry it out completely, then write artifacts/goals/REPORT-6.md. Never commit, never push.' --permission-mode acceptEdits --max-turns 200"
        let agent = "cd ~/Projects/app-wt/site && codex exec --full-auto 'Fix the flaky checkout test and explain the cause in NOTES.md'"
        let archive = "# Archiving the Mac build\ncd ~/Projects/app-wt/ship-mac && BUILD=42 python3 scripts/ship.py archive > /tmp/evidence/archive.log 2>&1"
        try account.control("/__menus/mode", [
            "jobTurns": [["text": "Here are the four screens.\n\nI'm starting a worker on the **four goal set-up fixes** from your review.", "command": worker]],
            "processes": [
                ["session_id": "proc_w", "command": worker, "cwd": "/Users/me/Projects/app-wt/goals-2", "status": "running", "uptime_seconds": 4920, "output_tail": ""],
                ["session_id": "proc_c", "command": agent, "status": "running", "uptime_seconds": 610, "output_tail": ""],
                ["session_id": "proc_a", "command": archive, "status": "running", "uptime_seconds": 1500, "output_tail": ""],
            ],
        ])
        openBotChat(app)
        let chip = app.activityCategory("background")
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()

        let titles = app.descendants(matching: .any).matching(identifier: "chat.background.title")
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 5))
        let names = (0..<titles.count).map { titles.element(boundBy: $0).label }
        XCTAssertTrue(names.contains { $0.hasPrefix("The four goal set-up fixes from your review, running") }, "\(names)")
        XCTAssertTrue(names.contains { $0.hasPrefix("Fix the flaky checkout test and explain the cause in NOTES.md, running") }, "\(names)")
        XCTAssertTrue(names.contains { $0.hasPrefix("Archiving the Mac build, running") }, "\(names)")

        let details = app.descendants(matching: .any).matching(identifier: "chat.background.detail")
        let detailWords = (0..<details.count).map { details.element(boundBy: $0).label }
        XCTAssertTrue(detailWords.contains("Claude Code · goals-2"), "\(detailWords)")
        XCTAssertTrue(detailWords.contains("Codex · site"), "\(detailWords)")
        XCTAssertTrue(detailWords.contains("python3 scripts/ship.py archive · ship-mac"), "\(detailWords)")

        let outputs = app.descendants(matching: .any).matching(identifier: "chat.background.output")
        let quiet = (0..<outputs.count).map { outputs.element(boundBy: $0).label }
        XCTAssertFalse(quiet.contains("No output yet"), "\(quiet)")
        XCTAssertTrue(quiet.contains("Quiet until it's done"), "\(quiet)")
        XCTAssertTrue(quiet.contains("Writing to archive.log"), "\(quiet)")
        shot(app, "background-purpose")
    }
}
