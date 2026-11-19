// [goals] Step 1 (docs/goals.md, "Progress and pace"): the rules behind every goal screen, as pure functions.
// - The ring never lies: your number when the goal has one, else milestones done, else tasks done; with none of those
//   the ring is empty and says "No plan yet".
// - Pace is said in words, only with a date: on pace, ahead, a week behind. Red only once it is late.
// - Nothing finishes by itself: a milestone whose tasks are all done, and a goal whose milestones are all done, are
//   offered (a question), never ticked.
// Tested in Tests/Pages/GoalViewsTests.

import Foundation

/// How a goal is doing against an even pace to its date.
nonisolated enum GoalPace: Hashable, Sendable {
    case onPace, ahead
    /// The gap in days at the even rate.
    case behind(days: Int)
    /// Past its date and not achieved.
    case late(days: Int)

    /// "on pace", "ahead", "3 days behind", "a week behind", "2 weeks behind", "3 days late".
    var words: String {
        switch self {
        case .onPace: return "on pace"
        case .ahead: return "ahead"
        case .behind(let days):
            if days < 7 { return days == 1 ? "1 day behind" : "\(days) days behind" }
            if days < 14 { return "a week behind" }
            return "\(days / 7) weeks behind"
        case .late(let days): return days == 1 ? "1 day late" : "\(days) days late"
        }
    }

    /// Red: late. Behind is the warning colour; on pace and ahead the good one.
    var tone: Tone {
        switch self {
        case .onPace, .ahead: return .good
        case .behind: return .behind
        case .late: return .late
        }
    }

    enum Tone: Sendable { case good, behind, late }
}

/// The Goals view's groups, top to bottom (each only when it has a goal).
nonisolated struct GoalGroups: Equatable, Sendable {
    var active: [Goal] = []
    /// Paused.
    var someday: [Goal] = []
    var achieved: [Goal] = []
    var letGo: [Goal] = []

    var isEmpty: Bool { active.isEmpty && someday.isEmpty && achieved.isEmpty && letGo.isEmpty }
}

/// The two offers of rule 5, one at a time (a milestone first).
nonisolated enum GoalOffer: Hashable, Sendable {
    /// "That was the last task in Launch week. Mark it done?"
    case milestone(GoalMilestone)
    /// "Every milestone is done. Mark this goal achieved?"
    case achieved

    var text: String {
        switch self {
        case .milestone(let milestone): return "That was the last task in \(milestone.title). Mark it done?"
        case .achieved: return "Every milestone is done. Mark this goal achieved?"
        }
    }

    var yes: String {
        switch self {
        case .milestone: return "Mark Done"
        case .achieved: return "Mark Achieved"
        }
    }

    /// What Not Yet is remembered under on this device ("milestone:<id>", "goal:<id>").
    func key(goal: Goal) -> String {
        switch self {
        case .milestone(let milestone): return "milestone:" + milestone.id
        case .achieved: return "goal:" + goal.id
        }
    }
}

