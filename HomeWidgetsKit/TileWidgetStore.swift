// [tile-widgets] What the Tile widget shows (TalkActivityWidget/TileWidget.swift): the index of the signed-in account's
// page tiles, a picture of each wanted tile per widget size and look, and what the placed widgets want. The app writes
// the index and the pictures (App/Widgets/TileWidgetWriter.swift); the extension reads them and notes what it wants.
// Kept in Keychain (`WidgetVault`, see there why). Pure rules below are what the tests read.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A Home Screen widget's size, as the store names it (WidgetKit's `WidgetFamily` is not Codable).
nonisolated enum TileFamily: String, Codable, CaseIterable, Sendable, Hashable {
    case small, medium, large, extraLarge
}

/// The tiles a widget can show, in the Tiles page's order (Main first, then each Dashboard page; each page's tiles as
/// they sit), and how to draw the quiet states.
nonisolated struct TileWidgetIndex: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// Signed in: the tiles as the app last saw them.
        case live
        /// Nobody is signed in: the widget says "Open Hermes HQ" and nothing else.
        case signedOut
    }

    struct Tile: Codable, Equatable, Sendable, Identifiable, Hashable {
        /// The tile's key (`TileWidgetIndex.key`): a hash of its pin's id, so no path is in a widget's settings.
        var id: String
        /// The pin's own id (`ArtifactPin.id`): the app opens that tile.
        var pin: String
        /// Its name as the Tiles page says it.
        var name: String
        /// Its bot's display name and profile.
        var bot: String
        var profile: String
        /// Its Dashboard page (id and name) and its place among all the tiles.
        var page: String
        var pageName: String
        var order: Int
    }

    var version = 1
    var state: State
    /// The app's URL scheme: the extension builds the taps' links with it.
    var scheme: String
    /// The signed-in account's key (`TileWidgetIndex.key` of its id): a link from a widget written under another
    /// account opens nothing of that one.
    var account: String
    /// The theme's tint, light and dark (0xRRGGBB): the not-drawn-yet and empty states' one colour.
    var tint: Int?
    var tintDark: Int?
    var tiles: [Tile] = []

    static let mainPage = "main"

    static func signedOut(scheme: String, tint: Int? = nil, tintDark: Int? = nil) -> TileWidgetIndex {
        TileWidgetIndex(state: .signedOut, scheme: scheme, account: "", tint: tint, tintDark: tintDark)
    }

    /// A widget with no tile chosen: the first tile of Main (else the first tile there is).
    var defaultTile: Tile? { tiles.first { $0.page == Self.mainPage } ?? tiles.first }

    func tile(_ key: String?) -> Tile? {
        guard let key else { return defaultTile }
        return tiles.first { $0.id == key }
    }

    /// A short, stable key for a string (a pin's id, an account's id): 16 hex digits of a FNV-1a hash, so no path or
    /// address goes into a widget's settings or a link, and the app and the extension agree without CryptoKit.
    static func key(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// The tiles in the Tiles page's order: `pages` in order (Main first), each page's tiles in `pins` order.
    static func ordered(_ tiles: [Tile], pages: [String]) -> [Tile] {
        var rank: [String: Int] = [:]
        for (place, page) in pages.enumerated() where rank[page] == nil { rank[page] = place }
        let main = rank[mainPage] ?? -1
        return tiles.enumerated().sorted { a, b in
            let pa = a.element.page == mainPage ? main : rank[a.element.page] ?? Int.max
            let pb = b.element.page == mainPage ? main : rank[b.element.page] ?? Int.max
            return pa != pb ? pa < pb : a.offset < b.offset
        }.enumerated().map { place, item in
            var tile = item.element
            tile.order = place
            return tile
        }
    }
}

/// One tile's picture at one widget size and look.
nonisolated struct TilePicture: Codable, Equatable, Sendable {
    /// When it was drawn.
    var drawnAt: Date
    /// The widget's size it was drawn for, in points, and the screen's scale.
    var width: Double
    var height: Double
    var scale: Double
    /// The picture was drawn in the widget's own window, edge to edge (false: a page that scrolls, its best part
    /// fitted whole with a margin of `edge`, the page's own colour).
    var fills: Bool
    /// The page's background, 0xRRGGBB (the margin around a fitted picture; the widget's own background).
    var edge: Int?
    /// The picture, as JPEG.
    var jpeg: Data
}

