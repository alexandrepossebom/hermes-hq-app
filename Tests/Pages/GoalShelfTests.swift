// [goals] Goals step 2's rules (docs/goals.md "Step 2"): the shelf card's short line, the shelf's cards and their order,
// when the shelf shows, what each card says next, the stacked shelf and the heading's words, the goal's mark for each
// status, and a search's Goals group and a task found by its goal's and its milestone's names.

import Foundation
import Testing
@testable import HermesHQNative

struct GoalShelfTests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()
    /// 2026-12-14 09:41 in Chicago (board 1's Monday).
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 12, day: 14, hour: 9, minute: 41))!
    private static let created = "2026-11-01T08:00:00-05:00"

    private static func task(_ id: String, title: String? = nil, goal: String? = nil, milestone: String? = nil,
                             done: Bool = false, position: Double = 0, helper: String? = nil) -> TodoTask {
        var o: [String: JSONValue] = ["id": .string(id), "rev": 2, "title": .string(title ?? id), "who": "me",
                                      "status": .string(done ? "done" : "open"), "position": .number(position),
                                      "created_at": "2026-11-02T08:00:00-06:00", "updated_at": "2026-11-02T08:00:00-06:00"]
        if let goal { o["goal"] = .string(goal) }
        if let milestone { o["milestone"] = .string(milestone) }
        if let helper { o["who"] = "together"; o["helper"] = .string(helper) }
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
    }

    private static func goal(_ id: String = "g_1", title: String? = nil, why: String = "", status: GoalState = .active,
                             due: String? = "2027-01-31", measure: GoalMeasure? = nil, milestones: [GoalMilestone] = [],
                             position: Double = 0, statusAt: String? = nil) -> Goal {
        Goal(id: id, title: title ?? id, why: why, status: status, statusAt: statusAt, due: due, position: position,
             measure: measure, milestones: milestones, createdAt: created, updatedAt: created)
    }

    private static func milestones(done: Int, of count: Int) -> [GoalMilestone] {
        (0..<count).map { GoalMilestone(id: "ms_\($0)", title: "Step \($0 + 1)", done: $0 < done) }
    }

    private static func line(_ goal: Goal, _ tasks: [TodoTask] = []) -> String {
        GoalViews.shortLine(goal, tasks: tasks, now: now, calendar: calendar)
    }

    // MARK: The short line

    @Test func theShortLineIsTheNumberOrTheCountThenTheDate() {
        // The board's three: "340 · by Jan 31", "1 of 4 · by Apr 11", "4 of 6 · by Dec 27".
        let testers = Self.goal(measure: GoalMeasure(unit: "testers", start: 0, target: 1000, now: 340), milestones: Self.milestones(done: 2, of: 5))
        #expect(Self.line(testers) == "340 · by Jan 31", "the number alone, whatever the milestones; no year in the next months")
        let run = Self.goal("g_10k", due: "2027-04-11", milestones: Self.milestones(done: 1, of: 4))
        #expect(Self.line(run) == "1 of 4 · by Apr 11", "milestones done of all")
        let trip = Self.goal("g_trip", due: "2026-12-27")
        let tasks = (0..<6).map { Self.task("t\($0)", goal: "g_trip", done: $0 < 4) } + [Self.task("other", goal: "g_else")]
        #expect(Self.line(trip, tasks) == "4 of 6 · by Dec 27", "tasks done of all, only this goal's")
    }

    @Test func theShortLineSaysWhatThereIs() {
        #expect(Self.line(Self.goal(measure: GoalMeasure(unit: "$", start: 0, target: 5000, now: 1200))) == "$1,200 · by Jan 31")
        #expect(Self.line(Self.goal(due: nil, measure: GoalMeasure(start: 0, target: 10, now: 12.5))) == "12.5", "no date: the number alone")
        #expect(Self.line(Self.goal()) == "by Jan 31", "no plan: only its date")
        #expect(Self.line(Self.goal(due: nil)) == "", "neither: empty (the card keeps the line's room)")
        #expect(Self.line(Self.goal(due: "2028-03-01")) == "by Mar 1, 2028", "far off: with its year")
        #expect(Self.line(Self.goal(due: "2026-12-01")) == "by Dec 1", "just past")
    }

    // MARK: The cards

    @Test func theCardsAreTheActiveGoalsInYourOrder() {
        let goals = [
            Self.goal("g_c", position: 3), Self.goal("g_a", position: 1),
            Self.goal("g_paused", status: .paused, position: 0.5),
            Self.goal("g_done", status: .achieved, statusAt: "2026-12-01T08:00:00-06:00"),
            Self.goal("g_gone", status: .letGo, statusAt: "2026-12-02T08:00:00-06:00"),
            Self.goal("g_b", position: 2),
        ]
        let cards = GoalShelf.cards(goals, tasks: [], now: Self.now, calendar: Self.calendar)
        #expect(cards.map(\.id) == ["g_a", "g_b", "g_c"])
    }

    @Test func aCardSaysWhatIsNext() throws {
        let staged = Self.goal(milestones: [GoalMilestone(id: "ms_1", title: "Beta", done: true), GoalMilestone(id: "ms_2", title: "Launch week")])
        let tasks = [
            Self.task("t_sent", title: "Send the beta email", goal: "g_1", milestone: "ms_2", done: true, position: 1),
            Self.task("t_notes", title: "Post the build notes", goal: "g_1", milestone: "ms_2", position: 2),
            Self.task("t_demo", title: "Record the demo", goal: "g_1", milestone: "ms_2", position: 3),
        ]
        let card = GoalShelf.card(staged, tasks: tasks, now: Self.now, calendar: Self.calendar)
        #expect(card.next == .task(id: "t_notes", title: "Post the build notes"))
        #expect(card.next.words == "Next: Post the build notes")
        #expect(card.line == "1 of 2 · by Jan 31")
        #expect(card.fraction == 0.5)
        #expect(card.spoken.hasPrefix("g_1, 50 percent"))
        #expect(card.spoken.hasSuffix("next: Post the build notes"), "read as the Goals view's card is")
        #expect(card.color == .blue)
        // Everything done: nothing next.
        let allDone = tasks.map { Self.task($0.id, title: $0.title, goal: "g_1", milestone: "ms_2", done: true) }
        #expect(GoalShelf.card(staged, tasks: allDone, now: Self.now, calendar: Self.calendar).next == .nothing)
        #expect(GoalShelfNext.nothing.words == "Nothing next")
        // No number, no milestones, no tasks: no plan.
        let bare = GoalShelf.card(Self.goal("g_bare", title: ""), tasks: [], now: Self.now, calendar: Self.calendar)
        #expect(bare.next == .noPlan && bare.next.words == "No plan yet")
        #expect(bare.fraction == nil)
        #expect(bare.title == "Untitled Goal")
    }

    // MARK: When it shows

    @Test func theShelfShowsOnTodayAloneWithAnActiveGoal() {
        let active = [Self.goal()], pausedOnly = [Self.goal(status: .paused), Self.goal("g_2", status: .achieved)]
        func shows(_ view: TodoView = .today, searching: Bool = false, scope: String = "all", supported: Bool = true,
                   goals: [Goal]? = nil) -> Bool {
            GoalShelf.shows(view: view, searching: searching, scope: scope, goalsSupported: supported, goals: goals ?? active)
        }
        #expect(shows())
        for view in [TodoView.upcoming, .inbox, .goals, .bots, .list("sec_home")] { #expect(!shows(view), "only on Today: \(view)") }
        #expect(!shows(searching: true), "not in a search")
        #expect(shows(scope: "@me"), "with Me")
        #expect(!shows(scope: "research"), "hidden with one bot picked")
        #expect(!shows(supported: false), "an older add-on")
        #expect(!shows(goals: []), "no goals")
        #expect(!shows(goals: pausedOnly), "no active goal")
    }

    @Test func atTheAccessibilitySizesTwoCardsAtMostAndTheHeadingsWords() {
        let cards = GoalShelf.cards([Self.goal("g_a", position: 1), Self.goal("g_b", position: 2), Self.goal("g_c", position: 3)],
                                    tasks: [], now: Self.now, calendar: Self.calendar)
        #expect(GoalShelf.drawn(cards, stacked: false).count == 3)
        #expect(GoalShelf.drawn(cards, stacked: true).map(\.id) == ["g_a", "g_b"])
        #expect(GoalShelf.headingCount(3, folded: false) == nil, "\"Goals\" open")
        #expect(GoalShelf.headingCount(3, folded: true) == 3, "\"Goals 3\" folded")
        #expect(GoalShelf.allWords(3) == "All 3")
        #expect(GoalShelf.headingValue(3, folded: false) == "3, shown")
        #expect(GoalShelf.headingValue(3, folded: true) == "3, hidden")
    }

    // MARK: The mark

    @Test func theMarkIsForAnActiveOrPausedGoal() {
        let goals = GoalState.allCases.map { Self.goal("g_\($0.rawValue)", status: $0) }
        for state in GoalState.allCases {
            let mark = GoalViews.markGoal(Self.task("t", goal: "g_\(state.rawValue)"), goals: goals)
            switch state {
            case .active, .paused: #expect(mark?.id == "g_\(state.rawValue)", "\(state): the mark")
            case .achieved, .letGo: #expect(mark == nil, "\(state): its list's dot again")
            }
        }
        #expect(GoalViews.markGoal(Self.task("t"), goals: goals) == nil, "no goal")
        #expect(GoalViews.markGoal(Self.task("t", goal: "g_deleted"), goals: goals) == nil, "a goal the list no longer has")
    }

    // MARK: Search

    @Test func aSearchFindsGoalsByNameAndWhyInAnyStatus() {
        let goals = [
            Self.goal("g_testers", title: "1,000 public testers", why: "So the public launch opens to a crowd.", position: 2),
            Self.goal("g_10k", title: "Run a 10K", position: 1),
            Self.goal("g_spanish", title: "Learn conversational Spanish", why: "To talk with the neighbours.", status: .paused),
            Self.goal("g_launch", title: "Launch the shop", status: .achieved, statusAt: "2026-12-01T08:00:00-06:00"),
            Self.goal("g_old", title: "Old launch plan", status: .letGo, statusAt: "2026-12-02T08:00:00-06:00"),
            Self.goal("g_paused_launch", title: "Launch party", status: .paused, position: 0.5),
        ]
        #expect(GoalViews.found(goals, query: "10k").map(\.id) == ["g_10k"], "by name, any case")
        #expect(GoalViews.found(goals, query: "neighbours").map(\.id) == ["g_spanish"], "by why, a paused goal")
        #expect(GoalViews.found(goals, query: " Launch ").map(\.id) == ["g_testers", "g_paused_launch", "g_launch", "g_old"],
                "the Goals view's order: active, Someday, Achieved, Let Go")
        #expect(GoalViews.found(goals, query: "").isEmpty)
        #expect(GoalViews.found(goals, query: "#launch").isEmpty, "a tag search finds tasks alone")
        #expect(GoalViews.found(goals, query: "porch").isEmpty)
    }

    @Test func aTaskIsFoundByItsGoalsAndItsMilestonesNames() {
        let goals = [Self.goal("g_10k", title: "Run a 10K", milestones: [GoalMilestone(id: "ms_5k", title: "Run a 5K")]),
                     Self.goal("g_trip", title: "Family trip to the coast", status: .achieved)]
        let shoes = Self.task("t_shoes", title: "Buy real running shoes", goal: "g_10k", milestone: "ms_5k")
        let signup = Self.task("t_signup", title: "Sign up for the race", goal: "g_10k")
        let tickets = Self.task("t_tickets", title: "Book the aquarium tickets", goal: "g_trip")
        let porch = Self.task("t_porch", title: "Fix the porch light")
        let tasks = [shoes, signup, tickets, porch]
        func found(_ words: String, scope: String = "all") -> [String] {
            TodoSections.filtered(tasks, scope: scope, query: words, goals: goals).map(\.id)
        }
        #expect(found("10k") == ["t_shoes", "t_signup"], "by its goal's name")
        #expect(found("5k") == ["t_shoes"], "by its milestone's name")
        #expect(found("coast") == ["t_tickets"], "any status")
        #expect(found("porch") == ["t_porch"], "its own words still")
        #expect(TodoSections.filtered(tasks, scope: "all", query: "10k").isEmpty, "with no goals passed, only its own words")
        #expect(GoalViews.searchWords(shoes, goals: goals) == ["Run a 10K", "Run a 5K"])
        #expect(GoalViews.searchWords(signup, goals: goals) == ["Run a 10K"])
        #expect(GoalViews.searchWords(porch, goals: goals).isEmpty)
        #expect(found("#10k").isEmpty, "a tag search looks at tags alone")
    }
}
