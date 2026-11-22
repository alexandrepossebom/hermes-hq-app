// [goals] Step 2 (docs/goals.md "Step 2", board 1's middle phone): the rules behind Today's Goals shelf, the goal's mark
// on a task's row, and a search that finds goals. Pure functions; the shelf is drawn by App/Pages/Goals/GoalShelfViews,
// the mark by `TodoRowView`. Tested in Tests/Pages/GoalShelfTests.

import Foundation

/// What a shelf card says under its name and its grey line.
nonisolated enum GoalShelfNext: Hashable, Sendable {
    /// "Next: <the goal's next task>" (its id, its name).
    case task(id: String, title: String)
    /// The goal has no number, no milestones and no tasks.
    case noPlan
    /// It has a plan and every task under it is done.
    case nothing
    /// [goals set-up] No next task, and a plan offer for it waits for your answer (the card itself stays where it is).
    case planWaits

    var words: String {
        switch self {
        case .task(_, let title): return "Next: " + title
        case .noPlan: return "No plan yet"
        case .nothing: return "Nothing next"
        case .planWaits: return GoalShelfNext.planWords
        }
    }

    static let planWords = "Plan to look at"

    /// A goal's next step: its next task; else, with the add-on's bots, a plan that waits for your answer; else no plan
    /// yet, or nothing next. A waiting plan never hides a task you could do now (the lead's orange dot already says
    /// something waits).
    static func of(_ goal: Goal, tasks: [TodoTask], bots: Bool, offers: [TodoOffer]) -> GoalShelfNext {
        if let task = GoalViews.nextTask(goal, tasks: tasks) {
            return .task(id: task.id, title: task.title.isEmpty ? "Untitled Task" : task.title)
        }
        if bots, goal.state == .active, GoalPlanAsk.planWaits(goal, offers: offers) { return .planWaits }
        return GoalViews.fraction(goal, tasks: tasks) == nil ? .noPlan : .nothing
    }
}

/// One small card on the shelf.
nonisolated struct GoalShelfCard: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var color: TodoListColor
    /// The ring, 0…1; nil with no plan.
    var fraction: Double?
    /// "340 · by Jan 31" (`GoalViews.shortLine`); empty for a goal with no plan and no date.
    var line: String
    var next: GoalShelfNext
    /// What VoiceOver hears: the Goals view's card's words (`GoalViews.spoken`).
    var spoken: String
    /// [goals step 3] The bots on the goal, the lead first (`GoalBots.team`); empty with no bot or before 0.9.66.
    var team: [String] = []
    /// The first of `team` leads the goal.
    var led = false
    /// [goals step 3] The lead's dot is orange: an offer for the goal waits for you (`GoalBots.waitsForYou`).
    var waits = false
    /// [goals step 4] "Nothing has moved in 16 days" (`GoalViews.stallLine`), in orange in the grey line's place.
    var stall: String?
}

nonisolated enum GoalShelf {
    /// At the accessibility text sizes the cards stack, two at most, then "All N ›".
    static let stackedMost = 2

    /// The shelf shows on Today alone, not during a search, on an add-on that keeps goals, with an active goal, and
    /// while the bots filter is All Bots or Me (with one bot picked it is hidden). `scope`: `PagesScope`'s key ("all",
    /// "@me", or a bot's profile).
    static func shows(view: TodoView, searching: Bool, scope: String, goalsSupported: Bool, goals: [Goal]) -> Bool {
        guard view == .today, !searching, goalsSupported, scope == "all" || scope == "@me" else { return false }
        return goals.contains { $0.state == .active }
    }

    /// The active goals in your order, each as a card. A paused, achieved or let-go goal has none.
    /// `bots`: the add-on knows goals' bots (`goal_bots`), so the cards carry faces and the waiting dot. `keptHere`: Keep
    /// Going tapped on this device, by goal id (`GoalKeptHere`).
    static func cards(_ goals: [Goal], tasks: [TodoTask], now: Date, bots: Bool = false, offers: [TodoOffer] = [],
                      keptHere: [String: Date] = [:], calendar: Calendar = .current) -> [GoalShelfCard] {
        GoalViews.groups(goals).active.map {
            card($0, tasks: tasks, now: now, bots: bots, offers: offers, keptHere: keptHere[$0.id], calendar: calendar)
        }
    }

    static func card(_ goal: Goal, tasks: [TodoTask], now: Date, bots: Bool = false, offers: [TodoOffer] = [],
                     keptHere: Date? = nil, calendar: Calendar = .current) -> GoalShelfCard {
        let fraction = GoalViews.fraction(goal, tasks: tasks)
        let next = GoalShelfNext.of(goal, tasks: tasks, bots: bots, offers: offers)
        return GoalShelfCard(id: goal.id, title: goal.title.isEmpty ? "Untitled Goal" : goal.title, color: goal.tint,
                             fraction: fraction, line: GoalViews.shortLine(goal, tasks: tasks, now: now, calendar: calendar),
                             next: next, spoken: GoalViews.spoken(goal, tasks: tasks, now: now, calendar: calendar)
                                + (next == .planWaits ? ", " + GoalShelfNext.planWords.lowercased() : ""),
                             team: bots ? GoalBots.team(goal) : [], led: bots && goal.lead != nil,
                             waits: bots && GoalBots.waitsForYou(goal, offers: offers),
                             stall: GoalViews.stalled(goal, tasks: tasks, now: now, keptHere: keptHere, calendar: calendar).map(GoalViews.stallLine))
    }

    /// The cards drawn: every one in a row; at the accessibility sizes the first `stackedMost`.
    static func drawn(_ cards: [GoalShelfCard], stacked: Bool) -> [GoalShelfCard] {
        stacked ? Array(cards.prefix(stackedMost)) : cards
    }

    /// The heading's words: "Goals" open, "Goals 3" folded ("All 3 ›" stands at its end either way).
    static func headingCount(_ count: Int, folded: Bool) -> Int? { folded ? count : nil }

    /// "All 3 ›".
    static func allWords(_ count: Int) -> String { "All \(count)" }

    /// VoiceOver: the heading is a button, "Goals, 3, shown" / "Goals, 3, hidden" (label, then value).
    static func headingValue(_ count: Int, folded: Bool) -> String { "\(count), " + (folded ? "hidden" : "shown") }
}

