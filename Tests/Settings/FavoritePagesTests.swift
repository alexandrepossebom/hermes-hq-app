import Foundation
import Testing
@testable import HermesHQNative

/// [favorites] More › Favorites: what is stored, how a bad list reads, adding, removing, and a drag that keeps a page
/// this gateway lacks where it was.
@Suite struct FavoritePagesTests {
    private func defaults() -> UserDefaults {
        let name = "FavoritePagesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func noneUntilAPageIsAdded() {
        let store = defaults()
        #expect(FavoritePages.ids(in: store).isEmpty)
        #expect(store.object(forKey: FavoritePages.key) == nil)
    }

    @Test func addingKeepsTheOrderAndEachPageOnce() {
        let store = defaults()
        FavoritePages.add("review", in: store)
        FavoritePages.add("tasks", in: store)
        FavoritePages.add("review", in: store)
        #expect(FavoritePages.ids(in: store) == ["review", "tasks"])
        #expect(FavoritePages.contains("tasks", in: store))
    }

    @Test func favoritesIsNeverAFavoriteOfItself() {
        let store = defaults()
        FavoritePages.add(FavoritePages.rowID, in: store)
        #expect(FavoritePages.ids(in: store).isEmpty)
        store.set(["files", FavoritePages.rowID, "", "files", "usage"], forKey: FavoritePages.key)
        #expect(FavoritePages.ids(in: store) == ["files", "usage"])
    }

    @Test func removingTheLastPageStoresNothing() {
        let store = defaults()
        FavoritePages.add("jobs", in: store)
        FavoritePages.remove("jobs", in: store)
        #expect(FavoritePages.ids(in: store).isEmpty)
        #expect(store.object(forKey: FavoritePages.key) == nil)
    }

    @Test func aDragKeepsAPageThisGatewayLacksInItsSlot() {
        let store = defaults()
        for id in ["review", "terminal", "tasks", "usage"] { FavoritePages.add(id, in: store) }
        // Terminal is missing on this gateway: the list shows Review, Tasks, Usage; Usage is dragged to the top.
        FavoritePages.reorder(shown: ["usage", "review", "tasks"], in: store)
        #expect(FavoritePages.ids(in: store) == ["usage", "terminal", "review", "tasks"])
    }

    @Test func aDragNamingUnknownPagesChangesNothingElse() {
        let store = defaults()
        for id in ["review", "tasks"] { FavoritePages.add(id, in: store) }
        FavoritePages.reorder(shown: ["tasks", "nope", "review"], in: store)
        #expect(FavoritePages.ids(in: store) == ["tasks", "review"])
    }

    @Test func favoritesCanBeATabWithItsOwnTag() {
        #expect(TabChoice(key: "page.favorites") == .page(FavoritePages.rowID))
        #expect(TabChoice.pageIDs.last == FavoritePages.rowID)   // new pages go at the end: the others keep their tags
        #expect(TabOrderPage.fallback(FavoritePages.rowID).title == "Favorites")
        #expect(MoreSearch.pageKeywords[FavoritePages.rowID]?.contains("starred") == true)
    }
}
