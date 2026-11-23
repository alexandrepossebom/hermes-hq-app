import UIKit

/// [threads] One account's threads (docs/spec/3x-threads.md §4): the chats started from inside a bot's chat, which
/// that chat draws in place.
///
/// A thread is known three ways:
/// - started here this run: a live chat with no screen (`LiveChatSession.listenOffScreen`), so its reply arrives while
///   the bot chat is the one on screen;
/// - listed by the gateway: a Sessions row whose parent is the bot chat (another device started it, or an earlier
///   run), read once over REST and again when its row changes;
/// - opened: the chat its screen uses, kept as the live one.
///
/// Only a few idle threads stay live; the rest keep the messages they last showed.
@MainActor
final class ThreadStore {
    private final class Entry {
        /// Stable for the run: the stored id for a listed thread, a local key for one started here.
        let key: String
        let profile: String
        /// The bot chat's id it was started under (nil when that chat had no stored id yet).
        var parentId: String?
        var storedId: String?
        var live: LiveChatSession?
        var startedAt: Date
        var anchorMessageId: String?
        var anchorRow: Int?
        var rowTitle: String?
        /// What it showed when last read or last live.
        var kept: [ChatMessage] = []
        /// The Sessions row state the last read was made for ("<last active>|<count>").
        var readStamp: String?
        var reading = false
        var problem: String?
        var lastChange = Date()
        /// What the bot chat last drew of it (a change in any of these redraws it).
        var drawn: Int = 0

        init(key: String, profile: String, parentId: String?, storedId: String?, startedAt: Date) {
            self.key = key; self.profile = profile; self.parentId = parentId; self.storedId = storedId; self.startedAt = startedAt
        }
    }

    private weak var model: AppModel?
    private var entries: [Entry] = []
    private var observers: [(owner: WeakBox<AnyObject>, profile: String, call: () -> Void)] = []
    private var owed: Set<String> = []
    private var notifyQueued = false
    /// Idle threads kept live (a running one always is).
    static let idleLive = 4

    init(model: AppModel) { self.model = model }

    // MARK: Observing

    /// `call` runs (once per run loop turn) when a thread of `profile` changed, for as long as `owner` lives.
    func observe(profile: String, owner: AnyObject, _ call: @escaping () -> Void) {
        observers.removeAll { $0.owner.value == nil }
        observers.append((WeakBox(owner), profile, call))
    }

