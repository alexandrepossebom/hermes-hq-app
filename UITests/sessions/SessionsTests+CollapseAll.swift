// [sessions-collapse] Every section on the Sessions page folds, in every view (owner 2026-11-11: "I want to be able to
// collapse all of the categories on the sessions page for every view"). Group By Recent: Pinned and Recent's days; the Projects
// side: "Projects" (every project at once, to one closed "Projects" header); kept across launches.

import XCTest

extension SessionsTests {
    /// The open "Projects" caption over the first project (a tap closes every project).
    @MainActor func projectsCaption(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["sessions.projects.caption"].firstMatch
    }

    @MainActor func test99_RecentSectionsAllFold() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-release").waitForExistence(timeout: 15), "the pinned chat")
        Thread.sleep(forTimeInterval: 1)
        shot(app, "collapse-all-1-open")

        // Pinned closes to its name, count and chevron (no See All under it).
        let pinned = header(app, "Pinned")
        XCTAssertTrue(pinned.waitForExistence(timeout: 5))
        pinned.tap()
        XCTAssertTrue(waitUntil(5) { !self.row(app, "s-release").exists }, "Pinned closed")
        XCTAssertTrue((header(app, "Pinned").value as? String)?.hasPrefix("Collapsed") == true, "\(header(app, "Pinned").value ?? "")")
        XCTAssertFalse(app.buttons["sessions.seeAll.pinned"].exists, "no See All on a closed Pinned")

        // [sessions-shape] Recent's days close too, each on its own.
        let days = ["Today", "Yesterday", "This Week", "Older"]
        func open(_ app: XCUIApplication) -> [String] {
            days.filter { self.header(app, $0).exists && (self.header(app, $0).value as? String)?.hasPrefix("Expanded") == true }
        }
        XCTAssertTrue(waitUntil(5) { !open(app).isEmpty }, "Recent's days (\(headers(app)))")
        for day in open(app) {
            header(app, day).tap()
            XCTAssertTrue(waitUntil(5) { !open(app).contains(day) }, "\(day) closed")
        }
        XCTAssertTrue(waitUntil(5) { self.order(app).isEmpty }, "no rows left (\(order(app)))")
        shot(app, "collapse-all-2-closed")

        // Kept across launches.
        app.terminate()
        let again = launch(keepView: true)
        XCTAssertTrue(header(again, "Today").waitForExistence(timeout: 15))
        XCTAssertTrue((header(again, "Pinned").value as? String)?.hasPrefix("Collapsed") == true)
        XCTAssertTrue(open(again).isEmpty, "every day still closed (\(headers(again)))")

        // Each opens again.
        header(again, "Pinned").tap()
        XCTAssertTrue(row(again, "s-release").waitForExistence(timeout: 5), "Pinned open again")
        header(again, "Today").tap()
        XCTAssertTrue(waitUntil(5) { open(again) == ["Today"] }, "Today open again")

        // [three-piles] The projects are the switch's other side: there "Projects" closes every project to one header.
        again.buttons["sessions.pills.projects"].tap()
        XCTAssertTrue(again.buttons["sessions.pills.bots"].waitForExistence(timeout: 8))
        let caption = projectsCaption(again)
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "the Projects caption")
        // On the word itself (the element's frame reaches up into the break above it).
        caption.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.75)).tap()
        let projects = header(again, "Projects")
        XCTAssertTrue(waitUntil(5) { projects.exists && (projects.value as? String)?.hasPrefix("Collapsed") == true },
                      "Projects closed (\(headers(again)))")
        XCTAssertFalse(headers(again).contains { $0.hasPrefix("Website") }, "no project rows under a closed Projects")
        XCTAssertTrue(projects.label.contains("project"), "it counts projects: \(projects.label)")

        projects.tap()
        XCTAssertTrue(projectsCaption(again).waitForExistence(timeout: 5), "Projects open again")
    }
}
