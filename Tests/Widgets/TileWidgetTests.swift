// [tile-widgets] The Tile widget's rules (docs/spec/1x-pages.md §5.8): the store's round trip and byte caps, sign-out,
// the tiles' order, which pictures are kept, the best picture for a widget, the links, the writer's index and what it
// draws, and the pushed refresh's throttle. Keychain items go under a test prefix, never the app's own.

import CoreGraphics
import Foundation
import Testing
@testable import HermesHQNative

/// Every test that touches Keychain runs under its own prefix and clears it after.
private func withVault(_ body: () throws -> Void) rethrows {
    let saved = WidgetVault.testPrefix
    WidgetVault.testPrefix = "ai.hermes.hq.widget-test-\(UUID().uuidString.prefix(8))."
    defer {
        TileWidgetStore.removeAll()
        WidgetVault.testPrefix = saved
    }
    try body()
}

private func tile(_ id: String, page: String = TileWidgetIndex.mainPage, name: String? = nil) -> TileWidgetIndex.Tile {
    TileWidgetIndex.Tile(id: id, pin: "pin-\(id)", name: name ?? id, bot: "Otto", profile: "otto", page: page,
                         pageName: page, order: 0)
}

private func index(_ tiles: [TileWidgetIndex.Tile]) -> TileWidgetIndex {
    TileWidgetIndex(state: .live, scheme: "hermes", account: TileWidgetIndex.key("acct"), tint: 0x0A84FF, tintDark: 0x409CFF,
                    tiles: tiles)
}

private func picture(_ bytes: Int, width: Double = 164, height: Double = 164, fill: UInt8 = 1) -> TilePicture {
    TilePicture(drawnAt: Date(timeIntervalSince1970: 1_000), width: width, height: height, scale: 3, fills: true,
                edge: 0xFFFFFF, jpeg: Data(repeating: fill, count: bytes))
}

private func image(width: Int, height: Int, noisy: Bool = false) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    if noisy, let data = context.data {
        var seed: UInt32 = 7
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        for i in 0..<(context.bytesPerRow * height) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            bytes[i] = UInt8(truncatingIfNeeded: seed >> 24)
        }
    } else {
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    return context.makeImage()!
}

private let sizes: [TileFamily: CGSize] = [.small: CGSize(width: 164, height: 164), .medium: CGSize(width: 348, height: 164),
                                           .large: CGSize(width: 348, height: 366)]

@Suite(.serialized) struct TileWidgetStoreTests {
    @Test func keysAreShortStableAndCarryNoPath() {
        let key = TileWidgetIndex.key("otto\u{1F}/Users/me/dashboards/agenda.html")
        #expect(key.count == 16)
        #expect(key.allSatisfy { $0.isHexDigit })
        #expect(key == TileWidgetIndex.key("otto\u{1F}/Users/me/dashboards/agenda.html"))
        #expect(key != TileWidgetIndex.key("otto\u{1F}/Users/me/dashboards/agenda2.html"))
        #expect(WidgetLink.valid(key))
    }

    @Test func theIndexRoundTripsThroughKeychain() {
        withVault {
            let written = index([tile("a"), tile("b", page: "p1")])
            #expect(TileWidgetStore.saveIndex(written))
            #expect(TileWidgetStore.loadIndex() == written)
        }
    }

    @Test func aPictureIsWrittenOnceAndThenUnchanged() {
        withVault {
            let one = picture(10_000)
            #expect(TileWidgetStore.savePicture(one, tile: "a", family: .small, dark: false) == .written)
            #expect(TileWidgetStore.savePicture(one, tile: "a", family: .small, dark: false) == .unchanged)
            #expect(TileWidgetStore.loadPicture(tile: "a", family: .small, dark: false) == one)
            #expect(TileWidgetStore.loadPicture(tile: "a", family: .small, dark: true) == nil, "each look apart")
            #expect(TileWidgetStore.savePicture(picture(10_000, fill: 2), tile: "a", family: .small, dark: false) == .written)
        }
    }

    @Test func aPictureOverTheCapIsRefused() {
        withVault {
            let over = picture(TileWidgetStore.maxPictureBytes + 8 * 1024)
            #expect(TileWidgetStore.savePicture(over, tile: "a", family: .large, dark: false) == .refused)
            #expect(TileWidgetStore.loadPicture(tile: "a", family: .large, dark: false) == nil)
            let under = picture(TileWidgetStore.maxPictureBytes - 1024)
            #expect(TileWidgetStore.savePicture(under, tile: "a", family: .large, dark: false) == .written)
        }
    }

