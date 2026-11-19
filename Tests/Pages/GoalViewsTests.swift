// [goals] Goals step 1's rules (docs/goals.md "Progress and pace"): the ring's fraction in each of its four cases and
// counting down, the even pace and every pace word, the next task across milestones, the Goals view's groups, the two
// offers (and Not Yet), a task's milestone cleared when its goal changes, and decoding with and without goals.

import Foundation
import Testing
@testable import HermesHQNative

struct GoalViewsTests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()
    /// 2026-11-16 09:41 in Chicago: day 15 of a goal made Nov 1 and due Dec 1 (30 days), so an even pace is 50%.
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9, minute: 41))!
    private static let created = "2026-11-01T08:00:00-05:00"

    private static func task(_ id: String, goal: String? = nil, milestone: String? = nil, done: Bool = false,
                             position: Double = 0) -> TodoTask {
        var o: [String: JSONValue] = ["id": .string(id), "rev": 2, "title": .string(id), "who": "me",
                                      "status": .string(done ? "done" : "open"), "position": .number(position),
                                      "created_at": "2026-11-02T08:00:00-06:00", "updated_at": "2026-11-02T08:00:00-06:00"]
        if let goal { o["goal"] = .string(goal) }
        if let milestone { o["milestone"] = .string(milestone) }
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
    }

    private static func goal(_ id: String = "g_1", status: GoalState = .active, due: String? = "2026-12-01",
                             measure: GoalMeasure? = nil, milestones: [GoalMilestone] = [], position: Double = 0,
                             statusAt: String? = nil) -> Goal {
        Goal(id: id, title: id, status: status, statusAt: statusAt, due: due, position: position, measure: measure,
             milestones: milestones, createdAt: created, updatedAt: created)
    }

    private static func milestones(done: Int, of count: Int) -> [GoalMilestone] {
        (0..<count).map { GoalMilestone(id: "ms_\($0)", title: "Step \($0 + 1)", done: $0 < done) }
    }

    // MARK: Fraction

    @Test func theRingFollowsTheNumberThenMilestonesThenTasks() throws {
        let tasks = (0..<6).map { Self.task("t\($0)", goal: "g_1", done: $0 < 4) }
        // 1. A number: 340 of 1,000, whatever the milestones and tasks say.
        let numbered = Self.goal(measure: GoalMeasure(unit: "testers", start: 0, target: 1000, now: 340), milestones: Self.milestones(done: 4, of: 5))
        #expect(GoalViews.fraction(numbered, tasks: tasks) == 0.34)
        #expect(GoalViews.line(numbered, tasks: tasks, now: Self.now, calendar: Self.calendar) == "340 of 1,000 · by Dec 1")
        // 2. Milestones, no number: 2 of 5.
        let staged = Self.goal(milestones: Self.milestones(done: 2, of: 5))
        #expect(GoalViews.fraction(staged, tasks: tasks) == 0.4)
        #expect(GoalViews.line(staged, tasks: tasks, now: Self.now, calendar: Self.calendar) == "2 of 5 milestones · by Dec 1")
        // 3. Only tasks: 4 of 6.
        let plain = Self.goal(due: nil)
        #expect(try #require(GoalViews.fraction(plain, tasks: tasks)) == 4.0 / 6.0)
        #expect(GoalViews.line(plain, tasks: tasks, now: Self.now, calendar: Self.calendar) == "4 of 6 tasks")
        // 4. Nothing: the ring is empty and says so.
        let bare = Self.goal("g_2", due: nil)
        #expect(GoalViews.fraction(bare, tasks: tasks) == nil)
        #expect(GoalViews.line(bare, tasks: tasks, now: Self.now, calendar: Self.calendar) == "No plan yet")
        #expect(GoalViews.barLine(bare, tasks: tasks, now: Self.now, calendar: Self.calendar) == "No plan yet")
        #expect(GoalViews.spoken(bare, tasks: tasks, now: Self.now, calendar: Self.calendar) == "g_2, No plan yet")
    }

    @Test func aNumberCanCountDownAndIsHeldToTheRing() {
        let weight = GoalMeasure(unit: "lbs", start: 185, target: 170, now: 180)
        #expect(weight.countsDown)
        #expect(abs(GoalViews.fraction(weight) - 1.0 / 3.0) < 0.0001)
        #expect(GoalViews.measureWords(weight, unit: true) == "180, down to 170 lbs")
        #expect(GoalViews.fraction(GoalMeasure(unit: "lbs", start: 185, target: 170, now: 190)) == 0, "gone the wrong way: empty, never below")
        #expect(GoalViews.fraction(GoalMeasure(start: 0, target: 10, now: 14)) == 1, "past the target: full, never over")
        #expect(GoalViews.measureWords(GoalMeasure(unit: "$", start: 0, target: 5000, now: 1200.5), unit: true) == "$1,200.5 of $5,000")
        #expect(GoalViews.percent(0.349) == "34%")
    }

    // MARK: Pace

    @Test func anEvenPaceRunsFromTheDayItWasMadeToItsDate() throws {
        let goal = Self.goal()
        #expect(GoalViews.evenPace(goal, now: Self.now, calendar: Self.calendar) == 0.5)
        let start = Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))!
        #expect(GoalViews.evenPace(goal, now: start, calendar: Self.calendar) == 0, "before it was made: nothing yet")
        let after = Self.calendar.date(from: DateComponents(year: 2026, month: 12, day: 9))!
        #expect(GoalViews.evenPace(goal, now: after, calendar: Self.calendar) == 1)
        #expect(GoalViews.evenPace(Self.goal(due: nil), now: Self.now, calendar: Self.calendar) == nil)
    }

    @Test func paceIsSaidInWords() {
        func pace(_ now: Double) -> GoalPace? {
            GoalViews.pace(Self.goal(measure: GoalMeasure(start: 0, target: 100, now: now)), tasks: [], now: Self.now, calendar: Self.calendar)
        }
        #expect(pace(50) == .onPace)
        #expect(pace(46) == .onPace, "within 5 points is on pace")
        #expect(pace(70) == .ahead)
        #expect(pace(30) == .behind(days: 6))     // 20 points of 30 days
        #expect(pace(20) == .behind(days: 9))
        #expect(pace(30)?.words == "6 days behind")
        #expect(pace(20)?.words == "a week behind")
        #expect(GoalPace.behind(days: 1).words == "1 day behind")
        #expect(GoalPace.behind(days: 13).words == "a week behind")
        #expect(GoalPace.behind(days: 14).words == "2 weeks behind")
        #expect(GoalPace.behind(days: 25).words == "3 weeks behind")
        #expect(GoalPace.onPace.words == "on pace" && GoalPace.ahead.words == "ahead")
        #expect(GoalPace.late(days: 1).words == "1 day late" && GoalPace.late(days: 3).words == "3 days late")
        #expect(GoalPace.onPace.tone == .good && GoalPace.ahead.tone == .good)
        #expect(GoalPace.behind(days: 3).tone == .behind && GoalPace.late(days: 3).tone == .late)
        let behind = Self.goal(measure: GoalMeasure(start: 0, target: 100, now: 20))
        #expect(GoalViews.barLine(behind, tasks: [], now: Self.now, calendar: Self.calendar) == "20% · an even pace would be 50% today")
        let even = Self.goal(milestones: Self.milestones(done: 2, of: 4))
        #expect(GoalViews.barLine(even, tasks: [], now: Self.now, calendar: Self.calendar) == "2 of 4 milestones · on pace")
    }

    @Test func pastItsDateItIsLateAndOnlyAnActiveGoalHasAPace() {
        let late = Self.goal(due: "2026-11-10", measure: GoalMeasure(start: 0, target: 100, now: 90))
        #expect(GoalViews.pace(late, tasks: [], now: Self.now, calendar: Self.calendar) == .late(days: 6))
        #expect(GoalViews.left(late, now: Self.now, calendar: Self.calendar) == "6 days late")
        let planless = Self.goal(due: "2026-11-10")
        #expect(GoalViews.pace(planless, tasks: [], now: Self.now, calendar: Self.calendar) == .late(days: 6), "late even with no plan")
        #expect(GoalViews.pace(Self.goal(due: "2026-12-01"), tasks: [], now: Self.now, calendar: Self.calendar) == nil, "no plan, not late: no pace")
        for status in [GoalState.paused, .achieved, .letGo] {
            #expect(GoalViews.pace(Self.goal(status: status, due: "2026-11-10", measure: GoalMeasure(start: 0, target: 100, now: 10)),
                                   tasks: [], now: Self.now, calendar: Self.calendar) == nil)
        }
        #expect(GoalViews.pace(Self.goal(due: nil, measure: GoalMeasure(start: 0, target: 100, now: 10)), tasks: [], now: Self.now,
                               calendar: Self.calendar) == nil, "no date, no pace")
        #expect(GoalViews.left(Self.goal(due: "2026-11-16"), now: Self.now, calendar: Self.calendar) == "Due today")
        #expect(GoalViews.left(Self.goal(due: "2026-11-17"), now: Self.now, calendar: Self.calendar) == "1 day left")
        #expect(GoalViews.left(Self.goal(due: "2027-01-03"), now: Self.now, calendar: Self.calendar) == "48 days left")
        #expect(GoalViews.left(Self.goal(due: "2027-03-16"), now: Self.now, calendar: Self.calendar) == "17 weeks left")
        #expect(GoalViews.left(Self.goal(status: .achieved), now: Self.now, calendar: Self.calendar) == nil)
        #expect(GoalViews.dateRow(Self.goal(due: "2027-01-31"), now: Self.now, calendar: Self.calendar) == "By Sun, Jan 31, 2027")
        #expect(GoalViews.dateRow(Self.goal(due: "2026-12-01"), now: Self.now, calendar: Self.calendar) == "By Tue, Dec 1")
    }

    // MARK: Next task and groups

    @Test func theNextTaskIsTheCurrentMilestonesFirstOpenOneInOrder() {
        let goal = Self.goal(milestones: [GoalMilestone(id: "a", title: "A", done: true), GoalMilestone(id: "b", title: "B"),
                                          GoalMilestone(id: "c", title: "C")])
        var tasks = [Self.task("in-a", goal: "g_1", milestone: "a", position: 1),
                     Self.task("b-done", goal: "g_1", milestone: "b", done: true, position: 1),
                     Self.task("b-second", goal: "g_1", milestone: "b", position: 3),
                     Self.task("b-first", goal: "g_1", milestone: "b", position: 2),
                     Self.task("c-1", goal: "g_1", milestone: "c", position: 0),
                     Self.task("loose", goal: "g_1", position: 0),
                     Self.task("other", goal: "g_2", milestone: "b", position: 0)]
        #expect(GoalViews.nextTask(goal, tasks: tasks)?.id == "b-first", "the current milestone's, in position order; not a done milestone's")
        #expect(GoalViews.count(GoalViews.tasks(of: goal, milestone: "b", in: tasks)) == "1 of 3")
        #expect(GoalViews.looseTasks(of: goal, in: tasks).map(\.id) == ["loose"])
        // The current milestone's tasks all done: the first open task under no milestone.
        tasks = tasks.filter { !$0.id.hasPrefix("b-") || $0.id == "b-done" }
        #expect(GoalViews.nextTask(goal, tasks: tasks)?.id == "loose")
        #expect(GoalViews.nextTask(goal, tasks: tasks.filter { $0.id != "loose" }) == nil)
        // A task under a milestone the goal no longer has counts as loose.
        let stray = [Self.task("stray", goal: "g_1", milestone: "gone")]
        #expect(GoalViews.looseTasks(of: goal, in: stray).map(\.id) == ["stray"])
        #expect(GoalViews.spoken(goal, tasks: [Self.task("b-first", goal: "g_1", milestone: "b")], now: Self.now, calendar: Self.calendar)
                == "g_1, 33 percent, 5 days behind, next: b-first")
    }

    @Test func goalsGroupByStatus() {
        let goals = [Self.goal("second", position: 2), Self.goal("first", position: 1),
                     Self.goal("paused", status: .paused, position: 3),
                     Self.goal("won-early", status: .achieved, statusAt: "2026-10-01T08:00:00-05:00"),
                     Self.goal("won-late", status: .achieved, statusAt: "2026-11-10T08:00:00-06:00"),
                     Self.goal("dropped", status: .letGo, statusAt: "2026-11-01T08:00:00-05:00")]
        let groups = GoalViews.groups(goals)
        #expect(groups.active.map(\.id) == ["first", "second"])
        #expect(groups.someday.map(\.id) == ["paused"])
        #expect(groups.achieved.map(\.id) == ["won-late", "won-early"], "latest first")
        #expect(groups.letGo.map(\.id) == ["dropped"])
        #expect(GoalViews.activeCount(goals) == 2)
        #expect(GoalViews.paused(goals) == ["paused"])
        #expect(GoalViews.groups([]).isEmpty)
        #expect(GoalViews.statusLine(goals[2], now: Self.now, calendar: Self.calendar) == "Paused Nov 1", "no status day: when it last changed")
        #expect(GoalViews.statusLine(goals[4], now: Self.now, calendar: Self.calendar) == "Achieved Nov 10")
        #expect(GoalViews.statusLine(goals[0], now: Self.now, calendar: Self.calendar) == nil)
        // A new goal takes the first colour no active goal uses.
        #expect(GoalViews.nextColor([Self.goal("a"), Self.goal("b", status: .paused)]) != .blue)
        #expect(GoalViews.nextColor([Self.goal("b", status: .paused)]) == .blue)
    }

    // MARK: Offers

    @Test func aMilestoneWhoseTasksAreAllDoneIsOfferedNeverTicked() {
        let goal = Self.goal(milestones: [GoalMilestone(id: "a", title: "Launch week"), GoalMilestone(id: "b", title: "Later")])
        let open = [Self.task("t1", goal: "g_1", milestone: "a", done: true), Self.task("t2", goal: "g_1", milestone: "a")]
        #expect(GoalViews.offer(goal, tasks: open) == nil)
        let done = [Self.task("t1", goal: "g_1", milestone: "a", done: true), Self.task("t2", goal: "g_1", milestone: "a", done: true)]
        let offer = GoalViews.offer(goal, tasks: done)
        #expect(offer == .milestone(goal.milestones[0]))
        #expect(offer?.text == "That was the last task in Launch week. Mark it done?" && offer?.yes == "Mark Done")
        #expect(goal.milestones[0].done == false, "only offered")
        #expect(GoalViews.offer(goal, tasks: []) == nil, "a milestone with no tasks is never offered")
        // Not Yet holds until something under it changes.
        let key = offer!.key(goal: goal)
        let said = [key: GoalViews.signature(offer!, goal: goal, tasks: done)]
        #expect(GoalViews.offer(goal, tasks: done, notYet: said) == nil)
        let more = done + [Self.task("t3", goal: "g_1", milestone: "a", done: true)]
        #expect(GoalViews.offer(goal, tasks: more, notYet: said) == .milestone(goal.milestones[0]))
        // A paused goal offers nothing.
        var paused = goal
        paused.status = "paused"
        #expect(GoalViews.offer(paused, tasks: done) == nil)
    }

    @Test func everyMilestoneDoneOffersAchieved() {
        let goal = Self.goal(milestones: Self.milestones(done: 3, of: 3))
        let offer = GoalViews.offer(goal, tasks: [])
        #expect(offer == .achieved)
        #expect(offer?.text == "Every milestone is done. Mark this goal achieved?" && offer?.yes == "Mark Achieved")
        #expect(offer?.key(goal: goal) == "goal:g_1")
        #expect(GoalViews.offer(goal, tasks: [], notYet: ["goal:g_1": GoalViews.signature(.achieved, goal: goal, tasks: [])]) == nil)
        #expect(GoalViews.offer(Self.goal(), tasks: []) == nil, "no milestones: nothing to offer")
        #expect(GoalViews.offer(Self.goal(status: .achieved, milestones: Self.milestones(done: 3, of: 3)), tasks: []) == nil)
    }

    // MARK: A task's goal

    @Test func changingATasksGoalClearsItsMilestone() {
        let goals = [Self.goal("g_1", milestones: [GoalMilestone(id: "a", title: "A")]), Self.goal("g_2")]
        #expect(GoalViews.assign(goal: "g_1", milestone: "a", goals: goals) == ["goal": "g_1", "milestone": "a"])
        #expect(GoalViews.assign(goal: "g_2", milestone: "a", goals: goals) == ["goal": "g_2", "milestone": .null], "not that goal's milestone")
        #expect(GoalViews.assign(goal: nil, milestone: "a", goals: goals) == ["goal": .null, "milestone": .null])
        let task = Self.task("t", goal: "g_1", milestone: "a")
        #expect(GoalViews.withMilestoneRule(["goal": "g_2"], task: task) == ["goal": "g_2", "milestone": .null])
        #expect(GoalViews.withMilestoneRule(["goal": .null], task: task) == ["goal": .null, "milestone": .null])
        #expect(GoalViews.withMilestoneRule(["goal": "g_1"], task: task) == ["goal": "g_1"], "the same goal keeps it")
        #expect(GoalViews.withMilestoneRule(["title": "x"], task: task) == ["title": "x"])
        #expect(GoalViews.withMilestoneRule(["goal": "g_2", "milestone": "b"], task: task) == ["goal": "g_2", "milestone": "b"])
    }

    // MARK: Decoding

    @Test func theListAnswerReadsGoalsOrTheirAbsence() throws {
        let with = try JSONDecoder().decode(TodoListAnswer.self, from: JSONValue.object([
            "rev": 4,
            "tasks": .array([.object(["id": "t_1", "rev": 1, "title": "Write the launch email", "who": "me", "status": "open", "goal": "g_1", "milestone": "ms_1"]),
                             .object(["id": "t_2", "rev": 1, "title": "Loose", "who": "me", "status": "open", "goal": "", "milestone": "ms_1"])]),
            "goals": .array([
                .object(["id": "g_1", "rev": 3, "title": "1,000 public testers", "status": "active", "color": "orange", "due": "2027-01-31",
                         "position": 5, "measure": ["unit": "testers", "start": 0, "target": 1000, "now": 340,
                                                     "history": .array([["at": "2026-11-01T08:00:00-05:00", "value": 60], "junk"])],
                         "milestones": .array([["id": "ms_1", "title": "Launch week", "done": false], ["title": "no id"]])]),
                .object(["id": "g_2", "title": "Later", "status": "someday_maybe", "color": "chartreuse"]),
                .object(["title": "no id at all"]),
            ]),
        ]).encoded())
        let goals = try #require(with.goals)
        #expect(goals.map(\.id) == ["g_1", "g_2"], "one bad goal never loses the others")
        #expect(goals[0].measure?.now == 340 && goals[0].measure?.history.count == 1 && goals[0].tint == .orange)
        #expect(goals[0].milestones.map(\.id) == ["ms_1"])
        #expect(goals[1].state == .active && goals[1].status == "someday_maybe", "an unknown status shows as active and is kept as sent")
        #expect(goals[1].tint == .blue && goals[1].milestones.isEmpty && goals[1].measure == nil)
        #expect(with.tasks?.first?.goal == "g_1" && with.tasks?.first?.milestone == "ms_1")
        #expect(with.tasks?.count == 2 && with.tasks?.last?.goal == nil && with.tasks?.last?.milestone == nil, "no goal, no milestone")

        let without = try JSONDecoder().decode(TodoListAnswer.self, from: JSONValue.object([
            "rev": 4, "tasks": .array([.object(["id": "t_1", "rev": 1, "title": "Old add-on", "who": "me", "status": "open"])]),
        ]).encoded())
        #expect(without.goals == nil, "an older add-on keeps no goals")
        #expect(without.tasks?.first?.goal == nil)

        let none = try JSONDecoder().decode(TodoListAnswer.self, from: JSONValue.object(["rev": 4, "tasks": [], "goals": []]).encoded())
        #expect(none.goals == [], "keeps goals, has none")
    }

    @Test func aGoalRoundTripsAndA409sGoalIsFoundWhereverItIs() throws {
        let goal = Self.goal(measure: GoalMeasure(unit: "km", start: 0, target: 10, now: 3), milestones: Self.milestones(done: 1, of: 2))
        let data = try JSONEncoder().encode(goal)
        #expect(try JSONDecoder().decode(Goal.self, from: data) == goal)
        let wire = try JSONValue.parse(data)
        #expect(try GoalsAPI.goal(JSONValue.object(["goal": wire]).encoded()) == goal)
        #expect(try GoalsAPI.goal(JSONValue.object(["detail": ["goal": wire]]).encoded()) == goal)
        let clash = HTTPError(status: 409, body: String(decoding: try JSONValue.object(["detail": ["goal": wire]]).encoded(), as: UTF8.self))
        #expect(GoalsAPI.conflict(clash) == goal)
        #expect(GoalsAPI.conflict(httpError(500, "boom")) == nil)
    }

    @Test func aPatchIsAppliedHereAsTheGatewayWill() {
        let base = Self.goal(measure: GoalMeasure(unit: "testers", start: 0, target: 1000, now: 340),
                             milestones: [GoalMilestone(id: "a", title: "A", done: true, doneAt: "2026-11-02T08:00:00-06:00"),
                                          GoalMilestone(id: "b", title: "B")])
        let moved = GoalWire.applying(["measure_now": 400], to: base)
        #expect(moved.measure?.now == 400 && moved.measure?.history.last?.value == 400 && moved.measure?.at != nil)
        let ticked = GoalWire.applying(["milestones": GoalWire.milestones([base.milestones[0], GoalMilestone(id: "b", title: "B", done: true)])], to: base)
        #expect(ticked.milestones[0].doneAt == "2026-11-02T08:00:00-06:00", "an unchanged tick keeps its day")
        #expect(ticked.milestones[1].done && ticked.milestones[1].doneAt != nil)
        let paused = GoalWire.applying(["status": "paused"], to: base)
        #expect(paused.state == .paused && paused.statusAt != nil)
        // A 409: sent again when the other edit left these fields alone, else theirs stands.
        var theirs = base
        theirs.rev = 5
        theirs.title = "Renamed elsewhere"
        #expect(GoalWire.resolve(base: base, current: theirs, fields: ["measure_now": 400]) == .resend(rev: 5))
        #expect(GoalWire.resolve(base: base, current: theirs, fields: ["title": "Mine"]) == .theirs)
    }
}
