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

/// [goals step 3] Who reads the goal's number (hermes-hq-push 0.9.66): you, or one bot and what it reads ("TestFlight
/// public testers"). On the wire `"you"` or `{bot, what}`; anything else reads as you.
nonisolated enum GoalSource: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    case you
    case bot(String, what: String)

    init(stringLiteral value: String) { self = .you }

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(JSONValue.self), case .object(let object) = value,
           let bot = object["bot"]?.string, !bot.isEmpty {
            self = .bot(bot, what: object["what"]?.string ?? "")
        } else {
            self = .you
        }
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        try single.encode(json)
    }

    var json: JSONValue {
        switch self {
        case .you: return .string("you")
        case .bot(let bot, let what): return .object(["bot": .string(bot), "what": .string(what)])
        }
    }

    /// The bot that reads it; nil when it is you.
    var bot: String? { if case .bot(let bot, _) = self { return bot } else { return nil } }
    /// What the bot reads ("TestFlight public testers"); "" for you.
    var what: String { if case .bot(_, let what) = self { return what } else { return "" } }
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
    /// You, or the bot that reads it (0.9.66; an older add-on always says "you").
    var source: GoalSource
    /// [goals step 4] When its bot last looked, moved or not (0.9.66); cleared by a new source.
    var checkedAt: String?
    /// Every change of `now`, newest last, 60 at most.
    var history: [GoalReading]

    enum CodingKeys: String, CodingKey { case unit, start, target, now, at, source, history, checkedAt = "checked_at" }

    init(unit: String = "", start: Double = 0, target: Double, now: Double? = nil, at: String? = nil, source: GoalSource = .you,
         checkedAt: String? = nil, history: [GoalReading] = []) {
        self.unit = unit; self.start = start; self.target = target; self.now = now ?? start; self.at = at
        self.source = source; self.checkedAt = checkedAt; self.history = history
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) ?? ""
        start = (try? c.decodeIfPresent(Double.self, forKey: .start)) ?? 0
        target = (try? c.decodeIfPresent(Double.self, forKey: .target)) ?? 0
        now = (try? c.decodeIfPresent(Double.self, forKey: .now)) ?? start
        at = (try? c.decodeIfPresent(String.self, forKey: .at)).flatMap { $0?.isEmpty == true ? nil : $0 }
        source = (try? c.decodeIfPresent(GoalSource.self, forKey: .source)) ?? .you
        checkedAt = (try? c.decodeIfPresent(String.self, forKey: .checkedAt)).flatMap { $0?.isEmpty == true ? nil : $0 }
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
    // [goals step 3] A bot on a goal (hermes-hq-push 0.9.66; an older add-on sends none of these, read as no bot).
    /// The bot that plans it, checks in and keeps its page (a profile), or nil.
    var lead: String?
    /// Bots that take its tasks (never the lead), 5 at most.
    var helpers: [String]
    /// New Tasks: "ask" (a card, the default) or "auto" (its lead and helpers add a task for you without one).
    var adds: String
    /// The weekly check-in, or nil (off).
    var review: GoalReview?
    /// Tell My Other Bots: every bot knows its name and why.
    var knownToAll: Bool
    /// The lead's "where it stands".
    var stands: GoalStands?
    /// The last check-in.
    var checkin: GoalCheckin?
    /// The goal's own chat (hidden from Sessions), once its first message made it.
    var chat: TodoChat?
    /// When its lead last wrote on its Goal Page; nil until then.
    var pageAt: String?
    /// [goals step 4] The stall question was answered Keep Going.
    var keptAt: String?
    /// The lead's "this looks done" (a milestone or the goal), answered Mark Done / Not Yet.
    var offer: GoalDoneOffer?

    enum CodingKeys: String, CodingKey {
        case id, rev, title, why, status, color, due, position, measure, milestones, log
        case statusAt = "status_at", createdAt = "created_at", updatedAt = "updated_at"
        case lead, helpers, adds, review, stands, checkin, chat, offer
        case knownToAll = "known_to_all", pageAt = "page_at", keptAt = "kept_at"
    }

    init(id: String, rev: Int = 1, title: String, why: String = "", status: GoalState = .active, statusAt: String? = nil,
         color: String? = "blue", due: String? = nil, position: Double = 0, measure: GoalMeasure? = nil,
         milestones: [GoalMilestone] = [], createdAt: String? = nil, updatedAt: String? = nil, log: [TodoLogEntry] = []) {
        self.id = id; self.rev = rev; self.title = title; self.why = why; self.status = status.rawValue
        self.statusAt = statusAt; self.color = color; self.due = due; self.position = position; self.measure = measure
        self.milestones = milestones; self.createdAt = createdAt; self.updatedAt = updatedAt; self.log = log
        self.lead = nil; self.helpers = []; self.adds = "ask"; self.review = nil; self.knownToAll = true; self.stands = nil
        self.checkin = nil; self.chat = nil; self.pageAt = nil; self.keptAt = nil; self.offer = nil
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
        func text(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0?.isEmpty == true ? nil : $0 } }
        let leadName = text(.lead)
        lead = leadName
        helpers = ((try? c.decodeIfPresent([String].self, forKey: .helpers)) ?? nil)?.filter { !$0.isEmpty && $0 != leadName } ?? []
        adds = text(.adds) == "auto" ? "auto" : "ask"
        review = (try? c.decodeIfPresent(GoalReview.self, forKey: .review)).flatMap { $0 }
        knownToAll = ((try? c.decodeIfPresent(Bool.self, forKey: .knownToAll)) ?? nil) ?? true
        stands = (try? c.decodeIfPresent(GoalStands.self, forKey: .stands)).flatMap { $0 }
        checkin = (try? c.decodeIfPresent(GoalCheckin.self, forKey: .checkin)).flatMap { $0 }
        chat = (try? c.decodeIfPresent(TodoChat.self, forKey: .chat)).flatMap { $0 }   // `{}` reads as none
        pageAt = text(.pageAt)
        keptAt = text(.keptAt)
        offer = (try? c.decodeIfPresent(GoalDoneOffer.self, forKey: .offer)).flatMap { $0 }
    }

    /// Its status as the app reads it (an unknown one is active).
    var state: GoalState { GoalState(rawValue: status) ?? .active }
    /// Its colour (an unknown or missing one is blue).
    var tint: TodoListColor { color.flatMap(TodoListColor.init(rawValue:)) ?? .blue }
    /// Its place among the goals: its position, or when it was added on an add-on that sent none.
    var order: Double { position != 0 ? position : (TodoDates.moment(createdAt)?.timeIntervalSince1970 ?? 0) }

    func milestone(_ id: String?) -> GoalMilestone? { id.flatMap { id in milestones.first { $0.id == id } } }
    /// [goals step 3] The lead first, then the helpers.
    var team: [String] { (lead.map { [$0] } ?? []) + helpers.filter { $0 != lead } }
}

