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
            #expect(!WorkingRing.isOn, "[ring-off-default] off by default")
            var told = 0
            let token = NotificationCenter.default.addObserver(forName: WorkingRing.didChange, object: nil, queue: nil) { _ in told += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            WorkingRing.isOn = true
            WorkingRing.isOn = true
            #expect(WorkingRing.isOn)
            #expect(UserDefaults.standard.object(forKey: WorkingRing.key) as? Bool == true)
            #expect(told == 1, "told once, not again for the same value")
            WorkingRing.isOn = false
            #expect(!WorkingRing.isOn && told == 2)
            #expect(UserDefaults.standard.object(forKey: WorkingRing.key) as? Bool == false,
                    "off is stored too: an older build reads nothing stored as on")
            UserDefaults.standard.set("nope", forKey: WorkingRing.key)
            #expect(!WorkingRing.isOn, "a value that is not a Bool reads as the default")
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

    /// Owner 2026-11-15: "There could be places where the working animation was the only thing that showed that the
    /// session or bot was working … find a solution to show that they're still working." With the ring off, the
    /// working dots go where the row's own words do not say it.
    @Test func ringOffPutsTheDotsWhereNoWordsSayItWorks() {
        func dots(ringOn: Bool = false, arc: Bool = true, card: Bool = false, fresh: SessionRowView.Fresh? = nil,
                  compact: Bool = false, large: Bool = false, snippet: String? = nil) -> Bool {
            SessionRowView.showsWorkingDots(ringOn: ringOn, arc: arc, card: card, fresh: fresh, compact: compact, large: large, snippet: snippet)
        }
        // Rows with nothing but the ring to say it: Pinned's one line (both groupings), and a search match.
        #expect(dots(compact: true), "Pinned's one-line row")
        #expect(dots(fresh: .pinned), "Group By Recent's Pinned row")
        #expect(dots(snippet: "the **fourth** hotel"), "a search result: its second line is the match")
        // Rows whose words say "Working…" already.
        #expect(!dots(), "a full row's second line says Working…")
        #expect(!dots(snippet: ""), "an empty match leaves Working… on the line")
        #expect(!dots(fresh: .recent), "Recent's status line")
        #expect(!dots(card: true), "a project card's status line")
        #expect(!dots(compact: true, large: true), "Pinned at the accessibility sizes keeps the full row")
        // The ring on, or nothing working (or waiting on you, or being deleted: `showsArc` false): no dots.
        #expect(!dots(ringOn: true, compact: true))
        #expect(!dots(arc: false, compact: true))
    }

    @Test func aPinnedTileTryingAgainShowsItWorksOverItsProblem() {
        var bot = Bot(id: "otto", name: "Otto", role: nil, preview: nil, lastActive: nil, isWorking: true, unread: false,
                      pinned: true, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: "c", head: nil)
        bot.attention = Attention.providerQuotaLimit.words
        let status = BotList.rowStatus(bot)
        #expect(status == .attention, "the problem stays until a good reply")
        #expect(BotList.tileShowsWorkingOverProblem(bot, status: status, ringOn: false))
        #expect(BotList.rowBadge(bot) == .working, "the dots it then shows")
        #expect(!BotList.tileShowsWorkingOverProblem(bot, status: status, ringOn: true), "the ring says it")
        bot.isWorking = false
        #expect(!BotList.tileShowsWorkingOverProblem(bot, status: BotList.rowStatus(bot), ringOn: false), "idle: the orange badge")
    }

    @Test func isFoundInSettingsSearch() {
        func find(_ words: String) -> [SettingsSearchEntry] { SettingsSearch.results(words, in: SettingsSearch.appRows) }
        for words in ["working ring", "Working Ring", "working animation", "ring"] {
            #expect(find(words).first?.target == .root("row:working-ring"), "\(words): it opens Appearance on its row")
        }
        #expect(find("working ring").first?.context == "Appearance", "it says which page it is on")
    }
}
