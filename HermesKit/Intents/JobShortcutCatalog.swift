// [shortcuts] The jobs the Shortcuts app's Run Job action offers (owner 2026-11-20 picked Run a Job from the shortcut
// ideas): the Jobs list as the app last read it, stored in the app's own defaults so the system's pickers read it off
// the main thread with no app model. Names, ids and owners only, never a prompt or a result.

import Foundation

nonisolated struct JobShortcutRecord: Codable, Equatable, Sendable {
    /// `<owner>|<id>` (`CronJob.key`).
    let key: String
    let id: String
    let owner: String
    let name: String
    /// `url + "\n" + username` (`VoiceBotCatalog.account`).
    let account: String
}

nonisolated enum JobShortcutCatalog {
    static let storeKey = "hq.intents.jobs"
    static let maxJobs = 512

    static func jobs(_ defaults: UserDefaults = .standard) -> [JobShortcutRecord] {
        guard let data = defaults.data(forKey: storeKey), data.count <= 1024 * 1024,
              let records = try? JSONDecoder().decode([JobShortcutRecord].self, from: data) else { return [] }
        return Array(records.prefix(maxJobs))
    }

    /// `named`: each job's title as the Jobs list shows it.
    static func records(_ jobs: [(job: CronJob, name: String)], account: String) -> [JobShortcutRecord] {
        var seen = Set<String>()
        return jobs.compactMap { item in
            let name = VoiceBotCatalog.clean(item.name)
            guard !item.job.id.isEmpty, !name.isEmpty, seen.insert(item.job.key).inserted else { return nil }
            return JobShortcutRecord(key: item.job.key, id: item.job.id, owner: item.job.owner, name: name, account: account)
        }
    }

    /// Writes only when the bytes differ. Returns whether it wrote.
    @discardableResult static func store(_ records: [JobShortcutRecord], _ defaults: UserDefaults = .standard) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(records.prefix(maxJobs))) else { return false }
        if defaults.data(forKey: storeKey) == data { return false }
        defaults.set(data, forKey: storeKey)
        return true
    }

    static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: storeKey) }

    /// What a run's shortcut hands to its next step: the newest run's words (its preview, else its title), or a line
    /// saying where the result went when the run left none to read.
    static func resultText(runs: [CronRun], startedAfter: Double?, job: String) -> String {
        let fresh = runs.filter { run in startedAfter.map { (run.startedAt ?? run.lastActive ?? 0) >= $0 - 5 } ?? true }
        let newest = fresh.max { ($0.startedAt ?? $0.lastActive ?? 0) < ($1.startedAt ?? $1.lastActive ?? 0) }
        let words = [newest?.preview, newest?.title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return words ?? "“\(job)” ran. Its result is in the job’s Run History in Hermes HQ."
    }
}
