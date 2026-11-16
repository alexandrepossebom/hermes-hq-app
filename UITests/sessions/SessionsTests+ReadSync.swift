// [read-sync] Read and unread follow the person's other device, and a chat this app isn't attached to says when it
// waits for them. The other device is the fixture's `/__fixture/read` (it stamps the read watermark exactly as its
// `PATCH /api/sessions/{id} {"unread": …}` does, and says `sessions.changed`); the gateway's live-session registry is
// `/__fixture/mode {"live": …}`. Run: HQN_SESSIONS_ONLY=test110_ReadStateFollowsTheOtherDevice scripts/e2e-sessions.sh SIM PORT

import CryptoKit
import XCTest

extension SessionsTests {
    /// The fixture's id for a bot's own chat (`bot_chat_id` in scripts/fixtures/sessions-gateway.py).
    func botChatId(_ profile: String) -> String {
        let digest = SHA256.hash(data: Data(profile.utf8)).map { String(format: "%02x", $0) }.joined()
        return "20261009_090000_bc" + digest.prefix(6)
    }

    /// Everything VoiceOver could read in a cell, joined.
    @MainActor func words(_ cell: XCUIElement) -> String {
        guard cell.exists else { return "" }
        let inner = cell.descendants(matching: .any).matching(NSPredicate(format: "label != ''")).allElementsBoundByIndex.map(\.label)
        return ([cell.label] + inner).joined(separator: " | ")
    }

    @MainActor func test110_ReadStateFollowsTheOtherDevice() throws {
        let app = launch()
        let trip = row(app, "s-trip")
        XCTAssertTrue(trip.waitForExistence(timeout: 15))
        XCTAssertFalse(labelOf(trip).contains("Unread"), "starts read (\(labelOf(trip)))")

        // Marked unread on the other device: it shows here. Read there: it goes here.
        fixture("/__fixture/read", ["id": "s-trip", "unread": true])
        XCTAssertTrue(waitUntil(40) { labelOf(trip).contains("Unread") }, "Mark as Unread made elsewhere shows (\(labelOf(trip)))")
        shot(app, "readsync-1-marked-unread-elsewhere")
        fixture("/__fixture/read", ["id": "s-trip", "unread": false])
        XCTAssertTrue(waitUntil(40) { !labelOf(trip).contains("Unread") }, "a read made elsewhere clears it (\(labelOf(trip)))")

        // A reply lands in a chat nobody ever read on the gateway (no watermark): unread here by this device's own
        // count. Read on the other device: this device's own dot goes too.
        let garden = row(app, "s-garden")
        setRow("s-garden", ["message_count": 9, "last_active": nowSeconds - 2], event: true)
        XCTAssertTrue(waitUntil(40) { labelOf(garden).contains("Unread") }, "new rows past this device's count (\(labelOf(garden)))")
        fixture("/__fixture/read", ["id": "s-garden", "unread": false])
        XCTAssertTrue(waitUntil(40) { !labelOf(garden).contains("Unread") }, "read elsewhere: the device's own dot goes (\(labelOf(garden)))")
        shot(app, "readsync-2-read-elsewhere")

        // The same in a third chat, read here by opening it: the gateway is told, though it never called the chat unread.
        let recipes = row(app, "s-recipes")
        setRow("s-recipes", ["message_count": 9, "last_active": nowSeconds - 2], event: true)
        XCTAssertTrue(waitUntil(40) { labelOf(recipes).contains("Unread") }, "(\(labelOf(recipes)))")
        XCTAssertTrue(writes("PATCH", "/api/sessions/s-recipes").isEmpty)
        recipes.tap()
        XCTAssertTrue(waitUntil(20) { self.writes("PATCH", "/api/sessions/s-recipes").contains { $0["unread"] as? Bool == false } },
                      "opening it writes the read for the other device")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(recipes.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(10) { !labelOf(recipes).contains("Unread") })

        // A chat this app never opened waits for the person, by the gateway's own word: its row says so.
        fixture("/__fixture/mode", ["live": ["s-trip": "waiting", botChatId("research"): "waiting"]])
        fixture("/__fixture/burst", ["count": 1, "interval": 0.1])
        XCTAssertTrue(waitUntil(60) { labelOf(trip).contains("Needs your input") || labelOf(trip).contains("Waiting") },
                      "the waiting chat's row says so (\(labelOf(trip)))")
        shot(app, "readsync-3-waiting-session")

        // The bots: Research's row says it waits for you, though its chat was never opened here.
        app.tabBars.buttons["Bots"].tap()
        let research = app.cells["bot-row-research"]
        XCTAssertTrue(research.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(60) { words(research).contains("Waiting for you") }, "the bot waits (\(words(research)))")
        shot(app, "readsync-4-waiting-bot")
        fixture("/__fixture/mode", ["live": false])
        fixture("/__fixture/burst", ["count": 1, "interval": 0.1])
        XCTAssertTrue(waitUntil(60) { !words(research).contains("Waiting for you") }, "answered elsewhere: the cue goes (\(words(research)))")

        // Its chat marked unread on the other device shows here (found by the read of every bot's watermark, at most
        // every two minutes), and a read there clears it within seconds.
        XCTAssertFalse(words(research).contains("Unread"), "(\(words(research)))")
        fixture("/__fixture/read", ["id": botChatId("research"), "unread": true])
        XCTAssertTrue(waitUntil(200) { words(research).contains("Unread") }, "the bot's Mark as Unread made elsewhere shows (\(words(research)))")
        shot(app, "readsync-5-bot-unread-elsewhere")
        fixture("/__fixture/read", ["id": botChatId("research"), "unread": false])
        XCTAssertTrue(waitUntil(40) { !words(research).contains("Unread") }, "read elsewhere: the bot's dot goes (\(words(research)))")
        shot(app, "readsync-6-bot-read-elsewhere")
    }
}
