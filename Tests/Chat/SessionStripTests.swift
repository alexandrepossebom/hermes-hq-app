import Foundation
import Testing
@testable import HermesHQNative

// [session-strip] Which of a bot's chats the strip under a chat's bar shows, in what order, and what each pill says.

@Suite("Session strip: a bot's chats under the bar")
struct SessionStripTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func bot(working: Bool = false, unread: Bool = false, canonical: String? = "bc") -> Bot {
        Bot(id: "hermes-hq", name: "Hermes HQ", role: nil, preview: nil, lastActive: now, isWorking: working, unread: unread,
            pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: canonical, head: nil)
    }

    func chat(_ id: String, ago: TimeInterval, profile: String = "hermes-hq", source: String? = "desktop", unread: Bool = false,
              running: Bool = false, archived: Bool = false, pinned: Bool = false) -> SessionSummary {
        var row = SessionSummary(id: id, profile: profile, title: "Chat \(id)", preview: nil, lastActive: now.addingTimeInterval(-ago),
                                 source: source, unread: unread, isRunning: running)
        row.archived = archived
        row.pinned = pinned
        return row
    }

    func entries(_ sessions: [SessionSummary], bot: Bot? = nil, current: String? = nil, onBotChat: Bool = false) -> [SessionStripEntry] {
        SessionStripRules.entries(bot: bot ?? self.bot(), sessions: sessions, profile: "hermes-hq", currentId: current,
                                  onBotChat: onBotChat, now: now)
    }

    @Test("The bot's own chat comes first, then its chats newest first")
    func order() {
        let shown = entries([chat("old", ago: 3600), chat("new", ago: 60), chat("mid", ago: 600)], current: "mid")
        #expect(shown.map(\.id) == ["bc", "new", "mid", "old"])
        #expect(shown[0].isBotChat && shown[0].title == "Hermes HQ")
        #expect(shown.filter(\.current).map(\.id) == ["mid"])
    }

    @Test("Only this bot's live chats: not another bot's, an archived one, a job's run, a tool's, or its own Bot Chat twice")
    func which() {
        let shown = entries([chat("mine", ago: 60), chat("theirs", ago: 60, profile: "ivy"), chat("gone", ago: 60, archived: true),
                             chat("job", ago: 60, source: "cron"), chat("tool", ago: 60, source: "tool"), chat("bc", ago: 30)],
                            current: "mine")
        #expect(shown.map(\.id) == ["bc", "mine"])
    }

    @Test("A chat older than a day shows only while it works, waits unread, is pinned, or is the one on screen")
    func active() {
        let day: TimeInterval = 86_400
        let shown = entries([chat("stale", ago: 3 * day), chat("busy", ago: 3 * day, running: true),
                             chat("unread", ago: 3 * day, unread: true), chat("pinned", ago: 3 * day, pinned: true),
                             chat("here", ago: 9 * day)], current: "here")
        #expect(Set(shown.map(\.id)) == ["bc", "busy", "unread", "pinned", "here"])
    }

    @Test("A chat already shown stays a pill after you've read it and moved on, though it is older than a day")
    func kept() {
        let day: TimeInterval = 86_400
        let read = chat("read", ago: 2 * day)
        #expect(!entries([read, chat("here", ago: 60)], current: "here").map(\.id).contains("read"))
        let shown = SessionStripRules.entries(bot: bot(), sessions: [read, chat("here", ago: 60)], profile: "hermes-hq",
                                              currentId: "here", onBotChat: false, kept: ["read"], now: now)
        #expect(shown.map(\.id) == ["bc", "here", "read"])
    }

    @Test("Working and New marks; the chat on screen is never marked New")
    func marks() {
        let shown = entries([chat("busy", ago: 60, running: true), chat("reply", ago: 120, unread: true),
                             chat("here", ago: 180, unread: true)], current: "here")
        let by = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, $0) })
        #expect(by["busy"]?.working == true && by["busy"]?.unread == false)
        #expect(by["reply"]?.unread == true)
        #expect(by["here"]?.unread == false && by["here"]?.current == true)
    }

    @Test("On the bot's own chat its pill is lit and not New; the bot's working shows on it")
    func botChat() {
        let shown = entries([chat("a", ago: 60)], bot: bot(working: true, unread: true), onBotChat: true)
        #expect(shown[0].current && shown[0].working && !shown[0].unread)
        #expect(shown.filter(\.current).count == 1)
    }

    @Test("At most eight pills, and the chat on screen is kept even when it is the oldest")
    func cap() {
        let many = (0..<12).map { chat("c\($0)", ago: TimeInterval(60 * ($0 + 1))) }
        let shown = entries(many, current: "c11")
        #expect(shown.count == SessionStripRules.most + 1)
        #expect(shown.last?.id == "c11" && shown.last?.current == true)
        #expect(entries(many, current: "c0").count == SessionStripRules.most)
    }

    @Test("\"default\" and an empty profile are the same bot")
    func defaultBot() {
        let main = Bot(id: "default", name: "Hermes", role: nil, preview: nil, lastActive: now, isWorking: false, unread: false,
                       pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: nil, head: nil)
        let shown = SessionStripRules.entries(bot: main, sessions: [chat("x", ago: 60, profile: "")], profile: "default",
                                              currentId: "x", onBotChat: false, now: now)
        #expect(shown.map(\.id) == ["", "x"])
    }

    // [bot-chat-sessions] The Mac: the strip holds only what is live; the Chats tab lists every chat, in groups.

    @Test("The Mac's strip leaves out a chat that was only touched in the last day: working, unread, pinned, on screen or gone through this run")
    func slim() {
        let chats = [chat("recent", ago: 600), chat("busy", ago: 900, running: true), chat("unread", ago: 1200, unread: true),
                     chat("pinned", ago: 1800, pinned: true), chat("here", ago: 2400), chat("seen", ago: 3000)]
        let shown = SessionStripRules.entries(bot: bot(), sessions: chats, profile: "hermes-hq", currentId: "here", onBotChat: false,
                                              kept: ["seen"], recent: false, now: now)
        #expect(shown.map(\.id) == ["bc", "busy", "unread", "pinned", "here", "seen"])
        #expect(entries(chats, current: "here").map(\.id).contains("recent"))
    }

    @Test("Every chat of the bot's, newest first: not another bot's, an archived one, a job's run, a tool's or its own Bot Chat")
    func every() {
        let all = SessionStripRules.chats(bot: bot(), sessions: [chat("old", ago: 9 * 86_400), chat("new", ago: 60),
                                                                 chat("theirs", ago: 60, profile: "ivy"), chat("gone", ago: 60, archived: true),
                                                                 chat("job", ago: 60, source: "cron"), chat("tool", ago: 60, source: "tool"),
                                                                 chat("bc", ago: 30)], profile: "hermes-hq")
        #expect(all.map(\.id) == ["new", "old"])
    }

    @Test("The Chats tab's groups: Working, Pinned, Today, Yesterday, Earlier, each chat in the first that fits, empty ones left out")
    func groups() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = calendar.startOfDay(for: now).addingTimeInterval(12 * 3600)
        func at(_ id: String, hours: Double, running: Bool = false, pinned: Bool = false) -> SessionSummary {
            var row = SessionSummary(id: id, profile: "hermes-hq", title: id, preview: nil, lastActive: noon.addingTimeInterval(-hours * 3600),
                                     source: "desktop", unread: false, isRunning: running)
            row.pinned = pinned
            return row
        }
        let chats = [at("morning", hours: 3), at("busy", hours: 30, running: true), at("pinned-busy", hours: 31, running: true, pinned: true),
                     at("yesterday", hours: 20), at("pinned", hours: 200, pinned: true), at("last-week", hours: 170)]
        let groups = SessionStripRules.groups(chats, now: noon, calendar: calendar)
        #expect(groups.map(\.title) == ["Working", "Pinned", "Today", "Yesterday", "Earlier"])
        #expect(groups.map { $0.chats.map(\.id) } == [["busy", "pinned-busy"], ["pinned"], ["morning"], ["yesterday"], ["last-week"]])
        #expect(SessionStripRules.groups([at("morning", hours: 3)], now: noon, calendar: calendar).map(\.title) == ["Today"])
        #expect(SessionStripRules.groups([], now: noon, calendar: calendar).isEmpty)
    }
}
