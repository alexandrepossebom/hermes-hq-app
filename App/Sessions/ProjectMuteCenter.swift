// [project-mute] The app's side of a project's Notifications (Project Settings › Notifications): which of this
// gateway's chats are in a project set to Only When It Needs Me or Mute, saved where the notification extension reads
// it (Shared/ProjectMutes.swift) and asked by the app's own alerts and the reply peek, beside the bot mutes
// (`BotMuteCenter`). Rewritten whenever the Sessions list or the setting changes; another gateway's part is left alone.

import Foundation

@MainActor
final class ProjectMuteCenter {
    static let shared = ProjectMuteCenter()

    struct Storage {
        var load: () -> Data?
        var save: (Data?) -> Void
        static let keychain = Storage(load: { ProjectMuteKeychain.read() }, save: { ProjectMuteKeychain.write($0) })
    }

    private(set) var levels: ProjectMutes.Levels
    /// The signed-in gateway's account, as pushes name it (PushPolicy.owner).
    var account: () -> String? = { PushRegistrar.shared.owner }
    private let storage: Storage
    #if DEBUG
    private var lastNamed: String?
    #endif

    init(storage: Storage = .keychain) {
        self.storage = storage
        levels = ProjectMutes.decode(storage.load())
    }

    /// The signed-in gateway's chats in projects that are not on All (stored id → level): replaces its part of the list.
    func update(_ chats: [String: ProjectNotify]) {
        #if DEBUG
        // UI tests read which chats the list names (`-HQDebugTextOut`).
        let named = chats.filter { $0.value != .all }.map { "\($0.key)=\($0.value.rawValue)" }.sorted().joined(separator: "\n")
        if named != lastNamed {
            lastNamed = named
            DebugHooks.recordText(named.isEmpty ? "none" : named, as: "project-mutes.txt")
        }
        #endif
        guard let account = account(), !account.isEmpty else { return }
        let next = ProjectMutes.replacing(levels, account: account, with: chats)
        guard next != levels else { return }
        levels = next
        storage.save(ProjectMutes.encode(next))
        AppLog.trace("notify", "project notifications: \(next[account]?.count ?? 0) chats quieted")
    }

    /// Whether a local alert (or the peek) of `kind` for the chat `session` (its stored id) may show.
    func allows(kind: String, session: String) -> Bool {
        guard let account = account() else { return true }
        return ProjectMutes.allows(kind: kind, account: account, session: session, levels: levels)
    }
}
