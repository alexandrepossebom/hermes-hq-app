// [goals] A goal's small sheets (docs/goals.md): Update (one number field: where the number stands now), the number
// itself (unit, from, to; + Number, Edit Number…, New Goal's Number), and Edit Goal… (name, colour, Pause Goal /
// Delete Goal…; each change saves as you make it, as Edit List's do).

import SwiftUI
import UIKit

// MARK: - Update

@MainActor @Observable
final class GoalUpdateModel {
    let measure: GoalMeasure
    var text: String
    init(measure: GoalMeasure) {
        self.measure = measure
        text = GoalNumberText.edit(measure.now)
    }
    var value: Double? { GoalNumberText.read(text) }
}

/// [goals] Step 2 ("Loose ends"): Update is a small sheet over the keyboard, as tall as its content, in the quick
/// add's shape (`QuickAddSheet`, as New Task and New Goal): one number field with its unit, what it was, and a round
/// Update at the end of the line. Return (or the button) saves and closes; a tap outside closes it.
enum GoalUpdateSheet {
    static func make(goal: Goal, save: @escaping (Double) -> Void) -> UIViewController {
        let model = GoalUpdateModel(measure: goal.measure ?? GoalMeasure(unit: "", start: 0, target: 0, now: 0, at: nil, source: "you", history: []))
        return GoalUpdateHost(model: model, save: save)
    }
}

final class GoalUpdateHost: UIHostingController<HQScaledRoot<GoalUpdateView>> {
    let model: GoalUpdateModel
    private let save: (Double) -> Void
    private var fitted: CGFloat = 120

    init(model: GoalUpdateModel, save: @escaping (Double) -> Void) {
        self.model = model
        self.save = save
        super.init(rootView: HQScaledRoot(GoalUpdateView(model: model)))
        rootView = HQScaledRoot(GoalUpdateView(model: model, onHeight: { [weak self] in self?.fit($0) },
                                               commit: { [weak self] in self?.commit() },
                                               close: { [weak self] in self?.dismiss(animated: true) }))
        QuickAddSheet.configure(self, identifier: "goal.update") { [weak self] in self?.fitted ?? 120 }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func fit(_ height: CGFloat) { QuickAddSheet.fit(self, height, fitted: fitted) { fitted = $0 } }

    /// The number saves and the sheet closes; a number that doesn't read says so with the error cue.
    func commit() {
        guard let value = model.value else { PagesHaptics.error(); return }
        PagesHaptics.success()
        save(value)
        dismiss(animated: true)
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        if model.value != nil { commands.append(.save("Update", #selector(commitFromKeyboard))) }
        let close = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeFromKeyboard))
        close.wantsPriorityOverSystemBehavior = true
        commands.append(close)
        return commands
    }
    override var canBecomeFirstResponder: Bool { true }
    @objc private func commitFromKeyboard() { commit() }
    @objc private func closeFromKeyboard() { dismiss(animated: true) }
}

struct GoalUpdateView: View {
    @Bindable var model: GoalUpdateModel
    var onHeight: (CGFloat) -> Void = { _ in }
    var commit: () -> Void = {}
    var close: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Update")
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .foregroundStyle(Color.hqLabel2)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if DeviceWord.isMac {
                    Button(action: close) {
                        Image(systemName: "xmark").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hqIconLabel("Close")
                    .accessibilityIdentifier("sheet.close")
                }
            }
            .padding(.top, 16)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if model.measure.unit == "$" { Text("$").font(Font.hq(.title2).weight(.semibold)).foregroundStyle(Color.hqLabel2) }
                TextField("Now", text: $model.text)
                    .keyboardType(.decimalPad)
                    .font(Font.hq(.title2).weight(.semibold))
                    .monospacedDigit()
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(commit)
                    .accessibilityLabel("Where it stands now")
                    .accessibilityIdentifier("goal.update.field")
                if !model.measure.unit.isEmpty, model.measure.unit != "$" {
                    Text(model.measure.unit).font(Font.hq(.body)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                }
                QuickAddButton(enabled: model.value != nil, saving: false, identifier: "goal.update.save", label: "Update", action: commit)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(.title2).capHeight / 2 }
            }
            .padding(.top, 6)
            Text(wasLine)
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqLabel2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .padding(.bottom, 14)
                .accessibilityIdentifier("goal.update.was")
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
    }

