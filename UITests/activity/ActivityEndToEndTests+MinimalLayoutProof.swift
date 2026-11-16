import XCTest

extension ActivityEndToEndTests {
    /// The approved collapsed activity surface occupies one 44 pt touch row even with several kinds present.
    /// This exact test is also run against the pre-change release to prove the old stack fails this contract.
    @MainActor func test60_CollapsedActivityUsesOneRowWithMultipleKinds() throws {
        let account = try FixtureAccount.load()
        try reset(account)
        try account.control("/__fixture/history", ["profile": "default", "count": 40])
        try account.control("/__fixture/control", ["profile": "default", "control": ["goal": Self.goal], "emit": false])
        try account.control("/__fixture/todo-state", ["profile": "default", "revision": 4, "todos": [
            ["id": "1", "content": "Read the changelog", "status": "completed"],
            ["id": "2", "content": "Write the notes", "status": "pending"]]])
        try account.control("/__fixture/subagents", ["delegations": [Any](), "subagents": [[
            "subagent_id": "sa_compact", "goal": "Index the docs", "status": "running",
            "started_at": Date().timeIntervalSince1970 - 30, "model": "fixture-model",
            "depth": 0, "tool_count": 2, "last_tool": "read_file", "accepting_steer": true]]])
        let app = launch(account, args: ["-HQDebugMotionProbe", "YES"])
        openChat(app)
        let shelf = element(app, "chat.shelf")
        XCTAssertTrue(shelf.waitForExistence(timeout: 10), "the simultaneous activity state appears")
        Thread.sleep(forTimeInterval: 6)
        shot("minimal-activity-multiple-kinds-collapsed")
        XCTAssertGreaterThanOrEqual(shelf.frame.height, 44, "the control keeps a full touch row")
        XCTAssertLessThanOrEqual(shelf.frame.height, 45, "multiple activity kinds must not stack independent bubbles")
        try reset(account)
    }
}
