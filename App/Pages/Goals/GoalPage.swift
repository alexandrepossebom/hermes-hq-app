// [goals] A goal's page (docs/goals.md "A goal's page", board 2's left and middle phones): a sheet over the Tasks page,
// as a task's is. The bar: back, a "Goal" capsule with the goal's mark, ⋯ (the hold menu's rows). The page itself is
// `GoalPlainView`, drawn from a task's page's rows. This file holds what the page does: its model (edits, ticks with
// the dust, the offers' answers, the sheets it opens) and the rows of ⋯ (`GoalMenu`, a card's hold menu too).

import SwiftUI
import UIKit

/// Where "Add a task" is open: under a milestone, or under No Milestone (or Tasks).
enum GoalAddSpot: Hashable {
    case milestone(String)
    case loose
}

@MainActor @Observable
final class GoalPageModel {
    let goalID: String
    let store: TasksStore
    let context: MorePages.Context
    @ObservationIgnored weak var controller: UIViewController?
    var notice: String?
    @ObservationIgnored private var noticeWork: DispatchWorkItem?
    /// Tasks ticked here: drawn ticked until they move (to done, under the milestone's count).
    var ticking: Set<String> = []
    /// Rows whose picture is in the air as dust (drawn empty until the list has closed behind them).
    var dusted: Set<String> = []
    /// Milestones a tap opened (true) or closed (false); the rest follow the rule (the current one open).
    var opened: [String: Bool] = [:]
    /// Not Yet answers on this device (`GoalNotYet`).
    var notYet = GoalNotYet.all
    var editingTitle = false
    var titleDraft = ""
    var editingWhy = false
    var whyDraft = ""
    var adding: GoalAddSpot?
    var newTask = ""
    var addingMilestone = false
    var newMilestone = ""
    /// The rows' frames in the page's own coordinates (for the dust).
    @ObservationIgnored var rowFrames: [String: CGRect] = [:]
    @ObservationIgnored private var lastSeen: Goal?

    #if DEBUG
    static weak var debugLast: GoalPageModel?
    #endif

    init(goalID: String, store: TasksStore, context: MorePages.Context) {
        self.goalID = goalID
        self.store = store
        self.context = context
        #if DEBUG
        Self.debugLast = self
        #endif
    }

    /// The goal (as it was last seen once deleted elsewhere, so the page stays readable until it closes).
    var goal: Goal? {
        if let goal = store.goal(goalID) { lastSeen = goal; return goal }
        return lastSeen
    }

    var gone: Bool { store.hasList && store.goal(goalID) == nil }
    var tasks: [TodoTask] { store.tasks }
    var readOnly: Bool { store.readOnlyGateway }

    func botName(_ profile: String?) -> String { PagesNames.botName(profile ?? "default", bots: context.bots) }
    func head(_ profile: String) -> JSONValue? { PagesNames.head(profile, bots: context.bots) }

    func show(_ text: String) {
        notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        HQAnnounce.say(text)
    }

    func isOpen(_ milestone: GoalMilestone, in goal: Goal) -> Bool {
        opened[milestone.id] ?? (milestone.id == GoalViews.current(goal)?.id)
    }

    func toggleOpen(_ milestone: GoalMilestone, in goal: Goal) {
        PagesHaptics.selection()
        let open = isOpen(milestone, in: goal)
        HQMotion.withAnimation(.snappy) { opened[milestone.id] = !open }
    }

    // MARK: Edits

    func patch(_ fields: [String: JSONValue]) {
        Task { if await !store.patchGoal(goalID, fields) { PagesHaptics.error() } }
    }

    func editTitle() {
        guard let goal, !gone, !readOnly else { return }
        titleDraft = goal.title
        editingTitle = true
    }

