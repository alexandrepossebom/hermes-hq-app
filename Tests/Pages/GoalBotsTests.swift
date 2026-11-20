// [goals steps 3-5] Bots on a goal (docs/goals.md "Step 3/4/5 in the app"; hermes-hq-push 0.9.66): each goal offer kind
// and a 0.9.65 goal decoded, the offer card's place, words, buttons and foot, the stall rule from each side, the who
// row, the number's source, the check-in's slot, looks-done, the push that opens a goal, the card's spoken words, a new
// goal's lead sent after it is made, and the store's answers to a goal offer (accept, decline, undo, answered on another
// device, a 409).

import Foundation
import Testing
@testable import HermesHQNative

struct GoalBotsTests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()
    /// Mon 2026-12-14 09:41 in Chicago.
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 12, day: 14, hour: 9, minute: 41))!
    private static func ago(days: Double) -> String { TodoDates.now(now.addingTimeInterval(-days * 86_400)) }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private static func name(_ profile: String?) -> String {
        ["default": "Hermes", "ivy": "Ivy", "wren": "Wren", "otto": "Otto"][profile ?? ""] ?? (profile ?? "")
    }

    private static func task(_ id: String, goal: String? = "g_1", done: Bool = false, doneAt: String? = nil, created: String? = nil,
                             milestone: String? = nil) -> TodoTask {
        var o: [String: JSONValue] = ["id": .string(id), "rev": 2, "title": .string(id), "who": "me", "status": .string(done ? "done" : "open"),
                                      "created_at": .string(created ?? ago(days: 40)), "updated_at": .string(created ?? ago(days: 40))]
        if let goal { o["goal"] = .string(goal) }
        if let doneAt { o["done_at"] = .string(doneAt) }
        if let milestone { o["milestone"] = .string(milestone) }
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
    }

    private static func goal(_ id: String = "g_1", lead: String? = nil, helpers: [String] = [], created: String? = nil,
                             milestones: [GoalMilestone] = [], review: GoalReview? = nil) -> Goal {
        var g = Goal(id: id, title: "Learn guitar", milestones: milestones, createdAt: created ?? ago(days: 40), updatedAt: created ?? ago(days: 40))
        g.statusAt = g.createdAt
        g.lead = lead; g.helpers = helpers; g.review = review
        return g
    }

    private static func offer(_ kind: String, id: String = "of_1", goal: String? = "g_1", bot: String = "default", state: String = "new",
                              tasks: Int = 0, milestones: Int = 0, at: String? = nil, held: Bool = false) -> TodoOffer {
        var o = TodoOffer(id: id, bot: bot, at: at ?? ago(days: 1), list: "", state: state)
        o.kind = kind; o.goal = goal; o.title = "Learn guitar"; o.held = held
        o.tasks = (0..<tasks).map { TodoOfferTask(title: "Task \($0 + 1)", who: "me") }
        o.milestones = (0..<milestones).map { GoalOfferMilestone(title: "Step \($0 + 1)") }
        return o
    }

    // MARK: Decoding

    @Test func eachGoalOfferKindDecodes() throws {
        let goal = try Self.decode(TodoOffer.self, """
        {"id":"of_g","kind":"goal","bot":"default","session_id":"s1","at":"2026-12-14T08:00:00Z","goal":null,"title":"Grow tomatoes",
         "why":"Fresh ones","due":"2027-07-01","measure":{"unit":"lbs","start":0,"target":20},"milestones":[{"title":"Seedlings"},{"title":"Beds","due":"2027-04-01"}],
         "tasks":[{"title":"Buy seeds","who":"me","milestone":"Seedlings"},{"title":"Find a bed plan","who":"bot","bot":"ivy"}],"state":"new"}
        """)
        #expect(goal.isGoal && goal.kind == "goal" && goal.goal == nil && goal.title == "Grow tomatoes" && goal.list == "Grow tomatoes")
        #expect(goal.measure == GoalOfferMeasure(unit: "lbs", start: 0, target: 20) && goal.due == "2027-07-01")
        #expect(goal.milestones.map(\.title) == ["Seedlings", "Beds"] && goal.milestones[1].due == "2027-04-01")
        #expect(goal.tasks[0].milestone == "Seedlings" && goal.tasks[1].botFor(goal) == "ivy" && goal.tasks[0].botFor(goal) == nil)

        let plan = try Self.decode(TodoOffer.self, """
        {"id":"of_p","kind":"plan","bot":"default","goal":"g_1","title":"Learn guitar","milestones":[{"title":"Chords"}],"tasks":[],"state":"accepted",
         "answered_at":"2026-12-14T09:00:00Z","made_milestones":["ms_9"],"added":[],"in_goal":true}
        """)
        #expect(plan.kind == "plan" && plan.goal == "g_1" && plan.madeMilestones == ["ms_9"] && plan.inGoal == true && !plan.isWaiting)

        let checkin = try Self.decode(TodoOffer.self, """
        {"id":"of_c","kind":"checkin","bot":"otto","goal":"g_1","title":"Learn guitar","summary":"Two lessons done. The third is booked.",
         "tasks":[{"title":"Practise scales","who":"me"}],"state":"new"}
        """)
        #expect(checkin.kind == "checkin" && checkin.summary == "Two lessons done. The third is booked." && checkin.tasks.count == 1)

        let tasks = try Self.decode(TodoOffer.self, """
        {"id":"of_t","kind":"tasks","bot":"wren","goal":"g_1","title":"Learn guitar","tasks":[{"title":"Tune it","who":"bot"}],"state":"undone",
         "kept":["t_1"],"held":true}
        """)
        #expect(tasks.kind == "tasks" && tasks.kept == ["t_1"] && tasks.held && tasks.tasks[0].botFor(tasks) == "wren")

        let list = try Self.decode(TodoOffer.self, #"{"id":"of_l","bot":"ivy","list":"Garden","tasks":[],"state":"new"}"#)
        #expect(!list.isGoal && list.kind == "list" && list.title.isEmpty, "a list offer has no kind")
    }

    @Test func aGoalFrom0965HasNoBot() throws {
        let goal = try Self.decode(Goal.self, """
        {"id":"g_1","rev":3,"title":"Run a 10K","why":"","status":"active","color":"orange","position":1,
         "measure":{"unit":"km","start":0,"target":10,"now":3,"at":"2026-12-01T08:00:00Z"},"milestones":[],"log":[]}
        """)
        #expect(goal.lead == nil && goal.helpers.isEmpty && goal.team.isEmpty && goal.review == nil && goal.adds == "ask" && goal.knownToAll)
        #expect(goal.stands == nil && goal.checkin == nil && goal.offer == nil && goal.keptAt == nil && goal.pageAt == nil)
        #expect(goal.measure?.source == .you && goal.measure?.checkedAt == nil)
        #expect(GoalBots.whoLine(goal, botName: Self.name) == nil)
    }

    @Test func aGoalFrom0966ReadsItsTeam() throws {
        let goal = try Self.decode(Goal.self, """
        {"id":"g_1","rev":3,"title":"Ship the beta","status":"active","lead":"default","helpers":["ivy","default","","wren"],"adds":"auto",
         "review":{"day":0,"time":"08:00"},"known_to_all":false,"stands":{"by":"default","at":"2026-12-14T08:02:00Z","text":"Build 12 is out.","next":"the invites"},
         "checkin":{"at":"2026-12-14T08:00:00Z","offer":"of_c","state":"offered"},"chat":{},"page_at":"","kept_at":null,
         "offer":{"kind":"done","what":"goal","by":"default","text":"All done.","at":"2026-12-14T08:00:00Z"},
         "measure":{"unit":"testers","start":0,"target":10,"now":4,"source":{"bot":"ivy","what":"TestFlight"},"checked_at":"2026-12-14T08:02:00Z"}}
        """)
        #expect(goal.team == ["default", "ivy", "wren"], "the lead first, never twice, no empty name")
        #expect(goal.adds == "auto" && goal.review == GoalReview(day: 0, time: "08:00") && !goal.knownToAll)
        #expect(goal.stands?.next == "the invites" && goal.checkin?.state == "offered" && goal.chat == nil && goal.pageAt == nil)
        #expect(goal.offer?.what == "goal" && goal.offer?.kept == false)
        #expect(goal.measure?.source == .bot("ivy", what: "TestFlight") && goal.measure?.checkedAt != nil)
        let bad = try Self.decode(Goal.self, #"{"id":"g_2","review":{"day":9,"time":"8"},"adds":"sometimes"}"#)
        #expect(bad.review == nil && bad.adds == "ask", "a slot the app can't read is no check-in")
    }

    // MARK: Where the card shows

    @Test func todayShowsTheOldestWaitingOfferForAGoalYouHave() {
        let goals = [Self.goal()]
        let older = Self.offer("plan", id: "of_a", at: Self.ago(days: 3))
        let newer = Self.offer("checkin", id: "of_b", at: Self.ago(days: 1))
        let held = Self.offer("tasks", id: "of_h", at: Self.ago(days: 5), held: true)
        let gone = Self.offer("tasks", id: "of_x", goal: "g_gone", at: Self.ago(days: 6))
        let list = TodoOffer(id: "of_l", bot: "ivy", at: Self.ago(days: 9), list: "Garden")
        let answered = Self.offer("plan", id: "of_d", state: "declined", at: Self.ago(days: 8))
        #expect(GoalOffers.today([newer, older, held, gone, list, answered], goals: goals)?.id == "of_a")
        #expect(GoalOffers.today([Self.offer("goal", id: "of_g", goal: nil)], goals: []) != nil, "a new goal's offer needs no goal")
        #expect(GoalOffers.today([held, list], goals: goals) == nil)
    }

    @Test func aGoalsPageListsWhatWaitsAndWhatYouAccepted() {
        var made = Self.offer("goal", id: "of_g", goal: nil, state: "accepted", at: Self.ago(days: 2)); made.madeGoal = "g_1"
        let waiting = Self.offer("tasks", id: "of_t", at: Self.ago(days: 1))
        let declined = Self.offer("plan", id: "of_p", state: "declined")
        let other = Self.offer("tasks", id: "of_o", goal: "g_2")
        #expect(GoalOffers.onGoal([waiting, declined, other, made], goal: "g_1").map(\.id) == ["of_g", "of_t"])
    }

    // MARK: Words and buttons

    @Test func eachKindHasItsTagAndButtons() {
        #expect(GoalOffers.tag(Self.offer("goal")) == "new goal" && GoalOffers.tag(Self.offer("plan")) == "plan")
        #expect(GoalOffers.tag(Self.offer("tasks", tasks: 2)) == "add 2 tasks?" && GoalOffers.tag(Self.offer("checkin")).isEmpty)

        #expect(GoalOffers.buttons(Self.offer("goal")).map(\.title) == ["Make This Goal", "Not Now"], "no plan, no quiet line")
        let goal = GoalOffers.buttons(Self.offer("goal", tasks: 1, milestones: 2))
        #expect(goal.map(\.title) == ["Make This Goal", "Not Now", "Keep the Goal, No Plan"])
        #expect(goal[2].quiet && !goal[2].plan && goal[2].action == .accept && goal[0].main)

        let plan = GoalOffers.buttons(Self.offer("plan", milestones: 3))
        #expect(plan.map(\.title) == ["Use This Plan", "Change It", "Keep the Goal, No Plan"] && plan[1].action == nil)

        #expect(GoalOffers.buttons(Self.offer("checkin")).map(\.title) == ["Got It", "Change", "Not Now"])
        #expect(GoalOffers.buttons(Self.offer("checkin", tasks: 2)).first?.title == "Add These 2")

        let tasks = GoalOffers.buttons(Self.offer("tasks", tasks: 2))
        #expect(tasks.map(\.title) == ["Add to Goal", "Just Tasks", "No"] && !tasks[1].inGoal && tasks[2].action == .decline)
        #expect(GoalOffers.buttons(Self.offer("tasks", state: "accepted")).isEmpty, "answered: no buttons")
    }

    @Test func anAnsweredCardSaysWhatBecameOfIt() {
        var goal = Self.offer("goal", state: "accepted"); goal.added = ["t_1", "t_2", "t_3", "t_4"]
        #expect(GoalOffers.done(goal) == "Made the goal and added 4 tasks")
        goal.plan = false
        #expect(GoalOffers.done(goal) == "Made the goal, no plan")
        var plan = Self.offer("plan", state: "accepted"); plan.madeMilestones = ["a", "b"]; plan.added = ["t"]
        #expect(GoalOffers.done(plan) == "Added 2 milestones and 1 task")
        #expect(GoalOffers.done(Self.offer("plan", state: "declined")) == "Kept the goal, no plan")
        #expect(GoalOffers.done(Self.offer("checkin", state: "accepted")) == "Seen")
        var tasks = Self.offer("tasks", state: "accepted"); tasks.added = ["a", "b", "c"]
        #expect(GoalOffers.done(tasks) == "Added 3 tasks to the goal")
        tasks.inGoal = false
        #expect(GoalOffers.done(tasks) == "Added 3 tasks, no goal")
        #expect(GoalOffers.done(Self.offer("tasks", state: "declined")) == "Not now")
        var undone = Self.offer("goal", state: "undone")
        #expect(GoalOffers.done(undone) == "Undone")
        undone.kept = ["t_1"]
        #expect(GoalOffers.done(undone) == "Undone, except what you changed")
        #expect(GoalOffers.done(Self.offer("goal")) == nil)
    }

    @Test func theFootIsButtonsOrOneLineWithUndo() {
        let waiting = GoalOffers.foot(Self.offer("goal", milestones: 1), past: false)
        #expect(waiting.main?.title == "Make This Goal" && waiting.others.map(\.title) == ["Not Now"] && waiting.quiet?.title == "Keep the Goal, No Plan")
        #expect(waiting.line == nil)
        let accepted = GoalOffers.foot(Self.offer("checkin", state: "accepted"), past: false)
        #expect(accepted.main == nil && accepted.line == "Seen" && accepted.good && accepted.undo)
        let declined = GoalOffers.foot(Self.offer("checkin", state: "declined"), past: false)
        #expect(declined.line == "Not now" && !declined.undo && !declined.good)
        #expect(GoalOffers.foot(Self.offer("checkin", state: "accepted"), past: true) == GoalOfferFoot(line: "Answered"))
    }

    @Test func theCheckinHeadNamesTheSlotsDay() {
        let checkin = Self.offer("checkin", at: "2026-12-16T14:00:00Z")   // a Wednesday
        #expect(GoalOffers.checkinHead(checkin, goal: Self.goal(review: GoalReview(day: 0)), botName: Self.name, calendar: Self.calendar) == "Hermes · Monday check-in")
        #expect(GoalOffers.checkinHead(checkin, goal: Self.goal(), botName: Self.name, calendar: Self.calendar) == "Hermes · Wednesday check-in", "no slot: the day it came")
    }

    @Test func aTasksOfferFromABotNotOnTheGoalSaysWhoLeads() {
        let goal = Self.goal(lead: "default", helpers: ["ivy"], review: GoalReview(day: 0))
        #expect(GoalOffers.leadNote(Self.offer("tasks", bot: "wren"), goal: goal, botName: Self.name) == "Hermes leads this goal and sees them at Monday’s check-in.")
        #expect(GoalOffers.leadNote(Self.offer("tasks", bot: "ivy"), goal: goal, botName: Self.name) == nil, "a helper's are its own")
        #expect(GoalOffers.leadNote(Self.offer("tasks", bot: "default"), goal: goal, botName: Self.name) == nil)
        var noSlot = goal; noSlot.review = nil
        #expect(GoalOffers.leadNote(Self.offer("tasks", bot: "wren"), goal: noSlot, botName: Self.name) == "Hermes leads this goal.")
        #expect(GoalOffers.leadNote(Self.offer("plan", bot: "wren"), goal: goal, botName: Self.name) == nil)
    }

    @Test func theSpokenHeadSaysWhoAndWhat() {
        #expect(GoalOffers.spoken(Self.offer("goal"), goal: nil, botName: Self.name) == "Hermes suggests a goal: Learn guitar")
        #expect(GoalOffers.spoken(Self.offer("tasks", bot: "ivy", tasks: 2), goal: nil, botName: Self.name) == "Ivy has 2 tasks for Learn guitar")
        #expect(GoalOffers.who(TodoOfferTask(title: "x", who: "bot"), offer: Self.offer("tasks", bot: "ivy"), botName: Self.name) == "Ivy")
        #expect(GoalOffers.who(TodoOfferTask(title: "x"), offer: Self.offer("tasks", bot: "ivy"), botName: Self.name) == "You")
    }

    // MARK: Who, the faces and the dot

    @Test func theWhoRowAndTheCardsSpokenWords() {
        #expect(GoalBots.whoLine(Self.goal(lead: "default"), botName: Self.name) == "Led by Hermes")
        #expect(GoalBots.whoLine(Self.goal(helpers: ["ivy"]), botName: Self.name) == "Helped by Ivy")
        #expect(GoalBots.whoLine(Self.goal(helpers: ["ivy", "wren"]), botName: Self.name) == "Helped by Ivy and 1 more")
        #expect(GoalBots.whoSpoken(Self.goal(lead: "default", helpers: ["ivy", "wren"]), botName: Self.name) == "Led by Hermes, with Ivy and Wren")
        #expect(GoalBots.cardSpoken(team: ["default", "ivy"], led: true, waits: true, botName: Self.name) == "Led by Hermes, with Ivy. Waiting for your answer.")
        #expect(GoalBots.cardSpoken(team: ["ivy"], led: false, waits: false, botName: Self.name) == "Helped by Ivy.")
        #expect(GoalBots.cardSpoken(team: [], led: false, waits: true, botName: Self.name).isEmpty, "no bot, no words")
    }

    @Test func theLeadsDotWaitsForYourAnswer() {
        let goal = Self.goal(lead: "default")
        #expect(!GoalBots.waitsForYou(goal, offers: []))
        #expect(GoalBots.waitsForYou(goal, offers: [Self.offer("checkin")]))
        #expect(!GoalBots.waitsForYou(goal, offers: [Self.offer("tasks", held: true), Self.offer("plan", state: "accepted"), Self.offer("tasks", goal: "g_2")]))
        var done = goal; done.offer = GoalDoneOffer(what: "goal", by: "default", text: "")
        #expect(GoalBots.waitsForYou(done, offers: []), "the lead's looks-done waits too")
    }

    // MARK: The push

    @Test func aCheckinsPushOpensItsGoal() {
        #expect(GoalBots.pushedGoal("goal:g_testers") == "g_testers")
        #expect(GoalBots.pushedGoal("goal:") == nil && GoalBots.pushedGoal("t_123") == nil && GoalBots.pushedGoal(nil) == nil)
    }

    // MARK: The check-in's slot and the number

    @Test func theSlotInWords() {
        #expect(GoalBots.time("08:00") == "8 AM" && GoalBots.time("08:30") == "8:30 AM" && GoalBots.time("12:00") == "12 PM")
        #expect(GoalBots.time("00:00") == "12 AM" && GoalBots.time("17:05") == "5:05 PM" && GoalBots.time("soon") == "soon")
        #expect(GoalBots.reviewWords(GoalReview(day: 0, time: "08:00")) == "Mondays 8 AM")
        #expect(GoalBots.reviewWords(GoalReview(day: 6, time: "20:00")) == "Sundays 8 PM" && GoalBots.reviewWords(nil) == "Off")
    }

    @Test func theNumbersSource() {
        let yours = GoalMeasure(unit: "testers", target: 10)
        #expect(GoalBots.numberFromWords(yours, botName: Self.name) == "You")
        #expect(GoalBots.sourceWords(yours, now: Self.now, botName: Self.name, calendar: Self.calendar) == nil, "yours: the row says Update")
        let read = GoalMeasure(unit: "testers", target: 10, source: .bot("ivy", what: "TestFlight"), checkedAt: "2026-12-14T08:02:00-06:00")
        #expect(GoalBots.numberFromWords(read, botName: Self.name) == "TestFlight · Ivy")
        #expect(GoalBots.sourceWords(read, now: Self.now, botName: Self.name, calendar: Self.calendar) == "TestFlight · 8:02 AM")
        let unnamed = GoalMeasure(unit: "", target: 10, source: .bot("ivy", what: " "))
        #expect(GoalBots.numberFromWords(unnamed, botName: Self.name) == "Ivy")
        #expect(GoalBots.sourceWords(unnamed, now: Self.now, botName: Self.name, calendar: Self.calendar) == "Ivy", "never looked: its name alone")
        let lastWeek = GoalMeasure(unit: "", target: 10, at: "2026-12-10T08:00:00-06:00", source: .bot("ivy", what: "TestFlight"))
        let words = GoalBots.sourceWords(lastWeek, now: Self.now, botName: Self.name, calendar: Self.calendar) ?? ""
        #expect(words.hasPrefix("TestFlight · ") && !words.contains("AM"), "another day: the day, not the time")
    }

    // MARK: Looks done

    @Test func looksDoneWaitsUntilAnswered() {
        let milestones = [GoalMilestone(id: "ms_1", title: "Launch week"), GoalMilestone(id: "ms_2", title: "Done one", done: true)]
        var goal = Self.goal(lead: "default", milestones: milestones)
        goal.offer = GoalDoneOffer(what: "ms_1", by: "default", text: "All four posts are up.")
        let offer = try! #require(GoalBots.looksDone(goal))
        #expect(GoalBots.looksDoneText(offer, goal: goal, botName: Self.name) == "Hermes thinks Launch week looks done: All four posts are up. Mark it done?")
        #expect(GoalBots.looksDoneYes(offer) == "Mark Done")
        goal.offer?.kept = true
        #expect(GoalBots.looksDone(goal) == nil, "Not Yet")
        goal.offer = GoalDoneOffer(what: "ms_2", by: "default", text: "")
        #expect(GoalBots.looksDone(goal) == nil, "that milestone is ticked already")
        goal.offer = GoalDoneOffer(what: "goal", by: "default", text: "")
        #expect(GoalBots.looksDone(goal).map { GoalBots.looksDoneText($0, goal: goal, botName: Self.name) } == "Hermes thinks this goal is achieved. Mark it achieved?")
        goal.status = "paused"
        #expect(GoalBots.looksDone(goal) == nil, "only on an active goal")
    }

    // MARK: The stall question

    @Test func aGoalStallsAfterTwoQuietWeeks() throws {
        let goal = Self.goal()
        let tasks = [Self.task("t_open", created: Self.ago(days: 20))]
        let stall = try #require(GoalViews.stalled(goal, tasks: tasks, now: Self.now, calendar: Self.calendar))
        #expect(stall.days >= 14 && stall.task?.id == "t_open")
        #expect(GoalViews.stallLine(GoalStall(days: 16)) == "Nothing has moved in 16 days")
        #expect(GoalViews.stallQuestion(GoalStall(days: 16), now: Self.now, calendar: Self.calendar) == "Still want this one?")
        #expect(GoalViews.stallQuestion(stall, now: Self.now, calendar: Self.calendar).hasPrefix("The next task, “t_open”, has been open since "))
    }

    @Test func anythingMovingKeepsTheStallAway() {
        let open = Self.task("t_open")
        let goal = Self.goal()
        #expect(GoalViews.stalled(goal, tasks: [], now: Self.now) == nil, "nothing open: nothing to ask")
        #expect(GoalViews.stalled(goal, tasks: [open, Self.task("t_done", done: true, doneAt: Self.ago(days: 3))], now: Self.now) == nil, "a task ticked")
        #expect(GoalViews.stalled(goal, tasks: [open, Self.task("t_else", goal: "g_2", done: true, doneAt: Self.ago(days: 1))], now: Self.now) != nil,
                "another goal's tick doesn't count")
        var kept = goal; kept.keptAt = Self.ago(days: 2)
        #expect(GoalViews.stalled(kept, tasks: [open], now: Self.now) == nil, "Keep Going on the gateway")
        #expect(GoalViews.stalled(goal, tasks: [open], now: Self.now, keptHere: Self.now.addingTimeInterval(-3_600)) == nil, "Keep Going on this device (0.9.65)")
        var moved = goal; moved.measure = GoalMeasure(unit: "", target: 10, now: 3, at: Self.ago(days: 4))
        #expect(GoalViews.stalled(moved, tasks: [open], now: Self.now) == nil, "the number moved")
        let ticked = Self.goal(milestones: [GoalMilestone(id: "ms", title: "x", done: true, doneAt: Self.ago(days: 5))])
        #expect(GoalViews.stalled(ticked, tasks: [open], now: Self.now) == nil, "a milestone ticked")
        #expect(GoalViews.stalled(Self.goal(created: Self.ago(days: 5)), tasks: [open], now: Self.now) == nil, "made this week")
        var resumed = goal; resumed.statusAt = Self.ago(days: 1)
        #expect(GoalViews.stalled(resumed, tasks: [open], now: Self.now) == nil, "resumed")
        var paused = goal; paused.status = "paused"
        #expect(GoalViews.stalled(paused, tasks: [open], now: Self.now) == nil, "paused goals don't ask")
        #expect(GoalViews.stalled(Self.goal(lead: "default"), tasks: [open], now: Self.now) != nil, "with a bot or without")
    }

    // MARK: The goal's chat

    @Test func theGoalsChatAndHiddenTurns() {
        var goal = Self.goal(lead: "default")
        goal.id = "g_abcdef123"
        #expect(GoalBots.sessionTitle(goal) == "Goal: Learn guitar · g_abcd")
        goal.title = String(repeating: "a", count: 90)
        #expect(GoalBots.sessionTitle(goal).count <= 100 && GoalBots.sessionTitle(goal).contains("…"))
        #expect(GoalBots.planRequest(goal, now: Self.now, calendar: Self.calendar).hasPrefix(GoalBots.planRequestStart))
        #expect(GoalBots.planRequest(goal, now: Self.now, calendar: Self.calendar).contains("(Goal id g_abcdef123)"))
        #expect(GoalBots.smallerStepRequest(goal, stall: GoalStall(days: 16)).contains("in 16 days"))
    }

    @Test func aPlanAskShowsYourWordsAfterARelaunch() {
        var goal = Self.goal(lead: "default")
        goal.title = "Learn guitar"
        let ask = GoalBots.planRequest(goal, typed: "Learn guitar  by\nMarch", now: Self.now, calendar: Self.calendar)
        #expect(ask.hasPrefix(GoalBots.planRequestStart))
        #expect(ask.contains("Goal: “Learn guitar”"), "the details are still there")
        #expect(GoalBots.planBubble(forStored: ask) == "Learn guitar by March", "your line, as one line")
        #expect(GoalBots.planBubble(forStored: "  " + ask.replacingOccurrences(of: "\n", with: "\n\n")) == "Learn guitar by March",
                "read from the stored row, whatever its spacing")
        #expect(GoalBots.planBubble(forStored: GoalBots.planRequest(goal, now: Self.now, calendar: Self.calendar)) == nil,
                "no words: no bubble words")
        #expect(GoalBots.planBubble(forStored: "Learn guitar") == nil, "any other turn shows as itself")
        #expect(GoalBots.planBubble(forStored: GoalBots.updateRequest(goal)) == nil)
        // The chat's re-read: the stored ask shows as your words with nothing noted this run.
        let titles = SentTitles()
        #expect(titles.title(forStored: ask) == "Learn guitar by March")
        let rows = titles.applied(to: [ChatMessage(id: "u1", role: .user, parts: [.text(ask)], timestamp: nil, rowId: 1)])
        #expect(rows.first?.plainText == "Learn guitar by March")
    }

    @Test func aNewGoalsTeamGoesInAPatch() {
        #expect(GoalWire.teamKeys.isSuperset(of: ["lead", "helpers", "review"]))
        #expect(!GoalWire.teamKeys.contains("title") && !GoalWire.teamKeys.contains("measure"))
    }

    /// The chat card's buttons: equal while every title fits; else what each needs; shrunk only past that.
    @Test func theButtonsRowFitsItsTitles() {
        // A phone's card: every title fits a third, so three equal buttons.
        let wide = GoalOffers.buttonWidths(natural: [96, 70, 80], available: 330)
        #expect(wide.widths == [110, 110, 110] && wide.scale == 1)
        // A narrow pane: "Add These 3" needs more than a third; each gets its need and an even share of the rest.
        let narrow = GoalOffers.buttonWidths(natural: [96, 70, 80], available: 270)
        #expect(narrow.widths == [104, 78, 88] && narrow.scale == 1)
        #expect(zip(narrow.widths, [96, 70, 80]).allSatisfy { $0 >= $1 }, "no title is cut")
        // Narrower than the titles: they shrink together, never below the floor.
        let tight = GoalOffers.buttonWidths(natural: [100, 100, 100], available: 270)
        #expect(tight.widths == [90, 90, 90] && tight.scale == 0.9)
        #expect(GoalOffers.buttonWidths(natural: [100, 100], available: 100).scale == 0.8)
        #expect(GoalOffers.buttonWidths(natural: [], available: 100).widths.isEmpty)
    }
}

