// [bot voices] E31 (owner 2026-11-21: "choose a voice for each bot"): Bot Info › Settings › Voice lists the live engine's
// voices for that bot and saves a pick for it alone, and Settings › Voice asks before a pick for all bots writes over a
// voice a bot was given.

import XCTest

extension TalkEndToEndTests {
    @MainActor func testE31_ABotsOwnVoice() throws {
        // Each bot has its own record, as Hermes' profiles do; every bot starts on Cedar.
        try account.control("/__fixture/voice", ["liveAvailable": true, "schemaVoice": true, "botConfigs": [String: Any](),
                                                 "voiceConfig": ["voice": ["gpt_live": ["voice": "cedar"]]]])
        // Pinned for the test (the argument domain wins over a save): this device talks with GPT-Live.
        let engine = ["-hq.voice.engine", "gpt-live"]
        var app = launch(engine)
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        holdMenu(app, row, "Bot Info").tap()
        XCTAssertTrue(app.staticTexts["bot-info.name"].waitForExistence(timeout: 6), "Bot Info opens")
        app.botInfoTab("Settings")
        let voice = app.buttons["bot-info.voice"]
        XCTAssertTrue(app.botInfoReveal(voice), "Bot Info › Settings has a Voice row")
        XCTAssertTrue(waitUntil(timeout: 8) { voice.label.contains("Cedar") }, "it names Ivy's voice (\(voice.label))")
        shot(app, "E31-bot-info-voice-row")

        // The list, with Ivy's voice ticked.
        voice.tap()
        let quartz = app.buttons["bot-voice.quartz"], cedar = app.buttons["bot-voice.cedar"]
        XCTAssertTrue(quartz.waitForExistence(timeout: 8), "GPT-Live's voices are listed for Ivy")
        XCTAssertTrue(cedar.waitForExistence(timeout: 3) && cedar.isSelected, "Cedar is ticked")
        XCTAssertFalse(quartz.isSelected)
        XCTAssertFalse(app.buttons["bot-voice.custom"].exists, "Cedar is on the list")
        shot(app, "E31-bot-voice-list")

        // A pick is Ivy's alone, and nothing but the voice is written.
        quartz.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { quartz.isSelected }, "Quartz is ticked")
        var profiles: [String] = []
        _ = waitUntil(timeout: 8) {
            profiles = (try? self.voiceState())?["configPutProfiles"] as? [String] ?? []
            return !profiles.isEmpty
        }
        Thread.sleep(forTimeInterval: 0.8)   // a second save would have landed by now
        profiles = (try? voiceState())?["configPutProfiles"] as? [String] ?? []
        XCTAssertEqual(profiles, ["ivy"], "only Ivy's voice changed")
        var puts = (try? voiceState())?["configPuts"] as? [[String: Any]] ?? []
        XCTAssertEqual(puts.count, 1)
        XCTAssertEqual(puts.first?.count, 1, "nothing but the voice was written: \(puts)")
        let written = (puts.first?["voice"] as? [String: Any])?["gpt_live"] as? [String: Any]
        XCTAssertEqual(written?["voice"] as? String, "quartz")
        XCTAssertEqual(written?.count, 1, "nothing but the voice was written: \(puts)")