    func saveTitle() {
        guard editingTitle else { return }
        editingTitle = false
        let clean = String(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !clean.isEmpty, clean != goal?.title else { return }
        PagesHaptics.selection()
        patch(["title": .string(clean)])
    }

    func editWhy() {
        guard let goal, !gone, !readOnly else { return }
        whyDraft = goal.why
        editingWhy = true
    }

    func saveWhy() {
        guard editingWhy else { return }
        editingWhy = false
        let clean = String(whyDraft.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").prefix(300))
        guard clean != goal?.why else { return }
        PagesHaptics.selection()
        patch(["why": .string(clean)])
    }

    func setDue(_ date: Date?) {
        PagesHaptics.selection()
        patch(["due": TodoWire.optional(date.map { TodoViews.dayKey(Calendar.current.startOfDay(for: $0), calendar: .current) })])
    }

    func setStatus(_ status: GoalState) {
        GoalMenu.setStatus(status, goalID: goalID, store: store)
    }

    /// The date row's "Choose Date…", and + Date.
    func pickDate() {
        guard let controller, let goal else { return }
        let picker = TodoDatePicker.make(date: goal.due.flatMap { TodoDates.day(String($0.prefix(10))) }, hasTime: false, dayOnly: true,
                                         title: "By", note: "The day you want this done by. Pace is measured against it.") { [weak self] date, _ in
            self?.setDue(date)
        }
        controller.present(picker, animated: true)
    }

    // MARK: Milestones

    private func saveMilestones(_ list: [GoalMilestone]) {
        patch(["milestones": GoalWire.milestones(list)])
    }

    func toggleMilestone(_ milestone: GoalMilestone) {
        guard let goal, !gone, !readOnly else { return }
        if milestone.done { PagesHaptics.selection() } else { PagesHaptics.success() }
        saveMilestones(goal.milestones.map { item in
            var item = item
            if item.id == milestone.id { item.done.toggle() }
            return item
        })
        if !milestone.done { HQAnnounce.say("Done: \(milestone.title)") }
    }

    func addMilestone() {
        let clean = String(newMilestone.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        newMilestone = ""
        guard let goal, !clean.isEmpty, goal.milestones.count < 30 else { return }
        PagesHaptics.selection()
        saveMilestones(goal.milestones + [GoalMilestone(id: TodoIDs.local(), title: clean, due: nil, done: false, doneAt: nil)])
    }

    func moveMilestone(_ milestone: GoalMilestone, by offset: Int) {
        guard var list = goal?.milestones, let at = list.firstIndex(where: { $0.id == milestone.id }) else { return }
        let to = at + offset
        guard list.indices.contains(to) else { return }
        PagesHaptics.selection()
        list.swapAt(at, to)
        saveMilestones(list)
    }

    func renameMilestone(_ milestone: GoalMilestone) {
        askName(title: "Rename Milestone", name: milestone.title, action: "Rename") { [weak self] name in
            guard let self, let goal = self.goal else { return }
            self.saveMilestones(goal.milestones.map { item in
                var item = item
                if item.id == milestone.id { item.title = String(name.prefix(120)) }
                return item
            })
        }
    }

    func setMilestoneDate(_ milestone: GoalMilestone) {
        guard let controller else { return }
        let picker = TodoDatePicker.make(date: milestone.due.flatMap { TodoDates.day(String($0.prefix(10))) }, hasTime: false, dayOnly: true,
                                         title: "Milestone Date", note: "When you want “\(milestone.title)” done.") { [weak self] date, _ in
            guard let self, let goal = self.goal else { return }
            PagesHaptics.selection()
            let day = TodoViews.dayKey(Calendar.current.startOfDay(for: date), calendar: .current)
            self.saveMilestones(goal.milestones.map { item in
                var item = item
                if item.id == milestone.id { item.due = day }
                return item
            })
        }
        controller.present(picker, animated: true)
    }

    func clearMilestoneDate(_ milestone: GoalMilestone) {
        guard let goal else { return }
        PagesHaptics.selection()
        saveMilestones(goal.milestones.map { item in
            var item = item
            if item.id == milestone.id { item.due = nil }
            return item
        })
    }

    /// Asks first; its tasks stay in the goal, under No Milestone.
    func deleteMilestone(_ milestone: GoalMilestone) {
        guard let controller else { return }
        let alert = UIAlertController(title: "Delete “\(milestone.title)”?", message: "Its tasks stay in this goal, under No Milestone.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete Milestone", style: .destructive) { [weak self] _ in
            guard let self, let goal = self.goal else { return }
            PagesHaptics.success()
            self.saveMilestones(goal.milestones.filter { $0.id != milestone.id })
        })
        controller.present(alert, animated: true)
    }

    // MARK: Tasks

    /// "Add a task" under a milestone (or none): an ordinary task of yours, in this goal.
    func addTask() {
        let clean = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        newTask = ""
        guard let spot = adding, !clean.isEmpty else { return }
        PagesHaptics.selection()
        var milestone: String?
        if case .milestone(let id) = spot { milestone = id }
        let parsed = TodoQuickParse.read(clean, now: Date())
        let body = TodoWire.newTask(title: parsed.title.isEmpty ? clean : parsed.title, who: .me, bot: nil,
                                    due: parsed.due.map { TodoDates.wire($0, hasTime: parsed.hasTime) }, repeatRule: parsed.repeatRule,
                                    prep: false, goal: goalID, milestone: milestone)
        Task { if await store.add(body) == nil { PagesHaptics.error() } }
    }

    func openTask(_ id: String) {
        guard let controller else { return }
        PagesHaptics.selection()
        let sheet = TodoSheet.make(taskID: id, store: store, context: context)
        controller.present(sheet, animated: true)
    }

    /// Ticks a task (or opens it again). The circle fills and the row turns to dust over the page (not under Reduce
    /// Motion), then the save moves it.
    func toggleTask(_ id: String) {
        guard let task = store.task(id) else { return }
        if task.isDone {
            PagesHaptics.selection()
            Task { if await !store.setDone(id, false) { PagesHaptics.error() } }
            return
        }
        PagesHaptics.success()
        ticking.insert(id)
        HQAnnounce.say("Done: \(task.title)")
        DispatchQueue.main.asyncAfter(deadline: .now() + (HQMotion.reduced ? 0.1 : TaskCheckOff.tick)) { [weak self] in
            guard let self else { return }
            let blown = self.blowAway(id)
            Task {
                if blown { try? await Task.sleep(for: .seconds(TaskCheckOff.sweep * 0.8)) }
                if await !self.store.setDone(id, true) { PagesHaptics.error() }
                self.ticking.remove(id)
                try? await Task.sleep(for: .seconds(0.35))
                self.dusted.remove(id)
            }
        }
    }

    private func blowAway(_ id: String) -> Bool {
        // The row's frame was taken in the window's space (SwiftUI's global one).
        guard !HQMotion.reduced, let view = controller?.view, view.window != nil, let global = rowFrames[id] else { return false }
        let frame = view.convert(global, from: nil)
        guard view.bounds.intersects(frame), TaskDust.play(area: frame, of: view) else { return false }
        dusted.insert(id)
        return true
    }

    // MARK: Offers (rule 5)

    func offer(_ goal: Goal) -> GoalOffer? {
        GoalViews.offer(goal, tasks: tasks, notYet: notYet)
    }

    func answer(_ offer: GoalOffer, yes: Bool) {
        guard let goal else { return }
        guard yes else {
            PagesHaptics.selection()
            GoalNotYet.remember(offer, goal: goal, tasks: tasks)
            HQMotion.withAnimation(.snappy) { notYet = GoalNotYet.all }
            return
        }
        switch offer {
        case .milestone(let milestone): toggleMilestone(milestone)
        case .achieved: setStatus(.achieved)
        }
    }

    // MARK: Sheets

    func updateNumber() {
        guard let controller, let goal, goal.measure != nil, !readOnly else { return }
        PagesHaptics.selection()
        controller.present(GoalUpdateSheet.make(goal: goal) { [weak self] value in
            self?.patch(["measure_now": .number(value)])
        }, animated: true)
    }

    /// + Number, and the number row's Edit Number…: unit, from, to (and where it stands now).
    func editNumber() {
        guard let controller, let goal, !readOnly else { return }
        PagesHaptics.selection()
        controller.present(GoalNumberSheet.make(measure: goal.measure, title: goal.measure == nil ? "Add a Number" : "Edit Number") { [weak self] measure in
            self?.patch(["measure": GoalWire.measure(measure)])
        }, animated: true)
    }

    func removeNumber() {
        guard let controller else { return }
        let alert = UIAlertController(title: "Remove the Number?", message: "The ring follows the milestones, or the tasks, instead.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove Number", style: .destructive) { [weak self] _ in
            PagesHaptics.success()
            self?.patch(["measure": .null])
        })
        controller.present(alert, animated: true)
    }

    func editGoal() {
        guard let controller else { return }
        GoalMenu.edit(goalID: goalID, store: store, from: controller)
    }

    #if DEBUG
    /// `-HQPagesGoalSheet update|edit|number`.
    func debugOpen(_ sheet: String) {
        switch sheet {
        case "update": updateNumber()
        case "edit": editGoal()
        case "number": editNumber()
        default: break
        }
    }
    #endif

    private func askName(title: String, name: String, action: String, done: @escaping (String) -> Void) {
        guard let controller else { return }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = name
            field.autocapitalizationType = .sentences
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: .default) { [weak alert] _ in
            let clean = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !clean.isEmpty, clean != name else { return }
            PagesHaptics.selection()
            done(clean)
        })
        controller.present(alert, animated: true)
    }
}

