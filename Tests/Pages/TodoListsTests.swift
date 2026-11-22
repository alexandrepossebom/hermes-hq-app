// [task-lists] A list on the Tasks page (owner 2026-11-14, six boards, "All approved"): Inbox is what isn't filed,
// Today shows what's next in each list, a list has a colour, an icon and a bot that keeps it, a bot offers a list or
// a batch of tasks as a card, a task says where it came from, and a bot offers to close your task instead of closing it.

import Foundation
import Testing
@testable import HermesHQNative

struct TodoListsTests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()
    /// Saturday 2026-11-14, 09:41 in Chicago.
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 9, minute: 41))!

    private func task(_ id: String, who: String = "me", bot: String? = nil, status: String = "open", due: String? = nil,
                      section: String? = nil, position: Double = 0, by: String? = nil, more: [String: JSONValue] = [:]) -> TodoTask {
        var o: [String: JSONValue] = ["id": .string(id), "title": .string(id), "who": .string(who), "status": .string(status),
                                      "updated_at": "2026-11-14T08:00:00-06:00", "created_at": "2026-11-13T08:00:00-06:00",
                                      "position": .number(position)]
        if let bot { o["bot"] = .string(bot) }
        if let due { o["due"] = .string(due) }
        if let section { o["section"] = .string(section) }
        if let by { o["created_by"] = .string(by) }
        if status == "done" { o["done_at"] = "2026-11-14T08:30:00-06:00" }
        for (key, value) in more { o[key] = value }
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private var lists: [TodoUserSection] {
        [TodoUserSection(id: "work", name: "Work", color: "blue", icon: "briefcase", bot: "otto", checkedAt: "2026-11-14T08:02:00-06:00"),
         TodoUserSection(id: "home", name: "Home", color: "green")]
    }

    private func name(_ profile: String?) -> String {
        ["default": "Hermes", "otto": "Otto", "ivy": "Ivy"][profile ?? "default"] ?? (profile ?? "")
    }

    private func groups(_ tasks: [TodoTask], _ view: TodoView, lists: [TodoUserSection]? = nil) -> [TodoGroup] {
        TodoViews.groups(tasks, view: view, sections: lists ?? self.lists, bots: ["default", "otto"], now: Self.now, calendar: Self.calendar)
    }

    // MARK: Board 1: Inbox is what isn't filed

    @Test func inboxIsEveryTaskInNoListDatedOrNot() {
        let tasks = [task("loose"), task("dated", due: "2026-11-20"), task("filed", section: "work"),
                     task("orphan", section: "gone"), task("bots", who: "bot", bot: "otto")]
        let inbox = groups(tasks, .inbox)
        #expect(Set(inbox.flatMap { $0.tasks.map(\.id) }) == ["loose", "dated", "orphan"],
                "a date doesn't file a task, and a bot's own task is under Bots")
        #expect(TodoViews.openCount(tasks, view: .inbox, sections: lists, now: Self.now, calendar: Self.calendar) == 3,
                "the pill says how many are left to file")
        #expect(TodoViews.emptyText(.inbox, listName: nil) == "Nothing left to file. A task in no list lands here.")
    }

    // MARK: Board 2: a list has a colour, an icon and a bot

    @Test func aListReadsItsLookAndRules() throws {
        let full = try decode(TodoUserSection.self, #"{"id":"w","name":"Work","color":"blue","icon":"briefcase","bot":"otto","adds":"ask","today":false,"checked_at":"2026-11-14T08:02:00-06:00"}"#)
        #expect(full.color == "blue" && full.icon == "briefcase" && full.bot == "otto")
        #expect(full.asksFirst && !full.inToday)
        #expect(TodoLists.color(full) == .blue)
        // An add-on older than 0.9.55: a name alone. Nothing is invented for it.
        let plain = try decode(TodoUserSection.self, #"{"id":"h","name":"Home"}"#)
        #expect(plain.color == nil && plain.icon == nil && plain.bot == nil && !plain.asksFirst && plain.inToday)
        #expect(TodoLists.color(plain) == nil)
        #expect(TodoLists.color(TodoUserSection(id: "x", name: "X", color: "mauve")) == nil, "a colour the app doesn't know draws no dot")
    }

    /// `PUT /tasks/sections` keeps what a caller leaves out, so every field goes each time: an unset one empty.
    @Test func aListIsSavedWhole() throws {
        let saved = try JSONValue.parse(JSONEncoder().encode(TodoUserSection(id: "w", name: "Work", color: "blue", bot: "otto", asksFirst: true)))
        #expect(saved["color"]?.string == "blue" && saved["bot"]?.string == "otto")
        #expect(saved["icon"]?.string == "", "no icon: sent empty, so the gateway clears it")
        #expect(saved["adds"]?.string == "ask" && saved["today"] == .bool(true))
        let cleared = try JSONValue.parse(JSONEncoder().encode(TodoUserSection(id: "w", name: "Work")))
        #expect(cleared["color"]?.string == "" && cleared["bot"]?.string == "" && cleared["adds"]?.string == "auto")
    }

    @Test func aRowCarriesItsListsDotOutsideTheList() {
        let filed = task("filed", section: "work"), loose = task("loose"), plain = task("plain", section: "old")
        let all = lists + [TodoUserSection(id: "old", name: "Old")]
        #expect(TodoLists.dot(filed, in: .today, sections: all) == .blue)
        #expect(TodoLists.dot(filed, in: .upcoming, sections: all) == .blue)
        #expect(TodoLists.dot(filed, in: .list("work"), sections: all) == nil, "every row there is that list's")
        #expect(TodoLists.dot(filed, in: .bots, sections: all) == nil)
        #expect(TodoLists.dot(loose, in: .today, sections: all) == nil)
        #expect(TodoLists.dot(plain, in: .today, sections: all) == nil, "a list with no colour yet")
    }

    @Test func aNewListTakesTheFirstFreeColour() {
        #expect(TodoLists.nextColor([]) == .blue)
        #expect(TodoLists.nextColor(lists) == .orange, "blue and green are taken")
        let every = TodoListColor.allCases.map { TodoUserSection(id: $0.rawValue, name: $0.name, color: $0.rawValue) }
        #expect(TodoLists.nextColor(every) == .blue)
        #expect(TodoListColor.gray.name == "Gray")
        #expect(TodoListIcons.all.contains(TodoListIcons.fallback))
        #expect(TodoListIcons.spoken("briefcase") == "Briefcase" && TodoListIcons.spoken("person.2") == "People")
    }

    // MARK: Board 3: Today shows what's next in each list

    @Test func todayShowsTheNextThreeOfEachListInYourOrder() {
        let work = (1...5).map { task("w\($0)", section: "work", position: Double($0)) }
        let tasks = work + [task("due", due: "2026-11-14", section: "work"), task("h1", section: "home"),
                            task("later", due: "2026-11-20", section: "work"), task("loose")]
        let today = groups(tasks, .today)
        #expect(today.map(\.kind) == [.today, .next("work"), .next("home")])
        #expect(today[1].tasks.map(\.id) == ["w1", "w2", "w3"], "the top three, in drag order; no date is made up for them")
        #expect(today[1].more == 2, "w4 and w5: “2 more in Work”")
        #expect(today[2].tasks.map(\.id) == ["h1"] && today[2].more == 0)
        let shown = today.flatMap { $0.tasks.map(\.id) }
        #expect(Set(shown).count == shown.count, "nothing shows twice")
        #expect(!shown.contains("later"), "due next week: it is under Upcoming")
        #expect(!shown.contains("loose"), "in no list: it is in Inbox")
        #expect(TodoViews.moreLine(2, list: "Work") == "2 more in Work")
    }

    @Test func aListCanStayOutOfToday() {
        var quiet = lists
        quiet[0].inToday = false
        let tasks = [task("w1", section: "work"), task("h1", section: "home")]
        #expect(groups(tasks, .today, lists: quiet).map(\.kind) == [.next("home")])
    }

    @Test func todaysPillCountsWhatIsDatedOnly() {
        let tasks = [task("due", due: "2026-11-14"), task("late", due: "2026-11-10"), task("w1", section: "work"), task("w2", section: "work")]
        #expect(TodoViews.openCount(tasks, view: .today, sections: lists, now: Self.now, calendar: Self.calendar) == 2)
        #expect(TodoViews.openCount(tasks, view: .list("work"), sections: lists, now: Self.now, calendar: Self.calendar) == 2)
    }

    @Test func nextNeverShowsABotsOwnWorkOrATaskWaitingToStart() {
        let tasks = [task("bots", who: "bot", bot: "otto", section: "work"),
                     task("waits", section: "work", more: ["starts": "2026-11-20"]), task("mine", section: "work")]
        let next = groups(tasks, .today).first { $0.kind == .next("work") }
        #expect(next?.tasks.map(\.id) == ["mine"])
    }

    @Test func aNextGroupNamesItsList() {
        #expect(TodoViews.heading(.next("work"), now: Self.now, sections: lists, botName: name)?.title == "Next in Work")
        #expect(TodoViews.doneLine(4) == "Done today · 4")
    }

    // MARK: Board 5: the bot that keeps a list

    @Test func aKeptListSaysWhoKeepsItInWords() {
        // The clock's own space before AM is a narrow one.
        let line = TodoLists.keeperLine(lists[0], now: Self.now, calendar: Self.calendar, botName: name)
        #expect(line?.replacingOccurrences(of: "\u{202F}", with: " ") == "Kept by Otto · checked 8:02 AM")
        var old = lists[0]
        old.checkedAt = "2026-11-13T17:00:00-06:00"
        #expect(TodoLists.keeperLine(old, now: Self.now, calendar: Self.calendar, botName: name) == "Kept by Otto · checked Yesterday")
        old.checkedAt = nil
        #expect(TodoLists.keeperLine(old, now: Self.now, calendar: Self.calendar, botName: name) == "Kept by Otto")
        #expect(TodoLists.keeperLine(lists[1], now: Self.now, calendar: Self.calendar, botName: name) == nil, "nobody keeps Home")
    }

    /// The owner's rule (2026-11-14): a face on a row means the bot is on that task. A list's bot is words.
    @Test func watchedByIsWordsAndOnlyOnYourOwnTask() {
        #expect(TodoLists.watchedBy(task("mine", section: "work"), sections: lists, botName: name) == "watched by Otto")
        #expect(TodoLists.watchedBy(task("shared", who: "together", bot: "otto", section: "work"), sections: lists, botName: name) == nil,
                "Otto is on it: its face says so")
        #expect(TodoLists.watchedBy(task("bots", who: "bot", bot: "otto", section: "work"), sections: lists, botName: name) == nil)
        #expect(TodoLists.watchedBy(task("done", status: "done", section: "work"), sections: lists, botName: name) == nil)
        #expect(TodoLists.watchedBy(task("home", section: "home"), sections: lists, botName: name) == nil)
        #expect(TodoLists.watchedBy(task("loose"), sections: lists, botName: name) == nil)
    }

    // MARK: Board 6: where a task came from, and a bot's offer to close it

    @Test func aTaskSaysWhereItCameFrom() {
        let source: JSONValue = .object(["kind": "chat", "profile": "otto", "from": .object([
            "app": "Email", "who": "Ivy", "at": "2026-11-13", "ref": "email:abc", "link": "https://mail.example.com/abc"])])
        let found = task("found", by: "otto", more: ["source": source])
        #expect(TodoLists.sourceLine(found, now: Self.now, calendar: Self.calendar) == "Email · Ivy · Yesterday")
        #expect(TodoLists.sourceURL(found)?.absoluteString == "https://mail.example.com/abc")
        let bare = task("bare", more: ["source": .object(["kind": "chat", "profile": "otto", "from": .object(["link": "https://example.com/x"])])])
        #expect(TodoLists.sourceLine(bare, now: Self.now, calendar: Self.calendar) == "Link")
        let odd = task("odd", more: ["source": .object(["kind": "chat", "from": .object(["app": "Notes", "link": "file:///Users/me/x"])])])
        #expect(TodoLists.sourceLine(odd, now: Self.now, calendar: Self.calendar) == "Notes")
        #expect(TodoLists.sourceURL(odd) == nil, "only a web link opens")
        #expect(TodoLists.sourceLine(task("mine"), now: Self.now, calendar: Self.calendar) == nil)
    }

    @Test func aBotOffersToCloseAndTheRowSaysSo() {
        let offered = task("call", section: "work", more: ["offer": .object(["kind": "done", "by": "otto", "text": "Ivy confirmed by email", "at": "2026-11-14T08:02:00-06:00"])])
        let offer = TodoLists.closeOffer(offered)
        #expect(offer?.by == "otto")
        #expect(offer.map { TodoLists.closeLine($0, botName: name) } == "Otto: looks done · Ivy confirmed by email")
        #expect(TodoLists.closeLine(TodoCloseOffer(by: "otto", text: " "), botName: name) == "Otto thinks this is done")
        let words = TodoViews.row(offered, in: .open, now: Self.now, calendar: Self.calendar, botName: name)
        #expect(words.note == "Otto: looks done · Ivy confirmed by email" && words.tone == .ready)
        // Keep Open: the offer is off the row. A finished task has none.
        let kept = task("kept", more: ["offer": .object(["kind": "done", "by": "otto", "text": "x", "kept": true])])
        #expect(TodoLists.closeOffer(kept) == nil)
        let done = task("done", status: "done", more: ["offer": .object(["kind": "done", "by": "otto", "text": "x"])])
        #expect(TodoLists.closeOffer(done) == nil)
        #expect(TodoLists.closeOffer(task("plain")) == nil)
    }

    // MARK: Board 4: a bot offers a list, or a batch of tasks

    private func offer(new: Bool = true, tasks: Int = 9, move: Int = 0, state: String = "new", moveState: String? = nil,
                       listed: Bool? = nil, added: Int = 0, session: String? = "s1") -> TodoOffer {
        TodoOffer(id: "o1", bot: "otto", sessionId: session, list: "Work", section: new ? nil : "work", isNew: new, why: "Nine things from this week",
                  tasks: (0..<tasks).map { TodoOfferTask(title: "Task \($0)") }, move: (0..<move).map { TodoOfferMove(id: "m\($0)", title: "Old \($0)") },
                  state: state, moveState: moveState ?? (move > 0 ? "new" : nil), listed: listed, added: (0..<added).map { "t\($0)" })
    }

    @Test func aNewListIsOfferedNotMade() {
        let o = offer()
        #expect(o.isWaiting && !o.asksMove)
        #expect(TodoLists.offerTitle(o, botName: name) == "Otto suggests a Work list")
        #expect(TodoLists.offerButtons(o).map(\.title) == ["Make Work & Add 9", "Add, No List", "Not Now"])
        #expect(TodoLists.offerButtons(o).map(\.action) == [.accept, .accept, .decline])
        #expect(TodoLists.offerButtons(o)[0].main && TodoLists.offerButtons(o)[0].makesList)
        #expect(!TodoLists.offerButtons(o)[1].makesList)
        #expect(TodoLists.offerDone(o) == nil)
        #expect(TodoLists.offerButtons(offer(tasks: 0)).map(\.title) == ["Make Work", "Not Now"], "a list alone")
    }

    @Test func tasksForAListThatAsksFirst() {
        let o = offer(new: false, tasks: 3)
        #expect(TodoLists.offerTitle(o, botName: name) == "Otto has 3 tasks for Work")
        #expect(TodoLists.offerButtons(o).map(\.title) == ["Add 3 to Work", "Not Now"])
        #expect(TodoLists.offerTitle(offer(new: false, tasks: 1), botName: name) == "Otto has 1 task for Work")
        let moves = offer(new: false, tasks: 0, move: 2)
        #expect(TodoLists.offerTitle(moves, botName: name) == "Otto would move 2 tasks to Work")
        #expect(TodoLists.offerButtons(moves).map(\.title) == ["Move 2 to Work", "Leave Them"])
    }

    /// Tasks already on the page are moved only when you say so, after the new ones are on.
    @Test func movingWhatIsAlreadyThereIsAskedSeparately() {
        let accepted = offer(move: 3, state: "accepted", moveState: "new", listed: true, added: 9)
        #expect(accepted.asksMove)
        #expect(TodoLists.offerTitle(accepted, botName: name) == "Move 3 tasks to Work?")
        #expect(TodoLists.offerButtons(accepted).map(\.title) == ["Move 3 to Work", "Leave Them"])
        #expect(TodoLists.offerButtons(accepted).map(\.action) == [.move, .leave])
        #expect(TodoLists.waiting([accepted]).count == 1, "it still waits on the Tasks page")
        let noList = offer(move: 3, state: "accepted", moveState: "left", listed: false, added: 9)
        #expect(!noList.asksMove, "“Add, No List”: there is no list to move them to")
        let moved = offer(move: 3, state: "accepted", moveState: "moved", listed: true, added: 9)
        #expect(TodoLists.offerDone(moved) == "Made Work and added 9 tasks, moved 3 tasks")
        #expect(TodoLists.waiting([moved]).isEmpty)
    }

    @Test func anAnsweredCardSaysWhatHappenedOnOneLine() {
        #expect(TodoLists.offerDone(offer(state: "accepted", listed: true, added: 9)) == "Made Work and added 9 tasks")
        #expect(TodoLists.offerDone(offer(state: "accepted", listed: false, added: 9)) == "Added 9 tasks, no list")
        #expect(TodoLists.offerDone(offer(new: false, tasks: 3, state: "accepted", listed: true, added: 3)) == "Added 3 tasks to Work")
        #expect(TodoLists.offerDone(offer(new: false, tasks: 0, move: 2, state: "accepted", moveState: "moved", listed: true)) == "Moved 2 tasks to Work")
        #expect(TodoLists.offerDone(offer(state: "declined")) == "Not now")
        #expect(TodoLists.offerDone(offer(state: "undone")) == "Undone")
        #expect(TodoLists.canUndo(offer(state: "accepted")) && !TodoLists.canUndo(offer()) && !TodoLists.canUndo(offer(state: "undone")))
        #expect(TodoLists.offerButtons(offer(state: "accepted", listed: true, added: 9)).isEmpty)
    }

    @Test func aChatShowsTheOffersMadeInIt() {
        let mine = offer(), other = offer(session: "s2"), none = offer(session: nil)
        let declined = offer(state: "declined"), undone = offer(state: "undone")
        #expect(TodoLists.offers([mine, other, none, declined, undone], inChat: "s1").count == 1)
        #expect(TodoLists.offers([mine], inChat: nil).isEmpty && TodoLists.offers([mine], inChat: "").isEmpty)
        #expect(TodoLists.waiting([mine, declined, undone]).count == 1)
    }

    /// The chat card is the same height whatever became of the offer: a filled button or one line, then a quiet row.
    @Test func theChatCardsFootInEveryState() {
        let fresh = TodoLists.chatFoot(offer(), past: false)
        #expect(fresh.main?.title == "Make Work & Add 9" && fresh.others.map(\.title) == ["Add, No List", "Not Now"])
        #expect(!fresh.undo && !fresh.opensTasks && fresh.line == nil)
        let done = TodoLists.chatFoot(offer(state: "accepted", listed: true, added: 9), past: false)
        #expect(done.main == nil && done.line == "Made Work and added 9 tasks" && done.good && done.undo && done.opensTasks)
        let asks = TodoLists.chatFoot(offer(move: 3, state: "accepted", moveState: "new", listed: true, added: 9), past: false)
        #expect(asks.main?.title == "Move 3 to Work" && asks.others.map(\.title) == ["Leave Them"] && asks.undo)
        let no = TodoLists.chatFoot(offer(state: "declined"), past: false)
        #expect(no.line == "Not now" && !no.good && !no.undo && no.opensTasks)
        let old = TodoLists.chatFoot(offer(), past: true)
        #expect(old.main == nil && old.line == "Answered" && !old.undo, "the gateway let it go a day after it was answered")
        // The title is what the bot offered, whatever happened after.
        #expect(TodoLists.chatTitle(offer(move: 3, state: "accepted", moveState: "new", listed: true, added: 9), botName: name) == "Otto suggests a Work list")
    }

    @Test func anOfferIsReadFromTheGateway() throws {
        let o = try decode(TodoOffer.self, #"""
        {"id":"o9","bot":"otto","session_id":"s1","at":"2026-11-14T08:02:00-06:00","list":"Work","section":null,"new":true,
         "why":"From this week","tasks":[{"title":"Send the report","due":"2026-11-16","source":{"app":"Email","who":"Ivy"}}],
         "move":[{"id":"t1","title":"Call the bank"}],"state":"accepted","move_state":"new","listed":true,"added":["t7"]}
        """#)
        #expect(o.isNew && o.section == nil && o.sessionId == "s1")
        #expect(o.tasks.first?.source?.who == "Ivy" && o.move.first?.title == "Call the bank")
        #expect(o.asksMove && o.added == ["t7"])
        // The least a gateway could send still reads.
        let bare = try decode(TodoOffer.self, #"{"id":"o2","list":"Home"}"#)
        #expect(bare.isWaiting && bare.isNew && bare.bot == "default" && bare.tasks.isEmpty)
    }

    @Test func theListAnswerCarriesListsAndOffers() throws {
        let answer = try decode(TodoListAnswer.self, #"""
        {"rev":4,"tasks":[],"lists":true,"sections":[{"id":"w","name":"Work","color":"blue","bot":"otto"}],
         "offers":[{"id":"o1","list":"Work","bot":"otto"},{"list":"broken"}]}
        """#)
        #expect(answer.lists && answer.sections?.first?.bot == "otto")
        #expect(answer.offers.map(\.id) == ["o1"], "one bad offer never loses the others")
        let older = try decode(TodoListAnswer.self, #"{"rev":4,"tasks":[],"sections":[{"id":"w","name":"Work"}]}"#)
        #expect(!older.lists && older.offers.isEmpty, "an add-on before 0.9.55")
    }

    // MARK: The chat's card

    @Test func aBotsOfferBecomesAChatCard() throws {
        let result = try JSONValue.parse(Data(#"""
        {"offer":{"id":"o1","bot":"otto","session_id":"s1","list":"Work","new":true,"why":"From this week",
                  "tasks":[{"title":"Send the report","due":"2026-11-16"}],"move":[],"state":"new","added":[]},
         "say":"The card is on their screen."}
        """#.utf8))
        guard case .tasksOffer(let offer)? = ToolCards.card(name: "tasks_offer", args: [:], result: result) else {
            Issue.record("no card"); return
        }
        #expect(offer.id == "o1" && offer.list == "Work" && offer.tasks.map(\.title) == ["Send the report"])
        // Saved with the chat and read back, it is the same card.
        let card = ToolCard.tasksOffer(offer)
        #expect(ToolCard(json: card.json) == card)
        // A refusal is no card.
        let refused = try JSONValue.parse(Data(#"{"error":"They said not now to a “Work” list."}"#.utf8))
        #expect(ToolCards.card(name: "tasks_offer", args: [:], result: refused) == nil)
    }

    @Test func aCardShowsWhatBecameOfItsOffer() {
        TodoOfferStates.forget()
        defer { TodoOfferStates.forget() }
        let offered = TodoOffer(id: "state-1", bot: "otto", list: "Work")
        #expect(TodoOfferStates.shown(offered).offer.state == "new" && !TodoOfferStates.shown(offered).past, "nothing read yet: as offered")
        var accepted = offered
        accepted.state = "accepted"
        #expect(TodoOfferStates.note([accepted], whole: false), "news")
        #expect(!TodoOfferStates.note([accepted], whole: false), "the same again is not")
        #expect(TodoOfferStates.shown(offered).offer.state == "accepted")
        // The gateway's whole list was read and an old offer isn't in it: answered more than a day ago.
        _ = TodoOfferStates.note([accepted], whole: true)
        let old = TodoOffer(id: "state-0", bot: "otto", list: "Home")
        #expect(TodoOfferStates.shown(old).past)
        #expect(!TodoOfferStates.shown(offered).past)
    }

    /// An offer sent twice is one card: two rows with one identity crash the list.
    @Test func anOfferSentTwiceIsOneCard() {
        let twice = [TodoOffer(id: "of_1", bot: "otto", list: "Work"), TodoOffer(id: "of_2", bot: "otto", list: "Home"),
                     TodoOffer(id: "of_1", bot: "otto", list: "Work")]
        #expect(TasksStore.once(twice).map(\.id) == ["of_1", "of_2"])
    }
}
