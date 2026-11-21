// [tile-models] Which model updates the tiles (owner 2026-11-18: "a way to set a default and fallback model for running
// all the tasks inside a tile … a global setting and then an individual override").
//
// A tile is kept fresh by a cron job (`TileJobs.match`). Hermes picks a run's model as: the job's own pin (`model` +
// `provider`) > `cron.model` > the bot's main model. An unpinned job follows its bot and walks the bot's fallback chain; a
// pinned job falls back to nothing, unless the job carries its own `fallback_providers` (a Hermes still adding it stores
// the field and ignores it).
//
// Settings › Tile Model sets, per gateway account, a Default model (none: each bot's own) and a Fallback model (none:
// each bot's own). A tile's Updates › Model sets an override for that tile's job. `TileModels.desired` turns those into
// the one change the job needs, or none; the app remembers each pin it applied (`TileModelSettings.applied`), so it only
// ever takes back its own pins, never one set by hand, by the bot, or on the Jobs page.

import Foundation

/// A provider and model, as the settings keep them and `fallback_providers` lists them.
nonisolated struct TileModelPick: Hashable, Sendable, Codable {
    var provider: String
    var model: String

    init(provider: String, model: String) {
        self.provider = provider.trimmingCharacters(in: .whitespaces)
        self.model = model.trimmingCharacters(in: .whitespaces)
    }

    /// The same model: a missing provider on either side matches any (a hand pin may name the model alone).
    func same(_ other: TileModelPick) -> Bool {
        guard model == other.model else { return false }
        return provider.isEmpty || other.provider.isEmpty || provider.lowercased() == other.provider.lowercased()
    }

    var json: JSONValue { ["provider": .string(provider), "model": .string(model)] }

    /// As UserDefaults keeps it (a plain dictionary, so settings sync carries it).
    var stored: [String: String] { ["provider": provider, "model": model] }

    init?(stored: Any?) {
        guard let dictionary = stored as? [String: Any], let model = dictionary["model"] as? String,
              !model.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        self.init(provider: dictionary["provider"] as? String ?? "", model: model)
    }

    /// `fallback_providers` as a job carries it: `[{provider, model}]` (a bare "provider:model" string read too).
    static func list(_ value: JSONValue?) -> [TileModelPick]? {
        guard let rows = value?.array else { return nil }
        return rows.compactMap { item in
            if let text = item.string {
                let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
                return parts.count == 2 ? TileModelPick(provider: parts[0], model: parts[1]) : TileModelPick(provider: "", model: text)
            }
            guard let model = item["model"]?.string, !model.isEmpty else { return nil }
            return TileModelPick(provider: item["provider"]?.string ?? "", model: model)
        }
    }
}

/// What the app last wrote to a job: its pin, and the fallback it sent with it (nil: none sent).
nonisolated struct TileModelApplied: Hashable, Sendable {
    var pin: TileModelPick
    var fallback: TileModelPick?

    var stored: [String: Any] {
        var out: [String: Any] = ["provider": pin.provider, "model": pin.model]
        if let fallback { out["fallback"] = fallback.stored }
        return out
    }

    init(pin: TileModelPick, fallback: TileModelPick?) {
        self.pin = pin
        self.fallback = fallback
    }

    init?(stored: Any?) {
        guard let pin = TileModelPick(stored: stored) else { return nil }
        self.pin = pin
        fallback = TileModelPick(stored: (stored as? [String: Any])?["fallback"])
    }
}