// MARK: - The store's answers to a goal offer

@MainActor
struct GoalOfferStoreTests {
    private nonisolated static let route = "/api/plugins/hermes-hq-push"

    private nonisolated static func wire<T: Encodable>(_ value: T) -> JSONValue { try! JSONValue.parse(JSONEncoder().encode(value)) }

    private nonisolated static func goal(lead: String? = "default") -> Goal {
        var g = Goal(id: "g_1", rev: 3, title: "Learn guitar", createdAt: "2026-11-01T08:00:00-05:00", updatedAt: "2026-11-01T08:00:00-05:00")
        g.lead = lead
        return g
    }

    private nonisolated static func offer(_ kind: String = "tasks", state: String = "new") -> TodoOffer {
        var o = TodoOffer(id: "of_1", bot: "default", at: "2026-12-14T08:00:00-06:00", list: "Learn guitar", state: state)
        o.kind = kind; o.goal = "g_1"; o.title = "Learn guitar"
        o.tasks = [TodoOfferTask(title: "Tune it", who: "me")]
        return o
    }

    private nonisolated static func list(offers: [TodoOffer], goals: [Goal] = [goal()], bots: Bool = true) -> JSONValue {
        var o: [String: JSONValue] = ["rev": 4, "tasks": [], "goals": .array(goals.map(wire)), "offers": .array(offers.map(wire))]
        if bots { o["goal_bots"] = true }
        return .object(o)
    }

