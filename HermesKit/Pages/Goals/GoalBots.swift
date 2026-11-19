// [goals] Steps 3 to 5 (docs/goals.md; boards 3, 4 and 5; hermes-hq-push 0.9.66): a bot on a goal, its offers, the
// weekly check-in and the stall question, as pure rules. The owner's words: "whatever bots I add to it can work to help
// me achieve that goal." The add-on enforces what a bot may do; these say what the person sees.
// - One lead per goal; helpers take tasks, not the plan. A face on a card or a row means the bot is on the goal.
// - Offers, not edits: a bot's goal, plan, check-in or tasks is a card you tap (`GoalOffers`).
// - The stall question is the app's own, bot or no bot (`GoalViews.stalled`).
// Plain words on screen ("Led by Hermes"); "offer", "kind" and "lead" stay in the code.
// Tested in Tests/Pages/GoalBotsTests.

import Foundation

/// A goal nothing has moved on for two weeks: how long, its next task, and since when that task has been open.
nonisolated struct GoalStall: Hashable, Sendable {
    var days: Int
    var task: TodoTask?
    var since: Date?
}

nonisolated extension GoalViews {
    /// The stall question waits this long.
    static let stallDays = 14

    /// The latest sign of life on a goal: made, resumed (its status changed), Keep Going (here or on the gateway), a
    /// task under it ticked, its number moved, a milestone ticked.
    static func lastMoved(_ goal: Goal, tasks all: [TodoTask], keptHere: Date? = nil) -> Date? {
        var moments = [goal.createdAt, goal.statusAt, goal.keptAt, goal.measure?.at].compactMap { TodoDates.moment($0) }
        moments += goal.milestones.compactMap { TodoDates.moment($0.doneAt) }
        moments += tasks(of: goal, in: all).compactMap { $0.isDone ? TodoDates.moment($0.doneAt) : nil }
        if let keptHere { moments.append(keptHere) }
        return moments.max()
    }

    /// Board 4's right phone ("A stalled goal, no bot"): an active goal with at least one open task, nothing under it
    /// ticked, its number unmoved and no milestone ticked for 14 days, and made, resumed and kept going more than 14
    /// days ago. Nil otherwise. `keptHere`: Keep Going on this device (an add-on before 0.9.66 keeps no `kept_at`).
    static func stalled(_ goal: Goal, tasks all: [TodoTask], now: Date, keptHere: Date? = nil, calendar: Calendar = .current) -> GoalStall? {
        guard goal.state == .active else { return nil }
        let open = tasks(of: goal, in: all).filter { !$0.isDone }
        guard !open.isEmpty, let last = lastMoved(goal, tasks: all, keptHere: keptHere) else { return nil }
        let gone = now.timeIntervalSince(last)
        guard gone >= Double(stallDays) * 86_400 else { return nil }
        let task = nextTask(goal, tasks: all) ?? open.first
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: now)).day ?? stallDays
        return GoalStall(days: max(stallDays, days), task: task, since: task.flatMap { TodoDates.moment($0.createdAt) } ?? last)
    }

    /// The card's orange second line, and the page's card's head: "Nothing has moved in 16 days".
    static func stallLine(_ stall: GoalStall) -> String { "Nothing has moved in \(stall.days) days" }

    /// "The next task, “Finish lesson 2”, has been open since Nov 28. Still want this one?"
    static func stallQuestion(_ stall: GoalStall, now: Date, calendar: Calendar = .current) -> String {
        guard let task = stall.task else { return "Still want this one?" }
        let since = stall.since.map { " since " + TodoWords.monthDay($0, now: now, calendar: calendar) } ?? ""
        return "The next task, “\(task.title)”, has been open\(since). Still want this one?"
    }
}