        // ▶ plays a sample without picking it.
        let play = app.buttons["bot-voice.marin.play"]
        play.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { play.label == "Stop Marin" }, "the sample plays")
        XCTAssertTrue(quartz.isSelected, "listening did not change the pick")
        shot(app, "E31-bot-voice-picked")
        play.tap()

        // Back: the row names the new voice.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntil(timeout: 6) { voice.exists && voice.label.contains("Quartz") }, "the row names Quartz (\(voice.label))")
        shot(app, "E31-bot-info-voice-row-after")

        // Settings › Voice: a pick for all bots asks before it takes Ivy's voice away.
        app = launch(engine + ["-HQDebugOpenVoice", "conversation"], reset: false)
        let delta = app.buttons["voice.settings.voice.delta"], bossa = app.buttons["voice.settings.voice.bossa"]
        XCTAssertTrue(delta.waitForExistence(timeout: 15), "GPT-Live's voices are listed")
        XCTAssertFalse(delta.isSelected)
        delta.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "it asks first")
        XCTAssertEqual(alert.label, "Change Every Bot’s Voice?")
        XCTAssertTrue(alert.staticTexts["Ivy (Quartz) has a voice of its own."].exists, "and names Ivy: \(alert.debugDescription)")
        shot(app, "E31-settings-asks")
        XCTAssertEqual((try? voiceState())?["configPutProfiles"] as? [String], ["ivy"], "nothing is saved before the answer")

        // Keep: every bot but Ivy.
        alert.buttons["Keep Its Own Voice"].tap()
        _ = waitUntil(timeout: 10) {
            profiles = (try? self.voiceState())?["configPutProfiles"] as? [String] ?? []
            return profiles.contains("default")
        }
        Thread.sleep(forTimeInterval: 1.0)   // the other bots' saves, side by side
        profiles = (try? voiceState())?["configPutProfiles"] as? [String] ?? []
        XCTAssertTrue(profiles.contains("default"), "saved for the bots without their own voice: \(profiles)")
        XCTAssertEqual(profiles.filter { $0 == "ivy" }.count, 1, "Ivy keeps Quartz: \(profiles)")
        XCTAssertTrue(delta.isSelected, "Delta is ticked")
        puts = (try? voiceState())?["configPuts"] as? [[String: Any]] ?? []
        let voices = puts.compactMap { (($0["voice"] as? [String: Any])?["gpt_live"] as? [String: Any])?["voice"] as? String }
        XCTAssertEqual(Set(voices.dropFirst()), ["delta"], "only Delta was written: \(voices)")
        let afterKeep = profiles.count

        // Cancel: the tick goes back and nothing is saved.
        bossa.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "it asks again: Ivy still has her own")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { delta.isSelected && !bossa.isSelected }, "the tick is back on Delta")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(((try? voiceState())?["configPutProfiles"] as? [String] ?? []).count, afterKeep, "Cancel saved nothing")

        // Change All Bots: Ivy too.
        bossa.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["Change All Bots"].tap()
        _ = waitUntil(timeout: 10) {
            profiles = (try? self.voiceState())?["configPutProfiles"] as? [String] ?? []
            return profiles.filter { $0 == "ivy" }.count == 2
        }
        XCTAssertEqual(profiles.filter { $0 == "ivy" }.count, 2, "Ivy's voice changed with the rest: \(profiles)")
        XCTAssertTrue(bossa.isSelected)
        shot(app, "E31-settings-changed-all")

        // With no bot on a voice of its own, a pick asks nothing.
        delta.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { delta.isSelected })
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(alert.exists, "no question when there is nothing to lose")
    }

    /// A bot Talk uses Standard with speaks with its Text to Speech voice: the row says so and opens the bot's own page.
    @MainActor func testE31b_AStandardBotsVoiceIsItsTextToSpeech() throws {
        try account.control("/__fixture/voice", ["schemaVoice": true, "botConfigs": [String: Any]()])
        let app = launch(["-hq.voice.engine", "chained"])
        let row = app.cells["bot-row-ivy"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        holdMenu(app, row, "Bot Info").tap()
        XCTAssertTrue(app.staticTexts["bot-info.name"].waitForExistence(timeout: 6), "Bot Info opens")
        app.botInfoTab("Settings")
        let voice = app.buttons["bot-info.voice"]
        XCTAssertTrue(app.botInfoReveal(voice), "Bot Info › Settings has a Voice row")
        XCTAssertTrue(waitUntil(timeout: 8) { voice.label.contains("Text to Speech") }, "Standard: the voice is Text to Speech's (\(voice.label))")
        shot(app, "E31b-bot-info-voice-row-standard")
        voice.tap()
        XCTAssertTrue(app.navigationBars["Text to Speech"].waitForExistence(timeout: 8), "a Text to Speech page opens")
        let scope = app.descendants(matching: .any).matching(identifier: "voice.settings.bot-scope").firstMatch
        XCTAssertTrue(app.botInfoReveal(scope), "and it is Ivy's own")
        XCTAssertEqual(scope.label, "These Text to Speech settings are Ivy’s own.")
        XCTAssertFalse(app.buttons["bot-voice.delta"].exists, "no live voices for Standard")
        shot(app, "E31b-bot-text-to-speech")
    }
}
