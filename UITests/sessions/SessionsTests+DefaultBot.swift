import XCTest

/// [project-default-bot] Owner 2026-11-17: "a project should be able to have a default bot and an easier way to start a
/// new session once you are inside the project."
extension SessionsTests {
    /// On a project's page Compose names the default bot (Website's only bot, Hermes) and starts the chat with it, with
    /// no sheet. The header's ⋯ › New Chat With… opens the chooser (Hermes says Default); a hold on Research there makes
    /// it the default, and Compose then starts Research's chat in the project.
    @MainActor func test40f_ProjectDefaultBot() throws {
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let toProjects = app.buttons["sessions.pills.projects"]
        XCTAssertTrue(toProjects.waitForExistence(timeout: 15))
        toProjects.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        let website = app.buttons["sessions.chip.project.0"]
        XCTAssertTrue(website.waitForExistence(timeout: 6))
        onScreen(app, website).tap()
        XCTAssertTrue(app.cells["sessions.projectPage"].waitForExistence(timeout: 6))
        let compose = app.buttons["sessions.compose"]
        XCTAssertEqual(compose.label, "New Chat in Website with Hermes", "Website's only bot is its default")
        shot(app, "T1-project-page")
        let more = app.buttons["sessions.projectPage.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the header's ⋯")
        more.tap()
        let with = app.buttons["New Chat With…"]
        XCTAssertTrue(with.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sessions.projectPage.defaultBot"].exists || app.buttons["Default Bot"].exists, "Default Bot")
        shot(app, "T2-project-menu")
        with.tap()
        let hermes = app.buttons["choose-bot-default"], research = app.buttons["choose-bot-research"]
        XCTAssertTrue(hermes.waitForExistence(timeout: 5), "New Chat With… opens the chooser")
        XCTAssertTrue(waitUntil(4) { hermes.label.contains("Default") }, "Hermes says Default (\(hermes.label))")
        Thread.sleep(forTimeInterval: 1)
        shot(app, "T3-chooser")
        research.press(forDuration: 1.0)
        let make = app.buttons["Make Default for Website"]
        XCTAssertTrue(make.waitForExistence(timeout: 5), "a hold offers Make Default")
        shot(app, "T4-make-default")
        make.tap()
        XCTAssertTrue(waitUntil(5) { research.label.contains("Default") && !hermes.label.contains("Default") }, "Research is the default")
        shot(app, "T5-chooser-research-default")
        // The sheet goes; Compose now names Research and starts its chat in the project with no sheet.
        app.navigationBars["New Chat"].buttons.firstMatch.tap()
        XCTAssertTrue(waitUntil(6) { !research.exists && compose.label == "New Chat in Website with Research" }, "Compose says so (\(compose.label))")
        compose.tap()
        XCTAssertTrue(waitUntil(10) {
            self.rpc("session.create").contains { $0["cwd"] as? String == "/home/hermes/site" && $0["profile"] as? String == "research" }
        }, "session.create for Research in Website's folder (\(rpc("session.create")))")
        XCTAssertFalse(app.buttons["choose-bot-default"].exists, "no chooser")
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10), "the new chat opens")
        shot(app, "T6-chat-open")
    }
}