nonisolated extension GoalViews {
    /// The shelf card's grey line: the number alone ("340"), else milestones done of all ("1 of 4"), else tasks done of
    /// all ("4 of 6"), then the date ("by Jan 31"). A goal with no plan says only its date; with neither it is empty.
    static func shortLine(_ goal: Goal, tasks all: [TodoTask], now: Date, calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if let measure = goal.measure {
            parts.append(number(measure.now, unit: measure.unit))
        } else if !goal.milestones.isEmpty {
            parts.append("\(goal.milestones.filter(\.done).count) of \(goal.milestones.count)")
        } else {
            let mine = tasks(of: goal, in: all)
            if !mine.isEmpty { parts.append("\(mine.filter(\.isDone).count) of \(mine.count)") }
        }
        if let raw = goal.due, let due = TodoDates.day(String(raw.prefix(10)), calendar: calendar) {
            parts.append("by " + shortDay(due, now: now, calendar: calendar))
        }
        return parts.joined(separator: " · ")
    }

    /// "Jan 31": a small card has no room for a year, so a date within the next eleven months (or the last one) drops
    /// it even across New Year (board 1: "by Jan 31" seen in December); farther off it says it ("Mar 1, 2028").
    static func shortDay(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let months = calendar.dateComponents([.month], from: calendar.startOfDay(for: now), to: date).month ?? 0
        guard (-1...10).contains(months) else { return TodoWords.monthDay(date, now: now, calendar: calendar) }
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = calendar.locale ?? .current
        format.setLocalizedDateFormatFromTemplate("MMMd")
        return format.string(from: date)
    }

    // MARK: The goal's mark on a task's row

    /// The goal whose mark a task's row carries, in its list's dot's place: a task in an active or paused goal. A task
    /// in an achieved or let-go goal (or one the list no longer has) has none, and shows its list's dot again.
    static func markGoal(_ task: TodoTask, goals: [Goal]) -> Goal? {
        guard let id = task.goal, let goal = goals.first(where: { $0.id == id }) else { return nil }
        return goal.state == .active || goal.state == .paused ? goal : nil
    }

    // MARK: Search

    /// A search's Goals group: goals whose name or why holds the words, any status, in the Goals view's order (active,
    /// Someday, Achieved, Let Go). Empty for no words.
    static func found(_ goals: [Goal], query: String) -> [Goal] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !words.isEmpty, !words.hasPrefix("#") else { return [] }   // "#tag" looks for a task's tag alone
        let hit = goals.filter { $0.title.lowercased().contains(words) || $0.why.lowercased().contains(words) }
        let made = groups(hit)
        return made.active + made.someday + made.achieved + made.letGo
    }

    /// The words a task is also found by: its goal's name and its milestone's name.
    static func searchWords(_ task: TodoTask, goals: [Goal]) -> [String] {
        guard let id = task.goal, let goal = goals.first(where: { $0.id == id }) else { return [] }
        return [goal.title] + [goal.milestone(task.milestone)?.title].compactMap { $0 }
    }
}
