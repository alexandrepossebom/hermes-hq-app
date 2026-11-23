// [favorites-live-tiles] A Dashboard tile on Favorites (docs/spec/3x-morepages.md §25 Q15–Q21; a public-beta tester,
// 2026-11-22: "it would be cool if for the new Favourites feature that you could add actual tiles instead of just a
// link to tiles"): its stored form, the missing rule, its route, Add Action's list and its sizes.
import CoreGraphics
import Foundation
import Testing
@testable import HermesHQNative

private func dashboardTile(id: String = "t1", pin: String? = "otto\u{1F}/Users/me/site/tile.html", name: String = "Revenue",
                           wide: Bool = false) -> QuickTile {
    var tile = QuickTile(id: id, kind: .dashboardTile, name: name, wide: wide)
    tile.pin = pin
    tile.pinName = pin == nil ? nil : name
    return tile
}

private func pin(_ file: String, bot: String = "otto") -> ArtifactPin {
    ArtifactPin(kind: .file, value: "/Users/me/site/\(file)", label: file, profile: bot, sessionId: "s1", sessionTitle: "Site")
}

@Suite struct FavoriteDashboardTileStoreTests {
    // Q15: stored as kind "dashboard-tile" with the pin's id and name, only when set; read back as written.
    @Test func aDashboardTileIsStoredAndReadBack() throws {
        let box = IntentsDefaults()
        var list = QuickTileList()
        list.add(dashboardTile(id: "t1", wide: true))
        list.add(QuickTile(id: "s", kind: .search))
        #expect(QuickTileStore.save(list, box.defaults))
        let back = QuickTileStore.load(box.defaults)
        #expect(back.tiles == list.tiles)
        #expect(back.tiles[0].known == .dashboardTile && back.tiles[0].wide)
        let raw = try #require(JSONSerialization.jsonObject(with: box.defaults.data(forKey: QuickTileStore.key) ?? Data()) as? [String: Any])
        let tiles = try #require(raw["tiles"] as? [[String: Any]])
        #expect(tiles[0]["kind"] as? String == "dashboard-tile")
        #expect(tiles[0]["pin"] as? String == "otto\u{1F}/Users/me/site/tile.html")
        #expect(tiles[0]["pinName"] as? String == "Revenue")
        #expect(tiles[1]["pin"] == nil && tiles[1]["pinName"] == nil, "a tile without a pin writes neither key")
        #expect(back.tiles[0].subtitle(botName: nil) == "tile")
        #expect(back.pins == ["otto\u{1F}/Users/me/site/tile.html"])
    }

    // Q15, Q8: as an older build wrote it back (it has no `pin` field, so the entry lost it): still read, kept in its
    // place, drawn switched off and never removed.
    @Test func anEntryAnOlderBuildWroteBackIsKept() {
        let box = IntentsDefaults()
        let json = """
        {"version":1,"seeded":true,"tiles":[
          {"id":"t1","kind":"dashboard-tile","name":"Revenue","symbol":"chart.xyaxis.line","color":"accent","wide":true},
          {"id":"s","kind":"search","name":"Search Chats","symbol":"magnifyingglass","color":"gray"}
        ]}
        """
        box.defaults.set(Data(json.utf8), forKey: QuickTileStore.key)
        let list = QuickTileStore.load(box.defaults)
        #expect(list.tiles.map(\.id) == ["t1", "s"])
        #expect(list.tiles[0].known == .dashboardTile && list.tiles[0].pin == nil)
        let missing = QuickTileRules.missing(list.tiles[0], world: QuickTileWorld(pins: [:]))
        #expect(missing == "“Revenue” isn’t on your Dashboard any more.")
        #expect(QuickTileRoute.make(list.tiles[0], world: QuickTileWorld()) == .unavailable("“Revenue” isn’t on your Dashboard any more."))
    }
}

@Suite struct FavoriteDashboardTileRuleTests {
    private let id = "otto\u{1F}/Users/me/site/tile.html"