    /// "Was 340 of 1,000 testers, Nov 16."
    private var wasLine: String {
        "Was \(GoalViews.measureWords(model.measure, unit: true))\(model.measure.at.flatMap(TodoDates.moment).map { ", " + TodoWords.monthDay($0, now: Date()) } ?? "")."
    }
}

/// Numbers as typed: "1,000", "12.5", "$40" all read; shown back without a trailing ".0".
enum GoalNumberText {
    static func read(_ text: String) -> Double? {
        let clean = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(clean)
    }

    static func edit(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}

// MARK: - The number (unit, from, to)

@MainActor @Observable
final class GoalNumberModel {
    var unit: String
    var start: String
    var target: String
    var now: String
    let editing: Bool
    init(measure: GoalMeasure?) {
        editing = measure != nil
        unit = measure?.unit ?? ""
        start = measure.map { GoalNumberText.edit($0.start) } ?? "0"
        target = measure.map { GoalNumberText.edit($0.target) } ?? ""
        now = measure.map { GoalNumberText.edit($0.now) } ?? ""
    }

    var measure: GoalMeasure? {
        guard let from = GoalNumberText.read(start), let to = GoalNumberText.read(target), from != to else { return nil }
        let at = GoalNumberText.read(now) ?? from
        return GoalMeasure(unit: String(unit.trimmingCharacters(in: .whitespaces).prefix(20)), start: from, target: to, now: at,
                           at: nil, source: "you", history: [])
    }
}

enum GoalNumberSheet {
    static func make(measure: GoalMeasure?, title: String, save: @escaping (GoalMeasure) -> Void) -> UINavigationController {
        let model = GoalNumberModel(measure: measure)
        let host = UIHostingController(rootView: HQScaledRoot(GoalNumberView(model: model)))
        // Full height: it opens with the keys up, and at half height they covered To and Now (step 2's UI test).
        let nav = ChatSheet.wrap(host, title: title, detents: [.large()])
        let item = UIBarButtonItem(title: "Done", primaryAction: UIAction { [weak host] _ in
            guard let measure = model.measure else { PagesHaptics.error(); return }
            PagesHaptics.success()
            save(measure)
            host?.dismiss(animated: true)
        })
        item.style = .prominent
        item.accessibilityIdentifier = "goal.number.save"
        host.navigationItem.rightBarButtonItem = item
        host.view.accessibilityIdentifier = "goal.number.sheet"
        return nav
    }
}

struct GoalNumberView: View {
    @Bindable var model: GoalNumberModel
    @FocusState private var focus: Field?
    enum Field: Hashable { case unit, start, target, now }

    var body: some View {
        Form {
            Section {
                field("Unit", text: $model.unit, prompt: "testers, lbs, $", field: .unit, id: "goal.number.unit", numeric: false)
                field("From", text: $model.start, prompt: "0", field: .start, id: "goal.number.start", numeric: true)
                field("To", text: $model.target, prompt: "1,000", field: .target, id: "goal.number.target", numeric: true)
                if model.editing {
                    field("Now", text: $model.now, prompt: model.start, field: .now, id: "goal.number.now", numeric: true)
                }
            } footer: {
                HQSectionFooter {
                    Text("The ring follows this number: how far it has come from where it started. A target under the start counts down (a weight to lose).")
                }
            }
            .hqSheetRows()
        }
        .hqGroupedPage()
        .onAppear { focus = model.editing ? .now : .unit }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, field: Field, id: String, numeric: Bool) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(Color.hqLabel)
            TextField(label, text: text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .keyboardType(numeric ? .decimalPad : .default)
                .textInputAutocapitalization(.never)
                .monospacedDigit()
                .focused($focus, equals: field)
                .accessibilityIdentifier(id)
        }
    }
}

