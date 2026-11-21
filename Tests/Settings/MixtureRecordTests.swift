// [moa-setup] Mixture of Agents' record (`GET`/`PUT /api/model/moa`) as the page changes it: what makes Hermes list it,
// presets added, deleted and made the default, the last reference model kept, and the words under the page's rows.

import Foundation
import Testing
@testable import HermesHQNative

nonisolated private func preset(enabled: Bool? = true, refs: Int = 2, fanout: String? = "user_turn") -> JSONValue {
    var object: [String: JSONValue] = [
        "reference_models": .array((0..<refs).map { ["provider": "openrouter", "model": .string("model-\($0)"), "enabled": true] }),
        "aggregator": ["provider": "anthropic", "model": "claude-opus-5.5"],
        "reference_temperature": 0.6, "aggregator_temperature": 0.4, "reference_timeout": nil, "degraded_reference_policy": "loud",
    ]
    if let enabled { object["enabled"] = .bool(enabled) }
    if let fanout { object["fanout"] = .string(fanout) }
    return .object(object)
}

nonisolated private func record(_ presets: [String: JSONValue], default name: String) -> JSONValue {
    MixtureRecord.mirrored(["default_preset": .string(name), "active_preset": "", "presets": .object(presets), "privacy_filter": ""])
}

@Suite struct MixtureRecordTests {
    @Test func listedOnlyWhileAPresetIsEnabled() throws {
        let on = record(["default": preset()], default: "default")
        #expect(MixtureRecord.anyEnabled(on) && MixtureRecord.enabling(on) == nil, "nothing to change: Hermes lists it")
        #expect(MixtureRecord.anyEnabled(record(["default": preset(enabled: nil)], default: "default")), "enabled unless it says otherwise")
        let off = record(["balanced": preset(enabled: false), "fast": preset(enabled: false, refs: 1)], default: "fast")
        #expect(!MixtureRecord.anyEnabled(off))
        let turned = try #require(MixtureRecord.enabling(off))
        #expect(turned["presets"]?["fast"]?["enabled"] == true, "the default preset is the one enabled")
        #expect(turned["presets"]?["balanced"]?["enabled"] == false, "the others are left as they were")
        #expect(turned["enabled"] == true, "and the top level follows the default preset")
        #expect(MixtureRecord.complete(turned))
    }

    @Test func completeNeedsAReferenceAndBothHalvesOfEverySlot() {
        #expect(MixtureRecord.complete(record(["default": preset()], default: "default")))
        #expect(!MixtureRecord.complete(record(["default": preset(refs: 0)], default: "default")), "no reference model")
        var holed = preset().object!
        holed["aggregator"] = ["provider": "anthropic", "model": " "]
        #expect(!MixtureRecord.complete(record(["default": .object(holed)], default: "default")), "an aggregator without a model")
        #expect(!MixtureRecord.complete(["presets": .object([:])]), "no preset at all")
    }

    @Test func aNewPresetCopiesTheOneShown() throws {
        let start = record(["default": preset(enabled: false, refs: 3)], default: "default")
        let added = try #require(MixtureRecord.adding("  Deep Research ", copying: "default", to: start))
        #expect(added.name == "deep_research", "as Hermes keeps it: no spaces (a chat switches with `<name> --provider moa`)")
        #expect(ConfigText.pretty(added.name) == "Deep Research", "and shown as it was typed")
        #expect(MixtureRecord.presetNames(added.record) == ["deep_research", "default"])
        #expect(added.record["presets"]?["deep_research"]?["reference_models"]?.array?.count == 3)
        #expect(added.record["presets"]?["deep_research"]?["enabled"] == true)
        #expect(added.record["default_preset"] == "default", "the default stays")
        #expect(MixtureRecord.complete(added.record), "a record Hermes takes")
        #expect(MixtureRecord.adding("DEFAULT", copying: "default", to: start) == nil, "taken")
        #expect(MixtureRecord.adding("!!!", copying: "default", to: start) == nil, "nothing left of the name")
        #expect(MixtureRecord.adding("Other", copying: "missing", to: start) == nil, "nothing to copy")
    }

