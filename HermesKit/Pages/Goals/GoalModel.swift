// [goals] What your tasks are for (docs/goals.md, owner 2026-11-18: "an area for goals … things that I want to achieve
// over time"). A goal is a finish line, an optional date, a one-line why, milestones, and ordinary tasks under them. The
// hermes-hq-push add-on keeps goals beside the list (0.9.65's `goals` in `GET /tasks`, `POST/PATCH/DELETE /goals`);
// the app draws them. Decoding is lenient as a task's is: an unknown status or colour, or a field missing, never loses
// the goal, and one bad goal never loses the list (TodoListAnswer decodes each on its own).
// Plain data and rules, tested in Tests/Pages/GoalViewsTests and Tests/Pages/GoalsStoreTests.

import Foundation

/// Where a goal stands. An unknown status (a later add-on's) reads as active, so the goal still shows.
nonisolated enum GoalState: String, CaseIterable, Sendable {
    case active, paused, achieved
    case letGo = "let_go"
}

/// The goal's number: "340 of 1,000 testers". A target below the start counts down ("185 to 170 lbs").
nonisolated struct GoalMeasure: Codable, Hashable, Sendable {
    /// "testers", "lbs", "$"; may be "".
    var unit: String
    var start: Double
    var target: Double
    var now: Double
    /// When `now` last changed.
    var at: String?
    /// "you" (a bot reads one in a later step).
    var source: String
    /// Every change of `now`, newest last, 60 at most.
    var history: [GoalReading]

    enum CodingKeys: String, CodingKey { case unit, start, target, now, at, source, history }

    init(unit: String = "", start: Double = 0, target: Double, now: Double? = nil, at: String? = nil, source: String = "you",
         history: [GoalReading] = []) {
        self.unit = unit; self.start = start; self.target = target; self.now = now ?? start; self.at = at
        self.source = source; self.history = history
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) ?? ""
        start = (try? c.decodeIfPresent(Double.self, forKey: .start)) ?? 0
        target = (try? c.decodeIfPresent(Double.self, forKey: .target)) ?? 0
        now = (try? c.decodeIfPresent(Double.self, forKey: .now)) ?? start
        at = (try? c.decodeIfPresent(String.self, forKey: .at)).flatMap { $0?.isEmpty == true ? nil : $0 }
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? "you"
        if let raw = try? c.decodeIfPresent([JSONValue].self, forKey: .history) {
            history = raw.compactMap { value in (try? value.encoded()).flatMap { try? JSONDecoder().decode(GoalReading.self, from: $0) } }
        } else {
            history = []
        }
    }

    /// It counts down (a weight to lose, a debt to pay off).
    var countsDown: Bool { target < start }
}

nonisolated struct GoalReading: Codable, Hashable, Sendable {
    var at: String?
    var value: Double
}

/// One milestone, in the goal's order.
nonisolated struct GoalMilestone: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    /// A day ("2027-01-31"), or nil.
    var due: String?
    var done: Bool
    var doneAt: String?

    enum CodingKeys: String, CodingKey { case id, title, due, done, doneAt = "done_at" }

    init(id: String, title: String, due: String? = nil, done: Bool = false, doneAt: String? = nil) {
        self.id = id; self.title = title; self.due = due; self.done = done; self.doneAt = doneAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        due = (try? c.decodeIfPresent(String.self, forKey: .due)).flatMap { $0?.isEmpty == true ? nil : $0 }
        done = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? false
        doneAt = (try? c.decodeIfPresent(String.self, forKey: .doneAt)).flatMap { $0?.isEmpty == true ? nil : $0 }
    }
}