    @Test func signOutLeavesOnlyASignedOutIndex() {
        withVault {
            _ = TileWidgetStore.saveIndex(index([tile("a")]))
            _ = TileWidgetStore.savePicture(picture(500), tile: "a", family: .small, dark: false)
            _ = TileWidgetStore.savePicture(picture(500), tile: "a", family: .small, dark: true)
            TileWidgetStore.noteWant(TileWant(tile: "a", family: .small, width: 164, height: 164, at: Date()))
            TileWidgetStore.signOut(scheme: "hermes")
            #expect(WidgetVault.accounts(service: TileWidgetStore.pictureService).isEmpty)
            #expect(TileWidgetStore.wants().isEmpty)
            let left = TileWidgetStore.loadIndex()
            #expect(left?.state == .signedOut)
            #expect(left?.tiles.isEmpty == true)
            #expect(left?.account == "")
            #expect(left?.scheme == "hermes")
        }
    }

    @Test func onlyWantedPicturesAreKept() {
        withVault {
            for family in [TileFamily.small, .medium] {
                for dark in [false, true] { _ = TileWidgetStore.savePicture(picture(100), tile: "a", family: family, dark: dark) }
            }
            _ = TileWidgetStore.savePicture(picture(100), tile: "gone", family: .small, dark: false)
            let removed = TileWidgetStore.keepPictures([TilePictureSpec(tile: "a", family: .small, width: 164, height: 164)])
            #expect(removed)
            #expect(Set(WidgetVault.accounts(service: TileWidgetStore.pictureService)) == ["a.small.l", "a.small.d"])
            #expect(!TileWidgetStore.keepPictures([TilePictureSpec(tile: "a", family: .small, width: 164, height: 164)]))
        }
    }

    @Test func aWantIsWrittenOnlyWhenItSaysSomethingNew() {
        withVault {
            let now = Date()
            #expect(TileWidgetStore.noteWant(TileWant(tile: nil, family: .medium, width: 348, height: 164, at: now)))
            #expect(!TileWidgetStore.noteWant(TileWant(tile: nil, family: .medium, width: 348, height: 164, at: now + 60)))
            #expect(TileWidgetStore.noteWant(TileWant(tile: nil, family: .medium, width: 350, height: 164, at: now + 120)),
                    "a new size")
            #expect(TileWidgetStore.noteWant(TileWant(tile: nil, family: .medium, width: 350, height: 164, at: now + 4000)),
                    "an hour on")
            #expect(TileWidgetStore.wants().count == 1)
        }
    }
}