    @Test func presetNamesAndTheirProblems() {
        let start = record(["default": preset(), "v2": preset()], default: "default")
        #expect(MixtureRecord.slug("Fast & Cheap") == "fast_cheap")
        #expect(MixtureRecord.slug("gpt-5 mix") == "gpt-5_mix")
        #expect(MixtureRecord.slug("  ") == "")
        #expect(MixtureRecord.slug(String(repeating: "a", count: 80)).count == 40)
        #expect(MixtureRecord.nameProblem("", in: start) == nil, "nothing typed yet: the prompt just waits")
        #expect(MixtureRecord.nameProblem("???", in: start) == "Use letters or numbers in the name.")
        #expect(MixtureRecord.nameProblem("V2", in: start) == "There is already a preset with that name.")
        #expect(MixtureRecord.nameProblem("Research", in: start) == nil)
    }

    @Test func deletingMovesTheDefaultAndNeverTakesTheLast() throws {
        let start = record(["balanced": preset(refs: 2), "fast": preset(refs: 1)], default: "balanced")
        #expect(start["reference_models"]?.array?.count == 2)
        let left = try #require(MixtureRecord.deleting("balanced", from: start))
        #expect(MixtureRecord.presetNames(left) == ["fast"], "left out of the record: that is how Hermes deletes one")
        #expect(left["default_preset"] == "fast")
        #expect(left["reference_models"]?.array?.count == 1, "the top level is the new default's")
        #expect(MixtureRecord.deleting("fast", from: left) == nil, "the last preset stays")
        #expect(MixtureRecord.deleting("nope", from: start) == nil)
        let kept = try #require(MixtureRecord.deleting("fast", from: start))
        #expect(kept["default_preset"] == "balanced", "deleting another preset leaves the default")
        var active = start.object!
        active["active_preset"] = "fast"
        #expect(MixtureRecord.deleting("fast", from: .object(active))?["active_preset"] == "")
    }