    private func changed(_ profile: String) {
        owed.insert(profile)
        guard !notifyQueued else { return }
        notifyQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notifyQueued = false
            let profiles = self.owed
            self.owed = []
            self.observers.removeAll { $0.owner.value == nil }
            for observer in self.observers where profiles.contains(observer.profile) { observer.call() }
        }
    }

    // MARK: Reading

    /// The threads of the bot chat known by `parentIds`, oldest first.
    func threads(profile: String, parentIds: Set<String>) -> [ChatThread] {
        adoptListed(profile: profile, parentIds: parentIds)
        return entries.filter { $0.profile == profile && belongs($0, to: parentIds) }
            .sorted { $0.startedAt < $1.startedAt }
            .map(thread)
    }

    /// One started here before its bot chat had a stored id belongs to that profile's bot chat.
    private func belongs(_ entry: Entry, to parentIds: Set<String>) -> Bool {
        guard let parent = entry.parentId else { return true }
        return parentIds.contains(parent)
    }

    private func thread(_ entry: Entry) -> ChatThread {
        let live = entry.live
        let listed = entry.storedId.flatMap { model?.sessionStore?.row(for: $0) }
        let title = [live?.title, listed?.title ?? entry.rowTitle].compactMap { $0 }
            .first { !$0.isEmpty && $0 != ThreadRules.defaultTitle }
        let scope = live?.layoutScope ?? "\(model?.account?.id ?? "")|\(entry.profile)|\(entry.storedId ?? entry.key)"
        return ChatThread(id: entry.key, storedId: live?.storedSessionId ?? entry.storedId, title: title, startedAt: entry.startedAt,
                          anchorMessageId: entry.anchorMessageId, anchorRow: entry.anchorRow,
                          messages: live?.messages ?? entry.kept,
                          // Started a moment ago with nothing sent yet: it is on its way, not idle.
                          running: live.map { $0.isRunning || ($0.messages.isEmpty && $0.threadProblem == nil) }
                              ?? (entry.storedId.map { model?.isSessionWorking($0) ?? false } ?? false),
                          problem: live?.threadProblem ?? entry.problem, scope: scope)
    }

    /// The Sessions rows whose parent is this bot chat become threads; a listed thread not live here is read again
    /// when its row moved.
    private func adoptListed(profile: String, parentIds: Set<String>) {
        guard let store = model?.sessionStore else { return }
        for row in store.rowsById.values where row.profile == profile && row.archived != true {
            guard let parent = row.parentSessionId, parentIds.contains(parent) else { continue }
            let entry: Entry
            if let known = entries.first(where: { $0.profile == profile && ($0.storedId == row.id || $0.live?.storedSessionId == row.id) }) {
                entry = known
                if entry.storedId == nil { entry.storedId = row.id }
            } else {
                entry = Entry(key: row.id, profile: profile, parentId: parent, storedId: row.id,
                              startedAt: Date(timeIntervalSince1970: row.startedAt ?? row.lastActive ?? Date().timeIntervalSince1970))
                entries.append(entry)
            }
            entry.rowTitle = row.title
            guard entry.live == nil else { continue }
            let stamp = "\(row.lastActive ?? 0)|\(row.messageCount ?? 0)"
            if entry.readStamp != stamp { read(entry, stamp: stamp) }
        }
    }

    private func read(_ entry: Entry, stamp: String) {
        guard !entry.reading, let client = model?.client, let stored = entry.storedId else { return }
        entry.reading = true
        let profile = entry.profile
        Task { [weak self, weak entry] in
            let result = try? await ThreadFetch.load(client: client, storedId: stored, profile: profile.isEmpty ? nil : profile)
            guard let self, let entry else { return }
            entry.reading = false
            guard let result else { return }      // the next change of its row tries again
            entry.readStamp = stamp
            guard entry.live == nil else { return }
            entry.kept = result.messages
            if let row = result.anchorRow { entry.anchorRow = row }
            entry.lastChange = Date()
            self.changed(profile)
        }
    }

    /// The Sessions list was read again: listed threads may have moved.
    func sessionsChanged() {
        for profile in Set(observers.map(\.profile)) { changed(profile) }
    }

    // MARK: Starting

    /// Starts a thread from `parent` (a bot's own chat) with `text` as its first message, under `anchor` (the message
    /// of the main chat it hangs under). The chat is made and the message sent with no screen; the reply runs beside
    /// whatever the main chat is doing.
    @discardableResult
    func start(text: String, in parent: LiveChatSession, bot: Bot, anchor: ChatMessage?, leavingOut localId: String? = nil) -> String? {
        guard let model else { return nil }
        let parentId = parent.readSessionId
        // §9: `localId` is the bubble of the words this thread is taking over; they are its message, not its seed.
        let seed = ThreadSeed.rows(from: parent.messages.filter { $0.id != localId }, running: parent.isRunning, anchorRow: anchor?.rowId,
                                   isSeedable: { !SideTaskRow.isSideRow($0) })
        var extra: [String: JSONValue] = [:]
        if let parentId { extra["parent_session_id"] = .string(parentId) }
        if !seed.isEmpty { extra["messages"] = .array(ThreadSeed.params(seed)) }
        let entry = Entry(key: "thread-\(UUID().uuidString)", profile: bot.id, parentId: parentId, storedId: nil, startedAt: Date())
        entry.anchorMessageId = anchor?.id
        entry.anchorRow = anchor?.rowId
        let folder = parent.menus.cwd.flatMap { $0.isEmpty ? nil : $0 }
        let chat = model.freshChat(for: bot, folder: folder, shownTitle: ThreadRules.defaultTitle, extra: extra) { [weak self, weak entry] stored in
            guard let self, let entry else { return }
            entry.storedId = stored
            self.changed(entry.profile)
            self.model?.refreshSessions()       // it lists under Sessions too, as any chat with that bot
        }
        entries.append(entry)
        if let live = chat as? LiveChatSession {
            adopt(live, for: entry)
            live.listenOffScreen()
            live.send(text)
            AppLog.note("threads", "thread started in \(AppLog.tag(parentId)) (profile \(bot.id)): \(seed.count) seed rows, anchor row \(anchor?.rowId.map(String.init) ?? "-"), main chat \(parent.isRunning ? "working" : "idle")")
        } else {
            entry.problem = "Not connected to the gateway."
        }
        changed(bot.id)
        trim()
        return entry.key
    }

    // MARK: A busy chat's words (docs/spec/3x-threads.md §9)

    /// By profile: the thread that last took its bot chat's words, and how many sends that chat had taken by then.
    private var busyThreads: [String: (key: String, heldAt: Int)] = [:]

    /// `parent` (a bot's own chat) cannot take `text` now: a thread takes it as its message. The same thread takes
    /// the next ones until the chat takes a send itself. False when no thread could be started (no gateway): the chat
    /// then hands the words back as it always did.
    func takeBusySend(_ text: String, from parent: LiveChatSession, bot: Bot, leavingOut localId: String) -> Bool {
        if let held = busyThreads[bot.id], let entry = entries.first(where: { $0.key == held.key }),
           ThreadRules.takesNextBusySend(heldAt: held.heldAt, accepted: parent.acceptedSends, live: entry.live != nil,
                                         problem: entry.live?.threadProblem != nil), let live = entry.live {
            live.send(text)
            AppLog.note("threads", "busy chat's words went on in its thread (profile \(bot.id))")
            changed(bot.id)
            return true
        }
        let anchor = ThreadRules.busyAnchor(in: parent.messages, leavingOut: localId)
        guard let key = start(text: text, in: parent, bot: bot, anchor: anchor, leavingOut: localId),
              let entry = entries.first(where: { $0.key == key }) else { return false }
        guard let live = entry.live else {
            entries.removeAll { $0.key == key }     // it never began: no thread line for it
            changed(bot.id)
            return false
        }
        busyThreads[bot.id] = (key, parent.acceptedSends)
        // With no screen of its own yet, words it cannot send either come back to the chat they were typed in.
        live.onDraftReturned = { [weak parent] text, reason in parent?.threadSendCameBack(text, reason: reason) }
        return true
    }

    private func adopt(_ live: LiveChatSession, for entry: Entry) {
        entry.live = live
        live.menus.isThread = true
        live.threadHold = true
        live.onThreadChange = { [weak self, weak entry, weak live] in
            guard let self, let entry, let live, entry.live === live else { return }
            var hasher = Hasher()
            hasher.combine(live.messages.count)
            if let last = live.messages.last { hasher.combine(last.id); hasher.combine(last.revision); hasher.combine(last.isStreaming) }
            hasher.combine(live.isRunning); hasher.combine(live.title); hasher.combine(live.storedSessionId)
            hasher.combine(live.threadProblem)
            let now = hasher.finalize()
            guard now != entry.drawn else { return }
            entry.drawn = now
            entry.lastChange = Date()
            if entry.storedId == nil { entry.storedId = live.storedSessionId }
            self.changed(entry.profile)
            if !live.isRunning { self.trim() }
        }
    }

    // MARK: Opening

    /// The chat for the thread's own screen: the live one, or the listed chat opened (and kept live from here on).
    func chatModel(for key: String) -> (any ChatSessionModel)? {
        guard let entry = entries.first(where: { $0.key == key }), let model else { return nil }
        if let live = entry.live { return live }
        guard let stored = entry.storedId else { return nil }
        let summary = SessionSummary(id: stored, profile: entry.profile, title: ThreadRules.name(thread(entry)), preview: nil,
                                     lastActive: entry.lastChange, source: nil, unread: false, isRunning: false)
        let chat = model.chat(for: summary)
        if let live = chat as? LiveChatSession { adopt(live, for: entry) }
        trim()
        return chat
    }

    /// "Thread", or its own short title; nil for a key not known.
    func name(for key: String) -> String? {
        entries.first(where: { $0.key == key }).map { ThreadRules.name(thread($0)) }
    }

    /// The thread whose stored chat is `storedId`, when the bot chat showing it is the one on screen: its reply is read
    /// there, so it raises no alert.
    func isDrawn(storedId: String?, profile: String, in focused: LiveChatSession?) -> Bool {
        guard let storedId, let focused, focused.menus.isBotChat, focused.profile == profile else { return false }
        return entries.contains { $0.profile == profile && ($0.storedId == storedId || $0.live?.storedSessionId == storedId) }
    }

    /// These threads stand open in the bot chat on screen: a finished reply in them is read there.
    func markSeen(_ keys: [String]) {
        guard let store = model?.sessionStore else { return }
        for entry in entries where keys.contains(entry.key) {
            guard let stored = entry.live?.storedSessionId ?? entry.storedId, entry.live?.isRunning != true else { continue }
            store.markReadInPlace(id: stored, profile: entry.profile)
        }
    }

    // MARK: Letting go

    /// Idle threads beyond the newest few stop listening; what they showed stays.
    private func trim() {
        let idle = entries.filter { entry in
            guard let live = entry.live else { return false }
            return !live.isRunning && !live.observing
        }.sorted { $0.lastChange > $1.lastChange }
        for entry in idle.dropFirst(Self.idleLive) { release(entry) }
    }

    private func release(_ entry: Entry) {
        guard let live = entry.live else { return }
        entry.kept = live.messages
        if entry.storedId == nil { entry.storedId = live.storedSessionId }
        entry.problem = live.threadProblem
        live.onThreadChange = nil
        live.endThreadHold()
        entry.live = nil
    }

    /// Sign-out or a gateway switch: nothing of this account's threads stays.
    func reset() {
        for entry in entries { entry.live?.onThreadChange = nil; entry.live?.threadHold = false }
        entries = []
        busyThreads = [:]
        observers = []
        owed = []
    }
}
