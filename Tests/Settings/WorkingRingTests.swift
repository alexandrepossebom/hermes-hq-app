import Foundation
import Testing
@testable import HermesHQNative

/// [working-ring] Settings › Appearance › Working Ring (owner 2026-11-15: "a toggle to be able to remove the animation
/// that goes around a bot or session to show it's working").
@Suite(.serialized) struct WorkingRingTests {
    private func keeping(_ body: () -> Void) {
        let before = UserDefaults.standard.object(forKey: WorkingRing.key)
        defer {
            if let before { UserDefaults.standard.set(before, forKey: WorkingRing.key) } else { UserDefaults.standard.removeObject(forKey: WorkingRing.key) }
        }
        body()
    }

    @Test func isOnUntilTurnedOffAndTellsTheLists() {
        keeping {
            UserDefaults.standard.removeObject(forKey: WorkingRing.key)
            #expect(WorkingRing.isOn, "on by default")
            var told = 0
            let token = NotificationCenter.default.addObserver(forName: WorkingRing.didChange, object: nil, queue: nil) { _ in told += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            WorkingRing.isOn = false
            WorkingRing.isOn = false
            #expect(!WorkingRing.isOn)
            #expect(UserDefaults.standard.object(forKey: WorkingRing.key) as? Bool == false)
            #expect(told == 1, "told once, not again for the same value")
            WorkingRing.isOn = true
            #expect(WorkingRing.isOn && told == 2)
            #expect(UserDefaults.standard.object(forKey: WorkingRing.key) == nil, "on, the default, is stored as nothing")
            UserDefaults.standard.set("nope", forKey: WorkingRing.key)
            #expect(WorkingRing.isOn, "a value that is not a Bool reads as the default")
        }
    }

    @Test func travelsWithTheOtherAppearanceSettings() {
        #expect(SyncedSettingKeys.settings.contains(WorkingRing.key))
        #expect(SyncedSettingKeys.synced(WorkingRing.key, accountId: "", library: false) == WorkingRing.key)
    }

    @Test func offTakesTheRingFromBotsAndChatsButNotTheirWorkingWords() {
        var bot = Bot(id: "otto", name: "Otto", role: nil, preview: "Earlier", lastActive: nil, isWorking: true, unread: false,
                      pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: "c", head: nil)
        #expect(BotList.showsArc(bot, ring: true))
        #expect(!BotList.showsArc(bot, ring: false))
        #expect(BotList.secondLine(bot).text == "Working…", "the row still says it works")
        #expect(BotList.rowBadge(bot) == .working, "and the face keeps its working dots")
        bot.isWorking = false
        #expect(!BotList.showsArc(bot, ring: true), "an idle bot never wears it")

        var session = SessionSummary(id: "s", profile: "otto", title: "Pricing", preview: "Earlier", lastActive: nil,
                                     source: nil, unread: false, isRunning: true)
        session.status = .working
        #expect(SessionRowView.showsArc(session, busy: false, ring: true))
        #expect(!SessionRowView.showsArc(session, busy: false, ring: false))
        #expect(SessionRowWords.detailText(session, detail: []) == "Working…", "the chat's row still says it works")
    }

    @Test func theSwitchFollowsTheStoredValue() {
        keeping {
            let bot = Bot(id: "otto", name: "Otto", role: nil, preview: nil, lastActive: nil, isWorking: true, unread: false,
                          pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: "c", head: nil)
            WorkingRing.isOn = false
            #expect(!BotList.showsArc(bot), "the default reads the switch")
            WorkingRing.isOn = true
            #expect(BotList.showsArc(bot))
        }
    }

    @Test func isFoundInSettingsSearch() {
        func find(_ words: String) -> [SettingsSearchEntry] { SettingsSearch.results(words, in: SettingsSearch.appRows) }
        for words in ["working ring", "Working Ring", "working animation", "ring"] {
            #expect(find(words).first?.target == .root("theme"), "\(words): it opens the Theme page")
        }
        #expect(find("working ring").first?.context == "Theme", "it says which page it is on")
    }
}
