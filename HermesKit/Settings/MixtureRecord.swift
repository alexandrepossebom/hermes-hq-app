// [moa-setup] Owner 2026-11-21: "The mixture of agents setup page needs all kinds of work. It's basically not usable."
// He had opened Settings › Providers › Mixture of Agents, which was the page every provider gets: Rename, a Show switch
// per "model" (its presets), Add Model… asking for a typed model ID, and Default Model. None of it sets Mixture of
// Agents up. That row now opens the one Mixture of Agents page (also Settings › Model › Mixture of Agents), which this
// file is the arithmetic of: the record Hermes serves at `GET /api/model/moa` and takes whole at `PUT`.
//
// What Hermes does with the record (`hermes_cli/moa_config.py`, `hermes_cli/inventory.py`):
//   - `presets` is a named map. Each preset has `reference_models` (at least one, each a provider and a model, with
//     its own `enabled`) and one `aggregator`. The aggregator is the model that answers; the references advise it.
//   - Mixture of Agents is a provider in the model menus whose models are the presets, and only while one preset is
//     `enabled` in the saved config. A preset's own `enabled` does nothing else the app shows. So there is no "on for
//     Hermes": a chat uses it by picking it as its model, and `/moa` sends one message through `default_preset`.
//   - A `PUT` keeps exactly the presets it is sent (one left out is deleted) and refuses a slot without a provider or a
//     model rather than repairing it.
//   - The default preset is served again on the top level, for older clients; `mirrored` keeps that in step.

import Foundation

