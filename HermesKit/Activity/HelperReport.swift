import Foundation

/// Ownership hints retained before hydration removes the async envelope and batch headings. Never infer ownership
/// from the report's prose, task count, or a shortened display title.
nonisolated struct HelperReport: Hashable, Sendable {
    struct Task: Hashable, Sendable {
        var goal: String
        var status: SubagentStatus
    }
    var delegationID: String?
    var tasks: [Task]

    static func parse(_ content: String) -> HelperReport? {
        guard content.hasPrefix("[ASYNC DELEGATION") else { return nil }
        let id = delegation.groups(content)?[1]
        var tasks: [Task] = []
        if content.hasPrefix("[ASYNC DELEGATION BATCH") {
            for header in batch.allMatches(content) {
                guard let parts = batch.groups(header), let goal = parts[1], let state = parts[2] else { continue }
                tasks.append(Task(goal: goal, status: status(state)))
            }
        } else if let goal = goal.groups(content)?[1] {
            tasks.append(Task(goal: goal, status: status(state.groups(content)?[1] ?? "completed")))
        }
        guard !tasks.isEmpty || id != nil else { return nil }
        return HelperReport(delegationID: id, tasks: Array(tasks.prefix(16)))
    }

    private static func status(_ value: String) -> SubagentStatus {
        switch value.lowercased() {
        case "completed", "ok", "success": return .completed
        case "failed", "error", "rejected", "timeout", "timed_out", "stalled": return .failed
        case "cancelled", "interrupted", "incomplete": return .interrupted
        default: return .dispatched
        }
    }
    private static let delegation = TRx(#"^\[ASYNC DELEGATION[^\]\n]*[—–-]\s*(deleg_[A-Za-z0-9_-]+)\]"#)
    /// The status is its first word: the gateway follows it with the call count and duration
    /// (`(status=completed, api_calls=34, 1192.42s)`), and a cut-short run adds a TRUNCATED note.
    private static let batch = TRx(#"(?m)^--- [✓✗⚠] TASK \d+/\d+: (.+?) {2}\(status=([A-Za-z_]+)[^\n]*\) ---\r?$"#)
    private static let goal = TRx(#"(?m)^Original goal: *(.+?)\r?$"#)
    private static let state = TRx(#"(?m)^Status: *([A-Za-z_]+)"#)

    var json: JSONValue {
        .object(["delegation": delegationID.map(JSONValue.string) ?? .null,
                 "tasks": .array(tasks.map { .object(["goal": .string($0.goal), "status": .string($0.status.rawValue)]) })])
    }
    init(delegationID: String?, tasks: [Task]) { self.delegationID = delegationID; self.tasks = tasks }
    init?(json: JSONValue?) {
        guard let object = json?.looseObject else { return nil }
        delegationID = object["delegation"]?.nonEmptyString
        tasks = (object["tasks"]?.array ?? []).prefix(16).compactMap { value in
            guard let fields = value.looseObject, let goal = fields["goal"]?.string,
                  let raw = fields["status"]?.string, let status = SubagentStatus(rawValue: raw) else { return nil }
            return Task(goal: goal, status: status)
        }
    }
}
