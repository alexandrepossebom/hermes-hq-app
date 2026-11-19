// [goals] New Goal (docs/goals.md "New Goal and Edit Goal"): the quick add's shape (`NewTodoSheet`, `QuickAddSheet`).
// One line for the goal (`TodoQuickParse` in goal mode reads its date: "Run a 10K by may 3" is "Run a 10K" by May 3),
// a line for why, and one row of buttons: the date, Number (unit, from, to) and Add. It closes on Add and the new
// goal's page opens, where milestones and tasks go.

import SwiftUI
import UIKit

@MainActor @Observable
final class NewGoalModel {
    let store: TasksStore
    var title = ""
    var why = ""
    /// A date picked by hand: the line's own date words stay in the name then.
    var manualDue = false
    var hasDue = false
    var due = Calendar.current.startOfDay(for: Date())
    var measure: GoalMeasure?
    var saving = false
    var failure: String?
    /// [goals step 3] Plan With <Bot>: off by default. With a bot, Add makes the goal led by it, and its chat plans.
    var planWith: String?
    @ObservationIgnored var onCreated: ((Goal?) -> Void)?
    /// [goals step 3] Added with Plan With: the goal, its bot and the line as you typed it (your bubble's words).
    @ObservationIgnored var onPlan: ((Goal, String) -> Void)?
    @ObservationIgnored weak var controller: UIViewController?
    let bots: [(id: String, name: String, head: JSONValue?)]

    init(store: TasksStore, bots: [Bot] = MorePages.context?.bots ?? []) {
        self.store = store
        self.bots = bots.map { ($0.id, PagesNames.botName($0.id, bots: bots), $0.head) }
    }

    /// The Plan With row shows only with the add-on's bots and a bot to pick.
    var offersPlan: Bool { store.goalBotsSupported && !bots.isEmpty }

    func setPlanWith(_ bot: String?) {
        PagesHaptics.selection()
        planWith = bot
    }

    var read: TodoQuickRead { TodoQuickParse.read(title, now: Date(), dates: !manualDue, goal: true) }

    /// The day it is due by: the hand-picked one, else the line's.
    var dueNow: Date? {
        if manualDue { return hasDue ? due : nil }
        return read.due.map { Calendar.current.startOfDay(for: $0) }
    }

    var name: String {
        let read = read.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return read.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : read
    }

    var canAdd: Bool { !name.isEmpty && !saving }

    func setDue(_ date: Date?) {
        PagesHaptics.selection()
        manualDue = true
        hasDue = date != nil
        if let date { due = Calendar.current.startOfDay(for: date) }
    }

    func pickDate() {
        guard let controller else { return }
        PagesHaptics.selection()
        let picker = TodoDatePicker.make(date: dueNow, hasTime: false, dayOnly: true, title: "By",
                                         note: "The day you want this done by. Pace is measured against it.") { [weak self] date, _ in
            self?.setDue(date)
        }
        controller.present(picker, animated: true)
    }

    func editNumber() {
        guard let controller else { return }
        PagesHaptics.selection()
        controller.present(GoalNumberSheet.make(measure: measure, title: "Number") { [weak self] measure in
            self?.measure = measure
        }, animated: true)
    }

    func clearNumber() {
        PagesHaptics.selection()
        measure = nil
    }

    func add() {
        guard canAdd else { return }
        saving = true
        failure = nil
        controller?.isModalInPresentation = true
        var body = GoalWire.newGoal(title: String(name.prefix(200)), why: String(why.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)),
                                    due: dueNow.map { TodoViews.dayKey($0, calendar: .current) }, measure: measure)
        let lead = offersPlan ? planWith : nil
        if let lead { body["lead"] = .string(lead) }
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let made = await store.addGoal(body)
            saving = false
            controller?.isModalInPresentation = false
            guard let made else {
                PagesHaptics.error()
                failure = store.addGoalFailure ?? "Check your connection, then try again."
                return
            }
            PagesHaptics.success()
            HQAnnounce.say("Added “\(made.title)”")
            if lead != nil, let plan = onPlan {
                if let controller { controller.dismiss(animated: true) { plan(made, typed) } } else { plan(made, typed) }
                return
            }
            let done = onCreated
            if let controller { controller.dismiss(animated: true) { done?(made) } } else { done?(made) }
        }
    }
}

enum NewGoalSheet {
    static func make(store: TasksStore, onCreated: @escaping (Goal?) -> Void, onPlan: ((Goal, String) -> Void)? = nil) -> UIViewController {
        let model = NewGoalModel(store: store)
        model.onCreated = onCreated
        model.onPlan = onPlan
        return NewGoalHost(model: model)
    }
}

final class NewGoalHost: UIHostingController<HQScaledRoot<NewGoalView>> {
    let model: NewGoalModel
    private var fitted: CGFloat = 150

    init(model: NewGoalModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(NewGoalView(model: model)))
        model.controller = self
        rootView = HQScaledRoot(NewGoalView(model: model, onHeight: { [weak self] in self?.fit($0) }))
        QuickAddSheet.configure(self, identifier: "goals.new") { [weak self] in self?.fitted ?? 150 }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func fit(_ height: CGFloat) { QuickAddSheet.fit(self, height, fitted: fitted) { fitted = $0 } }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        if model.canAdd { commands.append(.save("Add", #selector(addFromKeyboard))) }
        let close = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeFromKeyboard))
        close.wantsPriorityOverSystemBehavior = true
        commands.append(close)
        return commands
    }
    override var canBecomeFirstResponder: Bool { true }
    @objc private func addFromKeyboard() { model.add() }
    @objc private func closeFromKeyboard() { if !model.saving { dismiss(animated: true) } }
}

