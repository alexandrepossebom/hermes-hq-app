// [favorites] More › Favorites (a tester, a tester, 2026-11-20: "a widget where we can add pages we use often, for
// easier access", her pages buried under More). Owner 2026-11-20: one Favorites page you fill yourself, from a list of
// every page, not a star on each page. Which More pages it lists, in its order, on this device (as the tab order is).
// A page this gateway lacks stays chosen and is left out of the list until it is back.

import Foundation

nonisolated enum FavoritePages {
    static let key = "hqn.favorites"
    static let didChange = Notification.Name("hqn.favorites.changed")
    /// The Favorites page's own More row id (and its `TabChoice` page id): never a favorite of itself.
    static let rowID = "favorites"

    /// The chosen pages' More row ids, in the page's order.
    static var ids: [String] {
        get { ids(in: .standard) }
        set { if set(newValue, in: .standard) { NotificationCenter.default.post(name: didChange, object: nil) } }
    }

    static func ids(in defaults: UserDefaults) -> [String] {
        normalized(defaults.array(forKey: key)?.compactMap { $0 as? String } ?? [])
    }

    /// Stores `ids` (none is stored as nothing); answers whether the list changed.
    @discardableResult
    static func set(_ ids: [String], in defaults: UserDefaults) -> Bool {
        let next = normalized(ids)
        let before = self.ids(in: defaults)
        if next.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(next, forKey: key) }
        return next != before
    }

    /// Each page once, in the given order, never the Favorites page itself or an empty id.
    static func normalized(_ ids: [String]) -> [String] {
        var out: [String] = []
        for id in ids where !id.isEmpty && id != rowID && !out.contains(id) { out.append(id) }
        return out
    }

    static func contains(_ id: String, in defaults: UserDefaults = .standard) -> Bool { ids(in: defaults).contains(id) }

    /// Adds `id` at the end (a page already there stays where it is).
    static func add(_ id: String, in defaults: UserDefaults = .standard) {
        changed(set(ids(in: defaults) + [id], in: defaults), defaults)
    }

    static func remove(_ id: String, in defaults: UserDefaults = .standard) {
        changed(set(ids(in: defaults).filter { $0 != id }, in: defaults), defaults)
    }

    /// The list's rows dragged into a new order (`shown`: the chosen pages this gateway has, as the list now shows them).
    /// They take the slots the shown pages held; a chosen page the gateway lacks keeps its own slot.
    static func reorder(shown: [String], in defaults: UserDefaults = .standard) {
        let all = ids(in: defaults)
        let moving = Set(shown).intersection(all)
        var queue = shown.filter { moving.contains($0) }[...]
        let next = all.map { moving.contains($0) ? (queue.popFirst() ?? $0) : $0 }
        changed(set(next, in: defaults), defaults)
    }

    private static func changed(_ did: Bool, _ defaults: UserDefaults) {
        if did, defaults === UserDefaults.standard { NotificationCenter.default.post(name: didChange, object: nil) }
    }
}