    private nonisolated static func answer(_ offer: TodoOffer, goals: [Goal] = [goal()]) -> JSONValue {
        .object(["rev": 5, "offer": wire(offer), "sections": [], "goals": .array(goals.map(wire))])
    }

    private func store(_ client: PagesFakeClient) -> TasksStore {
        TasksStore(api: TasksAPI(client: client), account: client.account, directory: nil)
    }

    @Test func goalBotsNeedTheAddOnsWord() async {
        let old = PagesFakeClient { _ in Self.list(offers: [], bots: false) }
        let s = store(old)
        await s.refresh()
        #expect(s.goalsSupported && !s.goalBotsSupported && !s.goalPagesSupported, "0.9.65: goals, no bots")
        #expect(await s.keepGoing("g_1") == false, "Keep Going stays on this device")
        #expect(!old.log.contains { $0.method == "PATCH" })
        let new = PagesFakeClient { _ in Self.list(offers: []) }
        let t = store(new)
        await t.refresh()
        #expect(t.goalBotsSupported)
    }

    @Test func acceptShowsAtOnceAndSendsTheGoalsAnswer() async throws {
        let client = PagesFakeClient { _ in Self.list(offers: [Self.offer()]) }
        let s = store(client)
        await s.refresh()
        var accepted = Self.offer(state: "accepted"); accepted.added = ["t_9"]; accepted.inGoal = false
        let done = accepted
        client.respond { request in
            if request.method == "POST" {
                try await Task.sleep(for: .milliseconds(60))
                return Self.answer(done)
            }
            return Self.list(offers: [done])
        }
        let answering = Task { await s.answerOffer("of_1", .accept, plan: true, inGoal: false) }
        try await Task.sleep(for: .milliseconds(15))
        #expect(s.offers.first?.state == "accepted" && s.offers.first?.inGoal == false, "the card changes at once")
        #expect(await answering.value)
        let sent = try #require(client.log.first { $0.method == "POST" })
        #expect(sent.path == Self.route + "/tasks/offers/of_1")
        #expect(sent.body?["action"]?.string == "accept" && sent.body?["plan"]?.bool == true && sent.body?["in_goal"]?.bool == false)
        #expect(s.offers.first?.added == ["t_9"])
    }