nonisolated enum GoalViews {
    /// With no goals at all: what a goal is, in two lines.
    static let emptyText = "A goal is something you want to finish: a number to reach, a date, or a few milestones.\nPut tasks under it, and the ring shows how far you’ve come."

    // MARK: Tasks under a goal

    /// The goal's tasks, in their own order (`position`).
    static func tasks(of goal: Goal, in tasks: [TodoTask]) -> [TodoTask] {
        tasks.filter { $0.goal == goal.id }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// A milestone's tasks, in order.
    static func tasks(of goal: Goal, milestone: String, in all: [TodoTask]) -> [TodoTask] {
        tasks(of: goal, in: all).filter { $0.milestone == milestone }
    }

    /// The goal's tasks under no milestone (or under one the goal no longer has), in order.
    static func looseTasks(of goal: Goal, in all: [TodoTask]) -> [TodoTask] {
        let known = Set(goal.milestones.map(\.id))
        return tasks(of: goal, in: all).filter { task in task.milestone.map { !known.contains($0) } ?? true }
    }

    /// "1 of 4": a milestone's tasks done of all of them; nil with none.
    static func count(_ tasks: [TodoTask]) -> String? {
        tasks.isEmpty ? nil : "\(tasks.filter(\.isDone).count) of \(tasks.count)"
    }

    /// The milestone the goal is on: the first not done.
    static func current(_ goal: Goal) -> GoalMilestone? { goal.milestones.first { !$0.done } }

    /// The goal's next task: the first open task of the first milestone not done, else the first open task under no
    /// milestone, else none.
    static func nextTask(_ goal: Goal, tasks all: [TodoTask]) -> TodoTask? {
        if let milestone = current(goal), let task = tasks(of: goal, milestone: milestone.id, in: all).first(where: { !$0.isDone }) {
            return task
        }
        return looseTasks(of: goal, in: all).first { !$0.isDone }
    }

    // MARK: Progress

    /// What the ring shows, 0…1: your number, else milestones done, else tasks done; nil with none ("No plan yet").
    static func fraction(_ goal: Goal, tasks all: [TodoTask]) -> Double? {
        if let measure = goal.measure { return fraction(measure) }
        if !goal.milestones.isEmpty { return Double(goal.milestones.filter(\.done).count) / Double(goal.milestones.count) }
        let mine = tasks(of: goal, in: all)
        if !mine.isEmpty { return Double(mine.filter(\.isDone).count) / Double(mine.count) }
        return nil
    }

    /// `(now - start) / (target - start)`, held to 0…1 (a target below the start counts down the same way).
    static func fraction(_ measure: GoalMeasure) -> Double {
        let span = measure.target - measure.start
        guard span != 0 else { return measure.now == measure.target ? 1 : 0 }
        return min(1, max(0, (measure.now - measure.start) / span))
    }

    /// "34%".
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded(.down)))%" }

    /// What part of the way an even pace would have covered today, 0…1; nil with no date.
    static func evenPace(_ goal: Goal, now: Date, calendar: Calendar = .current) -> Double? {
        guard let span = span(goal, calendar: calendar) else { return nil }
        let today = calendar.startOfDay(for: now)
        guard span.days > 0 else { return today >= span.due ? 1 : 0 }
        let gone = days(from: span.created, to: today, calendar: calendar)
        return min(1, max(0, Double(gone) / Double(span.days)))
    }

    /// The pace in words; nil with no date, for an achieved, paused or let-go goal, and for one with no plan yet
    /// (until it is late).
    static func pace(_ goal: Goal, tasks all: [TodoTask], now: Date, calendar: Calendar = .current) -> GoalPace? {
        guard goal.state == .active, let span = span(goal, calendar: calendar) else { return nil }
        let today = calendar.startOfDay(for: now)
        if today > span.due { return .late(days: days(from: span.due, to: today, calendar: calendar)) }
        guard let done = fraction(goal, tasks: all), let even = evenPace(goal, now: now, calendar: calendar) else { return nil }
        let gap = even - done
        if abs(gap) <= 0.05 { return .onPace }
        if gap < 0 { return .ahead }
        return .behind(days: max(1, Int((gap * Double(max(1, span.days))).rounded())))
    }

    // MARK: Words

    /// A number as the app says it: "1,000", "12.5", "$" before it ("$1,200").
    static func number(_ value: Double, unit: String = "") -> String {
        let format = NumberFormatter()
        format.numberStyle = .decimal
        format.maximumFractionDigits = 2
        format.locale = Locale(identifier: "en_US")
        let text = format.string(from: NSNumber(value: value)) ?? String(value)
        return unit == "$" ? "$" + text : text
    }

    /// "340 of 1,000" (the card), "340 of 1,000 testers" (`unit: true`, the page's number row). Counting down:
    /// "185, down to 170 lbs".
    static func measureWords(_ measure: GoalMeasure, unit: Bool = false) -> String {
        let suffix = unit && !measure.unit.isEmpty && measure.unit != "$" ? " " + measure.unit : ""
        let now = number(measure.now, unit: measure.unit), target = number(measure.target, unit: measure.unit)
        if measure.countsDown { return "\(now), down to \(target)" + suffix }
        return "\(now) of \(target)" + suffix
    }

    /// The card's grey line, without the pace: "340 of 1,000 · by Jan 31", "1 of 4 milestones · by Apr 11", "4 of 6
    /// tasks", "No plan yet".
    static func line(_ goal: Goal, tasks all: [TodoTask], now: Date, calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if let measure = goal.measure {
            parts.append(measureWords(measure))
        } else if !goal.milestones.isEmpty {
            parts.append("\(goal.milestones.filter(\.done).count) of \(goal.milestones.count) " + (goal.milestones.count == 1 ? "milestone" : "milestones"))
        } else {
            let mine = tasks(of: goal, in: all)
            parts.append(mine.isEmpty ? "No plan yet" : "\(mine.filter(\.isDone).count) of \(mine.count) " + (mine.count == 1 ? "task" : "tasks"))
        }
        if let due = dueDate(goal, calendar: calendar) {
            parts.append("by " + TodoWords.monthDay(due, now: now, calendar: calendar))
        }
        return parts.joined(separator: " · ")
    }

    /// A Someday card's line: "Paused Nov 30" (what it is at stays on its page).
    static func statusLine(_ goal: Goal, now: Date, calendar: Calendar = .current) -> String? {
        let word: String
        switch goal.state {
        case .active: return nil
        case .paused: word = "Paused"
        case .achieved: word = "Achieved"
        case .letGo: word = "Let go"
        }
        guard let at = TodoDates.moment(goal.statusAt) ?? TodoDates.moment(goal.updatedAt) else { return word }
        return word + " " + TodoWords.monthDay(at, now: now, calendar: calendar)
    }

    /// The page's date row: "By Sun, Jan 31".
    static func dateRow(_ goal: Goal, now: Date, calendar: Calendar = .current) -> String? {
        guard let due = dueDate(goal, calendar: calendar) else { return nil }
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = calendar.locale ?? .current
        let sameYear = calendar.component(.year, from: due) == calendar.component(.year, from: now)
        format.setLocalizedDateFormatFromTemplate(sameYear ? "EEEMMMd" : "EEEMMMdy")
        return "By " + format.string(from: due)
    }

    /// At the date row's end: "48 days left", "17 weeks left", "Due today", "3 days late"; nil for a goal that is done
    /// with (achieved or let go) or has no date.
    static func left(_ goal: Goal, now: Date, calendar: Calendar = .current) -> String? {
        guard goal.state == .active || goal.state == .paused, let due = dueDate(goal, calendar: calendar) else { return nil }
        let count = days(from: calendar.startOfDay(for: now), to: due, calendar: calendar)
        if count == 0 { return "Due today" }
        if count < 0 { return GoalPace.late(days: -count).words }
        if count == 1 { return "1 day left" }
        if count <= 60 { return "\(count) days left" }
        return "\(count / 7) weeks left"
    }

    /// The line under the page's bar: "25% · an even pace would be 35% today", "1 of 4 milestones · on pace",
    /// "4 of 6 tasks", "No plan yet".
    static func barLine(_ goal: Goal, tasks all: [TodoTask], now: Date, calendar: Calendar = .current) -> String {
        guard let done = fraction(goal, tasks: all) else { return "No plan yet" }
        var parts: [String] = []
        if goal.measure != nil {
            parts.append(percent(done))
        } else if !goal.milestones.isEmpty {
            parts.append("\(goal.milestones.filter(\.done).count) of \(goal.milestones.count) " + (goal.milestones.count == 1 ? "milestone" : "milestones"))
        } else {
            let mine = tasks(of: goal, in: all)
            parts.append("\(mine.filter(\.isDone).count) of \(mine.count) " + (mine.count == 1 ? "task" : "tasks"))
        }
        switch pace(goal, tasks: all, now: now, calendar: calendar) {
        case .behind?:
            if let even = evenPace(goal, now: now, calendar: calendar) { parts.append("an even pace would be \(percent(even)) today") }
        case let pace?:
            parts.append(pace.words)
        case nil:
            break
        }
        return parts.joined(separator: " · ")
    }

    /// What VoiceOver hears for a card: "1,000 public testers, 34 percent, a week behind, next: Post the beta link".
    static func spoken(_ goal: Goal, tasks all: [TodoTask], now: Date, calendar: Calendar = .current) -> String {
        var parts = [goal.title]
        if let done = fraction(goal, tasks: all) { parts.append("\(Int((done * 100).rounded(.down))) percent") }
        else { parts.append("No plan yet") }
        if let pace = pace(goal, tasks: all, now: now, calendar: calendar) { parts.append(pace.words) }
        if let status = statusLine(goal, now: now, calendar: calendar) { parts.append(status) }
        if goal.state == .active, let next = nextTask(goal, tasks: all) { parts.append("next: " + next.title) }
        return parts.joined(separator: ", ")
    }

    // MARK: Groups

    /// Active (your order), Someday (paused, your order), Achieved and Let Go (latest first).
    static func groups(_ goals: [Goal]) -> GoalGroups {
        func ordered(_ list: [Goal]) -> [Goal] { list.sorted { ($0.order, $0.id) < ($1.order, $1.id) } }
        func latest(_ list: [Goal]) -> [Goal] {
            list.sorted { (TodoDates.moment($0.statusAt) ?? .distantPast, $0.id) > (TodoDates.moment($1.statusAt) ?? .distantPast, $1.id) }
        }
        return GoalGroups(active: ordered(goals.filter { $0.state == .active }),
                          someday: ordered(goals.filter { $0.state == .paused }),
                          achieved: latest(goals.filter { $0.state == .achieved }),
                          letGo: latest(goals.filter { $0.state == .letGo }))
    }

    /// The pill's number: active goals.
    static func activeCount(_ goals: [Goal]) -> Int { goals.filter { $0.state == .active }.count }

    /// Paused goals' ids: their tasks stay out of Today's "Next in <List>" groups (a dated one still shows on its day).
    static func paused(_ goals: [Goal]) -> Set<String> { Set(goals.filter { $0.state == .paused }.map(\.id)) }

    // MARK: Offers (rule 5)

    /// What sits under the page's bar now: a milestone not done whose tasks are all done, else (every milestone done)
    /// Mark Achieved; nil when neither, or when you said Not Yet to it and nothing under it changed since.
    /// `notYet`: the remembered answers, by `GoalOffer.key` → `signature`.
    static func offer(_ goal: Goal, tasks all: [TodoTask], notYet: [String: String] = [:]) -> GoalOffer? {
        guard goal.state == .active else { return nil }
        for milestone in goal.milestones where !milestone.done {
            let under = tasks(of: goal, milestone: milestone.id, in: all)
            guard !under.isEmpty, under.allSatisfy(\.isDone) else { continue }
            let offer = GoalOffer.milestone(milestone)
            if notYet[offer.key(goal: goal)] != signature(offer, goal: goal, tasks: all) { return offer }
        }
        if !goal.milestones.isEmpty, goal.milestones.allSatisfy(\.done) {
            let offer = GoalOffer.achieved
            if notYet[offer.key(goal: goal)] != signature(offer, goal: goal, tasks: all) { return offer }
        }
        return nil
    }

    /// What is under an offer, so Not Yet holds until something there changes: the milestone's tasks and their ticks,
    /// or the goal's milestones and theirs.
    static func signature(_ offer: GoalOffer, goal: Goal, tasks all: [TodoTask]) -> String {
        switch offer {
        case .milestone(let milestone):
            return tasks(of: goal, milestone: milestone.id, in: all).map { "\($0.id)=\($0.isDone ? 1 : 0)" }.joined(separator: ",")
        case .achieved:
            return goal.milestones.map { "\($0.id)=\($0.done ? 1 : 0)" }.joined(separator: ",")
        }
    }

    // MARK: A task's goal

    /// The fields that put a task in `goal` (nil: no goal) under `milestone`. A milestone that isn't one of that goal's
    /// is cleared, and clearing the goal clears the milestone.
    static func assign(goal: String?, milestone: String?, goals: [Goal]) -> [String: JSONValue] {
        let kept = goal.flatMap { id in goals.first { $0.id == id } }?.milestone(milestone)?.id
        return ["goal": TodoWire.optional(goal), "milestone": TodoWire.optional(goal == nil ? nil : kept)]
    }

    /// A task PATCH as sent: one that moves the task to another goal (or none) and says nothing of its milestone
    /// clears the milestone too, as the gateway does.
    static func withMilestoneRule(_ fields: [String: JSONValue], task: TodoTask) -> [String: JSONValue] {
        guard let goal = fields["goal"], fields["milestone"] == nil else { return fields }
        let next = goal.string.flatMap { $0.isEmpty ? nil : $0 }
        guard next != task.goal || next == nil else { return fields }
        var out = fields
        out["milestone"] = .null
        return out
    }

    /// The colour a new goal takes: the first no active goal uses (as the gateway picks it).
    static func nextColor(_ goals: [Goal]) -> TodoListColor {
        let used = Set(goals.filter { $0.state == .active }.map(\.tint))
        return TodoListColor.allCases.first { !used.contains($0) } ?? .blue
    }

    // MARK: Dates

    private static func dueDate(_ goal: Goal, calendar: Calendar) -> Date? {
        goal.due.flatMap { TodoDates.day(String($0.prefix(10)), calendar: calendar) }
    }

    private static func span(_ goal: Goal, calendar: Calendar) -> (created: Date, due: Date, days: Int)? {
        guard let due = dueDate(goal, calendar: calendar) else { return nil }
        let created = calendar.startOfDay(for: TodoDates.moment(goal.createdAt) ?? due)
        return (created, due, days(from: created, to: due, calendar: calendar))
    }

    private static func days(from: Date, to: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }
}
