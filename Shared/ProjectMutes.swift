// [project-mute] A project's Notifications (Project Settings › Notifications; owner 2026-11-21): All, Only When It Needs
// Me, or Mute. A push names its account, bot and chat but not the chat's folder, so the app keeps, beside the bot mutes
// (Shared/BotMutes.swift) and in the same shared Keychain group, which chats belong to a project that is not on All:
// gateway account → chat's stored id → level. The app rewrites its account's part whenever the Sessions list or the
// setting changes (`ProjectMuteCenter`); the notification extension and the app's own alerts read it. A chat made in
// such a project on another device is not in the list until this device has seen it. This device only; never logs.

import Foundation
import Security

/// A project's Notifications. The raw values are what the "sessions" document carries.
nonisolated enum ProjectNotify: String, CaseIterable, Hashable, Sendable {
    case all, needsMe, mute

    var title: String {
        switch self {
        case .all: "All"
        case .needsMe: "Only When It Needs Me"
        case .mute: "Mute"
        }
    }
}

nonisolated enum ProjectMutes {
    /// The kinds that wait on the owner (a command to approve, a question, a password): loud at every level. Local
    /// kinds and the push add-on's.
    static let needsOwner: Set<String> = ["approval", "approval.request", "input"]
    /// At most this many chats are kept per account (the newest the app listed).
    static let limit = 2_000

    /// account → chat's stored id → level (never `.all`).
    typealias Levels = [String: [String: ProjectNotify]]

    static func level(account: String, session: String, levels: Levels) -> ProjectNotify {
        guard !account.isEmpty, !session.isEmpty else { return .all }
        return levels[account]?[session] ?? .all
    }

    /// Whether an alert of `kind` for chat `session` (on `account`) may sound. Only When It Needs Me quiets what a bot
    /// mute quiets (finished replies and background work); Mute quiets every kind but the ones that wait on the owner.
    static func allows(kind: String, account: String, session: String, levels: Levels) -> Bool {
        switch level(account: account, session: session, levels: levels) {
        case .all: true
        case .needsMe: !BotMutes.silenced.contains(kind)
        case .mute: needsOwner.contains(kind)
        }
    }

    /// `levels` with `account`'s part replaced (an empty part removed).
    static func replacing(_ levels: Levels, account: String, with chats: [String: ProjectNotify]) -> Levels {
        var out = levels
        let quiet = chats.filter { $0.value != .all && !$0.key.isEmpty }
        out[account] = quiet.isEmpty ? nil : quiet
        return out
    }

    // Stored compactly: account → level → ids.
    static func encode(_ levels: Levels) -> Data? {
        var doc: [String: [String: [String]]] = [:]
        for (account, chats) in levels {
            var byLevel: [String: [String]] = [:]
            for (session, level) in chats where level != .all { byLevel[level.rawValue, default: []].append(session) }
            if !byLevel.isEmpty { doc[account] = byLevel.mapValues { $0.sorted() } }
        }
        return doc.isEmpty ? nil : try? JSONEncoder().encode(doc)
    }

    static func decode(_ data: Data?) -> Levels {
        let doc = data.flatMap { try? JSONDecoder().decode([String: [String: [String]]].self, from: $0) } ?? [:]
        var out: Levels = [:]
        for (account, byLevel) in doc {
            for (raw, sessions) in byLevel {
                guard let level = ProjectNotify(rawValue: raw), level != .all else { continue }
                for session in sessions { out[account, default: [:]][session] = level }
            }
        }
        return out
    }

    /// The list as the extension reads it.
    static func stored() -> Levels { decode(ProjectMuteKeychain.read()) }
}

/// The list in the Keychain group the app and its notification extension share, beside the bot mutes.
nonisolated enum ProjectMuteKeychain {
    static let service = "ai.hermes.hq.project-mutes"
    static let account = "levels"
    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> Data? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Replaces the list (nil or empty data removes it). Returns whether the Keychain holds what was asked.
    @discardableResult static func write(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty else {
            let status = SecItemDelete(item as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        if SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
