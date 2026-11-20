// [goals step 6] A goal you make gets a bot planning it, and adding bots is one tap (docs/goals.md "Step 6"): which bot
// New Goal starts on (the first time, remembered, No One remembered, the remembered bot gone), when a new lead is asked
// for a plan and when not, the page's "Ask <Bot> for a Plan", the once-a-minute guard, and the team sheet's ticks.

import Foundation
import Testing
@testable import HermesHQNative

struct GoalTeamTests {
    private static let now = Date(timeIntervalSince1970: 1_797_000_000)
    private static let bots = ["inbox", "default", "research", "finance"]

    private static func name(_ id: String) -> String {
        ["default": "Hermes", "research": "Research", "finance": "Finance", "inbox": "Inbox"][id] ?? id
    }

    private static func goal(lead: String? = nil, helpers: [String] = [], milestones: [GoalMilestone] = [],
                             status: String = "active") -> Goal {
        var g = Goal(id: "g_1", title: "Start making social media content", milestones: milestones,
                     createdAt: TodoDates.now(now), updatedAt: TodoDates.now(now))
        g.lead = lead; g.helpers = helpers; g.status = status
        return g
    }

    private static func task(goal: String? = "g_1", done: Bool = false) -> TodoTask {
        var o: [String: JSONValue] = ["id": "t_1", "rev": 2, "title": "Post once", "who": "me", "status": .string(done ? "done" : "open"),
                                      "created_at": .string(TodoDates.now(now)), "updated_at": .string(TodoDates.now(now))]
        if let goal { o["goal"] = .string(goal) }
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
    }

    private static func plan(state: String = "new", goal: String = "g_1", kind: String = "plan", held: Bool = false) -> TodoOffer {
        var o = TodoOffer(id: "of_1", bot: "default", at: TodoDates.now(now), list: "", state: state)
        o.kind = kind; o.goal = goal; o.held = held
        return o
    }

    // MARK: New Goal's Who's helping?

    @Test func newGoalStartsOnTheRootBotTheFirstTime() {
        #expect(GoalPlanWith.start(remembered: nil, bots: Self.bots) == ["default"])
        #expect(GoalPlanWith.start(remembered: nil, bots: ["inbox", "research"]) == ["inbox"], "no root bot: the first bot")
        #expect(GoalPlanWith.start(remembered: nil, bots: []) == [], "no bots: no one")
    }

    @Test func newGoalStartsOnWhatWasPickedLast() {
        #expect(GoalPlanWith.start(remembered: ["research", "finance"], bots: Self.bots) == ["research", "finance"])
        #expect(GoalPlanWith.start(remembered: ["research", "research"], bots: Self.bots) == ["research"])
    }

    @Test func noOneIsRememberedToo() {
        #expect(GoalPlanWith.start(remembered: [], bots: Self.bots) == [])
        let stored = GoalPlanWith.stored([])
        #expect(stored == "")
        #expect(GoalPlanWith.read(stored) == [], "No One reads back as No One, not as the first time")
        #expect(GoalPlanWith.read(nil) == nil)
        #expect(GoalPlanWith.read(GoalPlanWith.stored(["research", "default"])) == ["research", "default"])
    }

    @Test func aRememberedBotThatIsGoneFallsBack() {
        #expect(GoalPlanWith.start(remembered: ["wren"], bots: Self.bots) == ["default"], "all gone: the first time again")
        #expect(GoalPlanWith.start(remembered: ["wren", "finance"], bots: Self.bots) == ["finance"], "the one left leads")
        #expect(GoalPlanWith.start(remembered: ["wren"], bots: ["inbox"]) == ["inbox"])
    }

