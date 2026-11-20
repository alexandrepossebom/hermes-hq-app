// [tile-widgets] The Tile widget's one setting, Tile: the signed-in account's page tiles (`TileWidgetIndex`), by name
// with the bot's name under it, in sections by Dashboard page as the Tiles page orders them (Main first). Built into the
// app too, so the app can read a placed widget's choice (`WidgetCenter.currentConfigurations`, App/Widgets).

import AppIntents
import Foundation

nonisolated struct TileEntity: AppEntity, Sendable, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tile"
    static let defaultQuery = TileEntityQuery()

    /// The tile's key (`TileWidgetIndex.Tile.id`).
    var id: String
    var name: String
    var bot: String

    init(id: String, name: String, bot: String) {
        self.id = id
        self.name = name
        self.bot = bot
    }

    init(_ tile: TileWidgetIndex.Tile) { self.init(id: tile.id, name: tile.name, bot: tile.bot) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(bot)")
    }
}

nonisolated struct TileEntityQuery: EntityQuery, Sendable {
    init() {}

    private static func tiles() -> [TileWidgetIndex.Tile] {
        guard let index = TileWidgetStore.loadIndex(), index.state == .live else { return [] }
        return index.tiles
    }

    func entities(for identifiers: [String]) async throws -> [TileEntity] {
        let tiles = Self.tiles()
        return identifiers.compactMap { id in tiles.first { $0.id == id }.map(TileEntity.init) }
    }

    /// The tiles by Dashboard page, in the Tiles page's order.
    func suggestedEntities() async throws -> IntentItemCollection<TileEntity> {
        var sections: [(name: String, tiles: [TileEntity])] = []
        for tile in Self.tiles() {
            if let last = sections.indices.last, sections[last].name == tile.pageName {
                sections[last].tiles.append(TileEntity(tile))
            } else {
                sections.append((tile.pageName, [TileEntity(tile)]))
            }
        }
        // One page: no heading over the list.
        if sections.count <= 1 { return IntentItemCollection(items: sections.first?.tiles ?? []) }
        return IntentItemCollection(sections: sections.map { IntentItemSection(LocalizedStringResource("\($0.name)"), items: $0.tiles) })
    }
    // No `defaultResult`: a widget left unchosen keeps following the first tile of Main, whichever that is now.
}

/// Not `nonisolated` (an `@Parameter` refuses it): AppIntent's Sendable conformance keeps it off the main actor.
struct TileWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Tile"
    static let description = IntentDescription("Choose the tile this widget shows. With none chosen it shows the first tile on Main.")

    @Parameter(title: "Tile")
    var tile: TileEntity?

    init() {}

    init(tile: TileEntity?) { self.tile = tile }
}
