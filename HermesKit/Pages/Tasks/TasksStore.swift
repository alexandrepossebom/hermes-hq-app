// [tasks] The Tasks page's data (docs/tasks.md): the list painted from disk at once, then read from the add-on
// (`?since=<rev>` answers `unchanged` when nothing moved); optimistic writes that carry the task's rev, re-sent on a 409
// when the other edit touched other fields, or giving way to it when it touched the same ones (TodoEdits.resolve).
// Read on appear, on foreground, after a task push and after each write.

import Foundation
import Observation

/// The add-on's routes.
nonisolated struct TasksAPI: Sendable {
    static let base = PushPolicy.route + "/tasks"
    let client: any GatewayClient

    private func path(_ id: String) -> String { Self.base + "/" + PagesREST.segment(id) }

    @concurrent
    func list(since: Int?) async throws -> TodoListAnswer {
        let query = since.map { [URLQueryItem(name: "since", value: String($0))] } ?? []
        let data = try await PagesREST.send(client, "GET", Self.base, query: query)
        return try JSONDecoder().decode(TodoListAnswer.self, from: data)
    }

    @concurrent
    func create(_ fields: [String: JSONValue]) async throws -> TodoTask {
        try Self.task(try await PagesREST.send(client, "POST", Self.base, json: .object(fields)))
    }

    /// [tasks-first] `POST /tasks/{id}/attach` (hermes-hq-push 0.9.53): your own link, or a file as base64. The
    /// answer is the task with it in `made`.
    @concurrent
    func attach(_ id: String, _ body: [String: JSONValue]) async throws -> TodoTask {
        try Self.task(try await PagesREST.send(client, "POST", path(id) + "/attach", json: .object(body), timeout: 120))
    }

    /// `DELETE /tasks/{id}/made/{made}`: takes a file, link or note off the task.
    @concurrent
    func detach(_ id: String, made: String) async throws -> TodoTask {
        try Self.task(try await PagesREST.send(client, "DELETE", path(id) + "/made/" + made))
    }

    @concurrent
    func patch(_ id: String, rev: Int, fields: [String: JSONValue]) async throws -> TodoTask {
        var body = fields
        body["rev"] = .number(Double(rev))
        return try Self.task(try await PagesREST.send(client, "PATCH", path(id), json: .object(body)))
    }

    @concurrent
    func delete(_ id: String) async throws {
        _ = try await PagesREST.send(client, "DELETE", path(id))
    }

    @concurrent
    func settings() async throws -> TodoSettings {
        try JSONDecoder().decode(TodoSettings.self, from: try await PagesREST.send(client, "GET", Self.base + "/settings"))
    }

    @concurrent
    func saveSettings(_ settings: TodoSettings) async throws -> TodoSettings {
        let body = try JSONValue.parse(JSONEncoder().encode(settings))
        let data = try await PagesREST.send(client, "PUT", Self.base + "/settings", json: body)
        return (try? JSONDecoder().decode(TodoSettings.self, from: data)) ?? settings
    }

    /// `PUT /tasks/sections`: your sections, the whole list in order (hermes-hq-push 0.9.36). One left out is deleted;
    /// its tasks stay, under no section.
    @concurrent
    func saveSections(_ sections: [TodoUserSection]) async throws -> [TodoUserSection] {
        // [task-lists] Each list whole (colour, icon, bot, rules): 0.9.55 keeps them, an older add-on reads only id
        // and name. `checked_at` is the gateway's own.
        let list = JSONValue.array(sections.map { section -> JSONValue in
            guard case .object(var object)? = try? JSONValue.parse(JSONEncoder().encode(section)) else {
                return .object(["id": .string(section.id), "name": .string(section.name)])
            }
            object["id"] = .string(TodoIDs.isLocal(section.id) ? "" : section.id)
            object["checked_at"] = nil
            return .object(object)
        })
        let data = try await PagesREST.send(client, "PUT", Self.base + "/sections", json: .object(["sections": list]))
        struct Answer: Decodable { var sections: [TodoUserSection] }
        return try JSONDecoder().decode(Answer.self, from: data).sections
    }

    /// [task-lists] `POST /tasks/offers/{id}` (hermes-hq-push 0.9.55): your tap on a bot's offer. `list` false with
    /// `accept` is "Add, No List".
    @concurrent
    func answerOffer(_ id: String, action: TodoOfferAction, list: Bool = true, goal: (plan: Bool, inGoal: Bool)? = nil) async throws -> TodoOfferAnswer {
        var fields: [String: JSONValue] = ["action": .string(action.rawValue), "list": .bool(list)]
        // [goals step 3] A goal's offer (0.9.66): "Keep the Goal, No Plan" and "Just Tasks". Sent only for one, so a
        // list offer's answer is as it was.
        if let goal { fields["plan"] = .bool(goal.plan); fields["in_goal"] = .bool(goal.inGoal) }
        let body: JSONValue = .object(fields)
        let data = try await PagesREST.send(client, "POST", Self.base + "/offers/" + PagesREST.segment(id), json: body)
        return try JSONDecoder().decode(TodoOfferAnswer.self, from: data)
    }

    /// `POST /tasks/prep-job/{profile}`: that bot's "Task prep" scheduled job made, or removed, to match its open prep
    /// tasks (hermes-hq-push 0.9.32). A failure is only logged: the bot's own task tools reconcile it again.
    @concurrent
    func reconcilePrep(_ profile: String) async {
        do { _ = try await PagesREST.send(client, "POST", Self.base + "/prep-job/" + PagesREST.segment(profile), timeout: 30) }
        catch { AppLog.note("tasks", "prep job for \(profile) not reconciled: \(PagesREST.reason(error))") }
    }

    /// [goals step 5] `/status`: whether this add-on draws Goal Pages (0.9.66's `goal_pages`); nil when it couldn't be read.
    @concurrent
    func addOnDrawsGoalPages() async -> Bool? {
        guard let data = try? await PagesREST.send(client, "GET", PushPolicy.route + "/status", timeout: 15),
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (body["goal_pages"] as? Bool) == true
    }

    /// [goals step 5] `GET /goals/{id}/page`: the goal's Goal Page (hermes-hq-push 0.9.66), HTML the add-on draws.
    @concurrent
    func goalPage(_ id: String, names: [String: String]) async throws -> Data {
        let object = JSONValue.object(names.mapValues { .string($0) })
        let names = (try? object.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return try await PagesREST.send(client, "GET", GoalsAPI.base + "/" + PagesREST.segment(id) + "/page",
                                        query: [URLQueryItem(name: "names", value: names)], timeout: 20)
    }

    /// `/status`: whether this add-on serves Tasks (0.9.32's `tasks`); nil when it couldn't be read.
    @concurrent
    func addOnServesTasks() async -> Bool? {
        guard let data = try? await PagesREST.send(client, "GET", PushPolicy.route + "/status", timeout: 15),
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return PushPolicy.tasks(body)
    }

    /// `GET /tasks/{id}/page`: the task's Task Page (hermes-hq-push 0.9.38), HTML drawn from the task and what its bot
    /// wrote on it. `names`: the bots' names as the app shows them, by profile.
    @concurrent
    func page(_ id: String, names: [String: String]) async throws -> Data {
        let object = JSONValue.object(names.mapValues { .string($0) })
        let names = (try? object.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return try await PagesREST.send(client, "GET", path(id) + "/page", query: [URLQueryItem(name: "names", value: names)], timeout: 20)
    }

    /// A route's task answer: the task itself, or `{task: …}`.
    static func task(_ data: Data) throws -> TodoTask {
        if let task = try? JSONDecoder().decode(TodoTask.self, from: data) { return task }
        let json = try JSONValue.parse(data)
        // A 409's `{task}`, as FastAPI sends it (`{"detail": {"task": …}}`) or bare.
        for inner in [json["task"], json["detail"]?["task"]].compactMap({ $0 }) {
            if let task = try? JSONDecoder().decode(TodoTask.self, from: inner.encoded()) { return task }
        }
        throw PagesMessageError("The gateway sent a task this app can’t read.")
    }

    /// A 409's current task (`{detail: {task: <current>}}`), nil for any other failure.
    static func conflict(_ error: Error) -> TodoTask? {
        guard let http = error as? HTTPError, http.status == 409, let body = http.body?.data(using: .utf8) else { return nil }
        return try? task(body)
    }
}

/// What the disk cache keeps.
nonisolated struct TodoSnapshot: Codable, Sendable {
    var rev: Int
    var tasks: [TodoTask]
    var settings: TodoSettings
    var sections: [TodoUserSection]?
    var pages: Bool?
    var ideas: Int?
    var fields: Bool?
    var files: Bool?
    var lists: Bool?
    var offers: [TodoOffer]?
    /// [goals] nil: the add-on keeps no goals.
    var goals: [Goal]?
    /// [goals step 3] The add-on puts bots on goals (0.9.66), and draws Goal Pages.
    var goalBots: Bool?
    var goalPages: Bool?
    /// [goals step 3] Goals' offers seen here (a goal's chat card is told only the offer's id; this keeps what it was
    /// after the gateway lets it go).
    var seenOffers: [TodoOffer]?
}

/// `POST /tasks/offers/{id}`'s answer.
nonisolated struct TodoOfferAnswer: Decodable, Sendable {
    var rev: Int
    var offer: TodoOffer
    var sections: [TodoUserSection]
    /// [goals step 3] Every goal after the answer (0.9.66; an older add-on sends none).
    var goals: [Goal]?
}

@MainActor @Observable
final class TasksStore {
    let api: TasksAPI
    let account: GatewayAccount
    let directory: URL?
    var readOnlyGateway = false { didSet { TodoTaskStates.noteReadOnly(readOnlyGateway) } }

    /// Every task (optimistic edits applied). [chat-mark-done] The chat's close cards read a copy (`TodoTaskStates`).
    private(set) var tasks: [TodoTask] = [] { didSet { TodoTaskStates.note(tasks) } }
    private(set) var settings = TodoSettings() {
        didSet { if oldValue.enabled != settings.enabled { onEnabledChanged?(settings.enabled) } }
    }
    /// Tasks was turned on or off (here, on another device, or read back after a failed save).
    @ObservationIgnored var onEnabledChanged: ((Bool) -> Void)?
    private(set) var rev = 0
    /// Your own sections, in order.
    private(set) var sections: [TodoUserSection] = []
    /// The add-on keeps sections (0.9.36+); an older one is asked to update before the first is made.
    private(set) var sectionsSupported = false
    /// The add-on draws Task Pages (0.9.38+): a task a bot works on offers its page.
    private(set) var pagesSupported = false
    /// [tasks-first] The add-on keeps a task's priority, tags, alert and start day, and a shared task can repeat
    /// (0.9.53+): the task's page shows those rows only then (an older add-on would drop them on the floor).
    private(set) var fieldsSupported = false
    /// The add-on takes your own files and links on a task (0.9.53+).
    private(set) var filesSupported = false
    /// [task-lists] The add-on keeps a list's colour, icon, bot and rules, and bots' offers (0.9.55+): the Edit List
    /// sheet shows those rows only then.
    private(set) var listsSupported = false
    /// Bots' offers of a list or a batch of tasks: the ones that wait, and the last day's answered ones.
    private(set) var offers: [TodoOffer] = []
    /// [goals] Every goal, any status (optimistic edits applied); docs/goals.md.
    private(set) var goals: [Goal] = [] { didSet { TodoOfferStates.noteGoals(goals) } }
    /// [goals] The add-on keeps goals (`goals` in `GET /tasks`). Without it the page offers the update in Goals' place
    /// (`goalsNeedAddOn`). Public from hermes-hq-push 0.9.73 as re-published 2026-11-20 and 0.9.74; the "0.9.65" and
    /// "0.9.66" named here and in goals.py were only ever installed on the owner's computer (PushPolicy.goals).
    private(set) var goalsSupported = false
    /// [goals-addon] Tasks work but the add-on keeps no goals: an add-on from before Goals was published. The Goals
    /// pill stays and says to update the add-on (a public tester, 2026-11-20: "can't see Goals in Tasks").
    var goalsNeedAddOn: Bool { hasList && !needsAddOn && !goalsSupported }
    /// [goals step 3] The add-on puts bots on goals (`goal_bots`, with Goals in the public add-on): a lead, helpers,
    /// offers, the check-in.
    private(set) var goalBotsSupported = false
    /// [goals step 5] The add-on draws Goal Pages (`goal_pages` in `/status`).
    private(set) var goalPagesSupported = false
    /// [goals step 3] Goal offers seen here, by id (newest kept, 80 at most): what a goal's chat card draws once the
    /// gateway has let the offer go ("Answered").
    @ObservationIgnored private var seenOffers: [String: TodoOffer] = [:]
    @ObservationIgnored private var goalPagesAsked = false
    /// [task-ideas] New ideas to decide; nil when the add-on has no Ideas (older than 0.9.39), and the page keeps its
    /// Add a task row instead of the To Do | Ideas switch.
    private(set) var ideasCount: Int?
    /// A list is in hand (from disk or the gateway).
    private(set) var hasList = false
    /// The last read failed (shown only when there is no list).
    private(set) var error: String?
    private(set) var loading = false
    /// The add-on on the computer predates Tasks.
    private(set) var needsAddOn = false

    @ObservationIgnored var onChange: (() -> Void)?
    /// A write failed or gave way: plain words for a notice.
    @ObservationIgnored var onNotice: ((String) -> Void)?
    /// The task the last notice is about; nil when it is about the list as a whole (its settings or sections). The Mac's
    /// two panes say it on the task beside the list only when it is that task (Mac polish #44).
    @ObservationIgnored private(set) var noticeTask: String?
    /// [chat-mark-done] The last notice's words: a chat card's refused save says why under the chat's bar (the card
    /// clears it before its write).
    @ObservationIgnored var lastNotice: String?
    /// A refresh failed while a list shows (the page says "Couldn’t refresh. Showing what was saved.", as Jobs does).
    @ObservationIgnored var onRefreshFailed: ((String) -> Void)?
    /// Why the last `add` failed, in words (New Task's sheet says it on its own line; nil when it worked).
    @ObservationIgnored private(set) var addFailure: String?
    /// Every list change (local reminders follow it).
    @ObservationIgnored var onListChanged: (([TodoTask]) -> Void)?

    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var inFlight: [String: Int] = [:]
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var lastReadAt: Date?
    @ObservationIgnored private var sectionsWriting = false
    @ObservationIgnored private var offersWriting = 0
    /// [goals] Goals with a write on its way (by id): a read that left before it landed doesn't take it back.
    @ObservationIgnored private var goalsInFlight: [String: Int] = [:]
    private var goalsAPI: GoalsAPI { GoalsAPI(client: api.client) }
    /// [13-5] Forgotten at sign-out or a switch: an answer still on its way neither writes tasks.json again nor resets
    /// the phone's due reminders to this account's tasks.
    @ObservationIgnored private var closed = false

    init(api: TasksAPI, account: GatewayAccount, directory: URL?) {
        self.api = api
        self.account = account
        self.directory = directory
    }

    // MARK: Cache

    private var cacheURL: URL? { directory?.appending(path: "tasks.json") }

    /// The page is about to draw: paint the list from disk.
    func prepare() {
        guard !prepared, !closed else { return }
        prepared = true
        guard !hasList, let url = cacheURL, let cached = PagesCache.read(PagesCached<TodoSnapshot>.self, url) else { return }
        tasks = cached.value.tasks
        settings = cached.value.settings
        sections = cached.value.sections ?? []
        sectionsSupported = cached.value.sections != nil
        pagesSupported = cached.value.pages == true
        fieldsSupported = cached.value.fields == true
        filesSupported = cached.value.files == true
        listsSupported = cached.value.lists == true
        offers = Self.once(cached.value.offers ?? [])
        goals = cached.value.goals ?? []
        goalsSupported = cached.value.goals != nil
        goalBotsSupported = goalsSupported && cached.value.goalBots == true
        goalPagesSupported = goalBotsSupported && cached.value.goalPages == true
        for offer in cached.value.seenOffers ?? [] { seenOffers[offer.id] = offer }
        if !seenOffers.isEmpty { _ = TodoOfferStates.note(Array(seenOffers.values), whole: false) }
        noteOffers(whole: false)
        ideasCount = cached.value.ideas
        rev = cached.value.rev
        hasList = true
        changed()
    }

    private func save() {
        guard !closed, let url = cacheURL else { return }
        let snapshot = TodoSnapshot(rev: rev, tasks: tasks.filter { !TodoIDs.isLocal($0.id) }, settings: settings,
                                    sections: sectionsSupported ? sections.filter { !TodoIDs.isLocal($0.id) } : nil,
                                    pages: pagesSupported, ideas: ideasCount, fields: fieldsSupported, files: filesSupported,
                                    lists: listsSupported, offers: offers,
                                    goals: goalsSupported ? goals.filter { !TodoIDs.isLocal($0.id) } : nil,
                                    goalBots: goalBotsSupported, goalPages: goalPagesSupported,
                                    seenOffers: seenOffers.isEmpty ? nil : Array(seenOffers.values))
        PagesCache.write(PagesCached(at: Date().timeIntervalSince1970, value: snapshot), to: url)
    }

    private func changed() {
        guard !closed else { return }
        onChange?()
        onListChanged?(tasks)
    }

    // MARK: Reads

    func task(_ id: String) -> TodoTask? { tasks.first { $0.id == id } }

    /// Reads the list. `force` skips `?since=` (a push said something changed that the rev may not show yet).
    func refresh(force: Bool = false) async {
        guard !closed else { return }
        prepare()
        if !force, let at = lastReadAt, Date().timeIntervalSince(at) < 2 { return }
        readGeneration += 1
        let generation = readGeneration
        loading = true
        onChange?()
        defer { if generation == readGeneration { loading = false; onChange?() } }
        do {
            let answer = try await api.list(since: hasList && !force && rev > 0 ? rev : nil)
            guard generation == readGeneration else { return }
            lastReadAt = Date()
            if answer.unchanged { error = nil; needsAddOn = false; return }
            guard let fresh = answer.tasks else {
                // An add-on with no Tasks answers an empty object (or a page of its own).
                needsAddOn = await api.addOnServesTasks() != true
                if !needsAddOn { error = MoreWire.olderHermes }
                return
            }
            needsAddOn = false
            error = nil
            pagesSupported = answer.pages
            fieldsSupported = answer.fields
            filesSupported = answer.files
            listsSupported = answer.lists
            if offersWriting == 0 { offers = Self.once(answer.offers); noteOffers(whole: answer.lists) }
            ideasCount = answer.ideas
            adoptGoals(answer.goals)
            goalBotsSupported = goalsSupported && answer.goalBots
            if !goalBotsSupported { goalPagesSupported = false; goalPagesAsked = false }
            else if !goalPagesAsked {
                goalPagesAsked = true
                let api = api
                Task { [weak self] in
                    let draws = await api.addOnDrawsGoalPages()
                    guard let self, !self.closed else { return }
                    if let draws { self.goalPagesSupported = draws && self.goalBotsSupported; self.save(); self.onChange?() }
                    else { self.goalPagesAsked = false }
                }
            }
            if !sectionsWriting {
                sections = answer.sections ?? []
                sectionsSupported = answer.sections != nil
            }
            adopt(fresh, rev: answer.rev, settings: answer.settings)
        } catch {
            guard generation == readGeneration else { return }
            if let http = error as? HTTPError, PagesREST.isUnknownRoute(http) {
                needsAddOn = await api.addOnServesTasks() != true
                self.error = needsAddOn ? nil : PagesREST.reason(error)
            } else {
                self.error = PagesREST.reason(error)
            }
            if hasList, !needsAddOn, let reason = self.error { onRefreshFailed?(reason) }
        }
    }

    /// A read's list, keeping tasks that have a write on its way and ones added here and not yet answered.
    private func adopt(_ fresh: [TodoTask], rev: Int, settings: TodoSettings?) {
        var next = fresh
        let places = Dictionary(next.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for local in tasks {
            let inHand = inFlight[local.id] != nil || TodoIDs.isLocal(local.id)
            if let at = places[local.id] {
                // [tasks-first] A read that left before a change landed carries the task as it was (an older rev): it
                // never takes the change back. (Move To › New List… saved the list, which reads the list again, then
                // moved the task; the read's late answer put the task back in no list until the next read.)
                if inHand || next[at].rev < local.rev { next[at] = local }
            } else if inHand {
                next.append(local)
            }
        }
        tasks = next
        self.rev = rev
        if let settings { self.settings = settings }
        hasList = true
        TodoTaskStates.noteRead()   // [chat-mark-done] the gateway's list, not the one on disk
        save()
        changed()
    }

    /// [goals] A read's goals, keeping ones with a write on its way and ones added here and not yet answered (nil: the
    /// add-on keeps none).
    private func adoptGoals(_ fresh: [Goal]?) {
        guard let fresh else { goalsSupported = false; goals = []; return }
        goalsSupported = true
        var next = fresh
        let places = Dictionary(next.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for local in goals {
            let inHand = goalsInFlight[local.id] != nil || TodoIDs.isLocal(local.id)
            if let at = places[local.id] {
                if inHand || next[at].rev < local.rev { next[at] = local }
            } else if inHand {
                next.append(local)
            }
        }
        goals = next
    }

    /// [task-ideas] The Ideas page read or decided: the switch's count follows it at once.
    func ideasRead(_ count: Int) {
        guard ideasCount != nil, ideasCount != count else { return }
        ideasCount = count
        save()
        onChange?()
    }

    // MARK: Writes

    /// Acceptance is conditional on the exact revision shown. Never retry a conflict: the suggestion may have changed.
    func acceptSuggestedTitle(_ id: String, suggestion: String, forTitle: String) async -> Bool {
        guard !refuse(about: id) else { return false }
        guard inFlight[id] == nil else {
            notice("This task is being saved. Try again in a moment.", about: id)
            return false
        }
        guard let base = task(id), !TodoIDs.isLocal(id),
              base.title == forTitle, base.currentSuggestedTitle == suggestion else {
            notice("This suggestion is no longer current.", about: id)
            return false
        }
        begin(id)
        defer { end(id) }
        do {
            let answer = try await api.patch(id, rev: base.rev, fields: ["title": .string(suggestion)])
            put(answer); save(); changed()
            guard answer.title == suggestion else {
                notice("Couldn’t save the suggested title. Showing the saved task.", about: id)
                return false
            }
            return true
        } catch {
            if let current = TasksAPI.conflict(error) {
                put(current); save(); changed()
                notice("This task changed somewhere else. Showing the latest.", about: id)
            } else if PagesREST.status(error) == 404 {
                tasks.removeAll { $0.id == id }; save(); changed()
                notice("This task was deleted somewhere else.", about: id)
            } else {
                notice("Couldn’t save the suggested title. \(PagesREST.reason(error))", about: id)
            }
            return false
        }
    }

    private func refuse(quiet: Bool = false, about task: String? = nil) -> Bool {
        guard readOnlyGateway else { return false }
        if !quiet { notice(JobsStore.readOnlyNotice, about: task) }
        return true
    }

    private func notice(_ text: String, about task: String? = nil) {
        noticeTask = task
        lastNotice = text
        onNotice?(text)
    }

    private func put(_ task: TodoTask) {
        if let at = tasks.firstIndex(where: { $0.id == task.id }) { tasks[at] = task } else { tasks.append(task) }
    }

    private func begin(_ id: String) { inFlight[id, default: 0] += 1 }
    private func end(_ id: String) {
        let left = (inFlight[id] ?? 1) - 1
        inFlight[id] = left > 0 ? left : nil
    }

    /// Adds a task: shown at once, then swapped for the gateway's (its id, rev and times). nil when it failed, with
    /// the reason in `addFailure`. `quiet`: no notice of its own (Import from Reminders sums its adds up in one).
    @discardableResult
    func add(_ fields: [String: JSONValue], quiet: Bool = false) async -> TodoTask? {
        addFailure = nil
        guard !refuse(quiet: quiet) else { addFailure = JobsStore.readOnlyNotice; return nil }
        var draft = fields
        let localID = TodoIDs.local()
        draft["id"] = .string(localID)
        draft["created_at"] = .string(TodoDates.now())
        draft["updated_at"] = draft["created_at"]
        draft["created_by"] = .string("you")
        if let data = try? JSONValue.object(draft).encoded(), let shown = try? JSONDecoder().decode(TodoTask.self, from: data) {
            tasks.append(shown)
            changed()
        }
        do {
            let made = try await api.create(fields)
            tasks.removeAll { $0.id == localID }
            put(made)
            save()
            changed()
            reconcilePrep(TodoEdits.prepBots(before: nil, after: made, fields: nil))
            return made
        } catch {
            tasks.removeAll { $0.id == localID }
            changed()
            let reason = PagesREST.reason(error)
            addFailure = reason
            if !quiet { notice("Couldn’t add the task. \(reason)") }
            return nil
        }
    }

    /// Changes a task's fields (wire names). The change shows at once; a 409 re-sends it on the current rev when the
    /// other edit left these fields alone, and otherwise shows the current version.
    /// `touch`: the shown task counts as changed now (Keep, which sends no fields).
    @discardableResult
    func patch(_ id: String, _ fields: [String: JSONValue], touch: Bool = false) async -> Bool {
        guard !refuse(about: id), let base = task(id) else { return false }
        guard !TodoIDs.isLocal(id) else { notice("This task is still being added. Try again in a moment.", about: id); return false }
        let fields = GoalViews.withMilestoneRule(fields, task: base)   // [goals] another goal: no milestone of the last one
        if var shown = TodoEdits.applying(fields, to: base) {
            if touch { shown.updatedAt = TodoDates.now() }
            put(shown); changed()
        }
        begin(id)
        defer { end(id) }
        do {
            let answer = try await api.patch(id, rev: base.rev, fields: fields)
            put(answer)
            save()
            changed()
            reconcilePrep(TodoEdits.prepBots(before: base, after: answer, fields: Set(fields.keys)))
            return true
        } catch {
            if let current = TasksAPI.conflict(error) {
                switch TodoEdits.resolve(base: base, current: current, fields: fields) {
                case .resend(let rev):
                    if let answer = try? await api.patch(id, rev: rev, fields: fields) {
                        put(answer); save(); changed()
                        reconcilePrep(TodoEdits.prepBots(before: base, after: answer, fields: Set(fields.keys)))
                        return true
                    }
                    put(current); save(); changed()
                    notice("This task changed somewhere else. Showing the latest.", about: id)
                    return false
                case .theirs:
                    put(current); save(); changed()
                    notice("This task changed somewhere else. Showing the latest.", about: id)
                    return false
                }
            }
            if PagesREST.status(error) == 404 {
                tasks.removeAll { $0.id == id }
                save(); changed()
                notice("This task was deleted somewhere else.", about: id)
                return false
            }
            put(base)
            changed()
            notice("Couldn’t save the change. \(PagesREST.reason(error))", about: id)
            return false
        }
    }

    /// Ticks a task done (or opens it again). false when the gateway didn't take it (the task shows as it was).
    @discardableResult
    func setDone(_ id: String, _ done: Bool) async -> Bool {
        await patch(id, ["status": .string(done ? "done" : "open")])
    }

    /// Keep ("Still Need These?"): nothing about the task changes, but the gateway stamps it touched, so it leaves
    /// the group for another two weeks.
    @discardableResult
    func keep(_ id: String) async -> Bool {
        await patch(id, [:], touch: true)
    }

    /// Ticks one step.
    /// False when the gateway refused it.
    @discardableResult
    func setStep(_ taskID: String, step: String, done: Bool) async -> Bool {
        guard let task = task(taskID) else { return false }
        let steps = task.steps.map { s -> TodoStep in var s = s; if s.id == step { s.done = done }; return s }
        return await patch(taskID, ["steps": TodoWire.steps(steps)])
    }

    // MARK: Your own files and links ([tasks-first], hermes-hq-push 0.9.53)

    /// The largest file a task takes (the add-on's own cap).
    nonisolated static let fileLimit = 10 * 1024 * 1024

    /// Puts a link on the task. False when the gateway refused it (the notice has said why).
    @discardableResult
    func attachLink(_ id: String, url: String, title: String = "") async -> Bool {
        await attach(id, ["kind": "link", "url": .string(url), "title": .string(title)])
    }

    /// Puts a file on the task: its bytes are kept on the computer running Hermes, where the task's bot can read them.
    @discardableResult
    func attachFile(_ id: String, name: String, data: Data) async -> Bool {
        guard data.count <= Self.fileLimit else {
            notice("That file is over 10 MB. A task takes files up to 10 MB.", about: id)
            return false
        }
        return await attach(id, ["kind": "file", "name": .string(name), "data": .string(data.base64EncodedString())])
    }

    private func attach(_ id: String, _ body: [String: JSONValue]) async -> Bool {
        guard !refuse(about: id), task(id) != nil else { return false }
        guard filesSupported else {
            notice("Files and links on a task need the newest HQ add-on on your computer (0.9.53 or later).", about: id)
            return false
        }
        begin(id)
        defer { end(id) }
        do {
            put(try await api.attach(id, body))
            save()
            changed()
            return true
        } catch {
            notice("Couldn’t add it. \(PagesREST.reason(error))", about: id)
            return false
        }
    }

    /// Takes a file, link or note off the task (shown at once; put back if the gateway refuses).
    @discardableResult
    func detach(_ id: String, made: String) async -> Bool {
        guard !refuse(about: id), let before = task(id) else { return false }
        var shown = before
        shown.made.removeAll { $0.id == made }
        put(shown); changed()
        begin(id)
        defer { end(id) }
        do {
            put(try await api.detach(id, made: made))
            save()
            changed()
            return true
        } catch {
            put(before); changed()
            notice("Couldn’t remove it. \(PagesREST.reason(error))", about: id)
            return false
        }
    }

    /// Deletes a task (a chat card's Undo too: the task may not be in the list yet).
    @discardableResult
    func delete(_ id: String) async -> Bool {
        guard !refuse(about: id) else { return false }
        let at = tasks.firstIndex { $0.id == id }
        let removed = at.map { tasks.remove(at: $0) }
        if removed != nil { changed() }
        do {
            try await api.delete(id)
            save()
            reconcilePrep(TodoEdits.prepBots(before: removed, after: nil, fields: nil))
            return true
        } catch {
            if PagesREST.status(error) == 404 { save(); return true }
            if let removed, let at { tasks.insert(removed, at: min(at, tasks.count)); changed() }
            notice("Couldn’t delete the task. \(PagesREST.reason(error))", about: id)
            return false
        }
    }

    /// false when it wasn't saved (the settings are back as they were).
    @discardableResult
    func saveSettings(_ next: TodoSettings) async -> Bool {
        guard !refuse() else { return false }
        let before = settings
        settings = next
        onChange?()
        do {
            settings = try await api.saveSettings(next)
            save()
            onChange?()
            return true
        } catch {
            settings = before
            onChange?()
            notice("Couldn’t save Tasks settings. \(PagesREST.reason(error))")
            return false
        }
    }

    // MARK: Goals ([goals], hermes-hq-push 0.9.65)

    func goal(_ id: String) -> Goal? { goals.first { $0.id == id } }

    private func putGoal(_ goal: Goal) {
        if let at = goals.firstIndex(where: { $0.id == goal.id }) { goals[at] = goal } else { goals.append(goal) }
    }

    /// [goals set-up] A plan offer this device accepted (the gateway's answer): the app tells the goal's lead once.
    @ObservationIgnored var onPlanTaken: ((TodoOffer) -> Void)?

    /// Why the last `addGoal` failed, in words (New Goal says it on its own line; nil when it worked).
    @ObservationIgnored private(set) var addGoalFailure: String?

    /// Adds a goal (`GoalWire.newGoal`'s body): shown at once, then swapped for the gateway's. nil when it failed.
    @discardableResult
    func addGoal(_ fields: [String: JSONValue]) async -> Goal? {
        addGoalFailure = nil
        guard !refuse() else { addGoalFailure = JobsStore.readOnlyNotice; return nil }
        guard goalsSupported else {
            addGoalFailure = "Goals need the newest HQ add-on on your computer (0.9.74 or later)."   // [goals-addon] PushPolicy.goals
            notice(addGoalFailure ?? "")
            return nil
        }
        let localID = TodoIDs.local()
        let stamp = TodoDates.now()
        var shown = GoalWire.applying(fields, to: Goal(id: localID, rev: 0, title: "", color: nil, position: Date().timeIntervalSince1970,
                                                       createdAt: stamp, updatedAt: stamp))
        if shown.color == nil { shown.color = GoalViews.nextColor(goals).rawValue }
        goals.append(shown)
        changed()
        // [goals set-up] One write: POST /goals takes the lead, helpers, adds and review. An add-on from before that
        // ignores them, and what it left out goes in a PATCH right after (as it all did before).
        do {
            var made = try await goalsAPI.create(GoalWire.createBody(fields))
            let left = GoalWire.teamLeft(fields, made: made)
            if !left.isEmpty, let led = try? await goalsAPI.patch(made.id, rev: made.rev, fields: left) { made = led }
            goals.removeAll { $0.id == localID }
            putGoal(made)
            save()
            changed()
            return made
        } catch {
            goals.removeAll { $0.id == localID }
            changed()
            let reason = PagesREST.reason(error)
            addGoalFailure = reason
            notice("Couldn’t add the goal. \(reason)")
            return nil
        }
    }

    /// Changes a goal's fields (wire names: `title`, `why`, `color`, `position`, `due`, `status`, `measure`,
    /// `measure_now`, `milestones`). Shown at once; a 409 re-sends it on the current rev when the other edit left these
    /// fields alone, else the current goal shows. A milestone taken out takes its tasks to no milestone here too.
    @discardableResult
    func patchGoal(_ id: String, _ fields: [String: JSONValue]) async -> Bool {
        guard !refuse(), let base = goal(id) else { return false }
        guard !TodoIDs.isLocal(id) else { notice("This goal is still being added. Try again in a moment."); return false }
        let beforeTasks = tasks
        putGoal(GoalWire.applying(fields, to: base))
        if fields["milestones"] != nil { releaseTasks(of: id, keeping: Set(goal(id)?.milestones.map(\.id) ?? [])) }
        changed()
        goalsInFlight[id, default: 0] += 1
        defer {
            let left = (goalsInFlight[id] ?? 1) - 1
            goalsInFlight[id] = left > 0 ? left : nil
        }
        // A milestone made here goes without its local id; the gateway's answer brings the real one.
        do {
            let answer = try await goalsAPI.patch(id, rev: base.rev, fields: fields)
            putGoal(answer)
            save()
            changed()
            return true
        } catch {
            if let current = GoalsAPI.conflict(error) {
                if case .resend(let rev) = GoalWire.resolve(base: base, current: current, fields: fields),
                   let answer = try? await goalsAPI.patch(id, rev: rev, fields: fields) {
                    putGoal(answer); save(); changed()
                    return true
                }
                putGoal(current); tasks = beforeTasks; save(); changed()
                notice("This goal changed somewhere else. Showing the latest.")
                return false
            }
            if PagesREST.status(error) == 404 {
                goals.removeAll { $0.id == id }
                releaseTasks(of: id, keeping: nil)
                save(); changed()
                notice("This goal was deleted somewhere else.")
                return false
            }
            putGoal(base)
            tasks = beforeTasks
            changed()
            notice("Couldn’t save the change. \(PagesREST.reason(error))")
            return false
        }
    }

    /// Deletes a goal. Its tasks stay, with no goal and no milestone (the gateway clears them too).
    @discardableResult
    func deleteGoal(_ id: String) async -> Bool {
        guard !refuse() else { return false }
        let at = goals.firstIndex { $0.id == id }
        let removed = at.map { goals.remove(at: $0) }
        let beforeTasks = tasks
        releaseTasks(of: id, keeping: nil)
        changed()
        do {
            try await goalsAPI.delete(id)
            save()
            return true
        } catch {
            if PagesREST.status(error) == 404 { save(); return true }
            if let removed, let at { goals.insert(removed, at: min(at, goals.count)) }
            tasks = beforeTasks
            changed()
            notice("Couldn’t delete the goal. \(PagesREST.reason(error))")
            return false
        }
    }

    /// The goal's tasks lose their milestone when it isn't in `keeping`; with `keeping` nil they lose the goal too.
    private func releaseTasks(of goal: String, keeping: Set<String>?) {
        tasks = tasks.map { task in
            guard task.goal == goal else { return task }
            var task = task
            if let keeping {
                if let milestone = task.milestone, !keeping.contains(milestone) { task.milestone = nil }
            } else {
                task.goal = nil
                task.milestone = nil
            }
            return task
        }
    }

    /// [goals step 4] The stall question's Keep Going (`keep: true`). False on an add-on before 0.9.66, which keeps no
    /// `kept_at` (the page keeps it on this device instead, `GoalKeptHere`).
    @discardableResult
    func keepGoing(_ id: String) async -> Bool {
        guard goalBotsSupported else { return false }
        return await patchGoal(id, ["keep": .bool(true)])
    }

    /// [goals step 4] Mark Done / Not Yet on the lead's "this looks done".
    @discardableResult
    func answerLooksDone(_ id: String, done: Bool) async -> Bool {
        await patchGoal(id, ["offer_answer": .string(done ? "done" : "keep")])
    }

    /// Puts a task in a goal (nil: no goal), under one of its milestones or none.
    @discardableResult
    func setGoal(_ taskID: String, goal: String?, milestone: String? = nil) async -> Bool {
        await patch(taskID, GoalViews.assign(goal: goal, milestone: milestone, goals: goals))
    }

    // MARK: Sections

    /// Saves your sections (the whole list, in order). Shown at once; a section left out takes its tasks back to no
    /// section. Returns the saved list (new ones with their ids), nil when it failed.
    @discardableResult
    func saveSections(_ next: [TodoUserSection]) async -> [TodoUserSection]? {
        guard !refuse() else { return nil }
        guard sectionsSupported else {
            notice("Sections need the newest HQ add-on on your computer (0.9.36 or later).")
            return nil
        }
        let before = sections, beforeTasks = tasks
        let kept = Set(next.map(\.id))
        sections = next
        tasks = tasks.map { task in
            guard let id = task.section, !kept.contains(id) else { return task }
            var task = task; task.section = nil; return task
        }
        changed()
        sectionsWriting = true
        defer { sectionsWriting = false }
        do {
            let saved = try await api.saveSections(next)
            sections = saved
            save()
            changed()
            Task { await refresh(force: true) }
            return saved
        } catch {
            sections = before
            tasks = beforeTasks
            changed()
            notice("Couldn’t save your sections. \(PagesREST.reason(error))")
            return nil
        }
    }

    /// [task-lists] One list changed (its name, colour, icon, bot or rules); the others stay as they are.
    @discardableResult
    func saveSection(_ section: TodoUserSection) async -> Bool {
        guard sections.contains(where: { $0.id == section.id }) else { return false }
        return await saveSections(sections.map { $0.id == section.id ? section : $0 }) != nil
    }

    /// Each offer once, the first of an id kept: an id sent twice would be two rows with one identity, which the
    /// list refuses (a crash, seen on the Mac against the stand-in gateway).
    nonisolated static func once(_ offers: [TodoOffer]) -> [TodoOffer] {
        var seen = Set<String>()
        return offers.filter { seen.insert($0.id).inserted }
    }

    /// The chats' offer cards hear what the offers are now. [goals step 3] Goal offers are kept here too, so a goal's
    /// chat card (told only an id) still draws once the gateway has let one go.
    private func noteOffers(whole: Bool) {
        for offer in offers where offer.isGoal { seenOffers[offer.id] = offer }
        if seenOffers.count > 80 {
            let oldest = seenOffers.values.sorted { (TodoDates.moment($0.at) ?? .distantPast) < (TodoDates.moment($1.at) ?? .distantPast) }
            for offer in oldest.prefix(seenOffers.count - 80) { seenOffers[offer.id] = nil }
        }
        if TodoOfferStates.note(offers, whole: whole) { NotificationCenter.default.post(name: TodoOfferStates.changed, object: nil) }
    }

    /// [task-lists] Your tap on a bot's offer. The card changes at once; the list is read again for the tasks and
    /// the list it made, moved or took back. False when the gateway refused it (the card shows as it was).
    @discardableResult
    func answerOffer(_ id: String, _ action: TodoOfferAction, list: Bool = true, plan: Bool = true, inGoal: Bool = true) async -> Bool {
        guard !refuse(), let at = offers.firstIndex(where: { $0.id == id }) else { return false }
        let before = offers[at]
        var shown = before
        switch action {
        case .accept where before.isGoal:
            // [goals step 3] "Keep the Goal, No Plan" on a plan declines it (as the gateway does).
            if before.kind == "plan", !plan { shown.state = "declined" } else { shown.state = "accepted"; shown.plan = plan; shown.inGoal = inGoal }
        case .accept: shown.state = "accepted"; shown.listed = list || !before.isNew
        case .decline: shown.state = "declined"
        case .move: shown.moveState = "moved"
        case .leave: shown.moveState = "left"
        case .undo: shown.state = "undone"
        }
        offers[at] = shown
        noteOffers(whole: false)
        changed()
        offersWriting += 1
        defer { offersWriting -= 1 }
        do {
            let answer = try await api.answerOffer(id, action: action, list: list, goal: before.isGoal ? (plan, inGoal) : nil)
            if let now = offers.firstIndex(where: { $0.id == id }) { offers[now] = answer.offer }
            noteOffers(whole: false)
            if !sectionsWriting { sections = answer.sections }
            if let goals = answer.goals { adoptGoals(goals) }
            save()
            changed()
            // [goals set-up] This device took a plan: its lead is told, once (`GoalPlanTold`). Only here, on the
            // gateway's yes to this tap: another device's answer reaches this one as a 409 or a read, never as this.
            if action == .accept, answer.offer.kind == "plan", answer.offer.state == "accepted" { onPlanTaken?(answer.offer) }
            lastReadAt = nil
            await refresh(force: true)
            return true
        } catch {
            // [goals step 3] Answered on another device first (a 409): the card shows what became of it.
            if PagesREST.status(error) == 409 {
                if let now = offers.firstIndex(where: { $0.id == id }) { offers[now] = before }
                lastReadAt = nil
                Task { await refresh(force: true) }   // after this write is off the books, so the read takes the offers
                notice("That was already answered on another device.")
                return false
            }
            if let now = offers.firstIndex(where: { $0.id == id }) { offers[now] = before }
            noteOffers(whole: false)
            changed()
            notice("Couldn’t do that. \(PagesREST.reason(error))")
            Task { await refresh(force: true) }
            return false
        }
    }

    /// [task-lists] "Keep Open" on a bot's offer to close a task: the offer leaves the row, and the bot isn't to ask
    /// again.
    @discardableResult
    func keepOpen(_ id: String) async -> Bool {
        guard let base = task(id), var offer = base.offer else { return false }
        offer.kept = true
        guard let value = try? JSONValue.parse(JSONEncoder().encode(offer)) else { return false }
        // `offer` is what the row shows at once; the gateway reads only `keep_open`.
        return await patch(id, ["keep_open": .bool(true), "offer": value])
    }

    /// Adds a section at the end; returns it (with the gateway's id).
    func addSection(named name: String) async -> TodoUserSection? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        // [task-lists] A new list takes the first colour no list has (0.9.55+; an older add-on keeps only the name).
        let draft = TodoUserSection(id: TodoIDs.local(), name: String(clean.prefix(60)),
                                    color: listsSupported ? TodoLists.nextColor(sections).rawValue : nil)
        guard let saved = await saveSections(sections + [draft]) else { return nil }
        return saved.last { $0.name == draft.name } ?? saved.last
    }

    /// Moves tasks into `section` (nil: no section), at the end of it in the order given, or at `position` for one
    /// dragged task. False when any of them couldn't move (the notice has said why).
    @discardableResult
    func move(_ ids: [String], to section: String?, position: Double? = nil) async -> Bool {
        guard !refuse() else { return false }
        guard sectionsSupported else {
            notice("Sections need the newest HQ add-on on your computer (0.9.36 or later).")
            return false
        }
        var next = position ?? ((tasks.filter { $0.section == section && !ids.contains($0.id) }.map(\.order).max() ?? Date().timeIntervalSince1970) + 1)
        // Not `withTaskGroup`: optimized builds abort when a child finishes into a destroyed group (ChildTasks.swift).
        return await withChildTasks(of: Bool.self) { group in
            for id in ids {
                guard let task = task(id) else { continue }
                var fields: [String: JSONValue] = ["position": .number(next)]
                if task.section != section { fields["section"] = TodoWire.optional(section) }
                next += 1
                let body = fields
                group.addTask { await self.patch(id, body) }
            }
            var moved = true
            while let ok = await group.next() { moved = moved && ok }
            return moved
        }
    }

    /// Group By and Sort By (kept with the other Tasks settings on the gateway).
    /// False when the gateway refused it.
    @discardableResult
    func setLayout(group: String? = nil, sort: String? = nil) async -> Bool {
        var next = settings
        if let group { next.group = group }
        if let sort { next.sort = sort }
        guard next != settings else { return true }
        return await saveSettings(next)
    }

    /// After a change this app made: the bots whose "Task prep" job it may start or end (their own tools do it for theirs).
    private func reconcilePrep(_ bots: [String]) {
        guard !bots.isEmpty else { return }
        let api = api
        Task { for bot in bots { await api.reconcilePrep(bot) } }
    }

    /// Signed out or switched away: forget the list in memory (the cache folder is purged with the account's).
    func forget() {
        tasks = []
        sections = []
        goals = []
        rev = 0
        hasList = false
        prepared = false
        readGeneration += 1             // a read on its way is dropped
        changed()
        closed = true
        TodoTaskStates.forget()         // [chat-mark-done]
    }
}

/// Fields as the routes take them.
nonisolated enum TodoWire {
    static func steps(_ steps: [TodoStep]) -> JSONValue {
        .array(steps.map { .object(["id": .string($0.id), "title": .string($0.title), "who": .string($0.who), "done": .bool($0.done)]) })
    }

    static func optional(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }

    /// A new task's body.
    static func newTask(title: String, who: TodoWho, bot: String?, due: String?, repeatRule: String?, prep: Bool,
                        notes: String = "", steps: [TodoStep] = [], source: TodoSource? = TodoSource(kind: "app"),
                        goal: String? = nil, milestone: String? = nil) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "title": .string(title), "who": .string(who.rawValue), "notes": .string(notes), "prep": .bool(prep && who != .me),
            "steps": Self.steps(steps), "due": optional(due), "repeat": optional(who == .me ? repeatRule : nil),
        ]
        body["bot"] = who == .me ? .null : optional(bot ?? "default")
        if let source {
            var object: [String: JSONValue] = ["kind": .string(source.kind)]
            if let profile = source.profile { object["profile"] = .string(profile) }
            if let session = source.sessionId { object["session_id"] = .string(session) }
            if let reminder = source.reminderId { object["reminder_id"] = .string(reminder) }
            body["source"] = .object(object)
        }
        // [goals] Added on a goal's page: it starts in that goal (and the milestone it was added under). Sent only
        // then, so an older add-on never sees the keys.
        if let goal {
            body["goal"] = .string(goal)
            if let milestone { body["milestone"] = .string(milestone) }
        }
        return body
    }
}