    @Test func theQuietLineSaysWhatAddWillDo() {
        #expect(GoalPlanWith.note(["default"], botName: Self.name) == "Hermes will offer a plan when you add this.")
        #expect(GoalPlanWith.note(["default", "research"], botName: Self.name) == "Hermes leads. Research helps.")
        #expect(GoalPlanWith.note(["default", "research", "finance"], botName: Self.name) == "Hermes leads. Research and Finance help.")
        #expect(GoalPlanWith.note(["default", "research", "finance", "inbox"], botName: Self.name)
                == "Hermes leads. Research, Finance and Inbox help.")
        #expect(GoalPlanWith.note([], botName: Self.name) == "No bot. You can add one later.")
    }

    // MARK: When a lead is asked for a plan

    @Test func aFirstLeadOnAGoalWithNoPlanIsAsked() {
        let led = Self.goal(lead: "default")
        #expect(GoalPlanAsk.asksNewLead(before: nil, goal: led, tasks: [], offers: []))
        #expect(GoalPlanAsk.asksNewLead(before: nil, goal: led, tasks: [Self.task(done: true)], offers: []), "a done task is no plan")
        #expect(GoalPlanAsk.asksNewLead(before: nil, goal: led, tasks: [Self.task(goal: "g_2")], offers: []), "another goal's task")
    }

    @Test func aGoalWithAPlanIsNotAsked() {
        let milestone = GoalMilestone(id: "m_1", title: "First post")
        #expect(!GoalPlanAsk.asksNewLead(before: nil, goal: Self.goal(lead: "default", milestones: [milestone]), tasks: [], offers: []))
        #expect(!GoalPlanAsk.asksNewLead(before: nil, goal: Self.goal(lead: "default"), tasks: [Self.task()], offers: []), "an open task")
    }

    @Test func aWaitingPlanOfferIsNotAskedAgain() {
        let led = Self.goal(lead: "default")
        #expect(!GoalPlanAsk.asksNewLead(before: nil, goal: led, tasks: [], offers: [Self.plan()]))
        #expect(GoalPlanAsk.asksNewLead(before: nil, goal: led, tasks: [], offers: [Self.plan(state: "declined")]), "an answered plan")
        #expect(GoalPlanAsk.asksNewLead(before: nil, goal: led, tasks: [], offers: [Self.plan(goal: "g_2")]), "another goal's plan")
        #expect(GoalPlanAsk.asksNewLead(before: nil, goal: led, tasks: [], offers: [Self.plan(kind: "checkin")]), "not a plan")
        #expect(GoalPlanAsk.asksNewLead(before: nil, goal: led, tasks: [], offers: [Self.plan(held: true)]), "a held one never shows")
    }

    @Test func onlyAFirstLeadOnAnActiveGoalIsAsked() {
        #expect(!GoalPlanAsk.asksNewLead(before: "research", goal: Self.goal(lead: "default"), tasks: [], offers: []), "it had a lead")
        #expect(!GoalPlanAsk.asksNewLead(before: nil, goal: Self.goal(lead: nil, helpers: ["research"]), tasks: [], offers: []), "no lead")
        #expect(!GoalPlanAsk.asksNewLead(before: nil, goal: Self.goal(lead: "default", status: "paused"), tasks: [], offers: []))
        #expect(!GoalPlanAsk.asksNewLead(before: nil, goal: Self.goal(lead: "default", status: "achieved"), tasks: [], offers: []))
    }

    @Test func thePageOffersTheAskWithALeadAndNoPlan() {
        #expect(GoalPlanAsk.showsAsk(Self.goal(lead: "default"), tasks: [], offers: []))
        #expect(!GoalPlanAsk.showsAsk(Self.goal(), tasks: [], offers: []), "no lead: the Bots row says Add Bots")
        #expect(!GoalPlanAsk.showsAsk(Self.goal(lead: "default"), tasks: [], offers: [Self.plan()]), "hidden while a plan waits")
        #expect(!GoalPlanAsk.showsAsk(Self.goal(lead: "default"), tasks: [Self.task()], offers: []), "gone once a task comes")
        #expect(!GoalPlanAsk.showsAsk(Self.goal(lead: "default", milestones: [GoalMilestone(id: "m", title: "A")]), tasks: [], offers: []))
        #expect(GoalPlanAsk.buttonWords("Hermes") == "Ask Hermes for a Plan")
    }

    // MARK: Once a minute

    @Test func theSameAskIsNotSentTwiceInAMinute() {
        var guard_ = GoalPlanGuard()
        let first = guard_.mayAsk("g_1", now: Self.now)
        let doubleTap = guard_.mayAsk("g_1", now: Self.now.addingTimeInterval(0.3))
        let recent = guard_.recentlyAsked("g_1", now: Self.now.addingTimeInterval(30))
        let fromTheButton = guard_.mayAsk("g_1", now: Self.now.addingTimeInterval(59))
        let another = guard_.mayAsk("g_2", now: Self.now.addingTimeInterval(1))
        let later = guard_.mayAsk("g_1", now: Self.now.addingTimeInterval(61))
        #expect(first)
        #expect(!doubleTap, "a double tap")
        #expect(recent)
        #expect(!fromTheButton, "Edit Goal, then the page's button")
        #expect(another, "another goal")
        #expect(later, "a minute on, it may go again")
        #expect(!guard_.recentlyAsked("g_3", now: Self.now))
    }

    // MARK: The team sheet

    @Test func theFirstTickedLeadsAndTheNextHelps() {
        var pick = GoalTeamPick(lead: nil, helpers: [])
        pick.toggle("default")
        #expect(pick.lead == "default" && pick.helpers.isEmpty)
        pick.toggle("research")
        #expect(pick.lead == "default" && pick.helpers == ["research"])
        #expect(pick.team == ["default", "research"])
        #expect(pick.fields(from: GoalTeamPick(lead: nil, helpers: [])) == ["lead": "default", "helpers": ["research"]])
    }

    @Test func makeLeadSwapsThem() {
        var pick = GoalTeamPick(lead: "default", helpers: ["research", "finance"])
        pick.makeLead("finance")
        #expect(pick.lead == "finance" && pick.helpers == ["research", "default"])
        let before = GoalTeamPick(lead: "default", helpers: ["research", "finance"])
        #expect(pick.fields(from: before) == ["lead": "finance", "helpers": ["research", "default"]])
    }

    @Test func untickingTheLeadHandsItOn() {
        var pick = GoalTeamPick(lead: "default", helpers: ["research", "finance"])
        pick.toggle("default")
        #expect(pick.lead == "research" && pick.helpers == ["finance"])
        pick.toggle("finance")
        #expect(pick.lead == "research" && pick.helpers.isEmpty)
        pick.toggle("research")
        #expect(pick.lead == nil && pick.helpers.isEmpty)
        #expect(pick.fields(from: GoalTeamPick(lead: "research", helpers: [])) == ["lead": .null])
    }

    @Test func aGoalsTeamKeepsTheLeadOutOfItsHelpers() {
        var goal = Self.goal(lead: "default", helpers: ["default", "research", "research"])
        #expect(GoalTeamPick(goal).helpers == ["research"])
        goal.lead = nil
        var pick = GoalTeamPick(goal)
        pick.toggle("finance")
        #expect(pick.lead == nil && pick.helpers == ["default", "research", "finance"], "helpers with no lead: a tick helps")
        pick.makeLead("research")
        #expect(pick.lead == "research" && pick.helpers == ["default", "finance"])
    }

    @Test func eachRowSaysWhereTheBotStands() {
        let pick = GoalTeamPick(lead: "default", helpers: ["research"])
        #expect(pick.spoken("default", name: "Hermes") == "Hermes, on this goal, leads")
        #expect(pick.spoken("research", name: "Research") == "Research, on this goal")
        #expect(pick.spoken("finance", name: "Finance") == "Finance, not on this goal")
    }
}
