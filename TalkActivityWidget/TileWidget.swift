// [tile-widgets] The Tile widget (docs/spec/1x-pages.md §5.8): one of the owner's Tiles on the Home Screen, as its
// picture in the Tiles grid, edge to edge. The app draws the pictures at each placed widget's own size, light and dark
// (App/Widgets/TileWidgetWriter.swift), into Keychain (HomeWidgetsKit/TileWidgetStore.swift); this extension only
// reads them, and notes what each placed widget is so the app knows what to draw. It never reaches the gateway.
// Nothing in a picture moves with the clock: one entry, reloaded by the app when a picture changes.

import AppIntents
import SwiftUI
import UIKit
import WidgetKit

enum HQWidgetKinds {
    static let tile = "ai.hermes.hq.tile"
    static let tasks = "ai.hermes.hq.tasks"
}

extension TileFamily {
    nonisolated init?(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemMedium: self = .medium
        case .systemLarge: self = .large
        case .systemExtraLarge: self = .extraLarge
        default: return nil
        }
    }
}

nonisolated struct TileWidgetEntry: TimelineEntry, Sendable {
    enum Content: Sendable {
        /// The tile's pictures in each look (either may be missing), and whether each is this widget's own size.
        case picture(light: TilePicture?, dark: TilePicture?, name: String)
        /// No picture of this tile yet at any size: its name, its bot, and that the app draws it.
        case notDrawn(name: String, bot: String)
        case signedOut
        case noTiles
        /// The chosen tile was unpinned.
        case removed
        /// The widget gallery's preview before the app has drawn anything: a made-up tile.
        case sample
    }

    let date: Date
    let content: Content
    var link: URL? = nil
    var tint: Int? = nil
    var tintDark: Int? = nil
}

nonisolated struct TileWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TileWidgetEntry {
        TileWidgetEntry(date: Date(), content: .sample)
    }

    func snapshot(for configuration: TileWidgetIntent, in context: Context) async -> TileWidgetEntry {
        let entry = Self.entry(configuration.tile?.id, context: context, note: true)
        // The gallery's preview: the real default tile when the app has drawn it, else a sample, never an empty state.
        if context.isPreview, case .picture = entry.content { return entry }
        return context.isPreview ? TileWidgetEntry(date: Date(), content: .sample) : entry
    }

    func timeline(for configuration: TileWidgetIntent, in context: Context) async -> Timeline<TileWidgetEntry> {
        Timeline(entries: [Self.entry(configuration.tile?.id, context: context, note: true)], policy: .never)
    }

    static func entry(_ chosen: String?, context: Context, note: Bool) -> TileWidgetEntry {
        let now = Date()
        let family = TileFamily(context.family) ?? .small
        if note {
            // What this widget is, for the app to draw (only written when it says something new).
            TileWidgetStore.noteWant(TileWant(tile: chosen, family: family, width: Double(context.displaySize.width),
                                              height: Double(context.displaySize.height), at: now))
        }
        guard let index = TileWidgetStore.loadIndex() else {
            return TileWidgetEntry(date: now, content: .signedOut, link: nil)
        }
        let tints = (index.tint, index.tintDark)
        guard index.state == .live else {
            return TileWidgetEntry(date: now, content: .signedOut, link: WidgetLink.open.url(scheme: index.scheme),
                                   tint: tints.0, tintDark: tints.1)
        }
        guard !index.tiles.isEmpty else {
            return TileWidgetEntry(date: now, content: .noTiles, link: WidgetLink.tiles.url(scheme: index.scheme),
                                   tint: tints.0, tintDark: tints.1)
        }
        guard let tile = index.tile(chosen) else {
            return TileWidgetEntry(date: now, content: .removed, link: WidgetLink.tiles.url(scheme: index.scheme),
                                   tint: tints.0, tintDark: tints.1)
        }
        let link = WidgetLink.tile(key: tile.id, account: index.account).url(scheme: index.scheme)
        let find = { (key: String, family: TileFamily, dark: Bool) in TileWidgetStore.loadPicture(tile: key, family: family, dark: dark) }
        // Each look on its own: this family's picture in it, else the nearest there is.
        let light = TileWidgetPlan.best(for: tile.id, family: family, dark: false, find: find)?.picture
        let dark = TileWidgetPlan.best(for: tile.id, family: family, dark: true, find: find)?.picture
        guard light != nil || dark != nil else {
            return TileWidgetEntry(date: now, content: .notDrawn(name: tile.name, bot: tile.bot), link: link,
                                   tint: tints.0, tintDark: tints.1)
        }
        return TileWidgetEntry(date: now, content: .picture(light: light, dark: dark, name: tile.name), link: link,
                               tint: tints.0, tintDark: tints.1)
    }
}

struct TileWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: HQWidgetKinds.tile, intent: TileWidgetIntent.self, provider: TileWidgetProvider()) { entry in
            TileWidgetView(entry: entry)
        }
        .configurationDisplayName("Tile")
        .description("One of your Tiles from Hermes HQ.")
        // The picture goes edge to edge, cut by the widget's own shape.
        .contentMarginsDisabled()
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

