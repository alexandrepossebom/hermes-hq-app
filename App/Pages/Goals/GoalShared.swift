// [goals] What every goal screen shares (docs/goals.md, the owner-approved boards): the ring (how far along, in the
// goal's colour), the goal's mark (a target in its colour, where a list has its dot), the bar with its even-pace tick,
// the pace's colour, the "Add to Goal" choices (a task's page, a task row's hold menu), and Not Yet remembered on this
// device. The rules are HermesKit's `GoalViews`; this file only draws.

import SwiftUI
import UIKit

/// How far along a goal is: a ring in its colour over a faint track; empty with no plan. Never its own element: the
/// card or the title says the percent.
struct GoalRing: View {
    var fraction: Double?
    var color: TodoListColor
    var size: CGFloat
    /// Someday's quieter cards: the ring in grey.
    var quiet = false

    var body: some View {
        let line = max(2.5, size * 0.11)
        ZStack {
            Circle().stroke(Color.hqFill3, lineWidth: line)
            if let fraction, fraction > 0 {
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(quiet ? Color.hqLabel3 : color.ink, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(line / 2)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A goal's mark: a small target in its colour (a list's dot's place, on a task's page and in menus).
struct GoalMark: View {
    var color: TodoListColor
    var body: some View {
        Image(systemName: "smallcircle.filled.circle")
            .foregroundStyle(color.ink)
            .accessibilityHidden(true)
    }
}

/// The page's bar: how far along, in the goal's colour, with a tick where an even pace would be today.
struct GoalProgressBar: View {
    var fraction: Double?
    var even: Double?
    var color: TodoListColor

    var body: some View {
        GeometryReader { box in
            let width = box.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.hqFill3).frame(height: 6)
                if let fraction, fraction > 0 {
                    Capsule().fill(color.ink).frame(width: max(6, width * fraction), height: 6)
                }
                if let even {
                    Rectangle()
                        .fill(Color.hqLabel)
                        .frame(width: 2, height: 14)
                        .offset(x: min(max(0, width * even - 1), width - 2))
                }
            }
            .frame(height: 14)
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

extension GoalPace.Tone {
    /// On pace and ahead in green, behind in orange, late in red (the only red: rule 4).
    var ink: Color {
        switch self {
        case .good: return Color(uiColor: TodoInk.ready)
        case .behind: return Color.hqOrange
        case .late: return Color.hqRed
        }
    }
}

/// Not Yet on a goal's offer, kept on this device until something under it changes (`GoalViews.signature`).
enum GoalNotYet {
    private static let key = "HQGoalNotYet"

    static var all: [String: String] { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }

    static func remember(_ offer: GoalOffer, goal: Goal, tasks: [TodoTask]) {
        var stored = all
        stored[offer.key(goal: goal)] = GoalViews.signature(offer, goal: goal, tasks: tasks)
        UserDefaults.standard.set(stored, forKey: key)
    }
}

/// [goals step 4] The stall question's Keep Going, kept on this device (an add-on before 0.9.66 keeps no `kept_at`; on
/// 0.9.66 the gateway's `kept_at` says the same for every device). By goal id, when it was tapped.
enum GoalKeptHere {
    private static let key = "HQGoalKeptHere"

    static var all: [String: Date] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }

    static func remember(_ goal: String, at now: Date = Date()) {
        var stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        stored[goal] = now.timeIntervalSince1970
        UserDefaults.standard.set(stored, forKey: key)
    }

    #if DEBUG
    /// `-HQPagesForgetGoalKeeps` (PagesDebug): a test's device starts with no Keep Going.
    static func forget() { UserDefaults.standard.removeObject(forKey: key) }
    #endif
}

/// "Add to Goal": each active goal (then its milestones), No Goal, and Open Goal. One list of choices, drawn as a UIKit
/// menu (a task row's hold menu) or a SwiftUI one (a task's page).
@MainActor
enum GoalChoices {
    /// The menu for a task (its row's hold menu): ticks on where it is.
    static func menu(for taskID: String, store: TasksStore, open: @escaping (String) -> Void) -> UIMenu? {
        guard store.goalsSupported, let task = store.task(taskID) else { return nil }
        let active = GoalViews.groups(store.goals).active
        var rows: [UIMenuElement] = active.map { goal in
            let here = task.goal == goal.id
            guard !goal.milestones.isEmpty else {
                return UIAction(title: goal.title, image: UIImage(systemName: "smallcircle.filled.circle"), state: here ? .on : .off) { _ in
                    set(taskID, goal: goal.id, milestone: nil, store: store)
                }
            }
            var inner: [UIMenuElement] = [UIAction(title: "No Milestone", state: here && task.milestone == nil ? .on : .off) { _ in
                set(taskID, goal: goal.id, milestone: nil, store: store)
            }]
            inner += goal.milestones.filter { !$0.done || task.milestone == $0.id }.map { milestone in
                UIAction(title: milestone.title, state: here && task.milestone == milestone.id ? .on : .off) { _ in
                    set(taskID, goal: goal.id, milestone: milestone.id, store: store)
                }
            }
            return UIMenu(title: goal.title, image: UIImage(systemName: "smallcircle.filled.circle"), children: inner)
        }
        if task.goal != nil {
            rows.append(UIAction(title: "No Goal", image: UIImage(systemName: "minus.circle")) { _ in
                set(taskID, goal: nil, milestone: nil, store: store)
            })
            if let goal = task.goal {
                rows.append(UIAction(title: "Open Goal", image: UIImage(systemName: "arrow.up.forward.square")) { _ in
                    PagesHaptics.selection()
                    open(goal)
                })
            }
        }
        guard !rows.isEmpty else { return nil }
        return UIMenu(title: "Add to Goal", image: UIImage(systemName: "smallcircle.filled.circle"), children: rows)
    }

    static func set(_ taskID: String, goal: String?, milestone: String?, store: TasksStore) {
        PagesHaptics.selection()
        Task { if await !store.setGoal(taskID, goal: goal, milestone: milestone) { PagesHaptics.error() } }
    }
}

/// The same choices in SwiftUI (a task's page: its goal row and "+ Goal").
struct GoalChoiceItems: View {
    let task: TodoTask
    let store: TasksStore
    var open: (String) -> Void

    var body: some View {
        ForEach(GoalViews.groups(store.goals).active) { goal in
            let here = task.goal == goal.id
            if goal.milestones.isEmpty {
                Button { GoalChoices.set(task.id, goal: goal.id, milestone: nil, store: store) } label: {
                    if here { Label(goal.title, systemImage: "checkmark") } else { Text(goal.title) }
                }
            } else {
                Menu(goal.title) {
                    Button { GoalChoices.set(task.id, goal: goal.id, milestone: nil, store: store) } label: {
                        if here, task.milestone == nil { Label("No Milestone", systemImage: "checkmark") } else { Text("No Milestone") }
                    }
                    ForEach(goal.milestones.filter { !$0.done || task.milestone == $0.id }) { milestone in
                        Button { GoalChoices.set(task.id, goal: goal.id, milestone: milestone.id, store: store) } label: {
                            if here, task.milestone == milestone.id { Label(milestone.title, systemImage: "checkmark") } else { Text(milestone.title) }
                        }
                    }
                }
            }
        }
        if let goal = task.goal {
            Button("No Goal", systemImage: "minus.circle") { GoalChoices.set(task.id, goal: nil, milestone: nil, store: store) }
            Button("Open Goal", systemImage: "arrow.up.forward.square") { PagesHaptics.selection(); open(goal) }
        }
    }
}

/// [goals step 3] Your bots' names and faces, for a goal card's faces and the words VoiceOver hears for them.
struct GoalTeamLook: Hashable {
    var names: [String: String] = [:]
    var heads: [String: JSONValue] = [:]

    @MainActor init(bots: [Bot]) {
        names = Dictionary(bots.map { ($0.id, PagesNames.botName($0.id, bots: bots)) }, uniquingKeysWith: { a, _ in a })
        heads = Dictionary(bots.compactMap { bot in bot.head.map { (bot.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    init() {}

    func name(_ profile: String?) -> String { profile.flatMap { names[$0] } ?? profile ?? "" }

    func spoken(team: [String], led: Bool, waits: Bool) -> String {
        GoalBots.cardSpoken(team: team, led: led, waits: waits, botName: name)
    }
}

/// [goals step 3] The bots on a goal at its card's end: the lead first, then its helpers (three at most), each a little
/// over the next; the lead's dot orange while an offer for the goal waits for you (`GoalBots.waitsForYou`). A face
/// means the bot is on the goal; nothing else draws one. The card says it in words for VoiceOver.
struct GoalTeamFaces: View {
    var team: [String]
    var look: GoalTeamLook
    var waits: Bool
    var size: CGFloat

    var body: some View {
        HStack(spacing: -size * 0.22) {
            ForEach(Array(team.prefix(3).enumerated()), id: \.element) { index, bot in
                HeadImage(raw: look.heads[bot], profile: bot, size: size)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.hqGroupedCard).padding(-1.5))
                    .overlay(alignment: .bottomTrailing) {
                        if index == 0 && waits {
                            Circle()
                                .fill(Color.hqOrange)
                                .frame(width: size * 0.4, height: size * 0.4)
                                .background(Circle().fill(Color.hqGroupedCard).padding(-1.5))
                                .offset(x: 2, y: 2)
                                .accessibilityIdentifier("goal.card.waits")
                        }
                    }
                    .zIndex(Double(3 - index))
            }
        }
        .accessibilityHidden(true)
    }
}

/// [goals steps 3 and 4] A goal card's VoiceOver label: its words, then the stall line and who is on it.
enum GoalCardWords {
    static func label(_ spoken: String, stall: String?, team: String) -> String {
        [spoken, stall.map { $0 + "." } ?? "", team].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
