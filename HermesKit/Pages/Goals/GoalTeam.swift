// [goals step 6] A goal you make gets a bot planning it, and adding bots to a goal is one obvious tap (docs/goals.md
// "Step 6"). The owner, after making a first real goal on the shipped build: nothing happened, and they had expected a
// bot to start planning it; and there was no easy way to add a bot, or a team of bots, to a goal. Pure rules:
// - `GoalPlanWith`: which bots New Goal's Who's helping? row starts on (the root bot leading the first time, then what
//   you picked last), and the quiet line under it.
// - `GoalPlanAsk`: when a goal's lead is asked for a plan (a new first lead on a goal with no plan), and when the page
//   offers "Ask <Bot> for a Plan".
// - `GoalPlanGuard`: the same ask is never sent twice for one goal within a minute.
// - `GoalTeamPick`: the team sheet's ticks (the first ticked leads; Make Lead; unticking the lead hands it on).
// Tested in Tests/Pages/GoalTeamTests.

import Foundation

/// New Goal's Who's helping? row: which bots it starts on, and what Add will do.
nonisolated enum GoalPlanWith {
    /// The root bot's profile.
    static let root = "default"

    /// The team New Goal starts on, lead first; empty is No One. `remembered`: what was picked last on this device (nil
    /// the first time, empty for No One). The first time it is the root bot, else your first bot. A remembered bot that
    /// is gone drops out; when none is left, it is the first time again.
    static func start(remembered: [String]?, bots: [String]) -> [String] {
        let first: [String] = bots.contains(root) ? [root] : Array(bots.prefix(1))
        guard let remembered else { return first }
        if remembered.isEmpty { return [] }
        var kept: [String] = []
        for id in remembered where bots.contains(id) && !kept.contains(id) { kept.append(id) }
        return kept.isEmpty ? first : kept
    }

    /// The stored form (one line, ids joined by commas; "" is No One).
    static func stored(_ team: [String]) -> String { team.joined(separator: ",") }

    /// The stored form read back; nil when nothing was ever picked.
    static func read(_ stored: String?) -> [String]? {
        guard let stored else { return nil }
        return stored.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The quiet line under New Goal's Who's helping? row, saying what Add will do: "Hermes will offer a plan when you
    /// add this." / "Hermes leads. Research helps." / "Hermes leads. Research and Finance help." / "No bot. You can add
    /// one later."
    static func note(_ team: [String], botName: (String) -> String) -> String {
        guard let lead = team.first else { return "No bot. You can add one later." }
        let helpers = team.dropFirst().map(botName)
        guard let last = helpers.last else { return "\(botName(lead)) will offer a plan when you add this." }
        let names = helpers.count == 1 ? last : helpers.dropLast().joined(separator: ", ") + " and " + last
        return "\(botName(lead)) leads. \(names) \(helpers.count == 1 ? "helps" : "help")."
    }
}

/// When a goal's lead is asked for a plan (`GoalBots.planRequest`, a hidden turn in the goal's chat).
nonisolated enum GoalPlanAsk {
    /// A goal has a plan once it has a milestone or an open task under it.
    static func hasPlan(_ goal: Goal, tasks: [TodoTask]) -> Bool {
        !goal.milestones.isEmpty || GoalViews.tasks(of: goal, in: tasks).contains { !$0.isDone }
    }

    /// A plan offer for this goal waits for your answer (in a chat, on Today or on its page).
    static func planWaits(_ goal: Goal, offers: [TodoOffer]) -> Bool {
        offers.contains { $0.isGoal && $0.kind == "plan" && $0.isWaiting && !$0.held && $0.goal == goal.id }
    }

    /// No plan, none on its way to you: a lead would be asked for one. Only an active goal.
    static func needsPlan(_ goal: Goal, tasks: [TodoTask], offers: [TodoOffer]) -> Bool {
        goal.state == .active && !hasPlan(goal, tasks: tasks) && !planWaits(goal, offers: offers)
    }

    /// Edit Goal or the team sheet closed: the goal got its first lead (it had none when the sheet opened) and has no
    /// plan, so the goal reopens on its chat and the lead is asked for one. A goal that has a plan is not asked.
    static func asksNewLead(before: String?, goal: Goal, tasks: [TodoTask], offers: [TodoOffer]) -> Bool {
        before == nil && goal.lead != nil && needsPlan(goal, tasks: tasks, offers: offers)
    }

    /// The page's "No plan yet" and "Ask <Bot> for a Plan": a lead, and no plan. Gone once a milestone or a task comes,
    /// hidden while a plan offer waits.
    static func showsAsk(_ goal: Goal, tasks: [TodoTask], offers: [TodoOffer]) -> Bool {
        goal.lead != nil && needsPlan(goal, tasks: tasks, offers: offers)
    }

    /// "Ask Hermes for a Plan".
    static func buttonWords(_ lead: String) -> String { "Ask \(lead) for a Plan" }
}

/// The same plan ask is never sent twice for one goal within a minute (a double tap, Edit Goal then the page's button).
nonisolated struct GoalPlanGuard: Sendable {
    static let window: TimeInterval = 60
    private(set) var asked: [String: Date] = [:]

    init() {}

    /// Whether the ask may go now; true notes it as sent.
    mutating func mayAsk(_ goal: String, now: Date) -> Bool {
        if let at = asked[goal], now.timeIntervalSince(at) < Self.window, now >= at { return false }
        asked[goal] = now
        asked = asked.filter { now.timeIntervalSince($0.value) < Self.window * 10 }
        return true
    }

    /// Asked within the minute (the page's button says so rather than ask again).
    func recentlyAsked(_ goal: String, now: Date) -> Bool {
        guard let at = asked[goal] else { return false }
        return now >= at && now.timeIntervalSince(at) < Self.window
    }
}

/// The team sheet's ticks, and New Goal's Who's helping? chips: the first ticked bot leads, the others help.
nonisolated struct GoalTeamPick: Hashable, Sendable {
    var lead: String?
    var helpers: [String]

    init(lead: String?, helpers: [String]) {
        self.lead = lead
        self.helpers = helpers.reduce(into: [String]()) { out, id in if id != lead && !out.contains(id) { out.append(id) } }
    }

    /// Lead first.
    init(team: [String]) {
        self.init(lead: team.first, helpers: Array(team.dropFirst()))
    }

    init(_ goal: Goal) { self.init(lead: goal.lead, helpers: goal.helpers) }

    /// Lead first, then the helpers.
    var team: [String] { (lead.map { [$0] } ?? []) + helpers }

    func has(_ id: String) -> Bool { lead == id || helpers.contains(id) }

    /// A tick: on (the first one ticked leads, a later one helps) or off (unticking the lead makes the next ticked bot
    /// the lead).
    mutating func toggle(_ id: String) {
        if lead == id {
            lead = helpers.first
            helpers = Array(helpers.dropFirst())
        } else if let at = helpers.firstIndex(of: id) {
            helpers.remove(at: at)
        } else if lead == nil {
            // Helpers with no lead (an older goal): the new bot leads only when nothing else is ticked.
            if helpers.isEmpty { lead = id } else { helpers.append(id) }
        } else {
            helpers.append(id)
        }
    }

    /// Make Lead on a helper's row: the two swap places.
    mutating func makeLead(_ id: String) {
        guard let at = helpers.firstIndex(of: id) else {
            if lead == nil, !has(id) { lead = id }
            return
        }
        if let old = lead { helpers[at] = old } else { helpers.remove(at: at) }
        lead = id
    }

    /// The fields that changed, as the PATCH sends them (`lead`, `helpers`).
    func fields(from old: GoalTeamPick) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if lead != old.lead { out["lead"] = lead.map(JSONValue.string) ?? .null }
        if helpers != old.helpers { out["helpers"] = .array(helpers.map(JSONValue.string)) }
        return out
    }

    /// What VoiceOver hears for a bot's row: "Hermes, on this goal, leads" / "Research, on this goal" / "Finance, not on
    /// this goal".
    func spoken(_ id: String, name: String) -> String {
        if lead == id { return "\(name), on this goal, leads" }
        return has(id) ? "\(name), on this goal" : "\(name), not on this goal"
    }
}

nonisolated extension GoalBots {
    /// The page's Bots row with no bot on the goal: "Just Me" (Add Bots at its end).
    static let justMe = "Just Me"
    /// The team sheet's one line.
    static let teamNote = "The lead plans and checks in each week. The others take tasks."
}