// MARK: - Views

struct TileWidgetView: View {
    let entry: TileWidgetEntry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetFamily) private var family

    private var dark: Bool { scheme == .dark }

    /// The picture in this look (the other look's when this one isn't drawn).
    private var picture: TilePicture? {
        guard case .picture(let light, let darkPicture, _) = entry.content else { return nil }
        return dark ? (darkPicture ?? light) : (light ?? darkPicture)
    }

    var body: some View {
        content
            .widgetURL(entry.link)
            .containerBackground(for: .widget) { backdrop }
    }

    @ViewBuilder private var content: some View {
        switch entry.content {
        case .picture(_, _, let name):
            if let picture, let image = UIImage(data: picture.jpeg, scale: picture.scale) {
                TilePictureFill(image: image, edge: picture.edge.map(Color.init(hex:)))
                    .accessibilityLabel(Text(name))
            } else {
                TileQuietView(symbol: "chart.xyaxis.line", title: name, line: nil, tint: tint)
            }
        case .notDrawn(let name, let bot):
            TileQuietView(symbol: "chart.xyaxis.line", title: name, line: "\(bot) · Drawn when you open Hermes HQ", tint: tint)
        case .signedOut:
            TileQuietView(symbol: nil, title: "Open Hermes HQ", line: nil, tint: tint)
        case .noTiles:
            TileQuietView(symbol: "rectangle.3.group", title: "No Tiles Yet", line: "Pin a page as a Tile in Hermes HQ", tint: tint)
        case .removed:
            TileQuietView(symbol: "doc.questionmark", title: "Tile Removed", line: "Choose another tile, or open Tiles", tint: tint)
        case .sample:
            TileSampleView()
        }
    }

    /// The page's own colour behind a fitted picture; the system's background behind the quiet states.
    @ViewBuilder private var backdrop: some View {
        if let edge = picture?.edge { Color(hex: edge) }
        else if case .sample = entry.content { TileSampleView.page(dark) }
        else { Color(uiColor: .secondarySystemBackground) }
    }

    private var tint: Color {
        (dark ? entry.tintDark ?? entry.tint : entry.tint).map(Color.init(hex:)) ?? .accentColor
    }
}

/// The picture: edge to edge from its top when it is about the widget's shape, else fitted whole on the page's colour.
struct TilePictureFill: View {
    let image: UIImage
    let edge: Color?

    var body: some View {
        GeometryReader { geometry in
            if TileWidgetPlan.fills(image.size, in: geometry.size) {
                Image(uiImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    .clipped()
            } else {
                Image(uiImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFit()
                    .padding(6)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(edge ?? .clear)
            }
        }
    }
}

/// A quiet state: a symbol in the theme's tint, a title and a line, centred. A tap opens the app.
struct TileQuietView: View {
    let symbol: String?
    let title: String
    let line: String?
    let tint: Color
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .widgetAccentable()
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "app.badge")
                    .font(.title2)
                    .foregroundStyle(tint)
                    .widgetAccentable()
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if let line {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(family == .systemSmall ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)   // Small's third line, not cut at two
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The gallery's preview before any tile is drawn: a made-up revenue tile in the tile kit's own manner (a heading, a
/// big number, how it moved, a small chart, when it was updated).
struct TileSampleView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetFamily) private var family

    static func page(_ dark: Bool) -> Color { dark ? Color(red: 0.07, green: 0.08, blue: 0.10) : Color(red: 0.97, green: 0.97, blue: 0.98) }

    private static let bars: [Double] = [0.42, 0.55, 0.48, 0.62, 0.58, 0.71, 0.66, 0.8, 0.74, 0.9, 0.84, 1.0]

    var body: some View {
        let dark = scheme == .dark
        let ink = dark ? Color.white : Color(red: 0.08, green: 0.09, blue: 0.11)
        let soft = ink.opacity(0.55)
        let green = dark ? Color(red: 0.29, green: 0.85, blue: 0.47) : Color(red: 0.11, green: 0.6, blue: 0.3)
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
            HStack {
                Text("Revenue").font(.subheadline.weight(.semibold)).foregroundStyle(soft)
                Spacer()
                Text("This week").font(.caption2.weight(.medium)).foregroundStyle(soft)
            }
            Text("$12,480").font(.system(.title, design: .rounded).weight(.bold)).foregroundStyle(ink)
                .minimumScaleFactor(0.7).lineLimit(1)
            Text("▲ 8.2%").font(.caption.weight(.semibold)).foregroundStyle(green)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Self.bars.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index == Self.bars.count - 1 ? green : green.opacity(0.35))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .scaleEffect(x: 1, y: Self.bars[index], anchor: .bottom)
                }
            }
            .frame(maxHeight: .infinity)
            Text("Updated 5 min ago").font(.caption2).foregroundStyle(soft)
        }
        .padding(family == .systemSmall ? 14 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension Color {
    init(hex: Int) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