/// One goal, as the routes send it.
nonisolated struct Goal: Codable, Hashable, Sendable, Identifiable {
    var id: String
    /// Bumps on every change; a PATCH carries it (a stale one is a 409 with the current goal).
    var rev: Int
    var title: String
    var why: String
    /// As sent: "active" | "paused" | "achieved" | "let_go" (`state` reads it).
    var status: String
    /// When the status last changed.
    var statusAt: String?
    /// A list's colour name (`TodoListColor`); `tint` reads it.
    var color: String?
    /// A day ("2027-01-31"), or nil.
    var due: String?
    /// Smallest first; starts as the time it was added.
    var position: Double
    var measure: GoalMeasure?
    var milestones: [GoalMilestone]
    var createdAt: String?
    var updatedAt: String?
    var log: [TodoLogEntry]

    enum CodingKeys: String, CodingKey {
        case id, rev, title, why, status, color, due, position, measure, milestones, log
        case statusAt = "status_at", createdAt = "created_at", updatedAt = "updated_at"
    }

    init(id: String, rev: Int = 1, title: String, why: String = "", status: GoalState = .active, statusAt: String? = nil,
         color: String? = "blue", due: String? = nil, position: Double = 0, measure: GoalMeasure? = nil,
         milestones: [GoalMilestone] = [], createdAt: String? = nil, updatedAt: String? = nil, log: [TodoLogEntry] = []) {
        self.id = id; self.rev = rev; self.title = title; self.why = why; self.status = status.rawValue
        self.statusAt = statusAt; self.color = color; self.due = due; self.position = position; self.measure = measure
        self.milestones = milestones; self.createdAt = createdAt; self.updatedAt = updatedAt; self.log = log
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        rev = (try? c.decodeIfPresent(Int.self, forKey: .rev)) ?? 0
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        why = (try? c.decodeIfPresent(String.self, forKey: .why)) ?? ""
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? GoalState.active.rawValue
        statusAt = (try? c.decodeIfPresent(String.self, forKey: .statusAt)).flatMap { $0?.isEmpty == true ? nil : $0 }
        color = (try? c.decodeIfPresent(String.self, forKey: .color)).flatMap { $0?.isEmpty == true ? nil : $0 }
        due = (try? c.decodeIfPresent(String.self, forKey: .due)).flatMap { $0?.isEmpty == true ? nil : $0 }
        position = (try? c.decodeIfPresent(Double.self, forKey: .position)) ?? 0
        measure = (try? c.decodeIfPresent(GoalMeasure.self, forKey: .measure)).flatMap { $0 }
        // Each milestone on its own: one without an id is dropped, the others stay.
        if let raw = try? c.decodeIfPresent([JSONValue].self, forKey: .milestones) {
            milestones = raw.compactMap { value in
                (try? value.encoded()).flatMap { try? JSONDecoder().decode(GoalMilestone.self, from: $0) }.flatMap { $0.id.isEmpty ? nil : $0 }
            }
        } else {
            milestones = []
        }
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
        log = (try? c.decodeIfPresent([TodoLogEntry].self, forKey: .log)) ?? []
    }

    /// Its status as the app reads it (an unknown one is active).
    var state: GoalState { GoalState(rawValue: status) ?? .active }
    /// Its colour (an unknown or missing one is blue).
    var tint: TodoListColor { color.flatMap(TodoListColor.init(rawValue:)) ?? .blue }
    /// Its place among the goals: its position, or when it was added on an add-on that sent none.
    var order: Double { position != 0 ? position : (TodoDates.moment(createdAt)?.timeIntervalSince1970 ?? 0) }

    func milestone(_ id: String?) -> GoalMilestone? { id.flatMap { id in milestones.first { $0.id == id } } }
}

/// Goals' routes (hermes-hq-push 0.9.65): beside `/tasks`, with the same sign-in.
nonisolated struct GoalsAPI: Sendable {
    static let base = PushPolicy.route + "/goals"
    let client: any GatewayClient

    private func path(_ id: String) -> String { Self.base + "/" + PagesREST.segment(id) }

    @concurrent
    func create(_ fields: [String: JSONValue]) async throws -> Goal {
        try Self.goal(try await PagesREST.send(client, "POST", Self.base, json: .object(fields)))
    }

    @concurrent
    func patch(_ id: String, rev: Int, fields: [String: JSONValue]) async throws -> Goal {
        var body = fields
        body["rev"] = .number(Double(rev))
        return try Self.goal(try await PagesREST.send(client, "PATCH", path(id), json: .object(body)))
    }

    @concurrent
    func delete(_ id: String) async throws {
        _ = try await PagesREST.send(client, "DELETE", path(id))
    }

    /// A route's goal answer: the goal itself, or `{goal: …}` (a 409's, as FastAPI sends it inside `detail`, or bare).
    static func goal(_ data: Data) throws -> Goal {
        if let goal = try? JSONDecoder().decode(Goal.self, from: data) { return goal }
        let json = try JSONValue.parse(data)
        for inner in [json["goal"], json["detail"]?["goal"]].compactMap({ $0 }) {
            if let goal = try? JSONDecoder().decode(Goal.self, from: inner.encoded()) { return goal }
        }
        throw PagesMessageError("The gateway sent a goal this app can’t read.")
    }

    /// A 409's current goal, nil for any other failure.
    static func conflict(_ error: Error) -> Goal? {
        guard let http = error as? HTTPError, http.status == 409, let body = http.body?.data(using: .utf8) else { return nil }
        return try? goal(body)
    }
}

