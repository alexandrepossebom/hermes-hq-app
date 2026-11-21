// [shortcuts] "Add Task" and "Run Job" for Shortcuts and Siri (owner 2026-11-20 picked both from the shortcut ideas).
// Both run without opening Hermes HQ, as Ask Bot does: the system may run them with no window and no `AppModel`, so
// they reach the gateway the way the Share extension does (`ShareSender.rest`: the Keychain's sign-in, its own
// throwaway session), for the account the Bots list was last saved for (`AskRoster`).
//
//   Add Task  POST <hermes-hq-push>/tasks with the New Task sheet's body (`TodoWire.newTask`): your own task, or one
//             a bot does (alone, or with you). Returns the task's title.
//   Run Job   POST /api/cron/jobs/<id>/trigger?profile=<owner> (Run Now's call, `CronRunOnce`); a paused job is paused
//             again afterwards. With Wait for Result on, the newest run's words (`/runs`) go to the next step.

import AppIntents
import Foundation

// MARK: - Add Task

nonisolated enum ShortcutTaskWho: String, AppEnum {
    case together, bot

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Who Does It")
    static let caseDisplayRepresentations: [ShortcutTaskWho: DisplayRepresentation] = [
        .together: "You and the Bot",
        .bot: "The Bot",
    ]
    var wire: TodoWho { self == .bot ? .bot : .together }
}

struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let description: IntentDescription? = IntentDescription(
        "Add a task to your Tasks list without opening Hermes HQ. Pick a bot to have it help, or leave Bot empty for a task of your own.",
        categoryName: "Tasks")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Title") var taskTitle: String
    @Parameter(title: "Bot") var bot: VoiceNoteBot?
    @Parameter(title: "Who Does It", default: .together) var who: ShortcutTaskWho
    @Parameter(title: "Due") var due: Date?
    @Parameter(title: "Due Time Matters", default: false) var dueHasTime: Bool
    @Parameter(title: "Notes", inputOptions: String.IntentInputOptions(multiline: true)) var notes: String?

    static var parameterSummary: some ParameterSummary {
        When(\.$bot, .hasAnyValue) {
            Summary("Add task \(\.$taskTitle) for \(\.$bot)") {
                \.$who
                \.$due
                \.$dueHasTime
                \.$notes
            }
        } otherwise: {
            Summary("Add task \(\.$taskTitle)") {
                \.$bot
                \.$due
                \.$dueHasTime
                \.$notes
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let title = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AskBotError.message("Give the task a title.") }
        var profile: String?
        if let bot {
            guard let record = VoiceBotCatalog.resolve(id: bot.id), let id = VoiceBotCatalog.profile(key: record.key) else {
                throw VoiceNoteError.unavailableBot
            }
            profile = id
        }
        let body = ShortcutTaskBody.make(title: title, bot: profile, who: who.wire, due: due, hasTime: dueHasTime, notes: notes ?? "")
        let answer = try await ShortcutGateway.send("POST", TasksAPI.base, json: body, what: "the task")
        let made = (try? TasksAPI.task(answer.data))?.title ?? title
        AppLog.note("intents", "Add Task shortcut: added\(profile == nil ? "" : " for a bot")")
        return .result(value: made, dialog: IntentDialog(stringLiteral: "Added “\(made)” to Tasks."))
    }
}

/// The New Task sheet's body for a shortcut's task (pure: the tests read it).
nonisolated enum ShortcutTaskBody {
    static func make(title: String, bot: String?, who: TodoWho, due: Date?, hasTime: Bool, notes: String,
                     calendar: Calendar = .current) -> Data {
        let fields = TodoWire.newTask(title: title, who: bot == nil ? .me : who, bot: bot,
                                      due: due.map { TodoDates.wire($0, hasTime: hasTime, calendar: calendar) }, repeatRule: nil, prep: false,
                                      notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), source: TodoSource(kind: "app"))
        return (try? JSONValue.object(fields).encoded()) ?? Data()
    }
}

// MARK: - Run Job

nonisolated struct ShortcutJob: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Job")
    static let defaultQuery = ShortcutJobQuery()
    /// `<owner>|<id>`.
    let id: String
    let name: String
    let owner: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ record: JobShortcutRecord) {
        id = record.key
        name = record.name
        owner = record.owner
    }
}

nonisolated struct ShortcutJobQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ShortcutJob] {
        let all = JobShortcutCatalog.jobs()
        return identifiers.compactMap { id in all.first { $0.key == id }.map(ShortcutJob.init) }
    }

    func suggestedEntities() async throws -> [ShortcutJob] { JobShortcutCatalog.jobs().map(ShortcutJob.init) }

    func entities(matching string: String) async throws -> [ShortcutJob] {
        JobShortcutCatalog.jobs().filter { $0.name.localizedCaseInsensitiveContains(string) }.map(ShortcutJob.init)
    }
}