    @Test func keepTheGoalNoPlanOnAPlanDeclinesIt() async throws {
        let client = PagesFakeClient { _ in Self.list(offers: [Self.offer("plan")]) }
        let s = store(client)
        await s.refresh()
        client.respond { request in
            if request.method == "POST" { try await Task.sleep(for: .milliseconds(60)); return Self.answer(Self.offer("plan", state: "declined")) }
            return Self.list(offers: [Self.offer("plan", state: "declined")])
        }
        let answering = Task { await s.answerOffer("of_1", .accept, plan: false) }
        try await Task.sleep(for: .milliseconds(15))
        #expect(s.offers.first?.state == "declined", "as the gateway does")
        #expect(await answering.value)
        #expect(client.log.first { $0.method == "POST" }?.body?["plan"]?.bool == false)
    }

    @Test func declineAndUndo() async throws {
        let client = PagesFakeClient { _ in Self.list(offers: [Self.offer()]) }
        let s = store(client)
        await s.refresh()
        client.respond { request in
            request.method == "POST" ? Self.answer(Self.offer(state: "declined")) : Self.list(offers: [Self.offer(state: "declined")])
        }
        #expect(await s.answerOffer("of_1", .decline))
        #expect(s.offers.first?.state == "declined")
        #expect(GoalOffers.foot(try #require(s.offers.first), past: false).line == "Not now")

        let accepted = Self.offer(state: "accepted")
        client.respond { _ in Self.list(offers: [accepted]) }
        await s.refresh(force: true)
        var undone = Self.offer(state: "undone"); undone.kept = ["t_1"]
        let back = undone
        client.respond { request in request.method == "POST" ? Self.answer(back) : Self.list(offers: [back]) }
        #expect(await s.answerOffer("of_1", .undo))
        #expect(client.log.last { $0.method == "POST" }?.body?["action"]?.string == "undo")
        #expect(s.offers.first.flatMap(GoalOffers.done) == "Undone, except what you changed")
    }