/// [goals step 4] The weekly check-in's slot: a weekday (0 = Monday) and a time ("08:00"), in the gateway's own time.
nonisolated struct GoalReview: Codable, Hashable, Sendable {
    var day: Int
    var time: String

    init(day: Int = 0, time: String = "08:00") { self.day = day; self.time = time }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let day = try c.decode(Int.self, forKey: .day)
        let time = try c.decode(String.self, forKey: .time)
        guard (0...6).contains(day), time.wholeMatch(of: /\d{1,2}:\d{2}/) != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "no slot"))
        }
        self.day = day; self.time = time
    }

    var json: JSONValue { .object(["day": .number(Double(day)), "time": .string(time)]) }
}

/// [goals step 3] The lead's "where it stands": its words and what is next.
nonisolated struct GoalStands: Codable, Hashable, Sendable {
    var by: String
    var at: String?
    var text: String
    var next: String

    init(by: String, at: String? = nil, text: String, next: String = "") { self.by = by; self.at = at; self.text = text; self.next = next }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        by = (try? c.decodeIfPresent(String.self, forKey: .by)).flatMap { $0 } ?? "default"
        at = try? c.decodeIfPresent(String.self, forKey: .at)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)).flatMap { $0 } ?? ""
        next = (try? c.decodeIfPresent(String.self, forKey: .next)).flatMap { $0 } ?? ""
    }
}

/// [goals step 4] The last check-in: when, its offer, and what became of it.
nonisolated struct GoalCheckin: Codable, Hashable, Sendable {
    var at: String?
    var offer: String?
    /// "offered" | "accepted" | "declined" | "none" (handed to the lead, no card yet).
    var state: String

    init(at: String? = nil, offer: String? = nil, state: String = "offered") { self.at = at; self.offer = offer; self.state = state }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try? c.decodeIfPresent(String.self, forKey: .at)
        offer = (try? c.decodeIfPresent(String.self, forKey: .offer)).flatMap { $0 }
        state = (try? c.decodeIfPresent(String.self, forKey: .state)).flatMap { $0 } ?? "none"
    }
}

