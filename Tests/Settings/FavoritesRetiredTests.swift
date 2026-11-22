import Foundation
import Testing
@testable import HermesHQNative

/// [favorites-retired] Owner 2026-11-22: the Favorites page is gone and Quick Actions replaces it. A stored Favorites
/// tab (by key or saved tag) is the Quick Actions tab, the other pages keep their tags, More search's "favorites" finds
/// Quick Actions, and the pages chosen on Favorites join Quick Actions once as page tiles.
@Suite struct FavoritesRetiredTests {
    private func defaults() -> UserDefaults {
        let name = "FavoritesRetiredTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let pages: [String: (title: String, symbol: String)] = [
        "review": ("Review", "arrow.triangle.branch"), "tasks": ("Tasks", "checklist"), "usage": ("Usage", "chart.bar"),
    ]

    @Test func favoritesIsNoLongerAPageOrATab() {
        #expect(!TabChoice.pageIDs.contains(FavoritePages.rowID))
        #expect(TabChoice.pageIDs.last == QuickTileStore.rowID)
        #expect(MoreSearch.pageKeywords[FavoritePages.rowID] == nil)
        #expect(MoreSearch.pageKeywords[QuickTileStore.rowID]?.contains("favorites") == true)
    }

    @Test func aStoredFavoritesTabIsTheQuickActionsTab() {
        #expect(TabChoice(key: "page.favorites") == .page(QuickTileStore.rowID))
        #expect(TabChoice(tag: 121) == .page(QuickTileStore.rowID), "a saved Favorites tag opens Quick Actions")
        let store = defaults()
        store.set(["bots", "sessions", "page.favorites", "page.quick-actions"], forKey: TabOrder.key)
        #expect(TabOrder.tabs(in: store) == [.main(.bots), .main(.sessions), .page(QuickTileStore.rowID)], "once, not twice")
    }

    @Test func everyOtherPageKeepsItsTag() {
        // The tags builds with Favorites gave: Composio 120, Quick Actions 122.
        #expect(TabChoice.page("files").tag == 100)
        #expect(TabChoice.page("composio").tag == 120)
        #expect(TabChoice.page(QuickTileStore.rowID).tag == 122)
        for id in TabChoice.pageIDs { #expect(TabChoice(tag: TabChoice.page(id).tag) == .page(id)) }
    }

    @Test func theChosenPagesAreReadOnceAndCleared() {
        let store = defaults()
        #expect(FavoritePages.ids(in: store).isEmpty)
        store.set(["review", FavoritePages.rowID, "", "review", "tasks"], forKey: FavoritePages.key)
        #expect(FavoritePages.ids(in: store) == ["review", "tasks"])
        FavoritePages.clear(in: store)
        #expect(store.object(forKey: FavoritePages.key) == nil)
    }

    @Test func chosenPagesBecomePageTilesAfterTheRest() {
        var list = QuickTileList(tiles: QuickTileStore.starter(bot: "otto", name: "Otto"), seeded: true)
        let starter = list.tiles
        let changed = list.absorbFavorites(["usage", "review"], pages: pages)
        #expect(changed)
        #expect(Array(list.tiles.prefix(starter.count)) == starter, "the starter set stays first, as it was")
        let added = list.tiles.dropFirst(starter.count)
        #expect(added.map(\.page) == ["usage", "review"], "in Favorites' order")
        #expect(added.map(\.name) == ["Usage", "Review"])
        #expect(added.map(\.pageName) == ["Usage", "Review"])
        #expect(added.map(\.symbol) == ["chart.bar", "arrow.triangle.branch"])
        #expect(added.allSatisfy { $0.known == .page && !$0.wide && !$0.short })
        #expect(QuickTileRules.missing(added.first!, world: QuickTileWorld(pages: ["usage": "Usage"])) == nil)
        let again = list.absorbFavorites(["usage", "review"], pages: pages)
        #expect(!again, "a second time adds nothing")
    }

    @Test func aPageAlreadyATileOrNotOnThisGatewayIsNotAddedAgain() {
        var tile = QuickTile(id: "mine", kind: .page, name: "My Review")
        tile.page = "review"
        var list = QuickTileList(tiles: [tile], seeded: true)
        let changed = list.absorbFavorites(["review", "files", "tasks"], pages: pages)
        #expect(changed)
        #expect(list.tiles.map(\.page) == ["review", "tasks"], "review was already there; files isn't on this gateway")
        #expect(list.tiles.first?.name == "My Review", "the person's own tile is untouched")
    }

    @Test func aTileThatOpenedFavoritesGoes() {
        var stale = QuickTile(id: "fav", kind: .page, name: "Favorites")
        stale.page = FavoritePages.rowID
        var list = QuickTileList(tiles: [QuickTile(id: "s", kind: .search), stale], seeded: true)
        let changed = list.absorbFavorites([], pages: pages)
        #expect(changed)
        #expect(list.tiles.map(\.id) == ["s"])
    }
}
