// [tile-chats] A tile's own chat (owner 2026-11-21: "an easy way to be able to open the session attached to a Tile and
// I need to be sure that Tile sessions are hidden from everywhere else").
//
// The chats the app makes for a tile (New Tile, Change…, a button or a roll back with no chat yet) are born hidden on
// the gateway, as a task's own chat is (`session.create {hidden: true}`): no list on any device shows them, nor the
// desktop app's sidebar, nor search. The tile opens its chat (the opened tile's chat button, the hold menu's Open
// Chat). Tile chats an older app made in the open are known by how the app's ask begins: the lists drop them at once
// (`SessionRules.isBotChat`), and the Sessions store hides each on the gateway once (`toHide`).

import Foundation

nonisolated enum TileChats {
    /// How TileMaker's asks begin (`TileMaker.prompt`, `changePrompt`, `rolledBackPrompt`): a chat whose first message
    /// starts with one was made for a tile. Kept to their first words, which fit the gateway's 60-character preview.
    static let openings = [
        "Make me a live tile for my Hermes HQ Dashboard",
        "Change my Hermes HQ Dashboard tile",
        "I rolled my Hermes HQ tile",
    ]

    /// A chat's first message (the gateway's `preview`) is one of the app's asks for a tile.
    static func isTileChat(preview: String?) -> Bool {
        guard let preview else { return false }
        let text = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return openings.contains { text.hasPrefix($0) }
    }

    static func isTileChat(_ row: SidebarSessionRow) -> Bool { isTileChat(preview: row.preview) }

    /// The listed rows that are tile chats the gateway still shows (made before tile chats were born hidden): each is
    /// hidden on the gateway, so every other device and the desktop app stop listing it too.
    static func toHide(_ rows: [SidebarSessionRow]) -> [SidebarSessionRow] {
        var seen = Set<String>()
        return rows.filter { $0.hidden != true && isTileChat($0) && seen.insert($0.profile + "\u{1F}" + $0.id).inserted }
    }
}