struct NewGoalView: View {
    @Bindable var model: NewGoalModel
    var onHeight: (CGFloat) -> Void = { _ in }
    @FocusState private var focus: Field?
    enum Field: Hashable { case title, why }

    var body: some View {
        let read = model.read
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("New goal", text: $model.title, axis: .vertical)
                    .lineLimit(1...3)
                    .font(Font.hq(.body).weight(.medium))
                    .focused($focus, equals: .title)
                    .submitLabel(.next)
                    // Return goes on to the why (a pasted line break stays out of the name).
                    .onChange(of: model.title) { _, text in
                        guard text.contains("\n") else { return }
                        model.title = text.replacingOccurrences(of: "\n", with: " ")
                        focus = .why
                    }
                    .accessibilityIdentifier("goals.new.title")
                if DeviceWord.isMac {
                    Button { model.controller?.dismiss(animated: true) } label: {
                        Image(systemName: "xmark").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.saving)
                    .hqIconLabel("Close")
                    .accessibilityIdentifier("sheet.close")
                }
            }
            .padding(.top, 16)
            // What the line was read as, while it differs from what you typed.
            if model.dueNow != nil, !manualOnly, read.title != model.title.trimmingCharacters(in: .whitespaces), !read.title.isEmpty {
                Text("“\(read.title)”")
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1)
                    .padding(.top, 3)
                    .accessibilityLabel("Will be named \(read.title)")
                    .accessibilityIdentifier("goals.new.read")
            }
            TextField("Why it matters", text: $model.why, axis: .vertical)
                .lineLimit(1...3)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel)
                .focused($focus, equals: .why)
                .accessibilityIdentifier("goals.new.why")
                .padding(.top, 8)
            if let failure = model.failure {
                Text(failure).font(Font.hq(.footnote)).foregroundStyle(Color.hqRed)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    .accessibilityIdentifier("goals.new.failure")
            }
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        dateChip
                        numberChip
                        if model.offersPlan { planChip }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                QuickAddButton(enabled: model.canAdd, saving: model.saving, identifier: "goals.new.add") { model.add() }
            }
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { focus = .title }
    }

    private var manualOnly: Bool { model.manualDue }

    private var dateChip: some View {
        let now = Date()
        let words = model.dueNow.map { "By " + TodoWords.monthDay($0, now: now) }
        return Menu {
            Button("In a Month") { model.setDue(Calendar.current.date(byAdding: .month, value: 1, to: now)) }
            Button("In 3 Months") { model.setDue(Calendar.current.date(byAdding: .month, value: 3, to: now)) }
            Button("End of the Year") {
                let year = Calendar.current.component(.year, from: now)
                model.setDue(Calendar.current.date(from: DateComponents(year: year, month: 12, day: 31)))
            }
            Button("Choose Date…") { model.pickDate() }
            if model.dueNow != nil { Button("No Date", role: .destructive) { model.setDue(nil) } }
        } label: {
            QuickAddChip(words: words ?? "Date", symbol: "calendar", set: model.dueNow != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(words.map { "\($0). Change" } ?? "Date")
        .accessibilityIdentifier("goals.new.due")
    }

    /// [goals step 3] "Plan With Hermes": your bots and No One, off by default.
    private var planChip: some View {
        let name = model.planWith.flatMap { id in model.bots.first { $0.id == id }?.name }
        return Menu {
            Picker("Plan With", selection: Binding(get: { model.planWith ?? "" }, set: { model.setPlanWith($0.isEmpty ? nil : $0) })) {
                Text("No One").tag("")
                ForEach(model.bots, id: \.id) { bot in Text(bot.name).tag(bot.id) }
            }
        } label: {
            HStack(spacing: 5) {
                if let id = model.planWith {
                    HeadImage(raw: model.bots.first { $0.id == id }?.head, profile: id, size: 16).frame(width: 16, height: 16).accessibilityHidden(true)
                } else {
                    Image(systemName: "sparkles").imageScale(.small).foregroundStyle(Color.hqLabel2).accessibilityHidden(true)
                }
                Text(name.map { "Plan With \($0)" } ?? "Plan With a Bot").lineLimit(1)
            }
            .font(Font.hq(.footnote).weight(name != nil && !DeviceWord.isMac ? .semibold : .regular))
            .foregroundStyle(name != nil ? Color.hqTintText : Color.hqLabel2)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Capsule().fill(name != nil ? Color.hqTint.opacity(0.12) : Color.hqFill3))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name.map { "Plan With \($0). Change" } ?? "Plan With a Bot")
        .accessibilityHint("The bot leads the goal and offers a plan in its chat")
        .accessibilityIdentifier("goals.new.plan")
    }

    @ViewBuilder private var numberChip: some View {
        if let measure = model.measure {
            let words = GoalViews.number(measure.start, unit: measure.unit) + " → " + GoalViews.number(measure.target, unit: measure.unit)
                + (measure.unit.isEmpty || measure.unit == "$" ? "" : " " + measure.unit)
            Menu {
                Button("Edit Number…") { model.editNumber() }
                Button("No Number", role: .destructive) { model.clearNumber() }
            } label: {
                QuickAddChip(words: words, symbol: "flag", set: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Number: \(words.replacingOccurrences(of: "→", with: "to")). Change")
            .accessibilityIdentifier("goals.new.number")
        } else {
            Button { model.editNumber() } label: {
                QuickAddChip(words: "Number", symbol: "flag", set: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Number")
            .accessibilityIdentifier("goals.new.number")
        }
    }
}