struct TileWidgetPlanTests {
    @Test func tilesFollowTheTilesPageOrder() {
        let tiles = [tile("p2a", page: "p2"), tile("m1"), tile("p1a", page: "p1"), tile("m2"), tile("p2b", page: "p2"),
                     tile("lost", page: "deleted")]
        let ordered = TileWidgetIndex.ordered(tiles, pages: ["main", "p1", "p2"])
        #expect(ordered.map(\.id) == ["m1", "m2", "p1a", "p2a", "p2b", "lost"])
        #expect(ordered.map(\.order) == Array(0..<6))
        // The pages' own order (ArtifactPins always lists Main first; the rule doesn't assume it).
        #expect(TileWidgetIndex.ordered(tiles, pages: ["p2", "main", "p1"]).prefix(2).map(\.id) == ["p2a", "p2b"],
                "the pages' own order")
    }

    @Test func aWidgetWithNoTileShowsMainsFirst() {
        #expect(index([tile("x", page: "p1"), tile("m")]).defaultTile?.id == "m")
        #expect(index([tile("x", page: "p1")]).defaultTile?.id == "x")
        #expect(index([]).defaultTile == nil)
        #expect(index([tile("a"), tile("b")]).tile("b")?.id == "b")
        #expect(index([tile("a")]).tile("removed") == nil, "a removed tile: none (the widget says so)")
    }

    @Test func wantedPicturesArePlacedWidgetsAndTheFirstTile() {
        let idx = index([tile("a"), tile("b"), tile("c", page: "p1")])
        let now = Date()
        let specs = TileWidgetPlan.wanted(index: idx, wants: [], placed: [("b", .large), (nil, .medium), ("removed", .small)],
                                          fallback: sizes, now: now)
        #expect(specs == [
            TilePictureSpec(tile: "b", family: .large, width: 348, height: 366),
            TilePictureSpec(tile: "a", family: .medium, width: 348, height: 164),
            TilePictureSpec(tile: "a", family: .small, width: 164, height: 164),
            TilePictureSpec(tile: "a", family: .large, width: 348, height: 366),
        ])
        // Add to Home Screen…: the asked tile at all three.
        let asked = TileWidgetPlan.wanted(index: idx, wants: [], placed: [], asked: ["c"], fallback: sizes, now: now)
        #expect(asked.filter { $0.tile == "c" }.map(\.family) == [.small, .medium, .large])
        // Signed out: nothing.
        #expect(TileWidgetPlan.wanted(index: .signedOut(scheme: "hermes"), wants: [], placed: [("a", .small)], fallback: sizes,
                                      now: now).isEmpty)
    }

    /// A tile picked in Edit Widget shows at once: every tile's three sizes are kept ahead of the choice, after the
    /// placed ones, and only the first `ahead` tiles.
    @Test func everyTilesThreeSizesAreKeptAheadOfAChoice() {
        let idx = index([tile("a"), tile("b"), tile("c", page: "p1")])
        let now = Date()
        let placed: [(tile: String?, family: TileFamily)] = [("b", .large)]
        let live = TileWidgetPlan.wanted(index: idx, wants: [], placed: placed, fallback: sizes, now: now)
        let all = TileWidgetPlan.wanted(index: idx, wants: [], placed: placed, ahead: 12, fallback: sizes, now: now)
        #expect(Array(all.prefix(live.count)) == live, "what is on a widget comes first")
        for id in ["a", "b", "c"] {
            #expect(Set(all.filter { $0.tile == id }.map(\.family)) == [.small, .medium, .large], "\(id) at all three")
        }
        #expect(all.count == 9, "none twice")
        let ahead = TileWidgetPlan.aheadOnly(all: all, live: live)
        #expect(ahead == Set(all.filter { $0.tile == "c" || ($0.tile == "b" && $0.family != .large) }))
        // Only the first tiles when there are many.
        let two = TileWidgetPlan.wanted(index: idx, wants: [], placed: [], ahead: 2, fallback: sizes, now: now)
        #expect(Set(two.map(\.tile)) == ["a", "b"])
    }

    @Test func aWidgetsOwnSizeWinsAndOldWantsAreForgotten() {
        let idx = index([tile("a"), tile("b")])
        let now = Date()
        let wants = [TileWant(tile: "b", family: .medium, width: 349.7, height: 164.3, at: now - 60),
                     TileWant(tile: nil, family: .medium, width: 340, height: 160, at: now - 600),
                     TileWant(tile: "a", family: .large, width: 500, height: 500, at: now - TileWidgetPlan.wantKeptFor - 1)]
        // The system couldn't say what's placed: the recent wants stand in.
        let specs = TileWidgetPlan.wanted(index: idx, wants: wants, placed: nil, fallback: sizes, now: now)
        #expect(specs.contains(TilePictureSpec(tile: "b", family: .medium, width: 350, height: 164)), "the newest want's size")
        #expect(specs.contains(TilePictureSpec(tile: "a", family: .medium, width: 350, height: 164)))
        #expect(specs.contains(TilePictureSpec(tile: "a", family: .large, width: 348, height: 366)), "the old want forgotten")
        #expect(!specs.contains { $0.width == 500 })
    }

    @Test func theBestPictureIsItsOwnThenTheOtherLookThenAnotherSize() {
        let own = picture(1, fill: 1), otherLook = picture(1, fill: 2), otherSize = picture(1, fill: 3)
        #expect(TileWidgetPlan.best(for: "a", family: .small, dark: true) { _, family, dark in
            family == .small ? (dark ? own : otherLook) : otherSize
        }?.exact == true)
        let lookOnly = TileWidgetPlan.best(for: "a", family: .small, dark: true) { _, family, dark in
            family == .small && !dark ? otherLook : nil
        }
        #expect(lookOnly?.picture == otherLook)
        #expect(lookOnly?.exact == false)
        let sizeOnly = TileWidgetPlan.best(for: "a", family: .small, dark: false) { _, family, dark in
            family == .large && !dark ? otherSize : nil
        }
        #expect(sizeOnly?.picture == otherSize)
        #expect(TileWidgetPlan.best(for: "a", family: .small, dark: false) { _, _, _ in nil } == nil)
    }

    @Test func aPictureFillsWhenItsShapeIsCloseEnough() {
        #expect(TileWidgetPlan.fills(CGSize(width: 164, height: 164), in: CGSize(width: 164.3, height: 164.3)))
        #expect(TileWidgetPlan.fills(CGSize(width: 348, height: 164), in: CGSize(width: 349.7, height: 164.3)))
        #expect(!TileWidgetPlan.fills(CGSize(width: 164, height: 164), in: CGSize(width: 348, height: 164)))
        #expect(!TileWidgetPlan.fills(.zero, in: CGSize(width: 10, height: 10)))
    }

    @Test func fallbackSizesFollowTheScreen() {
        let pro = TileWidgetPlan.fallbackSizes(screen: CGSize(width: 402, height: 874), pad: false)
        #expect(pro[.small] == CGSize(width: 164, height: 164))
        #expect(pro[.medium] == CGSize(width: 348, height: 164))
        #expect(pro[.large] == CGSize(width: 348, height: 366))
        #expect(pro[.extraLarge] == nil, "no Extra Large on a phone")
        let landscape = TileWidgetPlan.fallbackSizes(screen: CGSize(width: 874, height: 402), pad: false)
        #expect(landscape == pro)
        let pad = TileWidgetPlan.fallbackSizes(screen: CGSize(width: 1032, height: 1376), pad: true)
        #expect(pad[.extraLarge] == CGSize(width: 795, height: 378.5))
    }

    @Test func aJPEGFitsTheCapOrIsLeftOut() throws {
        let plain = try #require(TilePictureEncoding.jpeg(image(width: 492, height: 492)))
        #expect(plain.count < 40 * 1024)
        let noisy = image(width: 1050, height: 1100, noisy: true)
        let capped = TilePictureEncoding.jpeg(noisy, maxBytes: 400 * 1024)
        if let capped { #expect(capped.count <= 400 * 1024) }
        #expect(TilePictureEncoding.jpeg(noisy, maxBytes: 1024) == nil, "never shrunk in pixels to fit")
    }

    @Test func aPictureLargerThanItsWidgetIsScaledInside() {
        let fitted = TilePictureEncoding.fitted(image(width: 2000, height: 1000), inside: CGSize(width: 1000, height: 1000))
        #expect(fitted.width == 1000)
        #expect(fitted.height == 500)
        let small = image(width: 400, height: 400)
        #expect(TilePictureEncoding.fitted(small, inside: CGSize(width: 492, height: 492)) === small)
    }
}