    @Test func makeDefaultMirrorsThePreset() throws {
        let start = record(["balanced": preset(refs: 2), "fast": preset(enabled: false, refs: 1)], default: "balanced")
        let next = try #require(MixtureRecord.settingDefault("fast", in: start))
        #expect(next["default_preset"] == "fast" && MixtureRecord.defaultPreset(next) == "fast")
        #expect(next["reference_models"]?.array?.count == 1 && next["enabled"] == false, "the top level is the default preset's")
        #expect(next["presets"]?["fast"]?["enabled"] == false, "the preset itself is unchanged")
        #expect(MixtureRecord.settingDefault("fast", in: next) == nil, "already the default")
        #expect(MixtureRecord.settingDefault("nope", in: start) == nil)
        #expect(MixtureRecord.defaultPreset(["default_preset": "gone", "presets": ["b": preset(), "a": preset()]]) == "a",
                "a default that names no preset: the first one")
    }

    @Test func aPresetKeepsOneReferenceModel() {
        #expect(MixtureRecord.canRemoveReference(preset(refs: 2)))
        #expect(!MixtureRecord.canRemoveReference(preset(refs: 1)), "Hermes refuses a preset with none")
        #expect(!MixtureRecord.canRemoveReference(nil))
    }

    @Test func editingAPresetKeepsTheTopLevelInStep() {
        let start = record(["balanced": preset(), "fast": preset(refs: 1)], default: "balanced")
        var changed = start["presets"]!["balanced"]!.object!
        changed["aggregator"] = ["provider": "openrouter", "model": "x-ai/grok-5"]
        let next = MixtureRecord.replacing("balanced", with: .object(changed), in: start)
        #expect(next["aggregator"]?["model"] == "x-ai/grok-5", "the default preset is on the top level too")
        var other = start["presets"]!["fast"]!.object!
        other["aggregator"] = ["provider": "openrouter", "model": "qwen/qwen3-coder"]
        let untouched = MixtureRecord.replacing("fast", with: .object(other), in: start)
        #expect(untouched["aggregator"]?["model"] == "claude-opus-5.5", "another preset's change stays off the top level")
        #expect(untouched["presets"]?["fast"]?["aggregator"]?["model"] == "qwen/qwen3-coder")
        #expect(next["privacy_filter"] == "", "what the page doesn't show goes back as it came")
    }

    @Test func theAdviceLineFollowsThePresetsFanout() {
        #expect(MixtureRecord.adviceLine(preset()) == "The aggregator answers and uses the tools. The reference models advise it once per message.")
        #expect(MixtureRecord.adviceLine(preset(fanout: nil)).hasSuffix("once per message."), "Hermes' default")
        #expect(MixtureRecord.adviceLine(preset(fanout: "per_iteration")).hasSuffix("advise it at every step."))
        #expect(MixtureRecord.adviceLine(preset(fanout: "every_n:3")).hasSuffix("advise it every 3 steps."))
        #expect(MixtureRecord.adviceLine(preset(fanout: "every_n:x")).hasSuffix("once per message."))
    }

    @Test func theSwitchFooterSaysHowAChatUsesIt() {
        #expect(SettingsWords.moaFooter(defaultBot: "Hermes")
                == "To use it, pick Mixture of Agents in a chat’s model menu, or send /moa with a message. Applies to Hermes only.")
        #expect(SettingsWords.moaFooter(defaultBot: "Hermes", on: false) == "Off, it is in no model menu. Applies to Hermes only.")
    }

    /// What the provider page could leave on Mixture of Agents, with no page left to undo it.
    @Test func whatTheProviderPageLeftIsUndone() throws {
        var prefs = ProviderPrefs()
        #expect(MixtureRecord.tidied(prefs, presets: ["default"]) == nil, "nothing to undo")
        prefs.setOff(true, provider: "moa")
        prefs.setProviderName("Council", provider: "moa", original: "Mixture of Agents")
        #expect(MixtureRecord.tidied(prefs, presets: ["default"]) == nil, "its name and its own switch aren't the provider page's leftovers")
        prefs.setHidden(true, provider: "moa", model: "default")
        prefs.addExtra("gpt-5.5", provider: "moa")
        prefs.setHidden(true, provider: "anthropic", model: "claude-haiku-5")
        let tidy = try #require(MixtureRecord.tidied(prefs, presets: ["default", "fast"]))
        #expect(!tidy.isHidden(provider: "moa", model: "default"), "the hidden preset shows again")
        #expect(tidy.extraModels("moa").isEmpty, "the typed model, which names no preset, is gone")
        #expect(tidy.isOff("moa") && tidy.providerName("moa") == "Council", "its switch and its name stay")
        #expect(tidy.isHidden(provider: "anthropic", model: "claude-haiku-5"), "another provider's choices are untouched")
        #expect(MixtureRecord.tidied(tidy, presets: ["default", "fast"]) == nil, "once")
    }

    /// Settings › Providers: its row counts presets, not models.
    @Test func itsProvidersRowCountsPresets() throws {
        let catalog = [ModelProviderOption(slug: "moa", name: "Mixture of Agents", models: ["default", "fast"], authenticated: true),
                       ModelProviderOption(slug: "nous", name: "Nous Portal", models: ["Hermes-4-405B"], authenticated: true)]
        let rows = ProviderList.merge(custom: [], vars: [], accounts: [], catalog: catalog)
        let moa = try #require(rows.first { $0.id == MixtureRecord.provider })
        #expect(ProviderList.rowLine(moa, catalog: catalog, prefs: ProviderPrefs()).count == "2 presets")
        #expect(ProviderList.shownLine(moa, catalog: catalog, prefs: ProviderPrefs()) == "2 presets shown")
        let one = [ModelProviderOption(slug: "moa", name: "Mixture of Agents", models: ["default"], authenticated: true)]
        #expect(ProviderList.shownEdge(moa, catalog: one, prefs: ProviderPrefs()).text == "1 preset")
        let nous = try #require(rows.first { $0.id == "nous" })
        #expect(ProviderList.shownEdge(nous, catalog: catalog, prefs: ProviderPrefs()).text == "1 model", "every other provider counts models")
    }
}