/// What a placed widget wants: the extension notes its family, its size and its tile from its timeline.
nonisolated struct TileWant: Codable, Equatable, Sendable {
    /// The tile's key; nil: no tile chosen (the default tile).
    var tile: String?
    var family: TileFamily
    var width: Double
    var height: Double
    var at: Date

    var size: CGSize { CGSize(width: width, height: height) }
}

/// One picture the app should keep: a tile at a widget size, both looks.
nonisolated struct TilePictureSpec: Hashable, Sendable {
    var tile: String
    var family: TileFamily
    var width: Int
    var height: Int
}

// MARK: - Which pictures are wanted (pure)

nonisolated enum TileWidgetPlan {
    /// A want not heard again for this long is from a widget since taken off the Home Screen (each placed widget's
    /// timeline is asked for whenever the app reloads it, and at least daily by the system).
    static let wantKeptFor: TimeInterval = 3 * 86_400

    /// The pictures to draw and keep: every placed widget's tile at its size (a widget with none chosen shows the
    /// default tile), the default tile at Small, Medium and Large (a widget added for the first time shows a picture at
    /// once), and the tiles `asked` (Add to Home Screen…) at those three. `placed`: what the system says is on the
    /// Home Screen (`WidgetCenter.currentConfigurations`), nil when it couldn't say; then the recent wants stand in.
    /// A family's size is the newest want's for it, else `fallback`'s. Tiles not in the index are left out.
    static func wanted(index: TileWidgetIndex, wants: [TileWant], placed: [(tile: String?, family: TileFamily)]?,
                       asked: [String] = [], fallback: [TileFamily: CGSize], now: Date) -> [TilePictureSpec] {
        guard index.state == .live, let first = index.defaultTile else { return [] }
        let recent = wants.filter { now.timeIntervalSince($0.at) < wantKeptFor }
        var sizes: [TileFamily: (CGSize, Date)] = [:]
        for want in recent where want.width > 0 && want.height > 0 {
            if let kept = sizes[want.family], kept.1 >= want.at { continue }
            sizes[want.family] = (want.size, want.at)
        }
        func size(_ family: TileFamily) -> CGSize? { sizes[family]?.0 ?? fallback[family] }
        let known = Set(index.tiles.map(\.id))
        var out: [TilePictureSpec] = []
        var seen = Set<TilePictureSpec>()
        func add(_ tile: String?, _ family: TileFamily) {
            let key = tile.flatMap { known.contains($0) ? $0 : nil } ?? (tile == nil ? first.id : nil)
            guard let key, let size = size(family) else { return }
            let spec = TilePictureSpec(tile: key, family: family, width: Int(size.width.rounded()), height: Int(size.height.rounded()))
            if seen.insert(spec).inserted { out.append(spec) }
        }
        let onScreen = placed ?? recent.map { ($0.tile, $0.family) }
        for widget in onScreen { add(widget.tile, widget.family) }
        for family in [TileFamily.small, .medium, .large] { add(first.id, family) }
        for tile in asked { for family in [TileFamily.small, .medium, .large] { add(tile, family) } }
        return out
    }

    /// The best picture for a widget showing `tile` at `family`, `size`: its own family's in its own look, else the
    /// other look, else another family's (shown fitted, until the app draws this one). Nil when none is drawn.
    static func best(for tile: String, family: TileFamily, dark: Bool,
                     find: (String, TileFamily, Bool) -> TilePicture?) -> (picture: TilePicture, exact: Bool)? {
        if let own = find(tile, family, dark) { return (own, true) }
        if let other = find(tile, family, !dark) { return (other, false) }
        let order: [TileFamily] = [.large, .medium, .extraLarge, .small].filter { $0 != family }
        for look in [dark, !dark] {
            for other in order { if let picture = find(tile, other, look) { return (picture, false) } }
        }
        return nil
    }

    /// Whether a picture fills a widget of `size` edge to edge (within 12 % of its shape, as a tile's picture fills its
    /// tile, `PagePictureView.cropAllowed`), else it is fitted whole.
    static func fills(_ picture: CGSize, in frame: CGSize) -> Bool {
        guard picture.width > 0, picture.height > 0, frame.width > 0, frame.height > 0 else { return false }
        let ratio = (picture.width / picture.height) / (frame.width / frame.height)
        return ratio <= 1 / 0.88 && ratio >= 0.88
    }

    /// The widgets' sizes in points by the screen's (portrait) size, from Apple's Human Interface Guidelines table, for
    /// the first pictures before any widget says its own size (`TileWant`). Nearest screen when this one isn't listed.
    static func fallbackSizes(screen: CGSize, pad: Bool) -> [TileFamily: CGSize] {
        let w = min(screen.width, screen.height), h = max(screen.width, screen.height)
        if pad {
            // iPad: a 2 × 2 icon block's widget, by the smaller side (iPad Pro 13", 11", mini).
            let table: [(CGFloat, [CGFloat])] = [(1032, [170, 378.5, 378.5, 795]), (834, [155, 342, 342, 715.5]),
                                                 (820, [155, 342, 342, 715.5]), (744, [141, 305.5, 305.5, 634.5])]
            let row = table.min { abs($0.0 - w) < abs($1.0 - w) }!.1
            return [.small: CGSize(width: row[0], height: row[0]), .medium: CGSize(width: row[1], height: row[0]),
                    .large: CGSize(width: row[2], height: row[2]), .extraLarge: CGSize(width: row[3], height: row[2])]
        }
        // iPhone: (screen width, height) → small side, medium/large width, large height.
        let table: [(CGSize, [CGFloat])] = [
            (CGSize(width: 440, height: 956), [170, 364, 382]), (CGSize(width: 430, height: 932), [170, 364, 382]),
            (CGSize(width: 428, height: 926), [170, 364, 382]), (CGSize(width: 414, height: 896), [169, 360, 379]),
            (CGSize(width: 414, height: 736), [159, 348, 357]), (CGSize(width: 402, height: 874), [164, 348, 366]),
            (CGSize(width: 393, height: 852), [158, 338, 354]), (CGSize(width: 390, height: 844), [158, 338, 354]),
            (CGSize(width: 375, height: 812), [155, 329, 345]), (CGSize(width: 375, height: 667), [148, 321, 324]),
            (CGSize(width: 360, height: 780), [155, 329, 345]), (CGSize(width: 320, height: 568), [141, 292, 311]),
        ]
        let row = table.min { abs($0.0.width - w) + abs($0.0.height - h) < abs($1.0.width - w) + abs($1.0.height - h) }!.1
        return [.small: CGSize(width: row[0], height: row[0]), .medium: CGSize(width: row[1], height: row[0]),
                .large: CGSize(width: row[1], height: row[2])]
    }
}

