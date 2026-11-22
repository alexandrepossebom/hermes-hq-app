// [favorites-retired] The Favorites page is gone (owner 2026-11-22: "I want to remove the Favorites page entirely. The
// Quick Actions page will replace it."). What is left is reading the pages a person chose there (`hqn.favorites`, on
// this device), so Quick Actions can take them in once as page tiles (`QuickTileList.absorbFavorites`), and clearing it.

import Foundation

nonisolated enum FavoritePages {
    static let key = "hqn.favorites"
    /// The retired page's More row id (and the `TabChoice` page id a stored tab may still name).
    static let rowID = "favorites"

    /// The chosen pages' More row ids, in the page's order (each once, never Favorites itself or an empty id).
    static func ids(in defaults: UserDefaults = .standard) -> [String] {
        var out: [String] = []
        for case let id as String in defaults.array(forKey: key) ?? [] where !id.isEmpty && id != rowID && !out.contains(id) {
            out.append(id)
        }
        return out
    }

    static func clear(in defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}