struct WidgetLinkTests {
    @Test func everyLinkRoundTrips() throws {
        let links: [WidgetLink] = [.tile(key: "0123456789abcdef", account: "fedcba9876543210"), .tiles, .tasks,
                                   .task(id: "t_42", account: "fedcba9876543210"), .newTask, .open]
        for link in links {
            let url = try #require(link.url(scheme: "hermes"))
            #expect(url.scheme == "hermes")
            #expect(url.host == "widget")
            #expect(WidgetLink.parse(url, scheme: "hermes") == link)
            #expect(WidgetLink.parse(url, scheme: "HERMES") == link, "the scheme in any case")
        }
    }

    @Test func otherLinksAreNotOurs() {
        #expect(WidgetLink.parse(URL(string: "hermes://widget/tile?id=abc&account=def")!, scheme: "hermesdev") == nil)
        #expect(WidgetLink.parse(URL(string: "hermes://job/tile?id=abc&account=def")!, scheme: "hermes") == nil)
        #expect(WidgetLink.parse(URL(string: "hermes://widget/tile?id=../../etc&account=def")!, scheme: "hermes") == nil)
        #expect(WidgetLink.parse(URL(string: "hermes://widget/tile?id=abc")!, scheme: "hermes") == nil, "no account")
        #expect(WidgetLink.parse(URL(string: "hermes://widget/reboot")!, scheme: "hermes") == nil)
        #expect(!WidgetLink.valid(String(repeating: "a", count: 161)))
    }
}