nonisolated enum MixtureRecord {
    /// The provider's id in the model catalog and in `ProviderPrefs`.
    static let provider = "moa"

    /// The default preset's fields Hermes repeats on the record's top level.
    static let flatKeys = ["aggregator", "aggregator_temperature", "reference_models", "reference_temperature",
                           "reference_timeout", "degraded_reference_policy", "fanout", "enabled"]

    static func presets(_ record: JSONValue) -> [String: JSONValue] { record["presets"]?.object ?? [:] }

    static func presetNames(_ record: JSONValue) -> [String] { presets(record).keys.sorted() }

    static func defaultPreset(_ record: JSONValue) -> String {
        let names = presetNames(record)
        if let named = record["default_preset"]?.string, names.contains(named) { return named }
        return names.first ?? ""
    }

    /// Every slot of every preset has a provider and a model, and every preset a reference: the only record Hermes
    /// takes (`validate_moa_payload`).
    static func complete(_ record: JSONValue) -> Bool {
        let all = presets(record)
        return !all.isEmpty && all.values.allSatisfy { preset in
            let refs = preset["reference_models"]?.array ?? []
            return !refs.isEmpty && refs.allSatisfy(slotDone) && slotDone(preset["aggregator"])
        }
    }

    private static func slotDone(_ slot: JSONValue?) -> Bool {
        !(slot?["provider"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && !(slot?["model"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A preset is enabled unless it says otherwise (Hermes' own default).
    static func isEnabled(_ preset: JSONValue?) -> Bool { preset?["enabled"]?.bool ?? true }

    /// One preset is enabled: what puts Mixture of Agents in Hermes' model menus once the record is saved.
    static func anyEnabled(_ record: JSONValue) -> Bool { presets(record).values.contains(where: isEnabled) }

    /// The record with one preset replaced, and the top level in step when it is the default one.
    static func replacing(_ name: String, with preset: JSONValue, in record: JSONValue) -> JSONValue {
        var all = presets(record)
        all[name] = preset
        return mirrored(with(record, "presets", .object(all)))
    }

    /// The default preset's fields copied onto the top level, as Hermes serves the record.
    static func mirrored(_ record: JSONValue) -> JSONValue {
        guard var object = record.object, let preset = presets(record)[defaultPreset(record)] else { return record }
        for key in flatKeys { if let value = preset[key] { object[key] = value } }
        return .object(object)
    }

    /// Turning it on: the default preset enabled when none is, so Hermes lists it. Nil when one already is.
    static func enabling(_ record: JSONValue) -> JSONValue? {
        guard !anyEnabled(record) else { return nil }
        let name = defaultPreset(record)
        guard let preset = presets(record)[name] else { return nil }
        return replacing(name, with: with(preset, "enabled", true), in: record)
    }

    // MARK: Presets

    /// A preset's name as Hermes keeps it, from what was typed: lowercase, words joined by `_` ("Deep Research" →
    /// `deep_research`, shown again as "Deep Research"). No spaces: a chat switches to a preset with
    /// `<name> --provider moa`, and a space would end the name there.
    static func slug(_ typed: String) -> String {
        var out = ""
        for scalar in typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, !out.hasSuffix("_") {
                out.append("_")
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return String(out.prefix(40))
    }

    /// Why a typed name can't be a new preset's; nil when it can.
    static func nameProblem(_ typed: String, in record: JSONValue) -> String? {
        let name = slug(typed)
        if name.isEmpty { return typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "Use letters or numbers in the name." }
        if presets(record).keys.contains(where: { $0.lowercased() == name }) { return "There is already a preset with that name." }
        return nil
    }

    /// A new preset, a copy of `source` (its models, so the record stays one Hermes takes). Nil when the name is taken
    /// or empty, or there is nothing to copy.
    static func adding(_ typed: String, copying source: String, to record: JSONValue) -> (record: JSONValue, name: String)? {
        let name = slug(typed)
        guard !name.isEmpty, nameProblem(typed, in: record) == nil, let copy = presets(record)[source] else { return nil }
        var all = presets(record)
        all[name] = with(copy, "enabled", true)
        return (with(record, "presets", .object(all)), name)
    }

    /// The record without a preset; the default moves to the first one left when it was the default. Nil for the last
    /// preset (Hermes needs one) or an unknown name.
    static func deleting(_ name: String, from record: JSONValue) -> JSONValue? {
        var all = presets(record)
        guard all.count > 1, all.removeValue(forKey: name) != nil else { return nil }
        var next = with(record, "presets", .object(all))
        if record["default_preset"]?.string == name || defaultPreset(record) == name {
            next = with(next, "default_preset", .string(all.keys.sorted().first ?? ""))
        }
        if record["active_preset"]?.string == name { next = with(next, "active_preset", "") }
        return mirrored(next)
    }

    /// `name` as the preset `/moa` uses. Nil when it already is, or isn't a preset.
    static func settingDefault(_ name: String, in record: JSONValue) -> JSONValue? {
        guard presets(record)[name] != nil, defaultPreset(record) != name else { return nil }
        return mirrored(with(with(record, "default_preset", .string(name)), "active_preset", .string(name)))
    }

    // MARK: A preset's models

    /// A preset can lose a reference model only while it has another: Hermes refuses a preset with none.
    static func canRemoveReference(_ preset: JSONValue?) -> Bool { (preset?["reference_models"]?.array ?? []).count > 1 }

    /// How often the reference models are asked, from the preset's `fanout`: `user_turn` (Hermes' default),
    /// `per_iteration`, or `every_n:<N>`.
    static func adviceLine(_ preset: JSONValue?) -> String {
        let fanout = (preset?["fanout"]?.string ?? "user_turn").lowercased()
        let often: String
        if fanout == "per_iteration" {
            often = "at every step"
        } else if fanout.hasPrefix("every_n:"), let steps = Int(fanout.dropFirst("every_n:".count)), steps >= 2 {
            often = "every \(steps) steps"
        } else {
            often = "once per message"
        }
        return "The aggregator answers and uses the tools. The reference models advise it \(often)."
    }

    // MARK: What the provider page left behind

    /// The app's choices without what the provider page (which this row opened until 2026-11-21) could do to Mixture of
    /// Agents and nothing shows any more: a preset hidden from the model menus, and a "model" added by a typed ID, which
    /// names no preset. Nil when there is nothing of either. Its name and its own On/Off are kept.
    static func tidied(_ prefs: ProviderPrefs, presets: [String]) -> ProviderPrefs? {
        let extras = prefs.extraModels(provider)
        let hidden = presets.filter { prefs.isHidden(provider: provider, model: $0) }
        guard !extras.isEmpty || !hidden.isEmpty else { return nil }
        var next = prefs
        next.setHidden(false, provider: provider, models: hidden)
        for model in extras { next.removeExtra(model, provider: provider) }
        return next
    }

    private static func with(_ value: JSONValue, _ key: String, _ field: JSONValue) -> JSONValue {
        var object = value.object ?? [:]
        object[key] = field
        return .object(object)
    }
}