// MARK: - Keychain

nonisolated enum TileWidgetStore {
    static var indexService: String { WidgetVault.service("tile.index") }
    static var pictureService: String { WidgetVault.service("tile.picture") }
    static var wantService: String { WidgetVault.service("tile.want") }

    /// An index this large is not one the app wrote (120 tiles are about 30 KB): read as absent.
    static let maxIndexBytes = 256 * 1024
    /// [tile-widgets] A picture's cap: 512 KB. (securityd logs "serialized item exceeds reasonable size" above about
    /// 32 KB, a warning only: every picture here was written and read back, 34–154 KB each, on iOS 27.2.) The largest widget on a phone is 364 × 382 pt, 1092 × 1146 px at 3x
    /// (1.25 MP); a dashboard of words and charts is 0.12–0.3 bytes a pixel as JPEG at quality 0.85, 150–375 KB, so the
    /// cap keeps the first quality for nearly every tile and leaves room for an iPad's Extra Large (1590 × 757 px at
    /// 2x). A widget extension has about 30 MB; one picture read at a time is well inside it. Twice PushFaces' 256 KB:
    /// a face is 300 px across.
    static let maxPictureBytes = 512 * 1024
    static let maxWantBytes = 4 * 1024

    static func saveIndex(_ index: TileWidgetIndex) -> Bool {
        WidgetVault.save(index, service: indexService, account: "index", maxBytes: maxIndexBytes)
    }

    static func loadIndex() -> TileWidgetIndex? {
        WidgetVault.load(TileWidgetIndex.self, service: indexService, account: "index", maxBytes: maxIndexBytes)
    }

    static func pictureAccount(_ tile: String, _ family: TileFamily, dark: Bool) -> String {
        "\(tile).\(family.rawValue).\(dark ? "d" : "l")"
    }

    /// Saves a picture. `.unchanged` when the same JPEG is there already (nothing written, nothing to reload).
    enum SaveResult: Equatable { case written, unchanged, refused }

    static func savePicture(_ picture: TilePicture, tile: String, family: TileFamily, dark: Bool) -> SaveResult {
        let account = pictureAccount(tile, family, dark: dark)
        if let kept = loadPicture(tile: tile, family: family, dark: dark), kept.jpeg == picture.jpeg,
           kept.width == picture.width, kept.height == picture.height, kept.fills == picture.fills { return .unchanged }
        return WidgetVault.save(picture, service: pictureService, account: account, maxBytes: maxPictureBytes + 4096) ? .written : .refused
    }

    static func loadPicture(tile: String, family: TileFamily, dark: Bool) -> TilePicture? {
        WidgetVault.load(TilePicture.self, service: pictureService, account: pictureAccount(tile, family, dark: dark),
                         maxBytes: maxPictureBytes + 4096)
    }

    /// Keeps only the pictures of `specs` (a tile unpinned, a widget taken away, a size no longer placed). Returns
    /// whether any went.
    @discardableResult
    static func keepPictures(_ specs: [TilePictureSpec]) -> Bool {
        let keep = Set(specs.flatMap { [pictureAccount($0.tile, $0.family, dark: false), pictureAccount($0.tile, $0.family, dark: true)] })
        var removed = false
        for account in WidgetVault.accounts(service: pictureService) where !keep.contains(account) {
            WidgetVault.delete(service: pictureService, account: account)
            removed = true
        }
        return removed
    }

    static func wantAccount(_ want: TileWant) -> String { "\(want.family.rawValue).\(want.tile ?? "default")" }

    /// The extension's note of a placed widget, written only when it says something new (or is an hour old), so a
    /// timeline asked for often writes nothing.
    @discardableResult
    static func noteWant(_ want: TileWant) -> Bool {
        let account = wantAccount(want)
        if let kept = WidgetVault.load(TileWant.self, service: wantService, account: account, maxBytes: maxWantBytes),
           kept.width == want.width, kept.height == want.height, want.at.timeIntervalSince(kept.at) < 3600 { return false }
        return WidgetVault.save(want, service: wantService, account: account, maxBytes: maxWantBytes)
    }

    static func wants() -> [TileWant] {
        WidgetVault.accounts(service: wantService).compactMap {
            WidgetVault.load(TileWant.self, service: wantService, account: $0, maxBytes: maxWantBytes)
        }
    }

    /// Sign-out: the index says signed out (with nothing else in it), and every picture and want goes.
    static func signOut(scheme: String) {
        WidgetVault.deleteAll(service: pictureService)
        WidgetVault.deleteAll(service: wantService)
        _ = saveIndex(.signedOut(scheme: scheme))
    }

    /// Everything the Tile widget keeps, gone (the tests; an identity with no widget).
    static func removeAll() {
        for service in [indexService, pictureService, wantService] { WidgetVault.deleteAll(service: service) }
    }
}