struct RunJobIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Job"
    static let description: IntentDescription? = IntentDescription(
        "Run one of your jobs now, without opening Hermes HQ. Its schedule doesn’t change. Turn on Wait for Result to get what the run wrote for the next action.",
        categoryName: "Jobs")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Job") var job: ShortcutJob
    @Parameter(title: "Wait for Result", default: true) var waitForResult: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$job)") { \.$waitForResult }
    }

    /// How long Run Now waits for a run (the app's Run Now waits 120 s; a shortcut gets a little less).
    static let runWait: TimeInterval = 110

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let record = JobShortcutCatalog.jobs().first(where: { $0.key == job.id }) else {
            throw AskBotError.message("That job isn’t in Hermes HQ any more. Open Jobs so the list updates, then pick it again.")
        }
        let path = CronRunOnce.jobPath(record.id)
        let owner = [URLQueryItem(name: "profile", value: record.owner)]
        let before = try await ShortcutGateway.send("GET", path, query: owner, what: "the job")
        guard let state = try? JSONValue.parse(before.data) else { throw AskBotError.message("Your gateway answered in a way Hermes HQ doesn’t understand.") }
        let paused = state["enabled"]?.bool == false || state["state"]?.string == "paused"
        let started = Date().timeIntervalSince1970
        let trigger = await Result.of {
            try await ShortcutGateway.send("POST", path + "/trigger", query: owner, what: "the job",
                                           timeout: waitForResult ? Self.runWait : 15)
        }
        // Run Now's rule: a paused job runs once and stays paused.
        if paused { _ = try? await ShortcutGateway.send("POST", path + "/pause", query: owner, what: "the job") }
        switch trigger {
        case .success:
            break
        case .failure(let error):
            if case ShareFailure.timedOut = error, waitForResult {
                AppLog.note("intents", "Run Job shortcut: still running")
                return .result(value: "", dialog: IntentDialog(stringLiteral: "“\(record.name)” is still running. Its result will be in Jobs."))
            }
            if !waitForResult, case ShareFailure.timedOut = error {
                return .result(value: "", dialog: IntentDialog(stringLiteral: "Started “\(record.name)”."))
            }
            throw error
        }
        AppLog.note("intents", "Run Job shortcut: ran")
        guard waitForResult else { return .result(value: "", dialog: IntentDialog(stringLiteral: "Started “\(record.name)”.")) }
        let runs = try? await ShortcutGateway.send("GET", path + "/runs", query: owner + [URLQueryItem(name: "limit", value: "5")], what: "the job")
        let list = runs.flatMap { try? JSONValue.parse($0.data) }.map(CronRun.list) ?? []
        let text = JobShortcutCatalog.resultText(runs: list, startedAfter: started, job: record.name)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - The gateway, with no app

nonisolated enum ShortcutGateway {
    /// One request as a share makes it; a refusal is worded for a shortcut (the gateway's own reason when it gave one).
    static func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Data? = nil, what: String,
                     timeout: TimeInterval = 30) async throws -> ShareRESTAnswer {
        let roster = AskRoster.read()
        let outcome = await Result.of {
            try await ShareSender().rest(method, path, query: query, json: json, roster: roster, timeout: timeout)
        }
        let answer: ShareRESTAnswer
        switch outcome {
        case .success(let got): answer = got
        case .failure(let failure as ShareFailure):
            if case .timedOut = failure { throw failure }
            throw AskBotError.words(failure, bot: "")
        case .failure(let error): throw error
        }
        guard answer.ok else { throw AskBotError.message(refusal(answer, what: what)) }
        return answer
    }

    /// The gateway's `detail`, else a sentence for the status (pure: the tests read it).
    static func refusal(_ answer: ShareRESTAnswer, what: String) -> String {
        if answer.status == 404 { return "Your gateway doesn’t have \(what). Update the Hermes HQ add-on, or open Hermes HQ to check." }
        if let value = try? JSONValue.parse(answer.data) {
            if let text = value["detail"]?.string, !text.isEmpty { return text }
            if let text = value["detail"]?["message"]?.string, !text.isEmpty { return text }
            if let text = value["error"]?.string, !text.isEmpty { return text }
        }
        if answer.status == 409 { return "That’s already running." }
        return "Your gateway didn’t accept \(what) (\(answer.status))."
    }
}