    // Q20: a pin not on this account's Dashboard: one sentence, nothing runs, the tile stays; an unknown Dashboard
    // (signed out, no account yet) is never "missing".
    @Test func aPinNoLongerOnTheDashboardIsMissing() {
        let tile = dashboardTile()
        #expect(QuickTileRules.missing(tile, world: QuickTileWorld(pins: ["other": "Other"])) == "“Revenue” isn’t on your Dashboard any more.")
        #expect(QuickTileRules.missing(tile, world: QuickTileWorld(pins: [id: "Revenue"])) == nil)
        #expect(QuickTileRules.missing(tile, world: QuickTileWorld()) == nil, "not known yet is never missing")
        #expect(QuickTileRoute.make(tile, world: QuickTileWorld(pins: [:])) == .unavailable("“Revenue” isn’t on your Dashboard any more."))
        #expect(QuickTileRoute.make(tile, world: QuickTileWorld(pins: [id: "Revenue"])) == .dashboardTile(id: id))
        #expect(!QuickTileRoute.dashboardTile(id: id).staysOnPage, "it opens something: the sheet closes and goes")
        // Gone, then pinned again: it is the same tile, working again (nothing removed it meanwhile).
        var list = QuickTileList(tiles: [tile], seeded: true)
        list.setWide(tile.id, true)
        #expect(list.tiles.count == 1)
    }

    // Q17: its name follows the pin's until it is typed over.
    @Test func itsNameFollowsThePinsUntilTypedOver() {
        var tile = dashboardTile()
        #expect(tile.shownName(currentPinName: "Revenue This Week") == "Revenue This Week")
        #expect(tile.shownName(currentPinName: nil) == "Revenue", "gone: the name it had")
        tile.name = "Money"
        #expect(tile.shownName(currentPinName: "Revenue This Week") == "Money")
        #expect(QuickTile(id: "m", kind: .memo, name: "Revenue").shownName(currentPinName: "Other") == "Revenue", "only a Dashboard tile")
    }

    // Q16: a picture is Small or Wide, never Short.
    @Test func aDashboardTileIsNeverShort() {
        var list = QuickTileList(tiles: [dashboardTile(), QuickTile(id: "m", kind: .memo)], seeded: true)
        list.setShort("t1", true)
        list.setShort("m", true)
        #expect(list.tiles.map(\.short) == [false, true])
        #expect(QuickTileKind.dashboardTile.isPicture && !QuickTileKind.memo.isPicture)
    }

    // Q19: Small is one column and square; Wide both columns, a Small tile's height (a Dashboard Medium's shape).
    @Test func smallIsSquareAndWideIsTwoColumnsAsTallAsASmallOne() {
        let small = FavoriteTileSize.picture(width: 402, side: 16, gap: 12, wide: false, stacked: false)
        let wide = FavoriteTileSize.picture(width: 402, side: 16, gap: 12, wide: true, stacked: false)
        #expect(small == CGSize(width: 179, height: 179))
        #expect(wide == CGSize(width: 370, height: 179))
        #expect(FavoriteTileSize.picture(width: 402, side: 16, gap: 12, wide: false, stacked: true) == wide, "one column: full width")
        #expect(FavoriteTileSize.height(picture: small, names: true, nameHeight: 20) == 199)
        #expect(FavoriteTileSize.height(picture: small, names: false, nameHeight: 20) == 179)
    }
}

@MainActor @Suite struct FavoriteDashboardTileAddTests {
    // Q15: Add Action lists the Dashboard's tiles in its order, named as it names them, less those on Favorites.
    @Test func addActionHidesPinsAlreadyOnFavorites() {
        let pins = [pin("tile.html"), pin("live.html"), pin("chart.png")]
        let names = [pins[0].id: "Revenue", pins[1].id: "Sales Today", pins[2].id: "Chart"]
        var list = QuickTileList(tiles: [dashboardTile(pin: pins[1].id, name: "Sales Today")], seeded: true)
        var choices = QuickActionChoice.dashboardTiles(pins, names: names, on: list)
        #expect(choices.map(\.title) == ["Revenue", "Chart"])
        #expect(choices.map(\.identifier) == ["quick.add.tile.tile.html", "quick.add.tile.chart.png"])
        #expect(choices.allSatisfy { $0.kind == .dashboardTile && $0.detail == "tile" })
        let made = choices[0].newTile()
        #expect(made.known == .dashboardTile && made.pin == pins[0].id && made.name == "Revenue" && made.pinName == "Revenue")
        // Added, it leaves the list; removed from Favorites, it is back.
        list.add(made)
        choices = QuickActionChoice.dashboardTiles(pins, names: names, on: list)
        #expect(choices.map(\.title) == ["Chart"])
        list.remove(made.id)
        #expect(QuickActionChoice.dashboardTiles(pins, names: names, on: list).count == 2)
        // An empty Dashboard: no rows, so no section.
        #expect(QuickActionChoice.dashboardTiles([], names: [:], on: list).isEmpty)
        // Searchable by name.
        #expect(choices[0].matches("chart") && !choices[0].matches("revenue"))
    }
}