nonisolated enum TileModels {
    /// The one write a job needs to run the model the settings ask for.
    struct Plan: Equatable, Sendable {
        /// The pin to set; nil takes the job's pin away (it follows its bot again).
        var pin: TileModelPick?
        enum Fallback: Equatable, Sendable {
            /// The field isn't sent.
            case leave
            /// `fallback_providers: [{provider, model}]`.
            case set(TileModelPick)
            /// `fallback_providers: null`: the one the app sent before is taken back.
            case clear
        }
        var fallback: Fallback
        /// What the app remembers about the job once the write goes through (nil: nothing, it's no pin of the app's).
        var record: TileModelApplied?

        /// The `updates` of `PUT /api/cron/jobs/<id>`.
        var updates: JSONValue {
            var out: [String: JSONValue] = [:]
            if let pin {
                out["model"] = .string(pin.model)
                out["provider"] = pin.provider.isEmpty ? .null : .string(pin.provider)
            } else {
                out["model"] = .null
                out["provider"] = .null
            }
            switch fallback {
            case .leave: break
            case .set(let pick): out["fallback_providers"] = .array([pick.json])
            case .clear: out["fallback_providers"] = .null
            }
            return .object(out)
        }
    }

    /// A job that runs a script and no model (`no_agent`, or a script and no prompt): never touched.
    static func isScriptOnly(_ job: CronJob) -> Bool {
        job.noAgent || ((job.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(job.script ?? "").isEmpty)
    }

    /// The job's own pin, nil when it follows its bot.
    static func pin(of job: CronJob) -> TileModelPick? {
        guard let model = job.model?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
        return TileModelPick(provider: job.provider ?? "", model: model)
    }

    /// The pin on the job is one the app put there (and nobody changed since).
    static func isAppPin(_ job: CronJob, applied: TileModelApplied?) -> Bool {
        guard let pin = pin(of: job), let applied else { return false }
        return pin.same(applied.pin)
    }

    /// The change `job` needs, or nil when it needs none (or isn't the app's to change).
    /// - `override`: this tile's own model. `default`/`fallback`: the account's Tile Model settings (nil: each bot's own).
    /// - `applied`: what the app last wrote to this job.
    static func desired(_ job: CronJob, override: TileModelPick?, default chosen: TileModelPick?, fallback: TileModelPick?,
                        applied: TileModelApplied?) -> Plan? {
        if isScriptOnly(job) { return nil }
        let current = pin(of: job)
        let appPin = isAppPin(job, applied: applied)
        // A pin set somewhere else (by hand, by the bot, on the Jobs page, or changed there since the app's) is kept,
        // unless this tile has its own model: then the owner chose for this tile.
        if override == nil, current != nil, !appPin { return nil }
        let target = override ?? chosen
        guard let target else {
            // Each bot's own: only the app's own pin is taken back.
            guard current != nil, appPin else { return nil }
            let clear = applied?.fallback != nil && sentFallbackStands(job, applied: applied)
            return Plan(pin: nil, fallback: clear ? .clear : .leave, record: nil)
        }
        let pinMatches = current.map { $0.same(target) } ?? false
        var plan = Plan(pin: target, fallback: .leave, record: TileModelApplied(pin: target, fallback: nil))
        if let fallback {
            plan.fallback = .set(fallback)
            plan.record?.fallback = fallback
            if pinMatches, fallbackMatches(job, fallback, applied: appPin ? applied : nil) { return nil }
            return plan
        }
        // Each bot's own fallback: no field, but the one the app sent earlier goes.
        if appPin, applied?.fallback != nil, sentFallbackStands(job, applied: applied) {
            plan.fallback = .clear
            return plan
        }
        return pinMatches ? nil : plan
    }

    /// The job already carries `fallback` as its one fallback. A job that doesn't say (an older Hermes's list, or none set)
    /// matches when the app's own record says it sent it.
    private static func fallbackMatches(_ job: CronJob, _ fallback: TileModelPick, applied: TileModelApplied?) -> Bool {
        if let carried = job.fallbackProviders {
            return carried.count == 1 && carried[0].same(fallback)
        }
        return applied?.fallback.map { $0.same(fallback) } ?? false
    }

    /// The fallback the app sent is still on the job (or the job doesn't say, and the app's record has one).
    private static func sentFallbackStands(_ job: CronJob, applied: TileModelApplied?) -> Bool {
        guard let sent = applied?.fallback else { return false }
        guard let carried = job.fallbackProviders else { return true }
        return carried.contains { $0.same(sent) }
    }

    // MARK: Words

    /// The model's name: the owner's for it under its provider (Settings › Providers), else the usual one.
    static func name(_ pick: TileModelPick) -> String {
        pick.provider.isEmpty ? ModelNames.displayModelName(pick.model) : ModelNames.displayModelName(pick.model, provider: pick.provider)
    }

    /// The model that runs the job, by name: its pin's, else its bot's (`botModel`, nil when unknown).
    static func runningName(_ job: CronJob, botModel: String?) -> String? {
        if isScriptOnly(job) { return nil }
        if let pin = pin(of: job) { return name(pin) }
        guard let botModel, !botModel.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return botModel
    }

    /// The Updates submenu's line: "Updated 5 min ago · hourly · GPT-6.2 Astra" (the status alone for a script, or a
    /// model whose name is unknown).
    static func updatesSubtitle(_ job: CronJob, botModel: String?, now: Date = Date()) -> String {
        let status = TileJobs.status(job, now: now)
        guard let name = runningName(job, botModel: botModel) else { return status }
        return status + " · " + name
    }

    /// The Model submenu's line, what runs it now: "Sonnet 5", "Opus 5.5 · Otto’s model", "Otto’s own model".
    static func modelSubtitle(_ job: CronJob, botName: String, botModel: String?) -> String {
        if isScriptOnly(job) { return "A script, no model" }
        if let pin = pin(of: job) { return name(pin) }
        if let botModel, !botModel.isEmpty { return "\(botModel) · \(botName)’s model" }
        return "\(botName)’s own model"
    }

    /// "Use Tile Default (Sonnet 5)", "Use Tile Default (Opus 5.5)" (the bot's own), "Use Tile Default (Otto’s Model)".
    static func useDefaultTitle(default chosen: TileModelPick?, botName: String, botModel: String?) -> String {
        if let chosen { return "Use Tile Default (\(name(chosen)))" }
        if let botModel, !botModel.isEmpty { return "Use Tile Default (\(botModel))" }
        return "Use Tile Default (\(botName)’s Model)"
    }

    /// The short list under it: the account's starred models, then recent ones, then (when those are none) the catalog's
    /// first few; the tile's own pick always listed. At most `limit`, each once.
    static func shortList(favorites: [String], recents: [TileModelPick], catalog: [TileModelPick], keep: TileModelPick?,
                          limit: Int = 6) -> [TileModelPick] {
        var out: [TileModelPick] = []
        func add(_ pick: TileModelPick) {
            guard !pick.model.isEmpty,
                  !out.contains(where: { $0.model == pick.model && $0.provider.lowercased() == pick.provider.lowercased() }) else { return }
            out.append(pick)
        }
        if let keep { add(keep) }
        for key in favorites {
            let parts = key.components(separatedBy: "::")
            guard parts.count == 2 else { continue }
            add(TileModelPick(provider: parts[0], model: parts[1]))
        }
        for pick in recents { add(pick) }
        if out.count <= (keep == nil ? 0 : 1) { for pick in catalog { add(pick) } }
        return Array(out.prefix(limit))
    }

    // MARK: Settings words

    static let eachBotsModel = "Each Bot’s Own Model"
    static let eachBotsFallback = "Each Bot’s Own Fallback"
    /// Under Default Model: the tiles' model is apart from the model a bot chats with.
    static let defaultFooter = "Separate from your bots’ chat model. A cheaper, faster model usually handles tile updates well."

    static func defaultValue(_ chosen: TileModelPick?) -> String { chosen.map(name) ?? eachBotsModel }
    static func fallbackValue(_ chosen: TileModelPick?) -> String { chosen.map(name) ?? eachBotsFallback }

    /// How a change of Settings › Tile Model went on the tiles: "2 tiles now run it.", "Couldn’t change 1 tile: …".
    static func appliedWords(changed: Int, failed: [String]) -> String {
        if let first = failed.first {
            let count = failed.count == 1 ? "1 tile" : "\(failed.count) tiles"
            let done = changed == 0 ? "" : " \(changed == 1 ? "1 other tile was" : "\(changed) other tiles were") changed."
            return "Couldn’t change \(count): \(first)\(done)"
        }
        switch changed {
        case 0: return "No tile’s job needed a change."
        case 1: return "1 tile’s job changed."
        default: return "\(changed) tiles’ jobs changed."
        }
    }

    /// The Tile Model page's footer, honest about what a Hermes without per-job fallbacks does.
    static func footer(default chosen: TileModelPick?, fallback: TileModelPick?) -> String {
        var lines: [String] = []
        if chosen == nil {
            lines.append("Each tile’s job runs its bot’s own model and falls back as that bot does. A tile’s own model (hold the tile › Updates › Model) still wins.")
        } else {
            lines.append("Tiles run this model unless a tile has its own (hold the tile › Updates › Model). A model set on a job by hand or by its bot is kept.")
        }
        if fallback != nil, chosen == nil {
            lines.append("This fallback goes only with a picked model: a tile given its own model falls back to it. Tiles on their bot’s own model use that bot’s fallbacks.")
        }
        if fallback != nil {
            lines.append("The fallback goes with a picked model. Until your gateway’s Hermes can carry a fallback for each job, a tile on a picked model won’t fall back: if its model fails, the update fails.")
        } else if chosen != nil {
            lines.append("A tile on a picked model doesn’t use its bot’s fallbacks: if its model fails, the update fails. Pick a fallback to add one.")
        }
        return lines.joined(separator: "\n\n")
    }
}

/// [tile-models] Settings › Tile Model and the tiles' own models, per gateway account, in UserDefaults (so settings sync
/// carries them to the owner's other devices: `SyncedSettingKeys.accountPrefixes` lists "hq.tileModels.").
nonisolated struct TileModelSettings {
    static let prefix = "hq.tileModels."
    let accountId: String
    let defaults: UserDefaults

    init(accountId: String, defaults: UserDefaults = .standard) {
        self.accountId = accountId
        self.defaults = defaults
    }

    static func key(_ name: String, accountId: String) -> String { "\(prefix)\(name)|\(accountId)" }
    private func key(_ name: String) -> String { Self.key(name, accountId: accountId) }

    /// Settings › Tile Model › Default model (nil: each bot's own).
    var defaultModel: TileModelPick? {
        get { TileModelPick(stored: defaults.dictionary(forKey: key("default"))) }
        nonmutating set { write(newValue?.stored, "default") }
    }

    /// Settings › Tile Model › Fallback model (nil: each bot's own).
    var fallbackModel: TileModelPick? {
        get { TileModelPick(stored: defaults.dictionary(forKey: key("fallback"))) }
        nonmutating set { write(newValue?.stored, "fallback") }
    }

    /// Each tile's own model, by its job's key (`<profile>|<id>`).
    func override(_ jobKey: String) -> TileModelPick? {
        TileModelPick(stored: defaults.dictionary(forKey: key("overrides"))?[jobKey])
    }

    func setOverride(_ pick: TileModelPick?, for jobKey: String) {
        var all = defaults.dictionary(forKey: key("overrides")) ?? [:]
        all[jobKey] = pick?.stored
        write(all.isEmpty ? nil : all, "overrides")
    }

    /// The pins the app applied, by job key.
    func applied(_ jobKey: String) -> TileModelApplied? {
        TileModelApplied(stored: defaults.dictionary(forKey: key("applied"))?[jobKey])
    }

    func setApplied(_ record: TileModelApplied?, for jobKey: String) {
        var all = defaults.dictionary(forKey: key("applied")) ?? [:]
        all[jobKey] = record?.stored
        write(all.isEmpty ? nil : all, "applied")
    }

    /// The change `job` needs under these settings (`TileModels.desired`).
    func plan(_ job: CronJob) -> TileModels.Plan? {
        TileModels.desired(job, override: override(job.key), default: defaultModel, fallback: fallbackModel, applied: applied(job.key))
    }

    /// After the write went through: what the app now owns on the job.
    func wrote(_ plan: TileModels.Plan, to jobKey: String) { setApplied(plan.record, for: jobKey) }

    private func write(_ value: Any?, _ name: String) {
        if let value { defaults.set(value, forKey: key(name)) } else { defaults.removeObject(forKey: key(name)) }
    }
}