// MARK: - Edit Goal

@MainActor @Observable
final class GoalEditModel {
    let store: TasksStore
    let goalID: String
    var name: String
    @ObservationIgnored var onDelete: (() -> Void)?
    /// [goals step 3] Your bots (id, name, face), for Led By, Helpers and Number From.
    let bots: [(id: String, name: String, head: JSONValue?)]
    @ObservationIgnored weak var controller: UIViewController?

    /// [goals step 6] The lead when Edit Goal opened: a first lead on a goal with no plan is asked for one when it closes.
    @ObservationIgnored let leadAtOpen: String?

    init(store: TasksStore, goalID: String, bots: [Bot] = MorePages.context?.bots ?? []) {
        self.store = store
        self.goalID = goalID
        name = store.goal(goalID)?.title ?? ""
        leadAtOpen = store.goal(goalID)?.lead
        self.bots = bots.map { ($0.id, PagesNames.botName($0.id, bots: bots), $0.head) }
    }

    /// [goals step 6] The Bots row: the team sheet over Edit Goal (Edit Goal's own close asks a new lead for a plan).
    func openTeam() {
        guard let controller else { return }
        GoalTeamSheet.present(goalID: goalID, store: store, from: controller, asksOnClose: false)
    }

    /// [goals step 6] Edit Goal closed: a goal that just got its first lead and has no plan reopens on its chat, and the
    /// lead is asked for a plan (as New Goal with a lead does).
    func closed() {
        commitName()
        GoalPlanAsks.sheetClosed(goalID: goalID, before: leadAtOpen, store: store)
    }

    func botName(_ id: String?) -> String {
        guard let id else { return "No One" }
        return bots.first { $0.id == id }?.name ?? PagesNames.botName(id, bots: [])
    }

    // MARK: [goals step 3] The goal's bots (GoalTeamRows)

    func setReview(_ review: GoalReview?) {
        PagesHaptics.selection()
        patch(["review": review?.json ?? .null])
    }

    func setAdds(_ auto: Bool) {
        PagesHaptics.selection()
        patch(["adds": .string(auto ? "auto" : "ask")])
    }

    func setKnownToAll(_ on: Bool) {
        PagesHaptics.selection()
        patch(["known_to_all": .bool(on)])
    }

    /// Number From: you, or a bot and what it reads (asked by name: "TestFlight").
    func setSource(_ bot: String?) {
        guard let bot else {
            PagesHaptics.selection()
            patch(["measure": .object(["source": GoalSource.you.json])])
            return
        }
        guard let controller else { return }
        let alert = UIAlertController(title: "Where Does \(botName(bot)) Read It?",
                                      message: "Name the place it checks, like TestFlight or your bank. It never guesses: if it can’t check, it asks you.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "TestFlight"
            field.text = self.goal?.measure?.source.what
            field.autocapitalizationType = .words
            field.accessibilityIdentifier = "goal.edit.source.what"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Set", style: .default) { [weak self, weak alert] _ in
            let what = String((alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            PagesHaptics.selection()
            self?.patch(["measure": .object(["source": GoalSource.bot(bot, what: what).json])])
        })
        controller.present(alert, animated: true)
    }

    var goal: Goal? { store.goal(goalID) }

    func commitName() {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard let goal else { return }
        guard !clean.isEmpty else { name = goal.title; return }
        name = clean
        guard clean != goal.title else { return }
        patch(["title": .string(clean)])
    }

    func setColor(_ color: TodoListColor) {
        guard color != goal?.tint else { return }
        patch(["color": .string(color.rawValue)])
    }

    func togglePause() {
        guard let goal else { return }
        GoalMenu.setStatus(goal.state == .paused ? .active : .paused, goalID: goalID, store: store)
    }

    private func patch(_ fields: [String: JSONValue]) {
        Task { if await !store.patchGoal(goalID, fields) { PagesHaptics.error() } }
    }
}

enum GoalEditSheet {
    static func make(goalID: String, store: TasksStore, onDelete: @escaping () -> Void) -> UIViewController {
        let model = GoalEditModel(store: store, goalID: goalID)
        model.onDelete = onDelete
        let host = GoalEditHost(model: model)
        model.controller = host
        host.view.accessibilityIdentifier = "goal.edit.sheet"
        let nav = ChatSheet.wrap(host, title: "Edit Goal")
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        return nav
    }
}

/// [goals step 6] Edit Goal's page: on its close, a new first lead is asked for a plan (`GoalEditModel.closed`).
final class GoalEditHost: UIHostingController<HQScaledRoot<GoalEditView>> {
    let model: GoalEditModel
    private var didClose = false

