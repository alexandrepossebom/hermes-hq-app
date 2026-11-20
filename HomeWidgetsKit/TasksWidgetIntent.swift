// [tasks-widget] The Tasks widget's one setting, Show (the views the page's own pills offer: Today, Upcoming, Inbox,
// each of your lists, Bots once a bot has a task of its own), and the check circle's intent. Built into the app and the
// extension (project.yml): the app reads a placed widget's choice, and the check-off runs in the app.

import AppIntents
import Foundation

nonisolated struct TasksViewEntity: AppEntity, Sendable, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "View"
    static let defaultQuery = TasksViewEntityQuery()

    /// `TodoView.key`.
    var id: String
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

nonisolated struct TasksViewEntityQuery: EntityQuery, Sendable {
    init() {}

    private static func choices() -> [TasksWidgetIndex.Choice] {
        guard let index = TasksWidgetStore.loadIndex(), index.state == .live else { return [] }
        return index.views
    }

    func entities(for identifiers: [String]) async throws -> [TasksViewEntity] {
        let choices = Self.choices()
        return identifiers.compactMap { id in choices.first { $0.id == id }.map { TasksViewEntity(id: $0.id, name: $0.name) } }
    }

    func suggestedEntities() async throws -> [TasksViewEntity] {
        Self.choices().map { TasksViewEntity(id: $0.id, name: $0.name) }
    }
    /// Today, as the page opens on Today (and the widget shows it with nothing chosen), so Show names it.
    func defaultResult() async -> TasksViewEntity? {
        Self.choices().first { $0.id == TasksWidgetIndex.defaultView }.map { TasksViewEntity(id: $0.id, name: $0.name) }
    }
}

/// Not `nonisolated` (an `@Parameter` refuses it).
struct TasksWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Tasks"
    static let description = IntentDescription("Choose what this widget shows. With nothing chosen it shows Today.")

    @Parameter(title: "Show")
    var view: TasksViewEntity?

    init() {}

    init(view: TasksViewEntity?) { self.view = view }
}

// MARK: - Ticking a task off from the widget

#if !targetEnvironment(macCatalyst)   // no Home Screen widgets on the Mac

/// What the check circle asks of the app. The app sets `checkOff` at launch (App/Widgets/TasksWidgetWriter.swift); the
/// extension never runs it. Returns whether the gateway took it.
@MainActor enum TasksWidgetActions {
    static var checkOff: ((_ task: String, _ account: String) async -> Bool)?
}

/// The check circle on a task's row. A `LiveActivityIntent`, so iOS performs it in the app's process (launched in the
/// background when it isn't running), never in the widget extension: the extension must not reach the gateway (a Sign
/// in with Nous account's refresh token rotates on every use).
struct TaskCheckOffIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark Task Done"
    static let isDiscoverable = false

    @Parameter(title: "Task")
    var task: String

    @Parameter(title: "Account")
    var account: String

    init() {}

    init(task: String, account: String) {
        self.task = task
        self.account = account
    }

    @MainActor func perform() async throws -> some IntentResult {
        _ = await TasksWidgetActions.checkOff?(task, account)
        return .result()
    }
}
#endif
