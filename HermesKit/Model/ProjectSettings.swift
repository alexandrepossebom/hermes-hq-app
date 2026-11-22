// [project-settings] Owner 2026-11-20/21: a project's page has settings of its own, on one page (⋯ › Project
// Settings…). These are their values as the device keeps them and the "sessions" document carries them; each is per
// project key. The page is `App/Sessions/ProjectSettingsPage.swift`; the rules are `SessionListPipeline`'s.

import Foundation

/// [project-auto-done] Move Quiet Chats to Done: after how many days without activity, and (a coding project) once the
/// chat's pull request has merged. Display only: nothing is archived.
nonisolated struct ProjectAutoDone: Hashable, Sendable {
    /// nil: Never.
    var days: Int? = nil
    var onMerge = false

    static let dayChoices = [3, 7, 14]
    static let mergedMark = "merged"

    init(days: Int? = nil, onMerge: Bool = false) {
        self.days = days
        self.onMerge = onMerge
    }

    /// "never", "3", "7", "14", each with "+merged" when the merge switch is on. Anything else reads as Never.
    init(raw: String?) {
        let parts = (raw ?? "").split(separator: "+").map(String.init)
        days = parts.first.flatMap(Int.init).flatMap { Self.dayChoices.contains($0) ? $0 : nil }
        onMerge = parts.dropFirst().contains(Self.mergedMark)
    }

    /// Kept even when it says Never, so sync carries turning it off.
    var raw: String { (days.map(String.init) ?? "never") + (onMerge ? "+" + Self.mergedMark : "") }

    var isOff: Bool { days == nil && !onMerge }

    static func title(days: Int?) -> String { days.map { "After \($0) Days" } ?? "Never" }
}

/// [project-new-chat-model] The model and reasoning a project's New Chat starts with. A part left out is the bot's own.
nonisolated struct ProjectNewChat: Codable, Hashable, Sendable {
    var provider: String? = nil
    var model: String? = nil
    var reasoning: String? = nil

    var isEmpty: Bool { model == nil && reasoning == nil }

    /// What `session.create` is given on top of its own parameters: nothing when nothing was chosen.
    var createParams: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if let model, !model.isEmpty {
            out["model"] = .string(model)
            if let provider, !provider.isEmpty { out["provider"] = .string(provider) }
        }
        if let reasoning, !reasoning.isEmpty { out["reasoning_effort"] = .string(reasoning) }
        return out
    }

    init(provider: String? = nil, model: String? = nil, reasoning: String? = nil) {
        self.provider = provider
        self.model = model
        self.reasoning = reasoning
    }

    init(json: JSONValue?) {
        func text(_ key: String) -> String? { json?[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        model = text("model")
        provider = model == nil ? nil : text("provider")
        reasoning = text("reasoning")
    }

    var json: JSONValue {
        var out: [String: JSONValue] = [:]
        if let model { out["model"] = .string(model) }
        if let provider, model != nil { out["provider"] = .string(provider) }
        if let reasoning { out["reasoning"] = .string(reasoning) }
        return .object(out)
    }
}

/// [project-look] A project's own emoji and colour (an index into `SessionColors`).
nonisolated struct ProjectLook: Codable, Hashable, Sendable {
    var emoji: String? = nil
    var color: Int? = nil

    var isEmpty: Bool { emoji == nil && color == nil }

    init(emoji: String? = nil, color: Int? = nil) {
        self.emoji = Self.oneEmoji(emoji)
        self.color = color.flatMap { SessionColors.names.indices.contains($0) ? $0 : nil }
    }

    init(json: JSONValue?) {
        self.init(emoji: json?["emoji"]?.string, color: json?["color"]?.int)
    }

    var json: JSONValue {
        var out: [String: JSONValue] = [:]
        if let emoji { out["emoji"] = .string(emoji) }
        if let color { out["color"] = .number(Double(color)) }
        return .object(out)
    }

    /// The field holds one character: the last one typed (so typing over a set emoji replaces it); nothing for
    /// blank text. `old`: what the field held; typed before it (the caret at the start), the new character is the
    /// first one.
    static func oneEmoji(_ text: String?, replacing old: String? = nil) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let last = trimmed.last, let first = trimmed.first else { return nil }
        if let old, trimmed.count > 1, String(last) == old, String(first) != old { return String(first) }
        return String(last)
    }
}