    init(model: GoalEditModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(GoalEditView(model: model)))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !didClose, isBeingDismissed || navigationController?.isBeingDismissed == true
                || (navigationController ?? self).presentingViewController == nil else { return }
        didClose = true
        model.closed()
    }
}

struct GoalEditView: View {
    @Bindable var model: GoalEditModel
    @FocusState private var naming: Bool

    var body: some View {
        let goal = model.goal
        Form {
            Section {
                HStack(spacing: 10) {
                    GoalMark(color: goal?.tint ?? .blue).font(Font.hq(.body)).frame(width: 24)
                    TextField("Goal", text: $model.name)
                        .focused($naming)
                        .submitLabel(.done)
                        .onSubmit { model.commitName() }
                        .onChange(of: naming) { _, focused in if !focused { model.commitName() } }
                        .accessibilityIdentifier("goal.edit.name")
                }
            }
            .hqSheetRows()

            Section {
                TaskColorSwatches(picked: goal?.tint, identifier: "goal.edit.color", clears: false) { choice in
                    if let choice { model.setColor(choice) }
                }
            } header: { HQSectionLabel { Text("Colour") } } footer: { HQSectionFooter {
                Text("The ring, the bar and the goal’s mark take this colour.")
            } }
            .hqSheetRows()

            if let goal, model.store.goalBotsSupported, !model.bots.isEmpty {
                GoalTeamRows(model: model, goal: goal)
            }

            if let goal, goal.state == .active || goal.state == .paused {
                Section {
                    Button { model.togglePause() } label: {
                        Label(goal.state == .paused ? "Resume Goal" : "Pause Goal",
                              systemImage: goal.state == .paused ? "play.circle" : "pause.circle")
                            .foregroundStyle(Color.hqTintText)
                    }
                    .accessibilityIdentifier("goal.edit.pause")
                } footer: { HQSectionFooter {
                    Text(goal.state == .paused ? "It goes back under your active goals."
                                               : "A paused goal waits under Someday, and its tasks stay out of Today’s next tasks.")
                } }
                .hqSheetRows()
            }

            Section {
                Button(role: .destructive) { PagesHaptics.selection(); model.onDelete?() } label: {
                    Label("Delete Goal…", systemImage: "trash").foregroundStyle(Color.hqRed)
                }
                .accessibilityIdentifier("goal.edit.delete")
            }
            .hqSheetRows()
        }
        .hqGroupedPage()
        .onDisappear { model.commitName() }
    }
}

/// [goals step 3] Edit Goal's bots (board 5's left phone), only with the add-on's `goal_bots`: [goals step 6] one Bots row
/// (the team sheet, in place of Led By and Helpers), Check-in; New Tasks, Number From; Tell My Other Bots. Each change
/// saves as you make it.
struct GoalTeamRows: View {
    @Bindable var model: GoalEditModel
    var goal: Goal