// MARK: - The picture's bytes

nonisolated enum TilePictureEncoding {
    /// The qualities tried, best first, until the JPEG fits the cap.
    static let qualities: [Double] = [0.85, 0.78, 0.7, 0.62, 0.55, 0.48, 0.4]

    /// `image` as JPEG under `maxBytes`, at the best quality that fits (nil when even the lowest doesn't). Never made
    /// smaller in pixels: a smaller picture would be blurry on the Home Screen.
    static func jpeg(_ image: CGImage, maxBytes: Int = TileWidgetStore.maxPictureBytes) -> Data? {
        for quality in qualities {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if output.length <= maxBytes { return output as Data }
        }
        return nil
    }

    /// WidgetKit refuses an image over its archive budget, 4.4 × the widget's own pixel area (measured on iOS 27.2,
    /// the extension's log: "Widget archival failed due to image being too large [31] - (4200, 1968), totalArea:
    /// 8265600 > max[2275490.8]" for a 349.7 × 164.3 pt Medium at 3x, and max 5054082 for the 349.7 × 365 pt Large;
    /// 2x pictures drew). A picture with more pixels than the widget's own is scaled down inside them: four times under
    /// the budget, and as sharp as the screen.
    static func fitted(_ image: CGImage, inside pixels: CGSize) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard pixels.width > 0, pixels.height > 0, w > pixels.width || h > pixels.height else { return image }
        let scale = min(pixels.width / w, pixels.height / h)
        let size = CGSize(width: max(1, (w * scale).rounded(.down)), height: max(1, (h * scale).rounded(.down)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage() ?? image
    }
}