@MainActor struct TileWidgetWriterTests {
    private let account = GatewayAccount(id: "http://127.0.0.1:9741|me", baseURL: URL(string: "http://127.0.0.1:9741")!,
                                         kind: .password, username: "me", label: "127.0.0.1")

    @Test func theIndexHasThePageTilesInTheTilesOrder() {
        let pins = ArtifactPins(fileURL: nil)
        let agenda = ArtifactPin(kind: .file, value: "/Users/me/dashboards/agenda.html", label: "", profile: "otto",
                                 sessionId: "s", sessionTitle: "t")
        let photo = ArtifactPin(kind: .file, value: "/Users/me/photo.png", label: "", profile: "otto", sessionId: "s",
                                sessionTitle: "t")
        let weather = ArtifactPin(kind: .file, value: "/Users/me/dashboards/weather.html", label: "", profile: "ivy",
                                  sessionId: "s", sessionTitle: "t")
        let site = ArtifactPin(kind: .link, value: "https://example.com/page.html", label: "", profile: "otto", sessionId: "s",
                               sessionTitle: "t")
        for pin in [weather, photo, agenda, site] { _ = pins.pin(pin) }
        let home = pins.addPage(named: "Home")
        pins.setPage(home.id, id: weather.id)
        pins.rename(id: agenda.id, to: "Today's Agenda")
        let index = TileWidgetWriter.index(pins: pins, bots: [], account: account, scheme: "hermes", tint: (0x0A84FF, nil))
        #expect(index.state == .live)
        #expect(index.account == TileWidgetIndex.key(account.id))
        #expect(index.tiles.map(\.pin) == [agenda.id, weather.id], "pages only, Main first; a picture and a link left out")
        #expect(index.tiles.first?.name == "Today's Agenda")
        #expect(index.tiles.first?.page == TileWidgetIndex.mainPage)
        #expect(index.tiles.last?.pageName == "Home")
        #expect(index.tiles.allSatisfy { !$0.id.contains("/") }, "no path in a widget's settings")
        #expect(index.defaultTile?.pin == agenda.id)
    }

    @Test func whatIsDrawnThisPass() {
        let a = TilePictureSpec(tile: "a", family: .small, width: 164, height: 164)
        let b = TilePictureSpec(tile: "b", family: .small, width: 164, height: 164)
        let now = Date()
        // No picture yet: drawn, even just drawn.
        #expect(TileWidgetWriter.due([a], stale: [], drawn: [TileWidgetWriter.specKey(a): now], has: { _ in false }, now: now) == [a])
        // Everything may have changed (nil): all, unless drawn in the last minute.
        #expect(TileWidgetWriter.due([a, b], stale: nil, drawn: [TileWidgetWriter.specKey(a): now - 30], has: { _ in true },
                                     now: now) == [b])
        #expect(TileWidgetWriter.due([a, b], stale: nil, drawn: [TileWidgetWriter.specKey(a): now - 90], has: { _ in true },
                                     now: now) == [a, b])
        // Only the stale tiles.
        #expect(TileWidgetWriter.due([a, b], stale: ["b"], drawn: [:], has: { _ in true }, now: now) == [b])
        #expect(TileWidgetWriter.due([a, b], stale: [], drawn: [:], has: { _ in true }, now: now).isEmpty)
        // Kept ahead of a choice: drawn while it has no picture, never again just because its page may have changed.
        #expect(TileWidgetWriter.due([a, b], stale: nil, drawn: [:], aheadOnly: [b], has: { _ in true }, now: now) == [a])
        #expect(TileWidgetWriter.due([a, b], stale: [], drawn: [:], aheadOnly: [b], has: { $0 == a }, now: now) == [b])
    }

    @Test func aPushRefreshesAtMostEveryTenMinutes() {
        let now = Date()
        #expect(WidgetRefresh.shouldRunPushed(last: nil, now: now))
        #expect(!WidgetRefresh.shouldRunPushed(last: now - 60, now: now))
        #expect(!WidgetRefresh.shouldRunPushed(last: now - 599, now: now))
        #expect(WidgetRefresh.shouldRunPushed(last: now - 600, now: now))
        #expect(WidgetRefresh.shouldRunPushed(last: now + 3600, now: now), "the clock went back")
    }
}
