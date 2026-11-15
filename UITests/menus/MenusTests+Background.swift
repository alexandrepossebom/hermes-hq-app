// [background] A command the bot left running in the background shows on the chat's shelf beside Subagents (owner
// 2026-11-15: a bot that started a long test run in the background and ended its turn looked idle). Against the menus
// fixture's `process.list` / `process.kill` (scripts/fixtures/menus-gateway.py, mode "processes"). Run with
// HQN_MENUS_ONLY=test33_BackgroundTaskChip scripts/e2e-menus.sh <sim>.

import XCTest

extension MenusTests {
    @MainActor func test33_BackgroundTaskChip() throws {
        let (account, app) = try start()
        try account.control("/__menus/mode", ["processes": [[
            "session_id": "proc_bg1", "command": "xcodebuild test -scheme Demo", "status": "running", "uptime_seconds": 372,
            "output_tail": "Test Suite 'All tests' started\n\nExecuted 120 tests, with 0 failures\n",
        ]]])
        openBotChat(app)

        // The chip: the command's time, a spinner (VoiceOver: running).
        let chip = app.descendants(matching: .any)["chat.shelf.background"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the Background task chip shows with no turn running")
        XCTAssertEqual(chip.label, "Background task · 6m, running")
        XCTAssertGreaterThan(calls(account, "process.list").count, 0, "read from process.list")
        shot(app, "background-chip")

        // Opened: the command and the newest line it printed.
        chip.tap()
        let title = app.descendants(matching: .any)["chat.background.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the opened card lists the command")
        XCTAssertTrue(title.label.hasPrefix("xcodebuild test -scheme Demo, running"), title.label)
        XCTAssertEqual(app.descendants(matching: .any)["chat.background.output"].firstMatch.label, "Executed 120 tests, with 0 failures")
        shot(app, "background-card")

        // It keeps being read while it runs.
        let reads = calls(account, "process.list").count
        XCTAssertTrue(waitUntil(timeout: 12) { self.calls(account, "process.list").count > reads }, "polled while it runs")

        // Stop Task sits behind the row's ⋯ (one tap can't end a long run by accident); the chip leaves once it ends.
        app.descendants(matching: .any)["chat.background.more"].firstMatch.tap()
        let stop = app.buttons["Stop Task"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Stop Task in the row's menu")
        shot(app, "background-stop-menu")
        stop.tap()
        XCTAssertTrue(waitUntil(timeout: 8) {
            self.calls(account, "process.kill").contains { ($0["process_id"] as? String) == "proc_bg1" }
        }, "process.kill for that command")
        XCTAssertTrue(waitUntil(timeout: 8) { !chip.exists }, "the chip leaves once nothing runs")
        shot(app, "background-stopped")

        // Nothing running and no turn: the reads stop.
        Thread.sleep(forTimeInterval: 1)
        let settled = calls(account, "process.list").count
        Thread.sleep(forTimeInterval: 7)
        XCTAssertEqual(calls(account, "process.list").count, settled, "no polls once nothing runs")
    }
}