/// [goals step 4] The lead says a milestone, or the goal, looks done (`goals_update looks_done`). You answer Mark Done or
/// Not Yet (`PATCH offer_answer`); after Not Yet it stays on the goal with `kept`.
nonisolated struct GoalDoneOffer: Codable, Hashable, Sendable {
    var kind: String
    /// A milestone's id, or "goal".
    var what: String
    var by: String
    var text: String
    var at: String?
    var kept: Bool
    var keptAt: String?

    enum CodingKeys: String, CodingKey { case kind, what, by, text, at, kept, keptAt = "kept_at" }

    init(what: String, by: String, text: String, at: String? = nil, kept: Bool = false, keptAt: String? = nil) {
        kind = "done"; self.what = what; self.by = by; self.text = text; self.at = at; self.kept = kept; self.keptAt = keptAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0 } ?? "done"
        what = try c.decode(String.self, forKey: .what)
        by = (try? c.decodeIfPresent(String.self, forKey: .by)).flatMap { $0 } ?? "default"
        text = (try? c.decodeIfPresent(String.self, forKey: .text)).flatMap { $0 } ?? ""
        at = try? c.decodeIfPresent(String.self, forKey: .at)
        kept = ((try? c.decodeIfPresent(Bool.self, forKey: .kept)) ?? nil) ?? false
        keptAt = try? c.decodeIfPresent(String.self, forKey: .keptAt)
    }
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
    /// [goals steps 3-5] The team fields POST /goals leaves out (the add-on's GoalIn has none of them): `addGoal`
    /// sends them in a PATCH once the goal is made.
    static let teamKeys: Set<String> = ["lead", "helpers", "adds", "review", "known_to_all", "chat"]

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
                // As the gateway merges it: a key left out keeps its value, `source` alone changes only who reads it
                // (and clears when it last looked), and `now` moving is stamped and added to the history.
                guard case .object(let object) = value else { out.measure = nil; continue }
                let old = out.measure
                guard let target = object["target"]?.double ?? old?.target else { continue }
                let start = object["start"]?.double ?? old?.start ?? 0
                var next = GoalMeasure(unit: object["unit"]?.string ?? old?.unit ?? "", start: start, target: target,
                                       now: object["now"]?.double ?? old?.now ?? start, at: old?.at, source: old?.source ?? .you,
                                       checkedAt: old?.checkedAt, history: old?.history ?? [])
                if let raw = object["source"], raw != .null,
                   let source = (try? raw.encoded()).flatMap({ try? JSONDecoder().decode(GoalSource.self, from: $0) }) {
                    if source != next.source { next.checkedAt = nil }
                    next.source = source
                }
                if old == nil || next.now != old?.now {
                    next.at = stamp
                    next.history = Array((next.history + [GoalReading(at: stamp, value: next.now)]).suffix(60))
                }
                out.measure = next
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
            // [goals step 3] A bot on the goal (0.9.66).
            case "lead":
                let lead = value.string.flatMap { $0.isEmpty ? nil : $0 }
                if lead != out.lead {
                    if lead != nil, out.lead == nil, out.review == nil, fields["review"] == nil { out.review = GoalReview() }
                    out.lead = lead
                }
                out.helpers = out.helpers.filter { $0 != out.lead }
            case "helpers":
                guard case .array(let list) = value else { continue }
                var seen = Set<String>()
                out.helpers = list.compactMap(\.string).filter { !$0.isEmpty && $0 != (fields["lead"]?.string ?? out.lead) && seen.insert($0).inserted }
                    .prefix(5).map { $0 }
            case "adds": if let adds = value.string, adds == "ask" || adds == "auto" { out.adds = adds }
            case "review":
                out.review = (try? value.encoded()).flatMap { try? JSONDecoder().decode(GoalReview.self, from: $0) }
            case "known_to_all": if let on = value.bool { out.knownToAll = on }
            case "chat":
                if let chat = (try? value.encoded()).flatMap({ try? JSONDecoder().decode(TodoChat.self, from: $0) }) { out.chat = chat }
            case "keep": if value.bool == true { out.keptAt = stamp }
            case "offer_answer":
                guard let answer = value.string, var offer = out.offer, !offer.kept else { continue }
                if answer == "keep" {
                    offer.kept = true; offer.keptAt = stamp; out.offer = offer
                } else if answer == "done" {
                    if offer.what == "goal" {
                        if out.status != GoalState.achieved.rawValue { out.status = GoalState.achieved.rawValue; out.statusAt = stamp }
                    } else {
                        out.milestones = out.milestones.map { item in
                            var item = item
                            if item.id == offer.what, !item.done { item.done = true; item.doneAt = stamp }
                            return item
                        }
                    }
                    out.offer = nil
                }
            default: continue
            }
        }
        // The lead's looks-done goes once you ticked it yourself (or the goal is no longer active).
        if let offer = out.offer {
            let settled = offer.what == "goal" ? out.state != .active : !out.milestones.contains { $0.id == offer.what && !$0.done }
            if settled { out.offer = nil }
        }
        out.updatedAt = stamp
        return out
    }

    /// One field's value on `goal`, to tell whether another edit touched it (a 409). `measure_now` is the number.
    static func value(_ key: String, of goal: Goal) -> JSONValue {
        if key == "measure_now" { return goal.measure.map { .number($0.now) } ?? .null }
        if key == "keep" || key == "offer_answer" { return .null }   // an answer, not a field another edit could move
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
