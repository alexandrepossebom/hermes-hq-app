// [threads] A bot chat's threads (docs/spec/3x-threads.md): the model a chat screen draws, and the pure rules for
// where a thread hangs in the chat, whether it shows open or folded, and what an open one shows.
//
// A thread is a session of its own in the bot's profile (`parent_session_id` = the bot chat), so it runs beside the
// bot chat's reply instead of joining it. The bot chat draws it in place: open (its last question and the answer) while
// it is the newest thing there, one folded line afterwards.

import Foundation

/// One thread, as the chat it hangs in draws it.
nonisolated struct ChatThread: Identifiable, Sendable {
    /// Its key in the chat's list: the stored session id once the gateway made it, a local key until then.
    var id: String
    var storedId: String?
    /// Its own short title; nil until it has one ("Thread" meanwhile).
    var title: String?
    var startedAt: Date
    /// The message of the main chat it hangs under: its id there when this device started the thread, and its stored
    /// row (the seed's closing note carries it to every other device). Without either, its start time places it.
    var anchorMessageId: String?
    var anchorRow: Int?
    /// What is said in it, oldest first (never its hidden seed).
    var messages: [ChatMessage]
    /// A reply is running in it.
    var running: Bool
    /// It could not start or send ("The gateway didn’t start a new chat."); the line says so.
    var problem: String?
    /// The cache scope of its rows' layouts (`ChatRow.scope`).
    var scope: String

    /// The messages that count as said: yours and the bot's.
    var spoken: [ChatMessage] { messages.filter { $0.role != .system } }
}

nonisolated enum ThreadRules {
    /// §9: said over the message box when words sent to a busy chat went on in a thread.
    static let busyNotice = "This chat is busy, so your message went into a thread."

    /// §9: where a thread that took a busy chat's words hangs: under the newest thing said in that chat (yours or the
    /// bot's), so it stands open at the foot with its answer in view. `localId` is the bubble of the words it took,
    /// which leaves the chat. (By time alone it would hang under your last message, above the bot's answer to it, and
    /// fold the moment it finished.)
    static func busyAnchor(in messages: [ChatMessage], leavingOut localId: String) -> ChatMessage? {
        messages.last { $0.id != localId && $0.role != .system }
    }

    /// §9: the thread that took a busy chat's words takes the next ones too, for as long as it is live and well and
    /// the chat has not taken a send itself since (`accepted` then and now).
    static func takesNextBusySend(heldAt: Int?, accepted: Int, live: Bool, problem: Bool) -> Bool {
        heldAt == accepted && live && !problem
    }

    /// The index in `messages` (the main chat's, oldest first) of the message `thread` hangs under; nil when that
    /// message is older than what is loaded (or the chat is empty).
    static func anchorIndex(of thread: ChatThread, in messages: [ChatMessage]) -> Int? {
        if let id = thread.anchorMessageId, let found = messages.lastIndex(where: { $0.id == id }) { return found }
        if let row = thread.anchorRow {
            if let exact = messages.lastIndex(where: { $0.rowId == row }) { return exact }
            // A reply folded from several stored rows carries its first row: the newest message at or before the anchor.
            var best: Int?
            var sawStored = false
            for (index, message) in messages.enumerated() {
                guard let own = message.rowId else { continue }
                sawStored = true
                if own <= row { best = index }
            }
            if best != nil || sawStored { return best }
        }
        // By time: under your newest message from before the thread began (the request the bot was busy with, or the
        // one it had just answered).
        var best: Int?
        for (index, message) in messages.enumerated() where message.role == .user {
            guard let at = message.timestamp else { continue }
            if at <= thread.startedAt { best = index } else { break }
        }
        return best
    }

    /// Open (its messages in place) or folded (one line). Open while it is the newest thing in the chat: nothing the
    /// bot has finished saying in the main chat comes after it. A thread still answering, or one that could not start,
    /// stays open wherever it is.
    static func isOpen(_ thread: ChatThread, anchor: Int, in messages: [ChatMessage]) -> Bool {
        if thread.running || thread.problem != nil { return true }
        guard anchor + 1 < messages.count else { return true }
        for message in messages[(anchor + 1)...] where message.role == .assistant && message.sender == nil {
            if !message.isStreaming && !ChatTranscript.blocks(message).isEmpty { return false }
        }
        return true
    }

    /// What an open thread shows in the main chat: your last message in it and what the bot said after it. `earlier`
    /// counts the spoken messages before those.
    static func shown(_ thread: ChatThread) -> (messages: [ChatMessage], earlier: Int) {
        let spoken = thread.spoken
        guard let lastYours = spoken.lastIndex(where: { $0.role == .user }) else { return (spoken, 0) }
        return (Array(spoken[lastYours...]), lastYours)
    }

    /// "Thread", or its own short title once it has one.
    static func name(_ thread: ChatThread) -> String {
        guard let title = thread.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title != defaultTitle
        else { return defaultTitle }
        // Hermes's first title is the opening words, cut: the app's own short title replaces it a moment later.
        let first = thread.spoken.first(where: { $0.role == .user }).map(ChatTranscript.messageText) ?? ""
        return ShortTitle.isPlaceholder(title, firstMessage: first) ? defaultTitle : title
    }

    static let defaultTitle = "Thread"

    /// "1 message", "4 messages".
    static func countWords(_ count: Int) -> String { count == 1 ? "1 message" : "\(count) messages" }

    /// The folded line's words after the name: "4 messages", or the problem.
    static func foldedTail(_ thread: ChatThread) -> String? {
        let count = thread.spoken.count
        return count > 0 ? countWords(count) : nil
    }

    /// The open block's header: "Thread", "Flight on Friday", and "· 6 messages" when it holds more than it shows.
    static func header(_ thread: ChatThread) -> (name: String, tail: String?) {
        let shown = self.shown(thread)
        return (name(thread), shown.earlier > 0 ? countWords(thread.spoken.count) : nil)
    }

    /// The threads of one chat by the index of the message each hangs under, oldest thread first under one message.
    static func byAnchor(_ threads: [ChatThread], in messages: [ChatMessage]) -> [Int: [ChatThread]] {
        var out: [Int: [ChatThread]] = [:]
        for thread in threads.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard let index = anchorIndex(of: thread, in: messages) else { continue }
            out[index, default: []].append(thread)
        }
        return out
    }
}

/// A thread read from the gateway without opening it (another device's, or one from an earlier run).
nonisolated enum ThreadFetch {
    nonisolated struct Result: Sendable {
        var messages: [ChatMessage]
        var anchorRow: Int?
    }

    /// From its stored rows: the hidden seed gives the anchor and is left out of the messages.
    static func read(rows: [JSONValue]) -> Result {
        var anchor: Int?
        var visible: [JSONValue] = []
        for row in rows {
            if row["display_kind"]?.string == "hidden" {
                if let text = row["content"]?.string, let found = ThreadSeed.anchorRow(in: text) { anchor = found }
                continue
            }
            visible.append(row)
        }
        return Result(messages: Hydration.fold(visible).messages, anchorRow: anchor)
    }

    static func load(client: any GatewayClient, storedId: String, profile: String?) async throws -> Result {
        read(rows: try await ChatTranscript.fetchAllRows(client: client, storedSessionId: storedId, profile: profile))
    }
}
