import XCTest

/// [projects-all-bots] Owner 2026-11-22: "I just created a new project … and I can't see it in my list." The Projects
/// side read only the projects of bots with a chat on the loaded page, and read them again at most once a minute, so a
/// project made in another app (the desktop) on a quieter bot never showed, and a new one on any bot waited a minute.
extension SessionsTests {
    /// A fourth bot, Atlas, has no chat in the list, only a project made elsewhere (Side Gig): its pill is on the
    /// Projects side from the start, and its row is in the list though no chat is in it. Then the desktop makes another
    /// (Launch Plan): one pull to refresh shows it.
    @MainActor func test40w_EveryBotsProjects() throws {
        fixture("/__fixture/mode", ["bots": 4])                       // Atlas: its own Bot Chat, nothing listed
        fixture("/__fixture/projects", ["profile": "atlas",
                                        "add": ["id": "p_sidegig", "label": "Side Gig", "path": "/Users/demo/sidegig"]])
        let app = launch(projectPages: true)
        XCTAssertTrue(row(app, "s-garden").waitForExistence(timeout: 15))
        let toProjects = app.buttons["sessions.pills.projects"], toBots = app.buttons["sessions.pills.bots"]
        XCTAssertTrue(toProjects.waitForExistence(timeout: 15), "the switch")
        XCTAssertFalse(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-' AND label CONTAINS 'Atlas'")).firstMatch.exists,
                       "Atlas has no chat in the list")
        toProjects.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(6) { toBots.exists && !toProjects.exists }, "the Projects side")

        func pill(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.' AND label BEGINSWITH %@", name)).firstMatch
        }
        func pills() -> [String] {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.chip.project.'")).allElementsBoundByIndex
                .map { String($0.label.prefix { $0 != "," }).replacingOccurrences(of: " project", with: "") }
        }
        Thread.sleep(forTimeInterval: 2)
        shot(app, "W0-projects-side")
        XCTAssertTrue(waitUntil(10) { pill("Side Gig").exists }, "Atlas's project, though Atlas has no listed chat (\(pills()))")
        XCTAssertTrue(waitUntil(6) { ["Website", "Reading", "App"].allSatisfy { pills().contains($0) } }, "the listed bots' too (\(pills()))")
        XCTAssertTrue(rpc("projects.tree").contains { $0["profile"] as? String == "atlas" }, "Atlas was asked")
        XCTAssertTrue(waitUntil(6) { self.header(app, "Side Gig").exists }, "and its row in the list, with no chat yet (\(headers(app)))")
        shot(app, "W1-every-bots-projects")

        // The desktop makes a project on Atlas while the phone is open: no pill yet (read under a minute ago) …
        fixture("/__fixture/projects", ["profile": "atlas",
                                        "add": ["id": "p_launch", "label": "Launch Plan", "path": "/Users/demo/launch"]])
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(pill("Launch Plan").exists, "not before a read (\(pills()))")
        shot(app, "W2-made-on-the-desktop-before-pull")
        // … and one pull to refresh brings it.
        let asked = rpc("projects.tree").filter { $0["profile"] as? String == "atlas" }.count
        let list = app.collectionViews["sessions.list"]
        // A finger on the first project row, dragged well down the screen and held: the list's pull to refresh.
        let top = app.coordinate(withNormalizedOffset: .zero)
        let first = header(app, "Website").frame
        top.withOffset(CGVector(dx: first.midX, dy: first.midY))
            .press(forDuration: 0.1, thenDragTo: top.withOffset(CGVector(dx: first.midX, dy: first.midY + 420)),
                   withVelocity: .default, thenHoldForDuration: 0.6)
        _ = list
        XCTAssertTrue(waitUntil(10) { self.rpc("projects.tree").filter { $0["profile"] as? String == "atlas" }.count > asked },
                      "the pull asked Atlas again")
        XCTAssertTrue(waitUntil(10) { pill("Launch Plan").exists }, "the desktop's project after one pull (\(pills()))")
        XCTAssertTrue(waitUntil(6) { self.header(app, "Launch Plan").exists }, "its row too (\(headers(app)))")
        shot(app, "W3-after-pull")
    }
}
