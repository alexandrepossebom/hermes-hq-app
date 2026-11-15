// [offline] The process half of the stale work check (docs/spec/3x-offline.md §6.6), from the web app's
// `src/stale-work-check.ts`. A chat that claims a running background process hears of its end only on the socket it
// was bound to; a phone that was away never does. `agents.list` (every background process, gated by no chat binding)
// says which are still running; a claim it no longer lists is dropped.

import Foundation

/// A background process a chat says is running (or was: finished rows linger for a moment).
nonisolated struct ProcessClaim: Hashable, Sendable {
    var id: String
    var running: Bool
}

nonisolated enum StaleWork {
    /// The ids `agents.list` reports as running; nil when the answer has no `processes` list (nothing can be said).
    static func runningProcesses(_ answer: JSONValue?) -> Set<String>? {
        guard case .array(let rows)? = answer?["processes"] else { return nil }
        var running = Set<String>()
        for row in rows where row["status"]?.string == "running" {
            if let id = row["session_id"]?.string, !id.isEmpty { running.insert(id) }
        }
        return running
    }

    /// The claims less the running ones the gateway no longer has; nil when nothing changes. A finished row is kept.
    static func dropProcesses(claims: [ProcessClaim], running: Set<String>) -> [ProcessClaim]? {
        guard claims.contains(where: { $0.running && !running.contains($0.id) }) else { return nil }
        return claims.filter { !$0.running || running.contains($0.id) }
    }

    static func claimsRunning(_ claims: [ProcessClaim]) -> Bool { claims.contains(where: \.running) }

    /// [background] The stored chats `subagent.roster` says still hold a background process (`background` > 0); nil when
    /// the answer has no `sessions` list (nothing can be said). The shared gateway answers `agents.list` with -32601, so
    /// this is how a chat left behind learns its command ended.
    static func backgroundSessions(_ answer: JSONValue?) -> Set<String>? {
        guard case .array(let rows)? = answer?["sessions"] else { return nil }
        var out = Set<String>()
        for row in rows {
            guard let id = row["session_id"]?.string, !id.isEmpty, case .number(let n)? = row["background"], n > 0 else { continue }
            out.insert(id)
        }
        return out
    }
}