/// [goals step 3] A bot on a goal: who leads and helps, the check-in's slot, where the number comes from.
nonisolated enum GoalBots {
    // MARK: Who

    /// The faces at a card's end and on the who row: the lead first, then the helpers.
    static func team(_ goal: Goal) -> [String] { goal.team }

    /// The who row: "Led by Hermes"; with no lead but helpers, "Helped by Ivy"; nil with no bot.
    static func whoLine(_ goal: Goal, botName: (String?) -> String) -> String? {
        if let lead = goal.lead { return "Led by \(botName(lead))" }
        guard let first = goal.helpers.first else { return nil }
        return goal.helpers.count == 1 ? "Helped by \(botName(first))" : "Helped by \(botName(first)) and \(goal.helpers.count - 1) more"
    }

    /// What VoiceOver hears for the who row: "Led by Hermes, with Ivy and Wren".
    static func whoSpoken(_ goal: Goal, botName: (String?) -> String) -> String? {
        guard let line = whoLine(goal, botName: botName) else { return nil }
        let helpers = goal.lead == nil ? [] : goal.helpers.map { botName($0) }
        return helpers.isEmpty ? line : line + ", with " + ListFormatter.localizedString(byJoining: helpers)
    }

    /// [goals step 4] The check-in's push carries `request` "goal:<id>" (kind "task", hermes-hq-push 0.9.66): the goal to
    /// open. Nil for a task's push (its `request` is the task's id).
    static func pushedGoal(_ request: String?) -> String? {
        guard let request, request.hasPrefix("goal:") else { return nil }
        let id = String(request.dropFirst(5))
        return id.isEmpty ? nil : id
    }

    /// What VoiceOver adds to a goal's card for its faces: "Led by Hermes, with Ivy. Waiting for your answer." Empty
    /// with no bot. `team`: lead first (`GoalBots.team`); `led`: the first is the lead.
    static func cardSpoken(team: [String], led: Bool, waits: Bool, botName: (String?) -> String) -> String {
        guard !team.isEmpty else { return "" }
        let names = team.map { botName($0) }
        let who = led
            ? "Led by \(names[0])" + (names.count > 1 ? ", with " + ListFormatter.localizedString(byJoining: Array(names.dropFirst())) : "")
            : "Helped by " + ListFormatter.localizedString(byJoining: names)
        return who + (waits ? ". Waiting for your answer." : ".")
    }

    /// The lead's dot is orange while something of that goal waits for you: an offer for it, or the lead's "this looks
    /// done".
    static func waitsForYou(_ goal: Goal, offers: [TodoOffer]) -> Bool {
        looksDone(goal) != nil || offers.contains { $0.isGoal && $0.isWaiting && !$0.held && $0.goal == goal.id }
    }

    // MARK: The check-in's slot

    static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    /// The times Edit Goal offers.
    static let reviewTimes = ["07:00", "08:00", "09:00", "12:00", "17:00", "18:00", "20:00"]

    /// "8 AM", "8:30 AM", "12 PM".
    static func time(_ hhmm: String) -> String {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return hhmm }
        let hour = parts[0] % 24, minute = parts[1]
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return (minute == 0 ? "\(twelve)" : String(format: "%d:%02d", twelve, minute)) + (hour < 12 ? " AM" : " PM")
    }

    /// "Mondays 8 AM"; "Off" with no check-in.
    static func reviewWords(_ review: GoalReview?) -> String {
        guard let review, weekdays.indices.contains(review.day) else { return "Off" }
        return "\(weekdays[review.day])s \(time(review.time))"
    }

    // MARK: The number's source

    /// Edit Goal's Number From: "TestFlight · Hermes", or "You".
    static func numberFromWords(_ measure: GoalMeasure, botName: (String?) -> String) -> String {
        guard let bot = measure.source.bot else { return "You" }
        let what = measure.source.what.trimmingCharacters(in: .whitespacesAndNewlines)
        return what.isEmpty ? botName(bot) : "\(what) · \(botName(bot))"
    }

    /// The number row's end when a bot reads it: "TestFlight · 8:02 AM" (when it last looked, else when it moved; a
    /// day's name on another day). Nil when the number is yours (the row says Update).
    static func sourceWords(_ measure: GoalMeasure, now: Date, botName: (String?) -> String, calendar: Calendar = .current) -> String? {
        guard let bot = measure.source.bot else { return nil }
        let what = measure.source.what.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = what.isEmpty ? botName(bot) : what
        guard let when = TodoDates.moment(measure.checkedAt) ?? TodoDates.moment(measure.at) else { return name }
        let words = calendar.isDate(when, inSameDayAs: now) ? TodoWords.clock(when, calendar: calendar) : TodoWords.day(when, now: now, calendar: calendar)
        return "\(name) · \(words)"
    }

    // MARK: Looks done

    /// The lead's "this looks done" while it waits: set, not kept (Not Yet), on an active goal, for a milestone not
    /// done (or the goal).
    static func looksDone(_ goal: Goal) -> GoalDoneOffer? {
        guard goal.state == .active, let offer = goal.offer, !offer.kept else { return nil }
        if offer.what == "goal" { return offer }
        return goal.milestones.contains { $0.id == offer.what && !$0.done } ? offer : nil
    }

    /// Its card's words: "Hermes thinks Launch week looks done: all four posts are up. Mark it done?"
    static func looksDoneText(_ offer: GoalDoneOffer, goal: Goal, botName: (String?) -> String) -> String {
        let why = offer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = why.isEmpty ? "." : ": " + (why.hasSuffix(".") ? String(why.dropLast()) : why) + "."
        if offer.what == "goal" { return "\(botName(offer.by)) thinks this goal is achieved\(reason) Mark it achieved?" }
        let name = goal.milestone(offer.what)?.title ?? "this milestone"
        return "\(botName(offer.by)) thinks \(name) looks done\(reason) Mark it done?"
    }

    static func looksDoneYes(_ offer: GoalDoneOffer) -> String { offer.what == "goal" ? "Mark Achieved" : "Mark Done" }

    // MARK: Where it stands

    /// The stands card's "since when": "today", "yesterday", "Nov 12".
    static func standsWhen(_ stands: GoalStands, now: Date, calendar: Calendar = .current) -> String? {
        guard let at = TodoDates.moment(stands.at) else { return nil }
        let day = TodoWords.day(at, now: now, calendar: calendar)
        return ["Today", "Yesterday", "Tomorrow"].contains(day) ? day.lowercased() : day
    }

    // MARK: What the app asks the lead (hidden turns in the goal's chat)

    /// The goal's chat's own title: unique per goal (a taken title reopens that chat, so two devices land in one),
    /// within Hermes's 100 characters.
    static func sessionTitle(_ goal: Goal) -> String {
        let name = goal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = name.count > 70 ? String(name.prefix(69)) + "…" : name
        return "Goal: \(short) · \(goal.id.prefix(6))"
    }

    /// The goal's details as the lead reads them.
    static func details(_ goal: Goal, now: Date, calendar: Calendar = .current) -> String {
        var lines = ["Goal: “\(goal.title)”"]
        let why = goal.why.trimmingCharacters(in: .whitespacesAndNewlines)
        if !why.isEmpty { lines.append("Why: \(why)") }
        if let row = GoalViews.dateRow(goal, now: now, calendar: calendar) { lines.append(row) }
        if let measure = goal.measure { lines.append("Number: \(GoalViews.measureWords(measure, unit: true))") }
        if !goal.milestones.isEmpty { lines.append("Milestones: " + goal.milestones.map(\.title).joined(separator: "; ")) }
        lines.append("(Goal id \(goal.id))")
        return lines.joined(separator: "\n")
    }

    /// New Goal's Plan With <Bot>: the hidden first turn (your bubble shows nothing you didn't type).
    static let planRequestStart = "I just made this goal and want you to lead it."
    /// The line as you typed it, inside the ask, so the stored turn can show it again as your bubble after a relaunch
    /// and on another device (`planBubble`).
    static let planWordsStart = "In my words: “"
    static let planWordsEnd = "”."
    static func planRequest(_ goal: Goal, typed: String? = nil, now: Date, calendar: Calendar = .current) -> String {
        let words = ChatText.flat(typed ?? "")
        return planRequestStart + (words.isEmpty ? "" : " " + planWordsStart + words + planWordsEnd)
            + "\n" + details(goal, now: now, calendar: calendar)
            + "\nAsk me at most three quick questions, on question cards, and look up what you can yourself. Then offer the "
            + "plan with goals_offer (kind \"plan\"): the milestones, and only the first week's tasks, each with who. "
            + "Nothing is added until I tap."
    }

    /// A stored Plan With ask → the words its bubble shows (what you typed); nil for any other turn.
    static func planBubble(forStored text: String) -> String? {
        let flat = ChatText.flat(text)
        guard flat.hasPrefix(planRequestStart + " " + planWordsStart) else { return nil }
        let rest = flat.dropFirst(planRequestStart.count + 1 + planWordsStart.count)
        // The words end at the first "”." followed by the goal's details ("Goal: “…”").
        guard let end = rest.range(of: planWordsEnd + " Goal: “") else { return nil }
        let words = String(rest[..<end.lowerBound])
        return words.isEmpty ? nil : words
    }

    /// Ask for an Update (the Goal Page's), as a hidden turn.
    static func updateRequest(_ goal: Goal) -> String {
        "Please look at where “\(goal.title)” stands now, check its number if you read it, and update where it stands and "
            + "its Goal Page (goals_update with stands and page). (Goal id \(goal.id))"
    }

    /// The stall question's Smaller Step with a lead, as a hidden turn.
    static func smallerStepRequest(_ goal: Goal, stall: GoalStall) -> String {
        let task = stall.task.map { "The next task, “\($0.title)”, " } ?? "Nothing under it "
        return "Nothing has moved on “\(goal.title)” in \(stall.days) days. \(task)hasn't been done. Offer me one smaller first "
            + "step I can do today (goals_offer, kind \"tasks\"), and ask nothing else. (Goal id \(goal.id))"
    }
}

