// [working-ledger] "The session is running and adding a skill from the marketplace but it isn't showing as running in
// the session list" (a tester, 2026-11-09): a turn another process runs (the add-on's sessions/working names it) says
// Working… on its Sessions row without the chat being opened, still does after the chat is opened and left, and stops
// when the gateway no longer names it.

import XCTest

extension SessionsTests {
    @MainActor func testUnopenedCompactedRowFollowsLiveStatus() throws {
        // The sidebar lists the newest segment; the running turn still names the middle one.
        setRow("s-trip", ["raw": ["_lineage_root_id": "trip-root", "_lineage_ids": ["trip-root", "trip-middle", "s-trip"]]])
        let app = launch()
        let trip = row(app, "s-trip")
        XCTAssertTrue(trip.waitForExistence(timeout: 15))
        XCTAssertFalse(labelOf(trip).contains("Working"))
        fixture("/__fixture/mode", ["live": ["trip-middle": "working"]])
        XCTAssertTrue(waitUntil(15) { labelOf(trip).contains("Working") }, "live start without opening the chat or emitting sessions.changed")
        shot(app, "unopened-compacted-working")
        fixture("/__fixture/mode", ["live": false])
        XCTAssertTrue(waitUntil(15) { trip.exists && !labelOf(trip).contains("Working") }, "live end on the same row")
        shot(app, "unopened-compacted-done")
    }

    @MainActor func test103_ATurnRunElsewhereSaysWorkingOnItsRow() throws {
        let app = launch()
        XCTAssertTrue(row(app, "s-trip").waitForExistence(timeout: 15))
        XCTAssertFalse(labelOf(row(app, "s-trip")).contains("Working"), labelOf(row(app, "s-trip")))
        shot(app, "ledger-1-idle")

        fixture("/__fixture/mode", ["working": ["s-trip"]])
        XCTAssertTrue(waitUntil(12) { self.labelOf(self.row(app, "s-trip")).contains("Working") },
                      "the gateway's turn shows without opening the chat (\(labelOf(row(app, "s-trip"))))")
        shot(app, "ledger-2-working")

        openChat(app, "s-trip")
        Thread.sleep(forTimeInterval: 1.5)
        backToList(app)
        XCTAssertTrue(waitUntil(8) { self.labelOf(self.row(app, "s-trip")).contains("Working") },
                      "still Working… after the chat was opened and left (\(labelOf(row(app, "s-trip"))))")

        fixture("/__fixture/mode", ["working": NSNull()])
        XCTAssertTrue(waitUntil(12) { !self.labelOf(self.row(app, "s-trip")).contains("Working") },
                      "it ends when the gateway's turn does (\(labelOf(row(app, "s-trip"))))")
        shot(app, "ledger-3-done")
    }
}
