// Watch Browser's last page (the owner, 2026-11-16: "once it was done, I couldn't see it anymore"). A cloud browser
// (Browser Use Cloud, a copy of the person's profile) closes when the bot is done with it, and the viewer used to go
// blank ("Browser Closed"). The viewer now keeps the last frame it drew for each bot and shows it, still, with the time,
// until that bot opens a browser again. One picture per bot, in Caches under the account's key, with file protection;
// sign-out deletes the account's pictures. Only frames this phone was shown are kept: nothing is fetched for it.

import CryptoKit
import Foundation

/// The last page a bot's browser showed on this phone: the frame's JPEG as the add-on sent it, the page's size, and
/// where it was.
nonisolated struct BrowserLastPage: Sendable, Equatable, Codable {
    var jpeg: Data
    var width: Double
    var height: Double
    var url: String?
    var title: String?
    /// The chat that drove the browser (`BrowserRow.driver`): a chat-only viewer shows only its own chat's page.
    var sessionId: String?
    /// When the frame was drawn.
    var at: Date

    /// The site, as the address field says it ("bestbuy.com"); empty for a blank tab.
    var host: String { BrowserAddress(url).host }

    /// A last page is kept this long; an older one is deleted on read.
    static let keptFor: TimeInterval = 7 * 24 * 3600

    func fresh(now: Date = Date()) -> Bool { now.timeIntervalSince(at) < Self.keptFor && at <= now.addingTimeInterval(60) }

    /// Whether a viewer with `scope` shows it: any page of the bot, or for another chat of the bot only its own.
    func fits(_ scope: BrowserScope) -> Bool {
        guard scope.chatOnly else { return true }
        guard let sessionId, !sessionId.isEmpty else { return false }
        return scope.sessionIds.contains(sessionId)
    }

    /// The words under the page: "Ivy’s browser has closed. This is the last page it showed, at 9:01 PM."
    static func caption(name: String, at: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let when: String
        if calendar.isDate(at, inSameDayAs: now) {
            when = "at \(at.formatted(time))"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(at, inSameDayAs: yesterday) {
            when = "yesterday at \(at.formatted(time))"
        } else {
            let day = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            when = "on \(at.formatted(day)) at \(at.formatted(time))"
        }
        return "\(name)’s browser has closed. This is the last page it showed, \(when)."
    }

    /// The "no browser" states the last page takes the place of: the bot has no browser open and none is on its way.
    /// A browser starting or not answering keeps its own words (it shows live in a moment), and so does an add-on
    /// that is switched off (its button is the next step).
    static func replaces(_ own: OwnBrowser??) -> Bool {
        switch own {
        case .none, .some(.none): return true
        case .some(.some(let o)):
            return !["ready", "starting", "external", "unknown", "not_responding", "off"].contains(o.status)
        }
    }
}

/// The kept pictures, one per bot of each account. Main actor; disk writes go to a utility queue, at most one per bot
/// every `writeEvery` while frames arrive, and at once on `flush` (the browser closed, the viewer left).
final class BrowserLastPages {
    static let shared = BrowserLastPages()

    private let folder: URL
    private let writeEvery: Duration
    private var memory: [String: BrowserLastPage] = [:]
    private var dirty: Set<String> = []
    private var writers: [String: Task<Void, Never>] = [:]
    private let disk = DispatchQueue(label: "ai.hermes.hqnative.browser.lastpage", qos: .utility)

    init(folder: URL = URL.cachesDirectory.appending(path: "browser-last-page", directoryHint: .isDirectory),
         writeEvery: Duration = .seconds(3)) {
        self.folder = folder
        self.writeEvery = writeEvery
    }

    nonisolated static func key(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    private func accountFolder(_ account: String) -> URL {
        folder.appending(path: Self.key(account), directoryHint: .isDirectory)
    }

    private func file(_ account: String, _ profile: String) -> URL {
        accountFolder(account).appending(path: Self.key(profile) + ".json")
    }

    private func slot(_ account: String, _ profile: String) -> String { "\(account)\u{1F}\(profile)" }

    /// The newest frame of `profile`'s browser: kept in memory now, on disk shortly.
    func keep(_ page: BrowserLastPage, account: String, profile: String) {
        guard !account.isEmpty, !profile.isEmpty, !page.jpeg.isEmpty, page.jpeg.count <= BrowserWire.maxFrameImage else { return }
        let slot = slot(account, profile)
        memory[slot] = page
        dirty.insert(slot)
        guard writers[slot] == nil else { return }
        let wait = writeEvery
        writers[slot] = Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.writers[slot] = nil
            self?.write(account: account, profile: profile)
        }
    }

    /// Writes `profile`'s page now if a newer one waits (the browser closed, or the viewer is leaving).
    func flush(account: String, profile: String) {
        let slot = slot(account, profile)
        writers[slot]?.cancel()
        writers[slot] = nil
        write(account: account, profile: profile)
    }

    private func write(account: String, profile: String) {
        let slot = slot(account, profile)
        guard dirty.remove(slot) != nil, let page = memory[slot] else { return }
        let url = file(account, profile)
        disk.async {
            guard let data = try? JSONEncoder().encode(page) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// `profile`'s last page, if one is kept and not older than a week.
    func page(account: String, profile: String, now: Date = Date()) -> BrowserLastPage? {
        guard !account.isEmpty, !profile.isEmpty else { return nil }
        let slot = slot(account, profile)
        if let kept = memory[slot] {
            if kept.fresh(now: now) { return kept }
            forget(account: account, profile: profile)
            return nil
        }
        let url = file(account, profile)
        var data: Data?
        disk.sync { data = try? Data(contentsOf: url) }
        guard let data, let page = try? JSONDecoder().decode(BrowserLastPage.self, from: data) else { return nil }
        guard page.fresh(now: now) else { forget(account: account, profile: profile); return nil }
        memory[slot] = page
        return page
    }

    private func forget(account: String, profile: String) {
        let slot = slot(account, profile)
        memory[slot] = nil
        dirty.remove(slot)
        writers[slot]?.cancel()
        writers[slot] = nil
        let url = file(account, profile)
        disk.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Sign-out: every picture of the account goes.
    func purge(account: String) {
        for slot in memory.keys where slot.hasPrefix(account + "\u{1F}") {
            memory[slot] = nil
            dirty.remove(slot)
            writers[slot]?.cancel()
            writers[slot] = nil
        }
        let url = accountFolder(account)
        disk.async { try? FileManager.default.removeItem(at: url) }
    }

    #if DEBUG
    /// Tests: wait for the disk queue.
    func debugDrain() { disk.sync {} }
    func debugForgetMemory() { memory.removeAll() }
    #endif
}
