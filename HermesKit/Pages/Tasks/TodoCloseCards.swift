// [chat-mark-done] A bot's offer to close your task, as a card under its reply (owner 2026-11-22: "When a bot knows that
// you are done with a task it needs to be able to give you an easy way to mark it as done."). Mark Done lived only on
// the task's own page (`TaskCloseOfferCard`); the bot said "ready to tap Mark Done" and nothing in the chat could be
// tapped. The card comes from the bot's `tasks_update`: `offer_done` (it offers, you answer), or `status: done` with
// `asked` (you told it to, so it did; you can take it back). What the card shows is the task as it is now, read from
// the Tasks store through `TodoTaskStates`, so a chat reopened days later, or a task answered on another device, says
// what is true. Plain data and rules, tested in Tests/Pages/TaskCloseCardTests.

import Foundation
import Synchronization

/// The Tasks store's tasks as the chat's close cards read them: built and measured off the main thread, so a copy is
/// kept here behind a lock (as `TodoOfferStates` keeps the offers), and each chat's rows take a snapshot of it.
nonisolated enum TodoTaskStates {
    /// A task changed in a way a card shows (done, its offer, gone), or the list was read: chats with a card rebuild.
    static let changed = Notification.Name("hq.tasks.close.changed")
    /// A chat's card names a task the store hasn't read (or an offer newer than the one it has): the list is read again.
    static let wanted = Notification.Name("hq.tasks.close.wanted")

    /// What a card needs of one task.
    nonisolated struct Entry: Hashable, Sendable {
        var done: Bool
        var offer: TodoCloseOffer?
    }

    nonisolated struct Snapshot: Hashable, Sendable {
        var tasks: [String: Entry] = [:]
        /// The gateway's list was read this run (a list only from disk may lack a task the bot just touched).
        var read = false
        /// The gateway takes no writes: the buttons show, dimmed, as on the task's page; no Undo.
        var readOnly = false
        /// Tasks a card's Undo opened again this run (the card then reads "Back on the list").
        var reopened: Set<String> = []
    }

    private static let box = Mutex<Snapshot>(Snapshot())
    private static let asked = Mutex<Set<String>>([])
    private static let posting = Mutex<Bool>(false)

    static func snapshot() -> Snapshot { box.withLock { $0 } }

    /// The store's list changed (an optimistic edit, a read, a save).
    static func note(_ tasks: [TodoTask]) {
        let next = Dictionary(tasks.map { ($0.id, Entry(done: $0.isDone, offer: $0.offer)) }, uniquingKeysWith: { first, _ in first })
        update { $0.tasks = next }
    }

    /// The gateway's list was read (not the one on disk).
    static func noteRead() { update { $0.read = true } }

    static func noteReadOnly(_ readOnly: Bool) { update { $0.readOnly = readOnly } }

    /// A card's Undo opened the task again.
    static func noteReopened(_ id: String) { update { $0.reopened.insert(id) } }

    /// Signed out, or the store let its list go.
    static func forget() {
        update { $0 = Snapshot() }
        asked.withLock { $0 = [] }
    }

    /// A card names a task the store hasn't read, or an offer newer than the store's: asked once per task and offer.
    static func want(_ id: String, at: String?) {
        guard asked.withLock({ $0.insert(id + "|" + (at ?? "")).inserted }) else { return }
        DispatchQueue.main.async { NotificationCenter.default.post(name: wanted, object: id) }
    }

    /// One `changed` for a burst of edits, posted on the main queue (never from inside the store's own change).
    private static func update(_ change: (inout Snapshot) -> Void) {
        let moved = box.withLock { s -> Bool in
            let before = s
            change(&s)
            return s != before
        }
        guard moved, posting.withLock({ busy -> Bool in defer { busy = true }; return !busy }) else { return }
        DispatchQueue.main.async {
            posting.withLock { $0 = false }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}

/// The card's rules and words.
nonisolated enum TodoCloseCards {
    /// What the card shows now.
    enum State: Hashable, Sendable {
        /// The offer waits: Mark Done and Keep Open.
        case waiting
        /// "Marked Done", with Undo when this is the chat's newest card for the task and the gateway takes writes.
        case done(undo: Bool)
        /// "Back on the list": opened again (the asked card after its Undo, or the offer's after one).
        case reopened
        /// "Kept Open": you chose Keep Open (here, on its page or another device).
        case kept
        /// "No longer on your list": deleted.
        case gone
        /// "Still open": open, but its offer went, or a newer card in this chat stands for it.
        case settled
    }

    enum Action: String, Sendable {
        case markDone = "mark done", keepOpen = "keep open", reopen
    }

    /// The card's state, or nil while the store hasn't read the task (the card waits for it: no buttons that then go).
    /// `asked`: the bot marked it done because you said so (no offer). `offer`: the one the bot's call made. `newest`:
    /// no later card in this chat stands for the task.
    static func state(asked: Bool, offer: TodoCloseOffer?, id: String, newest: Bool, in s: TodoTaskStates.Snapshot) -> State? {
        guard let task = s.tasks[id] else { return s.read ? .gone : nil }
        if task.done { return .done(undo: newest && !s.readOnly) }
        if asked { return .reopened }
        if task.offer?.kept == true { return .kept }
        guard newest else { return .settled }
        guard let live = task.offer else { return s.reopened.contains(id) ? .reopened : .settled }
        if newer(live.at, than: offer?.at) { return .settled }   // the bot offered again since (another chat)
        return .waiting
    }

    /// The quiet words in place of the buttons; nil while the offer waits.
    static func words(_ state: State) -> String? {
        switch state {
        case .waiting: return nil
        case .done: return "Marked Done"
        case .reopened: return "Back on the list"
        case .kept: return "Kept Open"
        case .gone: return "No longer on your list"
        case .settled: return "Still open"
        }
    }

    /// Every line the foot can say (its height is measured for the longest, so the card never jumps).
    static let allWords = ["Marked Done", "Back on the list", "Kept Open", "No longer on your list", "Still open"]

    /// Whether moment `a` is later than `b` (false when either is missing or unreadable).
    static func newer(_ a: String?, than b: String?) -> Bool {
        guard let a = TodoDates.moment(a), let b = TodoDates.moment(b) else { return false }
        return a > b
    }
}
