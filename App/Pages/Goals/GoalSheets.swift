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

enum GoalUpdateSheet {
    static func make(goal: Goal, save: @escaping (Double) -> Void) -> UINavigationController {
        let model = GoalUpdateModel(measure: goal.measure ?? GoalMeasure(unit: "", start: 0, target: 0, now: 0, at: nil, source: "you", history: []))
        let host = UIHostingController(rootView: HQScaledRoot(GoalUpdateView(model: model)))
        let nav = ChatSheet.wrap(host, title: "Update", detents: [.medium()])
        let item = UIBarButtonItem(title: "Update", primaryAction: UIAction { [weak host] _ in
            guard let value = model.value else { PagesHaptics.error(); return }
            PagesHaptics.success()
            save(value)
            host?.dismiss(animated: true)
        })
        item.style = .prominent
        item.accessibilityIdentifier = "goal.update.save"
        host.navigationItem.rightBarButtonItem = item
        host.view.accessibilityIdentifier = "goal.update.sheet"
        return nav
    }
}

struct GoalUpdateView: View {
    @Bindable var model: GoalUpdateModel
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    if model.measure.unit == "$" { Text("$").foregroundStyle(Color.hqLabel2) }
                    TextField("Now", text: $model.text)
                        .keyboardType(.decimalPad)
                        .font(Font.hq(.title2).weight(.semibold))
                        .monospacedDigit()
                        .focused($focused)
                        .accessibilityLabel("Where it stands now")
                        .accessibilityIdentifier("goal.update.field")
                    if !model.measure.unit.isEmpty, model.measure.unit != "$" {
                        Text(model.measure.unit).foregroundStyle(Color.hqLabel2).lineLimit(1)
                    }
                }
            } footer: {
                HQSectionFooter {
                    Text("Was \(GoalViews.measureWords(model.measure, unit: true))\(model.measure.at.flatMap(TodoDates.moment).map { ", " + TodoWords.monthDay($0, now: Date()) } ?? "").")
                }
            }
            .hqSheetRows()
        }
        .hqGroupedPage()
        .onAppear { focused = true }
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
        let nav = ChatSheet.wrap(host, title: title, detents: [.medium(), .large()])
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

    init(store: TasksStore, goalID: String) {
        self.store = store
        self.goalID = goalID
        name = store.goal(goalID)?.title ?? ""
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
        let host = UIHostingController(rootView: HQScaledRoot(GoalEditView(model: model)))
        host.view.accessibilityIdentifier = "goal.edit.sheet"
        let nav = ChatSheet.wrap(host, title: "Edit Goal")
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        return nav
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