    var body: some View {
        Section {
            let who = GoalBots.whoLine(goal, botName: model.botName) ?? GoalBots.justMe
            Button { model.openTeam() } label: {
                HStack(spacing: 8) {
                    Text("Bots").foregroundStyle(Color.hqLabel)
                    Spacer(minLength: 8)
                    ForEach(goal.team.prefix(3), id: \.self) { face in
                        HeadImage(raw: model.bots.first { $0.id == face }?.head, profile: face, size: 20).frame(width: 20, height: 20).accessibilityHidden(true)
                    }
                    Text(goal.team.isEmpty ? "Add Bots" : who)
                        .foregroundStyle(goal.team.isEmpty ? Color.hqTintText : Color.hqLabel2).lineLimit(1)
                    Image(systemName: "chevron.right").font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqLabel3).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bots, " + (GoalBots.whoSpoken(goal, botName: model.botName) ?? GoalBots.justMe))
            .accessibilityHint("Picks the bots on this goal and which one leads")
            .accessibilityIdentifier("goal.edit.bots")
            if goal.lead != nil {
                Menu {
                    Button("Off") { model.setReview(nil) }
                    ForEach(Array(GoalBots.weekdays.enumerated()), id: \.offset) { day, name in
                        Menu(name + "s") {
                            ForEach(GoalBots.reviewTimes, id: \.self) { time in
                                Button(GoalBots.time(time)) { model.setReview(GoalReview(day: day, time: time)) }
                            }
                        }
                    }
                } label: {
                    row("Check-in", value: GoalBots.reviewWords(goal.review), face: nil)
                }
                .accessibilityLabel("Check-in, \(GoalBots.reviewWords(goal.review))")
                .accessibilityIdentifier("goal.edit.review")
            }
        } footer: { HQSectionFooter {
            Text("The lead plans, checks in and keeps the goal’s page. Helpers take tasks.")
        } }
        .hqSheetRows()

        Section {
            Menu {
                Picker("New Tasks", selection: Binding(get: { goal.adds == "auto" }, set: { model.setAdds($0) })) {
                    Text("Ask First").tag(false)
                    Text("Add Without Asking").tag(true)
                }
            } label: {
                row("New Tasks", value: goal.adds == "auto" ? "Add Without Asking" : "Ask First", face: nil)
            }
            .accessibilityLabel("New Tasks, \(goal.adds == "auto" ? "Add Without Asking" : "Ask First")")
            .accessibilityIdentifier("goal.edit.adds")
            if let measure = goal.measure {
                Menu {
                    Button("You") { model.setSource(nil) }
                    ForEach(model.bots.filter { goal.team.contains($0.id) }, id: \.id) { bot in
                        Button(bot.name + "…") { model.setSource(bot.id) }
                    }
                } label: {
                    row("Number From", value: GoalBots.numberFromWords(measure, botName: model.botName), face: nil)
                }
                .accessibilityLabel("Number From, \(GoalBots.numberFromWords(measure, botName: model.botName))")
                .accessibilityIdentifier("goal.edit.source")
            }
            Toggle(isOn: Binding(get: { goal.knownToAll }, set: { model.setKnownToAll($0) })) {
                Text("Tell My Other Bots")
            }
            .accessibilityIdentifier("goal.edit.known")
        } footer: { HQSectionFooter {
            Text("Other bots know this goal’s name and why, so they can point things to it.")
        } }
        .hqSheetRows()
    }

    private func row(_ label: String, value: String, face: String?) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(Color.hqLabel)
            Spacer(minLength: 8)
            if let face {
                HeadImage(raw: model.bots.first { $0.id == face }?.head, profile: face, size: 20).frame(width: 20, height: 20).accessibilityHidden(true)
            }
            Text(value).foregroundStyle(Color.hqLabel2).lineLimit(1)
            Image(systemName: "chevron.right").font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqLabel3).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}
