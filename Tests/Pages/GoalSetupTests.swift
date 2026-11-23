// [goals set-up] A plan that sets up its goal (docs/goals.md "Set-up"): the plan request's wording and order, a plan
// offer's `setup` and `built_on` decoded (present, absent, partial), the card's rows per key, the once-only rule for
// telling the lead a plan was taken, New Goal's one POST, the lead's line, and "Plan to look at".

import Foundation
import Testing
@testable import HermesHQNative

struct GoalSetupTests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()
    /// Mon 2026-12-14 09:41 in Chicago.
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 12, day: 14, hour: 9, minute: 41))!

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private static func goal(_ id: String = "g_1", title: String = "I want to post a drawing every day", lead: String? = "otto") -> Goal {
        var g = Goal(id: id, title: title)
        g.lead = lead
        return g
    }

    private static func plan(_ extra: String = "", state: String = "new", goal: String = "g_1", added: String = "[]") throws -> TodoOffer {
        try decode(TodoOffer.self, """
        {"id": "of_1", "kind": "plan", "bot": "otto", "at": "2026-12-14T09:00:00-06:00", "goal": "\(goal)", "title": "x",
         "state": "\(state)", "list": "", "tasks": [], "added": \(added), "milestones": [{"title": "A week of drawings"}]\(extra)}
        """)
    }

    // MARK: The plan request

    @Test func thePlanRequestLooksFirstThenAsksThreeQuestionsInOrder() {
        let ask = GoalBots.planRequest(Self.goal(), typed: "Draw every day", now: Self.now, calendar: Self.calendar)
        #expect(ask.hasPrefix(GoalBots.planRequestStart))
        #expect(GoalBots.planBubble(forStored: ask) == "Draw every day", "the words wrapper still reads back")
        let look = ask.range(of: "First look for what I already have")!
        let questions = ask.range(of: "at most three questions, all on one question card")!
        let first = ask.range(of: "1. what done looks like")!, second = ask.range(of: "2. what I already have")!
        let third = ask.range(of: "3. how much time a week")!, offer = ask.range(of: "goals_offer (kind \"plan\")")!
        #expect(look.lowerBound < questions.lowerBound && questions.lowerBound < first.lowerBound)
        #expect(first.lowerBound < second.lowerBound && second.lowerBound < third.lowerBound && third.lowerBound < offer.lowerBound)
        #expect(ask.contains("skip any that your looking or the goal above already answers"))
        #expect(ask.contains("each with choices to tap"))
        for field in ["name (", "why (", "measure {unit, start, target}", "due (YYYY-MM-DD)", "built_on ("] {
            #expect(ask.contains(field), "names \(field)")
        }
        #expect(ask.contains("(Goal id g_1)"), "the goal's details are still there")
        #expect(GoalBots.planQuestions.count == 3)
    }

    // MARK: Decoding

    @Test func setupAndBuiltOnDecode() throws {
        let all = try Self.plan("""
        , "setup": {"name": " Draw every day ", "why": "To get my hand back.", "due": "2027-03-31T00:00:00",
                    "measure": {"unit": "drawings", "start": 0, "target": 100}},
          "built_on": ["Your course notes, 8 units", "  ", 3, "Sketching after work"]
        """)
        #expect(all.setup == GoalPlanSetup(name: "Draw every day", why: "To get my hand back.", due: "2027-03-31",
                                           measure: GoalOfferMeasure(unit: "drawings", start: 0, target: 100)))
        #expect(all.builtOn == ["Your course notes, 8 units", "  ", "Sketching after work"], "strings only")
        let none = try Self.plan()
        #expect(none.setup == nil && none.builtOn.isEmpty, "absent")
        let partial = try Self.plan(#", "setup": {"why": "To get my hand back.", "name": ""}"#)
        #expect(partial.setup == GoalPlanSetup(why: "To get my hand back."), "only the kept keys; an empty one is none")
        let empty = try Self.plan(#", "setup": {}, "built_on": null"#)
        #expect(empty.setup == nil && empty.builtOn.isEmpty, "an empty set-up is no set-up")
    }

    // MARK: The card's rows

    @Test func theCardsRowsPerKey() throws {
        let all = try Self.plan("""
        , "setup": {"name": "Draw every day", "why": "To get my hand back.", "due": "2027-01-31",
                    "measure": {"unit": "followers", "start": 0, "target": 1000}}
        """)
        let rows = GoalOffers.setupRows(all, now: Self.now, calendar: Self.calendar)
        #expect(rows.map(\.label) == ["Name", "Why", "Number", "By"], "in this order")
        #expect(rows.map(\.key) == ["name", "why", "measure", "due"])
        #expect(rows[0].value == "Draw every day" && rows[1].value == "To get my hand back.")
        #expect(rows[2].value == "0 of 1,000 followers")
        #expect(rows[3].value == "Sun, Jan 31, 2027", "as the goal's page words its date (another year: with it), without the By")
        #expect(GoalOffers.setupSpoken(rows[0]) == "Name: Draw every day")
        let dateOnly = try Self.plan(#", "setup": {"due": "2026-12-20"}"#)
        #expect(GoalOffers.setupRows(dateOnly, now: Self.now, calendar: Self.calendar).map(\.label) == ["By"])
        #expect(GoalOffers.setupRows(try Self.plan(), now: Self.now, calendar: Self.calendar).isEmpty, "none: the card as before")
        var notAPlan = all
        notAPlan.kind = "tasks"
        #expect(GoalOffers.setupRows(notAPlan, now: Self.now, calendar: Self.calendar).isEmpty)
    }

    @Test func builtOnLinesAreOneLineEachThreeAtMost() throws {
        let long = String(repeating: "a", count: 120)
        let offer = try Self.plan(#", "built_on": ["Your  course\nnotes", "", "\#(long)", "Three", "Four"]"#)
        let lines = GoalOffers.builtOn(offer)
        #expect(lines.count == 3)
        #expect(lines[0] == "Your course notes", "one line")
        #expect(lines[1].count == 90 && lines[1].hasSuffix("…"))
        #expect(lines[2] == "Three")
        #expect(GoalOffers.builtOn(try Self.plan()).isEmpty)
    }

    // MARK: Telling the lead, once

    @Test func takingAPlanTellsTheLeadOnce() throws {
        let accepted = try Self.plan(#", "made_milestones": ["m_1", "m_2", "m_3"]"#, state: "accepted", added: #"["t_1", "t_2", "t_3", "t_4"]"#)
        let goal = Self.goal(title: "Draw every day")
        var told = GoalPlanTold()
        #expect(told.shouldTell(action: .accept, answer: accepted, goal: goal))
        #expect(!told.shouldTell(action: .undo, answer: accepted, goal: goal), "not on Undo")
        #expect(!told.shouldTell(action: .decline, answer: accepted, goal: goal))
        #expect(!told.shouldTell(action: .accept, answer: try Self.plan(), goal: goal), "not accepted (a 409 or still waiting)")
        #expect(!told.shouldTell(action: .accept, answer: accepted, goal: Self.goal(lead: nil)), "no lead: nobody to tell")
        #expect(!told.shouldTell(action: .accept, answer: accepted, goal: Self.goal("g_2")), "another goal")
        #expect(!told.shouldTell(action: .accept, answer: accepted, goal: nil))
        var paused = goal; paused.status = "paused"
        #expect(!told.shouldTell(action: .accept, answer: accepted, goal: paused))
        var tasks = accepted; tasks.kind = "tasks"
        #expect(!told.shouldTell(action: .accept, answer: tasks, goal: goal), "only a plan")

        let first = told.mark("of_1", now: Self.now)
        #expect(first)
        #expect(!told.shouldTell(action: .accept, answer: accepted, goal: goal), "twice: Undo then accept again")
        let again = told.mark("of_1", now: Self.now)
        #expect(!again)
        // A relaunch reads it back.
        let back = GoalPlanTold.read(told.stored)
        #expect(!back.shouldTell(action: .accept, answer: accepted, goal: goal))
        #expect(GoalPlanTold.read("junk\nof_2 nope\n").told.isEmpty)
        // Old ones go after 30 days, and at most 200 are kept.
        var many = GoalPlanTold()
        for n in 0..<210 { _ = many.mark("of_\(n)", now: Self.now.addingTimeInterval(Double(n))) }
        #expect(many.told.count == GoalPlanTold.keep && many.told["of_209"] != nil && many.told["of_0"] == nil)
        _ = many.mark("of_new", now: Self.now.addingTimeInterval(31 * 86_400))
        #expect(many.told.count == 1)

        let words = GoalBots.planTakenRequest(goal, offer: accepted)
        #expect(words.hasPrefix(GoalBots.planTakenStart))
        #expect(words == "I took your plan for “Draw every day”: 3 milestones and 4 tasks are on it now. Start your own tasks "
                + "under it now, then tell me where it stands in one line (goals_update with stands). (Goal id g_1)")
        let bare = try Self.plan(state: "accepted")
        #expect(GoalBots.planTakenRequest(goal, offer: bare).contains("nothing new is on it, only its set-up"))
        let one = try Self.plan(#", "made_milestones": ["m_1"]"#, state: "accepted")
        #expect(GoalBots.planTakenRequest(goal, offer: one).contains("1 milestone is on it now"))
    }

    // MARK: New Goal

    @Test func aNewGoalWithALeadIsOnePost() throws {
        let fields: [String: JSONValue] = ["title": "Draw every day", "lead": "otto", "helpers": ["wren"],
                                           "review": ["day": 0, "time": "08:00"], "known_to_all": true]
        let body = GoalWire.createBody(fields)
        #expect(body["lead"] == "otto" && body["helpers"] == ["wren"] && body["review"] != nil, "the team goes in the POST")
        #expect(body["known_to_all"] == nil, "POST never takes it")
        var made = Goal(id: "g_1", title: "Draw every day")
        made.lead = "otto"; made.helpers = ["wren"]; made.review = GoalReview(day: 0, time: "08:00")
        #expect(GoalWire.teamLeft(fields, made: made) == ["known_to_all": true], "taken: only what POST never takes")
        let older = Goal(id: "g_1", title: "Draw every day")
        let left = GoalWire.teamLeft(fields, made: older)
        #expect(left["lead"] == "otto" && left["helpers"] == ["wren"] && left["review"] != nil, "an older add-on: PATCH them")
        #expect(GoalWire.teamLeft(["title": "Draw"], made: older).isEmpty, "no team: no PATCH")
    }

    @Test func theLeadsLineOnNewGoal() {
        let name: (String) -> String = { ["otto": "Otto", "wren": "Wren"][$0] ?? $0 }
        #expect(GoalPlanWith.note(["otto"], botName: name) == "Otto asks up to three questions, then offers a plan.")
        #expect(GoalPlanWith.note(["otto", "wren"], botName: name) == "Otto leads. Wren helps.", "with helpers as before")
    }

    // MARK: A taken plan's lines were added, not done (set-up 6)

    @Test func takenLinesHaveAPlusNotATick() {
        #expect(GoalOffers.lineMark(milestone: true, added: true) == "plus.square.fill")
        #expect(GoalOffers.lineMark(milestone: false, added: true) == "plus.circle.fill")
        #expect(GoalOffers.lineMark(milestone: true, added: false) == "square", "waiting: an empty box")
        #expect(GoalOffers.lineMark(milestone: false, added: false) == "circle", "waiting: an empty ring")
        for milestone in [true, false] {
            for added in [true, false] { #expect(!GoalOffers.lineMark(milestone: milestone, added: added).contains("checkmark")) }
        }
        #expect(GoalOffers.lineState(added: true) == "added")
        #expect(GoalOffers.lineState(added: false).isEmpty)
        #expect(!GoalOffers.lineState(added: true).contains("done"), "VoiceOver never says done")
    }

    // MARK: The lead's reply to "I took your plan" shows once (set-up 6)

    /// The goal's chat after the hidden plan-taken turn: the stored prompt is hidden (no bubble), the reply is row 2. The
    /// streamed bubble carries the turn end's `final_assistant_row_id` (`LiveChatSession.onComplete`), and the turn-end
    /// read binds it to its stored row by that, so the reply shows once though no prompt bubble stands before it.
    @Test func aHiddenTurnsReplyIsBoundToItsStoredRowByTheReceipt() throws {
        let reply = "Started on my two. It stands at the first step, with the plan on it."
        let page = Hydration.fold([
            ["role": "user", "content": "I took your plan for “Draw every day”.", "display_kind": "hidden", "row_id": 1, "timestamp": 1_800_000_000],
            ["role": "assistant", "content": .string(reply), "row_id": 2, "finish_reason": "stop", "timestamp": 1_800_000_005],
        ], pageSeq: 1)
        #expect(page.messages.map(\.role) == [.assistant], "the hidden prompt draws no bubble")
        let live = ChatMessage(id: "local-assistant-1", role: .assistant, parts: [.text(reply)], timestamp: nil, rowId: 2)
        let graft = TranscriptMerge.graft(fresh: page.messages, freshMeta: page.meta, onto: [live], previousMeta: [:],
                                          aliases: [:], replaceAll: false)
        #expect(graft.messages.map(\.id) == ["local-assistant-1"], "one bubble: the live one holds the stored row")
        #expect(graft.messages.filter { $0.plainText == reply }.count == 1)
    }

    // MARK: A waiting plan on the shelf and the Goals view

    @Test func aWaitingPlanSaysPlanToLookAt() throws {
        let goal = Self.goal()
        let waiting = try Self.plan()
        #expect(GoalShelfNext.of(goal, tasks: [], bots: true, offers: [waiting]) == .planWaits)
        #expect(GoalShelfNext.planWaits.words == "Plan to look at")
        #expect(GoalShelfNext.of(goal, tasks: [], bots: false, offers: [waiting]) != .planWaits, "no add-on bots")
        #expect(GoalShelfNext.of(goal, tasks: [], bots: true, offers: []) != .planWaits)
        #expect(GoalShelfNext.of(goal, tasks: [], bots: true, offers: [try Self.plan(state: "accepted")]) != .planWaits)
        var paused = goal; paused.status = "paused"
        #expect(GoalShelfNext.of(paused, tasks: [], bots: true, offers: [waiting]) != .planWaits)
    }
}