/// Goal fields as the routes take them, and a PATCH applied here at once (as the gateway will apply it).
nonisolated enum GoalWire {
    /// A new goal's body. `color` nil: the gateway picks the first colour no active goal uses.
    static func newGoal(title: String, why: String = "", due: String? = nil, color: String? = nil, measure: GoalMeasure? = nil,
                        milestones: [GoalMilestone] = []) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["title": .string(title)]
        if !why.isEmpty { body["why"] = .string(why) }
        if let due { body["due"] = .string(due) }
        if let color { body["color"] = .string(color) }
        if let measure { body["measure"] = Self.measure(measure) }
        if !milestones.isEmpty { body["milestones"] = Self.milestones(milestones) }
        return body
    }

    /// `measure`: unit, start, target, and now.
    static func measure(_ measure: GoalMeasure) -> JSONValue {
        .object(["unit": .string(measure.unit), "start": .number(measure.start), "target": .number(measure.target),
                 "now": .number(measure.now)])
    }

    /// The whole list in order. A milestone made here (a local id) goes without one: the gateway gives it one.
    static func milestones(_ list: [GoalMilestone]) -> JSONValue {
        .array(list.map { milestone in
            var object: [String: JSONValue] = ["title": .string(milestone.title), "due": TodoWire.optional(milestone.due),
                                               "done": .bool(milestone.done)]
            if !TodoIDs.isLocal(milestone.id) { object["id"] = .string(milestone.id) }
            return .object(object)
        })
    }

    /// `goal` with `fields` applied as the gateway applies a PATCH: `measure_now` moves the number (stamped, added to
    /// its history), a milestone keeps its `done_at` unless its tick changed, a status change is stamped.
    static func applying(_ fields: [String: JSONValue], to goal: Goal, now: Date = Date()) -> Goal {
        var out = goal
        let stamp = TodoDates.now(now)
        for (key, value) in fields {
            switch key {
            case "title": out.title = value.string ?? out.title
            case "why": out.why = value.string ?? ""
            case "color": out.color = value.string
            case "position": out.position = value.double ?? out.position
            case "due": out.due = value.string.flatMap { $0.isEmpty ? nil : $0 }
            case "status":
                if let status = value.string, status != out.status { out.status = status; out.statusAt = stamp }
            case "measure":
                if let data = try? value.encoded(), let measure = try? JSONDecoder().decode(GoalMeasure.self, from: data),
                   case .object(let object) = value {
                    var next = measure
                    next.source = "you"
                    next.history = out.measure?.history ?? []
                    next.at = out.measure?.at
                    if object["now"] == nil { next.now = out.measure?.now ?? measure.start }
                    if next.now != out.measure?.now { next.at = stamp; next.history = Array((next.history + [GoalReading(at: stamp, value: next.now)]).suffix(60)) }
                    out.measure = next
                } else {
                    out.measure = nil
                }
            case "measure_now":
                if let number = value.double, var measure = out.measure {
                    if number != measure.now {
                        measure.now = number
                        measure.at = stamp
                        measure.history = Array((measure.history + [GoalReading(at: stamp, value: number)]).suffix(60))
                    }
                    out.measure = measure
                }
            case "milestones":
                guard case .array(let list) = value else { continue }
                let before = Dictionary(out.milestones.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                out.milestones = list.prefix(30).compactMap { item in
                    guard case .object(let object) = item else { return nil }
                    let title = object["title"]?.string ?? ""
                    let id = object["id"]?.string ?? TodoIDs.local()
                    let done = object["done"]?.bool ?? false
                    let was = before[id]
                    let doneAt = was?.done == done ? was?.doneAt : (done ? stamp : nil)
                    return GoalMilestone(id: id, title: String(title.prefix(120)), due: object["due"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                                         done: done, doneAt: doneAt)
                }
            default: continue
            }
        }
        out.updatedAt = stamp
        return out
    }

    /// One field's value on `goal`, to tell whether another edit touched it (a 409). `measure_now` is the number.
    static func value(_ key: String, of goal: Goal) -> JSONValue {
        if key == "measure_now" { return goal.measure.map { .number($0.now) } ?? .null }
        guard case .object(let object)? = try? JSONValue.parse(JSONEncoder().encode(goal)) else { return .null }
        return object[key] ?? .null
    }

    /// A PATCH came back 409 with the `current` goal: sent again on its rev when the other edit left these fields
    /// alone, else the current goal stands (as a task's edits do, `TodoEdits.resolve`).
    static func resolve(base: Goal, current: Goal, fields: [String: JSONValue]) -> TodoEdits.Resolution {
        for key in fields.keys where key != "rev" {
            if value(key, of: base) != value(key, of: current) { return .theirs }
        }
        return .resend(rev: current.rev)
    }
}
