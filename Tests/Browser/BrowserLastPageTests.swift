// Watch Browser's last page: once a bot's browser closes, the viewer shows the last frame it drew, still, with the
// time, instead of "Browser Closed" (the owner, 2026-11-16). One picture per bot of each account, kept a week, gone
// with the account on sign-out.

import Foundation
import Testing
@testable import HermesHQNative

private func page(_ url: String? = "https://shop.example.com/washers", session: String? = "chat-1",
                  at: Date = Date(), bytes: Int = 64) -> BrowserLastPage {
    BrowserLastPage(jpeg: Data(repeating: 0xAB, count: bytes), width: 1280, height: 800, url: url, title: "Washers",
                    sessionId: session, at: at)
}

private func folder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "last-page-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@MainActor
struct BrowserLastPageTests {
    @Test func aKeptPageComesBackFromDiskAfterTheAppForgetsIt() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BrowserLastPages(folder: dir, writeEvery: .seconds(60))
        let kept = page()
        store.keep(kept, account: "acct-1", profile: "ivy")
        #expect(store.page(account: "acct-1", profile: "ivy") == kept, "in memory at once")
        store.flush(account: "acct-1", profile: "ivy")
        store.debugDrain()
        store.debugForgetMemory()
        #expect(store.page(account: "acct-1", profile: "ivy") == kept, "flushed to disk: a relaunched app still has it")
        #expect(store.page(account: "acct-1", profile: "wren") == nil, "one picture per bot")
        #expect(store.page(account: "acct-2", profile: "ivy") == nil, "and per account")
    }

    @Test func anUnflushedPageWaitsForItsWrite() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BrowserLastPages(folder: dir, writeEvery: .seconds(60))
        store.keep(page(), account: "acct-1", profile: "ivy")
        store.debugDrain()
        store.debugForgetMemory()
        #expect(store.page(account: "acct-1", profile: "ivy") == nil, "frames at 30 a second are not each written")
    }

    @Test func theNewestFrameWins() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BrowserLastPages(folder: dir, writeEvery: .seconds(60))
        store.keep(page("https://shop.example.com/one"), account: "a", profile: "ivy")
        store.keep(page("https://shop.example.com/two"), account: "a", profile: "ivy")
        store.flush(account: "a", profile: "ivy")
        store.debugDrain()
        store.debugForgetMemory()
        #expect(store.page(account: "a", profile: "ivy")?.url == "https://shop.example.com/two")
    }

    @Test func aWeekOldPageIsDropped() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BrowserLastPages(folder: dir, writeEvery: .seconds(60))
        let now = Date()
        store.keep(page(at: now.addingTimeInterval(-8 * 24 * 3600)), account: "a", profile: "ivy")
        #expect(store.page(account: "a", profile: "ivy", now: now) == nil)
        store.keep(page(at: now.addingTimeInterval(-3600)), account: "a", profile: "ivy")
        #expect(store.page(account: "a", profile: "ivy", now: now) != nil, "an hour old still shows")
    }

    @Test func signOutTakesEveryPictureOfTheAccount() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BrowserLastPages(folder: dir, writeEvery: .seconds(60))
        for bot in ["ivy", "wren"] {
            store.keep(page(), account: "leaving", profile: bot)
            store.flush(account: "leaving", profile: bot)
        }
        store.keep(page(), account: "staying", profile: "ivy")
        store.flush(account: "staying", profile: "ivy")
        store.purge(account: "leaving")
        store.debugDrain()
        store.debugForgetMemory()
        #expect(store.page(account: "leaving", profile: "ivy") == nil)
        #expect(store.page(account: "leaving", profile: "wren") == nil)
        #expect(store.page(account: "staying", profile: "ivy") != nil, "another account's pictures stay")
    }

    @Test func nothingIsKeptWithoutAnAccountOrAPicture() {
        let store = BrowserLastPages(folder: folder(), writeEvery: .seconds(60))
        store.keep(page(), account: "", profile: "ivy")
        store.keep(page(bytes: 0), account: "a", profile: "ivy")
        #expect(store.page(account: "", profile: "ivy") == nil)
        #expect(store.page(account: "a", profile: "ivy") == nil)
    }

    @Test func anotherChatOfTheBotShowsOnlyItsOwnPage() {
        let kept = page(session: "chat-1")
        #expect(kept.fits(BrowserScope(profile: "ivy", title: "Ivy")), "the bot's own viewer: any page of the bot")
        #expect(kept.fits(BrowserScope(profile: "ivy", sessionIds: ["chat-1"], title: "Ivy", chatOnly: true)))
        #expect(!kept.fits(BrowserScope(profile: "ivy", sessionIds: ["chat-2"], title: "Ivy", chatOnly: true)))
        #expect(!page(session: nil).fits(BrowserScope(profile: "ivy", sessionIds: ["chat-1"], title: "Ivy", chatOnly: true)))
    }

    @Test func theLastPageTakesThePlaceOfNoBrowserOnly() {
        #expect(BrowserLastPage.replaces(.none), "still asking the add-on")
        #expect(BrowserLastPage.replaces(.some(nil)), "an older add-on")
        for status in ["cloud", "hosted", "real_profile", "released", "error"] {
            #expect(BrowserLastPage.replaces(.some(OwnBrowser(status: status))), "\(status): no browser open")
        }
        for status in ["ready", "starting", "not_responding", "off"] {
            #expect(!BrowserLastPage.replaces(.some(OwnBrowser(status: status))), "\(status): its own words stay")
        }
    }

    @Test func theCaptionSaysWhen() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let locale = Locale(identifier: "en_US")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 21, minute: 30)))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 21, minute: 1)))
        let yesterday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 8, minute: 5)))
        let older = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 14, minute: 0)))
        func words(_ at: Date) -> String {
            BrowserLastPage.caption(name: "Ivy", at: at, now: now, calendar: calendar, locale: locale)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(words(today) == "Ivy’s browser has closed. This is the last page it showed, at 9:01 PM.")
        #expect(words(yesterday) == "Ivy’s browser has closed. This is the last page it showed, yesterday at 8:05 AM.")
        #expect(words(older) == "Ivy’s browser has closed. This is the last page it showed, on Nov 12, 2026 at 2:00 PM.")
    }
}
