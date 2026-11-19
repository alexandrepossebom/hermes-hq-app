// [sync] The Sessions list's hand-picked parts follow the owner from device to device (owner 2026-11-03): Sort By
// Manual's chat order, the project and bot group orders, favorite projects, chat colours, and Sort By / Group By / Row
// Detail. Kept on the gateway as the document "sessions" (`GatewaySync`). The filters, folds and read markers stay on
// each device.

import Foundation

extension SessionStore: GatewaySynced {
    /// Sort By Manual's chats kept on the gateway (the top of the order; the rest stay on the device).
    static let syncedChatOrderLimit = 500

    var syncName: String { "sessions" }

    func syncValue() -> JSONValue {
        let rows = Array(view.rowDetail.map(\.rawValue).sorted())
        return [
            "chatOrder": .array(device.chatOrder.prefix(Self.syncedChatOrderLimit).map { .string($0) }),
            "projectOrder": .array(device.projectOrder.map { .string($0) }),
            "botGroupOrder": .array(device.botGroupOrder.map { .string($0) }),
            "favoriteProjects": .array(device.favoriteProjects.map { .string($0) }),
            "archivedProjects": .array(device.archivedProjects.map { .string($0) }),       // [project-pills]
            "projectBots": .object(device.projectBots.mapValues { .string($0) }),          // [project-default-bot]
            "codingProjects": .object(device.codingProjects.mapValues { .bool($0) }),
            "colors": .object(device.colors.mapValues { .number(Double($0)) }),
            "sortBy": .string(view.sortBy.rawValue),
            "groupBy": .string(view.groupBy.rawValue),
            "rowDetail": .array(rows.map { .string($0) }),
            "recentPreview": .bool(view.recentPreview),
        ]
    }

    func adoptSynced(_ value: JSONValue, merge: GatewaySyncMerge, base: JSONValue?) {
        let oldCodingProjects = device.codingProjects
        func strings(_ key: String) -> [String] { (value[key]?.array ?? []).compactMap(\.string) }
        /// The gateway's order first; this device's chats it doesn't name keep their places after it.
        func joined(_ remote: [String], _ local: [String]) -> [String] {
            let named = Set(remote)
            return remote + local.filter { !named.contains($0) }
        }
        if merge == .rebase {
            // This device's change is the newest; only colours set elsewhere meanwhile come in.
            for (key, raw) in value["colors"]?.object ?? [:] where device.colors[key] == nil {
                if let index = raw.int { device.colors[key] = index }
            }
            for (key, raw) in value["projectBots"]?.object ?? [:] where device.projectBots[key] == nil {
                if let bot = raw.string { device.projectBots[key] = bot }
            }
            for (key, raw) in value["codingProjects"]?.object ?? [:] where device.codingProjects[key] == nil {
                if let enabled = raw.bool { device.codingProjects[key] = enabled }
            }
        } else {
            device.chatOrder = joined(strings("chatOrder"), device.chatOrder)
            device.projectOrder = joined(strings("projectOrder"), merge == .firstContact ? device.projectOrder : [])
            device.botGroupOrder = joined(strings("botGroupOrder"), merge == .firstContact ? device.botGroupOrder : [])
            device.favoriteProjects = joined(strings("favoriteProjects"), merge == .firstContact ? device.favoriteProjects : [])
            device.archivedProjects = joined(strings("archivedProjects"), merge == .firstContact ? device.archivedProjects : [])
            var colors = merge == .firstContact ? device.colors : [:]
            for (key, raw) in value["colors"]?.object ?? [:] { if let index = raw.int { colors[key] = index } }
            device.colors = colors
            // [project-default-bot] A gateway copy written before this had no such part: the device keeps its own.
            if let remote = value["projectBots"]?.object {
                var chosen = merge == .firstContact ? device.projectBots : [:]
                for (key, raw) in remote { if let bot = raw.string { chosen[key] = bot } }
                device.projectBots = chosen
            }
            if let remote = value["codingProjects"]?.object {
                var chosen = merge == .firstContact ? device.codingProjects : [:]
                for (key, raw) in remote { if let enabled = raw.bool { chosen[key] = enabled } }
                device.codingProjects = chosen
            }
            var prefs = view
            if let raw = value["sortBy"]?.string, let sort = SessionSortBy(rawValue: raw) { prefs.sortBy = sort }
            if let raw = value["groupBy"]?.string, let group = SessionGroupBy(rawValue: raw) { prefs.groupBy = group }
            if let raw = value["rowDetail"]?.array {
                let detail = Set(raw.compactMap(\.string).compactMap(SessionRowDetail.init(rawValue:)))
                if !detail.isEmpty { prefs.rowDetail = detail }
            }
            if let on = value["recentPreview"]?.bool { prefs.recentPreview = on }
            view = prefs
            device.view = prefs
        }
        persistState()
        if oldCodingProjects != device.codingProjects { codingProjectsChanged() }
        rebuild()
    }
}
