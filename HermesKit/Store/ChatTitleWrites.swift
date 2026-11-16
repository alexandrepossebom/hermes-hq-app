import Foundation

/// One title-write order for a stored chat, shared by its open/retained screens and the Sessions list.
/// Weak entries disappear with those users; completed chats are not held alive by the registry.
@MainActor final class ChatTitleWrites {
    private struct Key: Hashable {
        let account: String
        let profile: String
        let id: String
    }
    private static var entries: [Key: WeakBox<ChatTitleWrites>] = [:]

    static func shared(account: String, profile: String, id: String) -> ChatTitleWrites {
        entries = entries.filter { $0.value.value != nil }
        let key = Key(account: account, profile: profile, id: id)
        if let found = entries[key]?.value { return found }
        let made = ChatTitleWrites(key: key)
        entries[key] = WeakBox(made)
        return made
    }

    private let key: Key
    var id: String { key.id }
    var tail: Task<Void, Never>?
    /// Echoes belong to the stored chat, including writes started by another retained screen.
    var automaticTitleWrites: Set<String> = []
    private(set) var manualRequests = 0
    private var revision = 0
    private var chats: [WeakBox<LiveChatSession>] = []
    private init(key: Key) { self.key = key }

    func attach(_ chat: LiveChatSession) {
        chats.removeAll { $0.value == nil }
        if !chats.contains(where: { $0.value === chat }) { chats.append(WeakBox(chat)) }
    }

    /// Reserve the manual edit before waiting, so an automatic event cannot queue a newer competing write.
    /// The completion task is itself the queue tail: another screen's rename waits for this edit too.
    func rename(to typed: String, write: @escaping @MainActor () async throws -> String) async throws -> String {
        manualRequests += 1
        revision += 1
        let thisRevision = revision
        let previousTitles = chats.compactMap { ref -> (WeakBox<LiveChatSession>, String)? in
            guard let chat = ref.value else { return nil }
            return (ref, chat.title)
        }
        for (ref, _) in previousTitles { ref.value?.applyTitle(typed.isEmpty ? "Untitled Chat" : typed, rowTitle: typed) }
        let previous = tail
        let request = Task { @MainActor in
            await previous?.value
            return try await write()
        }
        let completion = Task { @MainActor in
            switch await request.result {
            case .success(let stored):
                ManualChatTitles.set(!stored.isEmpty, account: self.key.account, profile: self.key.profile, id: self.key.id)
                for ref in self.chats {
                    ref.value?.pendingAutomaticTitle = nil
                    if self.revision == thisRevision {
                        ref.value?.applyTitle(stored.isEmpty ? "Untitled Chat" : stored, rowTitle: stored)
                    }
                }
            case .failure:
                if self.revision == thisRevision {
                    for (ref, title) in previousTitles { ref.value?.applyTitle(title, rowTitle: title) }
                }
            }
            self.manualRequests -= 1
            if self.manualRequests == 0 {
                for ref in self.chats { ref.value?.reconsiderAutomaticTitle() }
            }
        }
        tail = completion
        await completion.value
        return try await request.value
    }
}