enum GoalPage {
    static func make(goalID: String, store: TasksStore, context: MorePages.Context) -> UINavigationController {
        let model = GoalPageModel(goalID: goalID, store: store, context: context)
        let host = GoalPageHost(model: model)
        let nav = ChatSheet.wrap(host, title: "Goal", detents: [.large()])
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        return nav
    }
}

final class GoalPageHost: UIHostingController<HQScaledRoot<GoalPlainView>> {
    let model: GoalPageModel
    /// The bar's title: "Goal" with the goal's mark in its colour (where a task's page names its list).
    private let goalTitle = ChatTitleView()
    private let mark = UIImageView()

    init(model: GoalPageModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(GoalPlainView(model: model)))
        model.controller = self
        title = "Goal"
        goalTitle.title = "Goal"
        goalTitle.accessibilityIdentifier = "goal.title-bar"
        mark.contentMode = .scaleAspectFit
        mark.image = UIImage(systemName: "smallcircle.filled.circle",
                             withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium))
        mark.isAccessibilityElement = false
        goalTitle.accessory = mark
        navigationItem.titleView = goalTitle
        watchGoal()
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                MainActor.assumeIsolated {
                    guard let self, !self.model.gone, !self.model.readOnly else { completion([]); return }
                    completion(GoalMenu.items(goalID: self.model.goalID, store: self.model.store, from: self, source: nil))
                }
            },
        ]))
        more.accessibilityLabel = "More"
        more.accessibilityIdentifier = "goal.more"
        navigationItem.rightBarButtonItem = more
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The mark follows the goal's colour (Edit Goal here or on another device).
    private func watchGoal() {
        let tint = withObservationTracking { model.goal?.tint ?? .blue } onChange: { [weak self] in
            DispatchQueue.main.async { self?.watchGoal() }
        }
        mark.tintColor = UIColor(tint.ink)
        // ChatTitleView places and sizes its accessory (a square, centred); sizing it here after a layout knocked a new
        // goal's mark into the capsule's corner.
        goalTitle.frame.size = goalTitle.intrinsicContentSize
        goalTitle.setNeedsLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "goal.sheet"
    }
}