    @Test func answeredOnAnotherDeviceShowsWhatBecameOfIt() async throws {
        let client = PagesFakeClient { _ in Self.list(offers: [Self.offer("checkin")]) }
        let s = store(client)
        await s.refresh()
        #expect(GoalOffers.today(s.offers, goals: s.goals)?.id == "of_1")
        var there = Self.offer("checkin", state: "accepted"); there.added = ["t_2"]
        let theirs = there
        client.respond { _ in Self.list(offers: [theirs]) }
        await s.refresh(force: true)
        #expect(GoalOffers.today(s.offers, goals: s.goals) == nil, "Today's card goes")
        let foot = GoalOffers.foot(try #require(s.offers.first), past: false)
        #expect(foot.main == nil && foot.line == "Added 1 task" && foot.undo)
    }

    @Test func aConflictPutsTheCardBackAndReadsAgain() async throws {
        let client = PagesFakeClient { _ in Self.list(offers: [Self.offer()]) }
        let s = store(client)
        await s.refresh()
        var notices: [String] = []
        s.onNotice = { notices.append($0) }
        let elsewhere = Self.offer(state: "accepted")
        client.respond { request in
            if request.method == "POST" { throw httpError(409, "That offer was already answered.") }
            return Self.list(offers: [elsewhere])
        }
        #expect(await s.answerOffer("of_1", .decline) == false)
        #expect(notices == ["That was already answered on another device."])
        for _ in 0..<40 where s.offers.first?.state != "accepted" { try await Task.sleep(for: .milliseconds(25)) }
        #expect(s.offers.first?.state == "accepted", "read again: what the other device did")
    }

    @Test func aNewGoalsLeadIsSetRightAfterItIsMade() async throws {
        let client = PagesFakeClient { _ in Self.list(offers: [], goals: []) }
        let s = store(client)
        await s.refresh()
        let made = Self.goal(lead: nil), led = Self.goal()
        client.respond { request in request.method == "POST" ? Self.wire(made) : Self.wire(led) }
        var body = GoalWire.newGoal(title: "Learn guitar")
        body["lead"] = "default"
        let answer = await s.addGoal(body)
        #expect(answer?.lead == "default")
        let post = try #require(client.log.first { $0.method == "POST" })
        #expect(post.path == Self.route + "/goals" && post.body?["lead"] == nil, "POST /goals takes no lead")
        let patch = try #require(client.log.first { $0.method == "PATCH" })
        #expect(patch.path == Self.route + "/goals/g_1" && patch.body?["lead"]?.string == "default" && ActivityJSON.int(patch.body?["rev"]) == 3)
        #expect(s.goal("g_1")?.lead == "default")
    }
}
