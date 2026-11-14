// [task-lists] Lists that mean something, and a bot that keeps one (owner 2026-11-14, six agreed boards): a list has a
// colour and an icon, Today shows what's next in each list, a kept list says who keeps it, a bot offers a list with a
// card (nothing changes until you tap), and a task a bot added says where it came from. The fixture starts with them
// after `/__fixture/tasks-mode {"lists": true}`. Run with scripts/e2e-pages.sh (HQN_PAGES_ONLY=testTasks_Kept…);
// every look: TEST_RUNNER_HQN_TASKS_LOOK=dark | desktop | desktop-dark.

import XCTest

extension PagesTests {
    /// The fixture with its lists, and the app opened on them. The run's first launch signs in, and signing in taps
    /// "Not Now" on the password prompt, which is also an offer's own answer: so that launch happens before the lists.
    @MainActor private func launchWithLists(_ arguments: [String]) throws -> XCUIApplication {
        if !Self.freshThisRun { launchSignedIn(Self.look).terminate() }
        try account.control("/__fixture/tasks-mode", ["lists": true])
        return launchSignedIn(Self.look + arguments)
    }

    /// Today's "Next in" groups, the keeper line, Edit List, and an offer answered on the Tasks page.
    @MainActor func testTasks_KeptLists() throws {
        app = try launchWithLists(["-HQPagesTab", "4", "-HQPagesMore", "tasks"])
        let name = Self.lookName
        let any = app.descendants(matching: .any)
        let offers = { self.requests().filter { $0.method == "POST" && $0.path.contains("/tasks/offers/") } }
        let sectionsPut = { self.requests().filter { $0.method == "PUT" && $0.path.hasSuffix("/tasks/sections") } }

        XCTAssertTrue(app.buttons["tasks.view.today"].firstMatch.waitForExistence(timeout: 20), "Tasks opens")
        XCTAssertTrue(app.buttons["tasks.view.list.Work"].firstMatch.waitForExistence(timeout: 10), "with the lists as pills")
        shot("tasks-keeper-0-open" + name)

        // The offer waits at the top; nothing was added.
        let make = app.buttons["tasks.offer.Make Party & Add 4"].firstMatch
        XCTAssertTrue(make.waitForExistence(timeout: 20), "the offer's card is on the page")
        XCTAssertFalse(app.cells["task-row-Order the cake"].exists, "nothing is added before the tap")
        shot("tasks-keeper-1-offer" + name)

        // Today: what's next in each list, three at most, no dates invented, and the rest behind one row.
        let deck = app.cells["task-row-Send Wren the revised deck"].firstMatch
        for _ in 0..<5 where !deck.exists || !deck.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(deck.exists, "the list's first task is in Today")
        let more = any["tasks.more"].firstMatch
        for _ in 0..<3 where !more.exists || !more.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(more.exists, "the rest are one row")
        XCTAssertTrue(more.label.contains("3 more in Work"), more.label)
        XCTAssertFalse(app.cells["task-row-Call the print vendor back"].exists, "the fourth is not in Today")
        shot("tasks-keeper-2-today-next" + name)

        // The row opens the list, which says who keeps it.
        more.tap()
        let work = app.buttons["tasks.view.list.Work"].firstMatch
        XCTAssertTrue(waitUntil(10) { work.exists && work.isSelected }, "the list is on show")
        let keeper = any["tasks.keeper"].firstMatch
        XCTAssertTrue(keeper.waitForExistence(timeout: 5), "a kept list says so")
        XCTAssertTrue(keeper.label.hasPrefix("Kept by Hermes · checked"), keeper.label)
        XCTAssertTrue(app.cells["task-row-Call the print vendor back"].waitForExistence(timeout: 5), "with every task")
        XCTAssertFalse(make.exists, "another list's offer stays out of this list")
        shot("tasks-keeper-3-list" + name)

        // Hold the pill › Edit List…: colour, icon, who keeps it, and whether it shows in Today.
        work.press(forDuration: 0.8)
        let edit = app.buttons["Edit List…"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "the pill's menu edits the list")
        edit.tap()
        let today = any["tasks.list-edit.today"].firstMatch
        XCTAssertTrue(any["tasks.list-edit.color.orange"].firstMatch.waitForExistence(timeout: 10), "the sheet has the colours")
        shot("tasks-keeper-4-edit" + name)
        any["tasks.list-edit.color.orange"].firstMatch.tap()
        XCTAssertTrue(waitUntil(10) { sectionsPut().contains { put in
            ((put.body?["sections"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == "Work" && $0["color"] as? String == "orange" }
        } }, "the colour is saved")
        for _ in 0..<3 where !today.exists || !today.isHittable { app.swipeUp() }
        XCTAssertTrue(today.exists, "Show in Today is a switch")
        shot("tasks-keeper-4b-edit-bot" + name)
        let toggle = today.switches.firstMatch.exists ? today.switches.firstMatch : today
        toggle.tap()
        XCTAssertTrue(waitUntil(10) { sectionsPut().contains { put in
            ((put.body?["sections"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == "Work" && $0["today"] as? Bool == false }
        } }, "Show in Today off is saved")
        app.buttons["sheet.close"].firstMatch.tap()

        // Today no longer shows that list's next tasks.
        let todayPill = app.buttons["tasks.view.today"].firstMatch
        let rail = any["tasks.views"].firstMatch
        for _ in 0..<4 where !todayPill.exists || todayPill.frame.minX < 8 { rail.swipeRight() }
        todayPill.tap()
        XCTAssertTrue(make.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(5) { !deck.exists }, "a list switched off is not in Today")

        // Accept: the list is made with its tasks, and the two tasks already here are asked about.
        make.tap()
        XCTAssertTrue(waitUntil(10) { offers().contains { $0.body?["action"] as? String == "accept" } }, "the tap answers the offer")
        let party = app.buttons["tasks.view.list.Party"].firstMatch
        XCTAssertTrue(party.waitForExistence(timeout: 10), "the list is a pill")
        let move = app.buttons["tasks.offer.Move 2 to Party"].firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 10), "moving your own tasks is asked")
        shot("tasks-keeper-5-accepted" + name)
        move.tap()
        XCTAssertTrue(waitUntil(10) { offers().contains { $0.body?["action"] as? String == "move" } }, "and done on the tap")
        XCTAssertTrue(waitUntil(10) { !move.exists }, "the card goes once answered")
        let width = app.windows.firstMatch.frame.maxX
        for _ in 0..<5 where party.frame.maxX > width - 8 || party.frame.width < 20 { rail.swipeLeft() }
        party.tap()
        XCTAssertTrue(app.cells["task-row-Order the cake"].waitForExistence(timeout: 10), "the offered tasks are in it")
        XCTAssertTrue(app.cells["task-row-Mom’s birthday gift"].waitForExistence(timeout: 5), "and the moved ones")
        XCTAssertTrue(any["tasks.keeper"].firstMatch.waitForExistence(timeout: 5), "kept by the bot that offered it")
        shot("tasks-keeper-6-party" + name)
    }

    /// A task a bot added: where it came from, who watches it (in words), and an offer to close it that you answer.
    @MainActor func testTasks_KeptTaskPage() throws {
        app = try launchWithLists(["-HQPagesTab", "4", "-HQPagesMore", "tasks", "-HQPagesOpenTask", "Approve the Q1 budget sheet"])
        let name = Self.lookName
        let any = app.descendants(matching: .any)
        let source = any["task.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 20), "the task says where it came from")
        XCTAssertTrue(source.label.contains("Email") && source.label.contains("Juno"), source.label)
        let watched = any["task.watched-by"].firstMatch
        XCTAssertTrue(watched.exists, "who watches it is in words")
        XCTAssertTrue(watched.label.contains("watched by Hermes"), watched.label)
        let keep = app.buttons["task.close-offer.keep"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "the offer to close it is a card")
        XCTAssertTrue(app.buttons["task.close-offer.done"].firstMatch.exists)
        shot("tasks-keeper-7-task" + name)
        keep.tap()
        XCTAssertTrue(waitUntil(10) { self.requests().contains {
            $0.method == "PATCH" && $0.path.hasSuffix("/tasks/t_w_budget") && $0.body?["keep_open"] as? Bool == true
        } }, "Keep Open is sent")
        XCTAssertTrue(waitUntil(10) { !keep.exists }, "and the card goes")
        XCTAssertFalse(self.requests().contains {
            $0.method == "PATCH" && $0.path.hasSuffix("/tasks/t_w_budget") && $0.body?["status"] as? String == "done"
        }, "the task stays open")
    }

    /// The offer in the chat it was made in: one card, answered there, with Undo.
    @MainActor func testTasks_KeptOfferInChat() throws {
        app = try launchWithLists([])
        let name = Self.lookName
        let offers = { self.requests().filter { $0.method == "POST" && $0.path.contains("/tasks/offers/") } }
        tabButton("Sessions", in: app).tap()
        let row = app.cells["session-row-s-lists"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the party chat is listed")
        row.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 15), "the chat opens")
        let main = app.buttons["chat.offer.main"].firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 15), "the offer is a card")
        XCTAssertTrue(waitUntil(10) { main.label == "Make Party & Add 4" }, main.label)
        XCTAssertEqual(app.buttons["chat.offer.left"].firstMatch.label, "Add, No List")
        XCTAssertEqual(app.buttons["chat.offer.right"].firstMatch.label, "Not Now")
        XCTAssertTrue(offers().isEmpty, "nothing is answered before a tap")
        shot("tasks-keeper-8-chat-offer" + name)

        main.tap()
        XCTAssertTrue(waitUntil(10) { offers().contains { $0.body?["action"] as? String == "accept" } }, "the tap answers it")
        XCTAssertTrue(waitUntil(10) { main.exists && main.label == "Move 2 to Party" }, "then asks about your own two: \(main.label)")
        shot("tasks-keeper-9-chat-move" + name)
        app.buttons["chat.offer.left"].firstMatch.tap()   // Leave Them
        XCTAssertTrue(waitUntil(10) { offers().contains { $0.body?["action"] as? String == "leave" } }, "Leave Them is sent")
        let undo = app.buttons["chat.offer.right"].firstMatch
        XCTAssertTrue(waitUntil(10) { undo.exists && undo.label == "Undo" }, "what happened, with Undo")
        shot("tasks-keeper-10-chat-done" + name)
        undo.tap()
        XCTAssertTrue(waitUntil(10) { offers().contains { $0.body?["action"] as? String == "undo" } }, "Undo takes it back")
        shot("tasks-keeper-11-chat-undone" + name)
    }
}