/// The rows of a goal's ⋯ and of its card's hold menu: Edit Goal…, Pause or Resume, Mark Achieved, Let It Go, Delete
/// Goal… (asks first; its tasks are kept). An achieved or let-go goal can be made active again.
@MainActor
enum GoalMenu {
    static func items(goalID: String, store: TasksStore, from presenter: UIViewController, source: UIView?) -> [UIMenuElement] {
        guard let goal = store.goal(goalID) else { return [] }
        var states: [UIMenuElement] = []
        switch goal.state {
        case .active:
            states.append(UIAction(title: "Pause", image: UIImage(systemName: "pause.circle")) { _ in setStatus(.paused, goalID: goalID, store: store) })
        case .paused:
            states.append(UIAction(title: "Resume", image: UIImage(systemName: "play.circle")) { _ in setStatus(.active, goalID: goalID, store: store) })
        case .achieved, .letGo:
            states.append(UIAction(title: "Make Active Again", image: UIImage(systemName: "arrow.uturn.backward.circle")) { _ in
                setStatus(.active, goalID: goalID, store: store)
            })
        }
        if goal.state != .achieved {
            states.append(UIAction(title: "Mark Achieved", image: UIImage(systemName: "checkmark.seal")) { _ in setStatus(.achieved, goalID: goalID, store: store) })
        }
        if goal.state != .letGo {
            states.append(UIAction(title: "Let It Go", image: UIImage(systemName: "wind")) { _ in setStatus(.letGo, goalID: goalID, store: store) })
        }
        return [
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Edit Goal…", image: UIImage(systemName: "pencil")) { [weak presenter] _ in
                    guard let presenter else { return }
                    edit(goalID: goalID, store: store, from: presenter)
                },
            ]),
            UIMenu(options: .displayInline, children: states),
            UIAction(title: "Delete Goal…", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak presenter, weak source] _ in
                guard let presenter else { return }
                confirmDelete(goalID: goalID, store: store, from: presenter, source: source)
            },
        ]
    }

    /// A status change, with its own cue: success for Mark Achieved, a tap for the rest.
    static func setStatus(_ status: GoalState, goalID: String, store: TasksStore) {
        if status == .achieved { PagesHaptics.success() } else { PagesHaptics.selection() }
        Task { if await !store.patchGoal(goalID, ["status": .string(status.rawValue)]) { PagesHaptics.error() } }
        let words: String? = switch status {
        case .achieved: "Achieved"
        case .paused: "Paused. It waits under Someday."
        case .letGo: "Let go. It stays under Let Go."
        case .active: nil
        }
        if let words { HQAnnounce.say(words) }
    }

    static func edit(goalID: String, store: TasksStore, from presenter: UIViewController) {
        guard store.goal(goalID) != nil else { return }
        PagesHaptics.selection()
        presenter.present(GoalEditSheet.make(goalID: goalID, store: store) { [weak presenter] in
            guard let presenter else { return }
            confirmDelete(goalID: goalID, store: store, from: presenter, source: nil)
        }, animated: true)
    }

    /// "Delete “…”?" first. Its tasks stay on your list, with no goal. A goal's page closes once it is gone.
    static func confirmDelete(goalID: String, store: TasksStore, from presenter: UIViewController, source: UIView?) {
        guard let goal = store.goal(goalID) else { return }
        // Asked over whatever is on top (Edit Goal, or the page itself).
        var top = presenter
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let sheet = UIAlertController(title: "Delete “\(goal.title)”?", message: "Its tasks stay on your list, with no goal.",
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Delete Goal", style: .destructive) { [weak presenter] _ in
            Task {
                if await store.deleteGoal(goalID) {
                    PagesHaptics.success()
                    // Close the goal's page (and Edit Goal over it) once the goal is gone.
                    if let page = presenter?.navigationController?.viewControllers.first as? GoalPageHost ?? presenter as? GoalPageHost {
                        // From the sheet's presenter: the page and anything over it (Edit Goal) go together.
                        (page.navigationController?.presentingViewController ?? page.presentingViewController)?.dismiss(animated: true)
                    } else if presenter?.presentedViewController != nil {
                        presenter?.dismiss(animated: true)
                    }
                } else {
                    PagesHaptics.error()
                }
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = source ?? top.view
            popover.sourceRect = source?.bounds ?? CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        }
        top.present(sheet, animated: true)
    }
}
