import Foundation

/// Which chats were deliberately named on this device. The gateway's title event has no provenance, so a name like
/// "New Chat" must not become an automatic placeholder again on reopen. Also remembers a short fallback awaiting
/// the gateway's naming model, but only while the stored title still matches it. Removed with account preferences.
enum ManualChatTitles {
    static let storageKey = "hq.manual-chat-titles"

    private static func sessionKey(profile: String, id: String) -> String { "\(profile.utf8.count):\(profile)\(id)" }
    private static func accountKey(_ account: String) -> String { "\(storageKey)|\(account)" }

    static func contains(account: String, profile: String, id: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let id else { return false }
        return (defaults.stringArray(forKey: accountKey(account)) ?? []).contains(sessionKey(profile: profile, id: id))
    }

    static func set(_ manual: Bool, account: String, profile: String, id: String?, defaults: UserDefaults = .standard) {
        guard let id else { return }
        let key = accountKey(account)
        var names = Set(defaults.stringArray(forKey: key) ?? [])
        let session = sessionKey(profile: profile, id: id)
        if manual { names.insert(session) } else { names.remove(session) }
        if names.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(names.sorted(), forKey: key) }
        awaitModel(nil, account: account, profile: profile, id: id, defaults: defaults)
    }

    static func isAwaitingModel(_ title: String, account: String, profile: String, id: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let id else { return false }
        return defaults.dictionary(forKey: accountKey(account) + "|awaiting")?[sessionKey(profile: profile, id: id)] as? String == title
    }

    static func awaitModel(_ title: String?, account: String, profile: String, id: String?, defaults: UserDefaults = .standard) {
        guard let id else { return }
        let key = accountKey(account) + "|awaiting"
        var titles = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        titles[sessionKey(profile: profile, id: id)] = title
        if titles.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(titles, forKey: key) }
    }

    static func forget(accountId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: accountKey(accountId))
        defaults.removeObject(forKey: accountKey(accountId) + "|awaiting")
    }

    static func forgetAll(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(storageKey + "|") {
            defaults.removeObject(forKey: key)
        }
    }
}
