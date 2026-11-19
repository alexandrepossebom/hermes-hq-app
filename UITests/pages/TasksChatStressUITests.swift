// [tasks] Owner 2026-11-19 (voice memo): "I sent an agent a message inside of a task, left the task, went to a
// different page inside the app, got a notification that the agent had responded. Click the notification and then I
// could not read the chat. It wasn't showing me what I was needing to see. … stress test all that functionality and
// make sure that you always land on the right place."
// Every path here ends on the same promise: the reply the alert was for is on screen, its first line in sight, under
// the task's bar, in the task it belongs to. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasksStress_…).

import XCTest

extension PagesTests {
    /// The memo's path: a message from the task's page, the task closed, another tab, the reply's alert tapped.
    @MainActor func testTasksStress_1_ReplyAlertAfterLeaving() throws {
        let ask = "Stress one: did Ivy write back?"
        openContractAndSend(ask)
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { !self.app.descendants(matching: .any)["task.sheet"].firstMatch.exists }, "the task is closed")
        tab("Bots")
        let reply = stressReply("one")
        try finishTurn(matching: ask, asked: ask, reply: reply)
        openContractChatLink()
        assertLandsOnReply(reply, asked: ask, name: "stress-1-after-leaving")
    }

    /// The same, the alert tapped while another bot's chat is open in Bots (the sheet opens from a pushed chat).
    @MainActor func testTasksStress_2_ReplyAlertFromAnotherChat() throws {
        let ask = "Stress two: anything new?"
        openContractAndSend(ask)
        app.buttons["sheet.close"].firstMatch.tap()
        tab("Bots")
        let row = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'bot-row-' OR identifier BEGINSWITH 'bot-tile-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "a bot to open")
        row.tap()
        XCTAssertTrue(app.textViews["composer.text"].firstMatch.waitForExistence(timeout: 10), "another bot's chat is open")
        let reply = stressReply("two")
        try finishTurn(matching: ask, asked: ask, reply: reply)
        openContractChatLink()
        assertLandsOnReply(reply, asked: ask, name: "stress-2-from-another-chat")
    }

    /// The alert tapped while ANOTHER task's page is open: that task goes, this one opens at its reply.
    @MainActor func testTasksStress_3_ReplyAlertOverAnotherTask() throws {
        let ask = "Stress three: still waiting?"
        openContractAndSend(ask)
        app.buttons["sheet.close"].firstMatch.tap()
        let other = app.cells["task-row-Renew passport"].firstMatch
        XCTAssertTrue(waitUntil(10) { other.exists && other.isHittable }, "back on the list")
        other.tap()
        XCTAssertTrue(app.buttons["task.check"].firstMatch.waitForExistence(timeout: 10), "another task is open")
        let reply = stressReply("three")
        try finishTurn(matching: ask, asked: ask, reply: reply)
        openContractChatLink()
        assertLandsOnReply(reply, asked: ask, name: "stress-3-over-another-task")
    }

    /// No alert: the task opened again from the list after the reply landed. The task's view says there is a new
    /// reply, and one tap shows it.
    @MainActor func testTasksStress_4_ReopenFromListAfterReply() throws {
        let ask = "Stress four: news?"
        openContractAndSend(ask)
        app.buttons["sheet.close"].firstMatch.tap()
        tab("Bots")
        let reply = stressReply("four")
        try finishTurn(matching: ask, asked: ask, reply: reply)
        sleep(2)
        tab("More")
        let row = app.cells["task-row-Follow up with Ivy on the contract"].firstMatch
        if !row.waitForExistence(timeout: 5) {
            let more = app.cells["more-row-tasks"].firstMatch
            if more.waitForExistence(timeout: 5) { more.tap() }
        }
        XCTAssertTrue(waitUntil(15) { row.exists && row.isHittable }, "the task's row")
        row.tap()
        let line = app.buttons["task.chat-line"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 15), "the task's view with its chat line")
        shot("stress-4a-reopened")
        XCTAssertTrue(waitUntil(10) { line.label.contains("New reply") }, "the line says a reply came: \(line.label)")
        line.tap()
        assertLandsOnReply(reply, asked: ask, name: "stress-4b-line-tapped", viaAlert: false)
    }

    /// The reply lands while the task's page is still open on the task's view (the chat covered): the line tells of it,
    /// and the alert's tap (an alert for the chat on show) shows it.
    @MainActor func testTasksStress_5_ReplyWhileTaskOpen() throws {
        let ask = "Stress five: and now?"
        openContractAndSend(ask)
        // Back to the task's view (the bar's tap), as someone reading their steps while the bot works.
        let bar = app.descendants(matching: .any)["task.bar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the send rolled the task up to its bar")
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["task.check"].firstMatch.waitForExistence(timeout: 5), "the task's view again")
        let reply = stressReply("five")
        try finishTurn(matching: ask, asked: ask, reply: reply)
        let line = app.buttons["task.chat-line"].firstMatch
        XCTAssertTrue(waitUntil(10) { line.exists && line.label.contains("New reply") }, "the open task says a reply came: \(line.label)")
        shot("stress-5a-reply-while-open")
        openContractChatLink()
        assertLandsOnReply(reply, asked: ask, name: "stress-5b-alert-while-open")
    }

    /// A cold launch from the alert after the message was sent (the app was swiped away while the bot worked).
    @MainActor func testTasksStress_6_ReplyAlertColdLaunch() throws {
        let ask = "Stress six: done yet?"
        openContractAndSend(ask)
        app.terminate()
        let reply = stressReply("six")
        try finishTurn(matching: ask, asked: ask, reply: reply)
        app = XCUIApplication()
        app.launchArguments = ["-HQPagesHUDSeconds", "6"] + Self.look
        openContractChatLink()
        _ = app.wait(for: .runningForeground, timeout: 15)
        assertLandsOnReply(reply, asked: ask, name: "stress-6-cold", timeout: 30)
    }

    // MARK: Helpers

    /// A long reply (taller than the screen) whose first line is the one to read.
    private func stressReply(_ tag: String) -> String {
        "FIRSTLINE-\(tag): Ivy replied this morning and signed the contract.\n\n"
            + (1...14).map { "Detail \($0): the signed copy is in Contracts, page \($0) initialled, nothing more needed from you on this part." }
                .joined(separator: "\n\n")
            + "\n\nLASTLINE-\(tag): I ticked the step and closed the nudge."
    }

    @MainActor private func openContractAndSend(_ words: String) {
        app = launchSignedIn(Self.look + ["-HQPagesTab", "4", "-HQPagesMore", "tasks",
                                          "-HQPagesOpenTask", "Follow up with Ivy on the contract"])
        let message = app.buttons["task.message"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 20), "the task opens with its message box")
        message.tap()
        let field = app.textViews["composer.text"].firstMatch
        // A tap the page didn't take yet (it was still settling on a loaded machine) is tried once more.
        if !field.waitForExistence(timeout: 5), message.exists { message.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the chat's box")
        field.typeText(words)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        if !waitUntil(3, { (field.value as? String) != words }), send.exists { send.tap() }
        XCTAssertTrue(waitUntil(10) { self.stressPrompts().contains { $0.contains(words) } }, "sent: \(stressPrompts())")
    }

    /// The bot's turn ends: the asked words and the reply go into the chat's history (as Hermes keeps them), and the
    /// reply streams and completes on the socket.
    private func finishTurn(matching: String, asked: String, reply: String) throws {
        try account.control("/__fixture/append", ["session_id": "20261104_090000_tcsam01", "role": "user", "text": asked])
        try account.control("/__fixture/turn-end", ["match": matching, "text": reply])
    }

    @MainActor private func openContractChatLink() {
        let scheme = ProcessInfo.processInfo.environment["HQN_URL_SCHEME"].flatMap { $0.isEmpty ? nil : $0 } ?? "hermeshq-native"
        XCUIDevice.shared.system.open(URL(string: "\(scheme)://session/20261104_090000_tcsam01")!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
    }

    /// The promise: the task's bar, the chat on show, the reply's FIRST line in sight between the bar and the composer.
    @MainActor private func assertLandsOnReply(_ reply: String, asked: String, name: String, viaAlert: Bool = true,
                                               timeout: TimeInterval = 15) {
        let tag = String(reply.prefix(while: { $0 != ":" }))
        let bar = app.descendants(matching: .any)["task.bar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: timeout), "\(name): the task, as its bar")
        let title = app.descendants(matching: .any)["chat.title"].firstMatch
        XCTAssertTrue(waitUntil(5) { title.exists && title.label.hasPrefix("Follow up with Ivy on the contract") },
                      "\(name): the task's name on top: \(title.exists ? title.label : "none")")
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", tag)).firstMatch
        let landed = waitUntil(10) { first.exists }
        shot(name)
        XCTAssertTrue(landed, "\(name): the reply is in the chat")
        // Where its first line is: under the bar, above the composer.
        let field = app.textViews["composer.text"].firstMatch
        let top = bar.frame.maxY, bottom = field.exists ? field.frame.minY : app.frame.maxY
        let cellTop = first.frame.minY
        measured("\(name): bar foot \(top), composer top \(bottom), reply frame \(first.frame)")
        XCTAssertTrue(cellTop >= top - 1 && cellTop + 20 <= bottom,
                      "\(name): the reply's first line is in sight (reply starts at \(cellTop), room \(top)…\(bottom))")
        let mine = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", asked)).firstMatch
        XCTAssertTrue(mine.exists, "\(name): what you asked is there too")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "chat.title").count, 1, "\(name): one chat on show")
        _ = viaAlert
    }

    private func stressPrompts() -> [String] {
        let state = (try? account.control("/__fixture/state")) ?? [:]
        return ((state["rpc"] as? [[String: Any]]) ?? []).filter { ($0["method"] as? String) == "prompt.submit" }
            .compactMap { ($0["params"] as? [String: Any])?["text"] as? String }
    }
}
