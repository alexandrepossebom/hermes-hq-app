import Foundation

/// Which of a chat's messages is the newest to hand over each page. A bot that is asked to change its page answers by
/// rewriting the file and handing the same page over again, so a chat about one page grew a column of identical big
/// cards (they all picture the file as it is now). The newest keeps its card; the earlier ones fold to one line that
/// says "Updated below" (`PageCardView`). Owner 2026-11-17, Grok Bot's pages do this.
nonisolated enum PageOrder {
    /// The pages a reply's text hands over alone on a line (`::preview{file="…"}`, `MEDIA:/…/page.html`, a bare path),
    /// as written.
    static func paths(in text: String) -> [String] {
        guard text.range(of: ".htm", options: .caseInsensitive) != nil else { return [] }
        var out: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.range(of: ".htm", options: .caseInsensitive) != nil else { continue }
            var path: String?
            if let named = MediaTags.previewPath(line) {
                path = named
            } else if line.hasPrefix("MEDIA:") {
                path = String(line.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: " `\"'"))
            } else if line.hasPrefix("/") || line.hasPrefix("~/") || line.hasPrefix("`/") || line.hasPrefix("`~/") {
                let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                if !bare.contains(" ") || bare.hasSuffix(".html") || bare.hasSuffix(".htm") { path = bare }
            }
            if let path, HTMLPageSheet.opens(name: path), !out.contains(path) { out.append(path) }
        }
        return out
    }

    private static let lock = NSLock()
    /// Each message's pages by its id, with the length of the text they were read from (a streaming reply grows).
    nonisolated(unsafe) private static var known: [String: (length: Int, paths: [String])] = [:]

    static func paths(of message: ChatMessage) -> [String] {
        var length = 0
        for part in message.parts { if case .text(let text) = part { length += text.utf8.count } }
        guard length > 0 else { return [] }
        lock.lock()
        if let hit = known[message.id], hit.length == length { lock.unlock(); return hit.paths }
        lock.unlock()
        var found: [String] = []
        for part in message.parts {
            if case .text(let text) = part { for path in paths(in: text) where !found.contains(path) { found.append(path) } }
        }
        lock.lock()
        if known.count > 20_000 { known.removeAll() }
        known[message.id] = (length, found)
        lock.unlock()
        return found
    }

    /// For each page the bot's messages hand over: the id of the newest message that does. Empty for a chat with no pages.
    static func latest(_ messages: [ChatMessage]) -> [String: String] {
        var out: [String: String] = [:]
        for message in messages where message.role == .assistant {
            for path in paths(of: message) { out[path] = message.id }
        }
        return out
    }

    /// [page-fold] The oldest message at or after `floor` that hands over a page `messages[from...]` hand over too; `from`
    /// when there is none. A new reply that hands a page over again folds the earlier cards, so their rows are made
    /// again with it (`ChatRowModel.rebuildNewest`).
    static func reach(from: Int, floor: Int, in messages: [ChatMessage]) -> Int {
        guard from > floor, from < messages.count else { return from }
        var named = Set<String>()
        for message in messages[from...] where message.role == .assistant { named.formUnion(paths(of: message)) }
        guard !named.isEmpty else { return from }
        var lowest = from
        var i = from - 1
        while i >= floor {
            if messages[i].role == .assistant, paths(of: messages[i]).contains(where: named.contains) { lowest = i }
            i -= 1
        }
        return lowest
    }

    /// The last chat asked about, and its answer: one build of a chat's rows asks once per bubble that hands a page over.
    nonisolated(unsafe) private static var memo: (key: String, latest: [String: String])?

    /// The pages `text` (part of message `id`) hands over that a later message of the chat hands over again. A bubble
    /// with no page costs one search of its own text; the chat is only read for one that has.
    static func updatedBelow(_ text: String, messageId id: String, in messages: [ChatMessage]) -> Set<String> {
        let own = paths(in: text)
        guard !own.isEmpty, let last = messages.last else { return [] }
        var length = 0
        for part in last.parts { if case .text(let text) = part { length += text.utf8.count } }
        let key = "\(messages.count)|\(messages.first?.id ?? "")|\(last.id)|\(length)"
        lock.lock()
        let kept = memo?.key == key ? memo?.latest : nil
        lock.unlock()
        let newest = kept ?? latest(messages)
        if kept == nil {
            lock.lock()
            memo = (key, newest)
            lock.unlock()
        }
        return Set(own.filter { newest[$0].map { $0 != id } ?? false })
    }

    /// The pages `text` (part of message `id`) hands over that a later message hands over again.
    static func updatedBelow(_ text: String, messageId id: String, latest: [String: String]) -> Set<String> {
        guard !latest.isEmpty else { return [] }
        return Set(paths(in: text).filter { latest[$0].map { $0 != id } ?? false })
    }
}