/// [goals step 3] A goal's offer card: where it shows, its words and its buttons. One height in every state.
nonisolated enum GoalOffers {
    /// A goal's offers that wait for you (held ones never show).
    static func waiting(_ all: [TodoOffer]) -> [TodoOffer] {
        all.filter { $0.isGoal && $0.isWaiting && !$0.held }
    }

    /// The top of Today: one at a time, the oldest first (under any list offer). An offer for a goal you no longer have
    /// (or not yet read) waits.
    static func today(_ all: [TodoOffer], goals: [Goal]) -> TodoOffer? {
        let known = Set(goals.filter { $0.state == .active }.map(\.id))
        return waiting(all).filter { $0.goal.map(known.contains) ?? true }
            .sorted { (TodoDates.moment($0.at) ?? .distantPast, $0.id) < (TodoDates.moment($1.at) ?? .distantPast, $1.id) }.first
    }

    /// On a goal's page: what waits for it, and what you accepted today (its card keeps Undo), oldest first.
    static func onGoal(_ all: [TodoOffer], goal: String) -> [TodoOffer] {
        all.filter { $0.isGoal && !$0.held && ($0.goal == goal || $0.madeGoal == goal) && ($0.isWaiting || $0.state == "accepted") }
            .sorted { (TodoDates.moment($0.at) ?? .distantPast, $0.id) < (TodoDates.moment($1.at) ?? .distantPast, $1.id) }
    }

    // MARK: The buttons' row

    /// The card's buttons in one row of `available` points (gaps taken out): equal widths while every title fits its
    /// share; else each gets what its title needs plus an even share of what is left; and only when even that is too
    /// wide (a narrow Mac pane, a large text size) the titles shrink, to no less than `floor`. `natural`: each title's
    /// width with its insets, at full size. Widths are whole points.
    static func buttonWidths(natural: [CGFloat], available: CGFloat, floor: CGFloat = 0.8) -> (widths: [CGFloat], scale: CGFloat) {
        guard !natural.isEmpty, available > 0 else { return (natural.map { _ in 0 }, 1) }
        let count = CGFloat(natural.count)
        let equal = (available / count).rounded(.down)
        if natural.allSatisfy({ $0 <= equal }) { return (natural.map { _ in equal }, 1) }
        let need = natural.reduce(0, +)
        if need <= available {
            let extra = (available - need) / count
            return (natural.map { ($0 + extra).rounded(.down) }, 1)
        }
        let scale = max(floor, available / need)
        return (natural.map { ($0 * available / need).rounded(.down) }, scale)
    }

    // MARK: Words

    /// The quiet word after the goal's name: "new goal", "plan", "add 2 tasks?"; the check-in has its own head.
    static func tag(_ offer: TodoOffer) -> String {
        switch offer.kind {
        case "goal": return "new goal"
        case "plan": return "plan"
        case "tasks": return "add \(TodoLists.count(offer.tasks.count))?"
        default: return ""
        }
    }

    /// The check-in card's head: "Hermes · Monday check-in" (the goal's slot's day, else the day it came).
    static func checkinHead(_ offer: TodoOffer, goal: Goal?, botName: (String?) -> String, calendar: Calendar = .current) -> String {
        let day: String
        if let review = goal?.review, GoalBots.weekdays.indices.contains(review.day) {
            day = GoalBots.weekdays[review.day]
        } else if let at = TodoDates.moment(offer.at) {
            let index = (calendar.component(.weekday, from: at) + 5) % 7   // Sunday 1 → 6, Monday 2 → 0
            day = GoalBots.weekdays[index]
        } else {
            day = "Weekly"
        }
        return "\(botName(offer.bot)) · \(day) check-in"
    }

    /// "5 milestones", "1 milestone".
    static func milestoneCount(_ n: Int) -> String { n == 1 ? "1 milestone" : "\(n) milestones" }

    /// A task's who: "You", or the bot's name.
    static func who(_ task: TodoOfferTask, offer: TodoOffer, botName: (String?) -> String) -> String {
        task.botFor(offer).map { botName($0) } ?? "You"
    }

    /// Under a tasks card from a bot that isn't on the goal: "Hermes leads this goal and sees them at Monday's check-in."
    static func leadNote(_ offer: TodoOffer, goal: Goal?, botName: (String?) -> String) -> String? {
        guard offer.kind == "tasks", let goal, let lead = goal.lead, offer.bot != lead, !goal.helpers.contains(offer.bot) else { return nil }
        guard let review = goal.review, GoalBots.weekdays.indices.contains(review.day) else { return "\(botName(lead)) leads this goal." }
        return "\(botName(lead)) leads this goal and sees them at \(GoalBots.weekdays[review.day])’s check-in."
    }

    /// The card's answers, the filled one first. `change` is not an answer: it puts the cursor in the goal's chat.
    static func buttons(_ offer: TodoOffer) -> [GoalOfferButton] {
        guard offer.isWaiting else { return [] }
        let hasPlan = !offer.milestones.isEmpty || !offer.tasks.isEmpty
        switch offer.kind {
        case "goal":
            var out = [GoalOfferButton(title: "Make This Goal", action: .accept, main: true),
                       GoalOfferButton(title: "Not Now", action: .decline)]
            if hasPlan { out.append(GoalOfferButton(title: "Keep the Goal, No Plan", action: .accept, plan: false, quiet: true)) }
            return out
        case "plan":
            return [GoalOfferButton(title: "Use This Plan", action: .accept, main: true),
                    GoalOfferButton(title: "Change It", action: nil),
                    GoalOfferButton(title: "Keep the Goal, No Plan", action: .accept, plan: false, quiet: true)]
        case "checkin":
            let n = offer.tasks.count
            return [GoalOfferButton(title: n == 0 ? "Got It" : "Add These \(n)", action: .accept, main: true),
                    GoalOfferButton(title: "Change", action: nil),
                    GoalOfferButton(title: "Not Now", action: .decline)]
        default:   // tasks
            return [GoalOfferButton(title: "Add to Goal", action: .accept, main: true),
                    GoalOfferButton(title: "Just Tasks", action: .accept, inGoal: false),
                    GoalOfferButton(title: "No", action: .decline)]
        }
    }

    /// What an answered card says in place of its buttons: "Made the goal and added 4 tasks", "Added 3 tasks", "Kept
    /// the goal, no plan", "Not now", "Undone". Nil while it waits.
    static func done(_ offer: TodoOffer) -> String? {
        let n = offer.added.count
        switch offer.state {
        case "accepted":
            switch offer.kind {
            case "goal":
                if offer.plan == false { return "Made the goal, no plan" }
                return n > 0 ? "Made the goal and added \(TodoLists.count(n))" : "Made the goal"
            case "plan":
                let m = offer.madeMilestones.count
                let parts = [m > 0 ? milestoneCount(m) : nil, n > 0 ? TodoLists.count(n) : nil].compactMap { $0 }
                return parts.isEmpty ? "Plan added" : "Added " + parts.joined(separator: " and ")
            case "checkin":
                return n > 0 ? "Added \(TodoLists.count(n))" : "Seen"
            default:
                if offer.inGoal == false { return "Added \(TodoLists.count(n)), no goal" }
                return "Added \(TodoLists.count(n)) to the goal"
            }
        case "declined": return offer.kind == "plan" ? "Kept the goal, no plan" : "Not now"
        case "undone": return offer.kept.isEmpty ? "Undone" : "Undone, except what you changed"
        default: return nil
        }
    }

    /// The card's foot as the offer stands now. `past`: answered more than a day ago (the gateway let it go).
    static func foot(_ offer: TodoOffer, past: Bool) -> GoalOfferFoot {
        if past { return GoalOfferFoot(line: "Answered") }
        let buttons = buttons(offer)
        if let main = buttons.first(where: \.main) {
            return GoalOfferFoot(main: main, others: buttons.filter { !$0.main && !$0.quiet }, quiet: buttons.first(where: \.quiet))
        }
        return GoalOfferFoot(line: done(offer) ?? "Answered", good: offer.state == "accepted", undo: offer.state == "accepted")
    }

    /// The rows a card lists, at most `shown` (the rest are "N more ›").
    static let shown = 3

    /// What VoiceOver hears for a card's head.
    static func spoken(_ offer: TodoOffer, goal: Goal?, botName: (String?) -> String) -> String {
        let name = offer.title.isEmpty ? (goal?.title ?? "a goal") : offer.title
        switch offer.kind {
        case "goal": return "\(botName(offer.bot)) suggests a goal: \(name)"
        case "plan": return "\(botName(offer.bot))’s plan for \(name)"
        case "checkin": return checkinHead(offer, goal: goal, botName: botName) + ", \(name)"
        default: return "\(botName(offer.bot)) has \(TodoLists.count(offer.tasks.count)) for \(name)"
        }
    }
}

/// A button on a goal's offer card.
nonisolated struct GoalOfferButton: Hashable, Sendable {
    var title: String
    /// nil: not an answer (Change It / Change: the goal's chat takes the cursor).
    var action: TodoOfferAction?
    var plan = true
    var inGoal = true
    var main = false
    /// The quiet line under the buttons ("Keep the Goal, No Plan").
    var quiet = false
}

/// The foot of a goal's offer card: the buttons, or one line with Undo. The card keeps one height either way.
nonisolated struct GoalOfferFoot: Hashable, Sendable {
    var main: GoalOfferButton?
    var others: [GoalOfferButton] = []
    var quiet: GoalOfferButton?
    var line: String?
    var good = false
    var undo = false
}
