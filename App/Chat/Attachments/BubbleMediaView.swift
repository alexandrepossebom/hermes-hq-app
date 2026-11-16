import UIKit

// The photos and file rows inside a chat bubble (docs/spec/1x-attachments.md §7.3, §7.5): it lays out exactly what
// `AttachmentBubbleLayout` measured, clips your album to the bubble's outline (a photo-only bubble is the photos
// themselves), and hands taps, long presses and learnt sizes to the chat screen through `ChatMediaCellDelegate`.

/// What a chat cell's photos and files ask of the screen (the chat view controller adopts it).
@MainActor protocol ChatMediaCellDelegate: AnyObject {
    /// A photo tapped: the viewer over `items` (the message's or reply part's photos), starting at `index`; `source`
    /// finds a tile for the zoom transition while it is on screen.
    func chatCellOpenMedia(messageId: String, items: [MediaItem], index: Int, source: @escaping (Int) -> UIView?)
    /// "Photo too large to load" › Tap to open: the original as a file.
    func chatCellOpenMediaAsFile(messageId: String, item: MediaItem)
    func chatCellOpenFile(messageId: String, row: FileRowView)
    func chatCellMediaMenu(messageId: String, item: MediaItem, tile: MediaTileView) -> UIMenu?
    func chatCellFileMenu(messageId: String, row: FileRowView) -> UIMenu?
    func chatCellLearnedMediaSize(messageId: String, index: Int, width: Int, height: Int)
    func chatCellLearnedReplyMediaSize(messageId: String, key: String, width: Int, height: Int)
    func chatCellMediaUnavailable(messageId: String, path: String, reason: String)
    /// [mac] Stress test 2026-10-28 #19: what a file row carries when it is dragged out of the chat (nil: it isn't).
    func chatCellFileDragProvider(messageId: String, row: FileRowView) -> NSItemProvider?
}

final class BubbleMediaView: UIView, MediaTileHost, FileRowHost, UIContextMenuInteractionDelegate {
    /// The screen (the cell's delegate, when it adopts `ChatMediaCellDelegate`).
    var delegateProvider: (() -> ChatMediaCellDelegate?)?
    private(set) var messageId = ""

    private var groupViews: [UIView] = []
    /// Each group's photos: the ones on its tiles, then a grid's photos past its "+N" (the viewer pages them all).
    private var groupItems: [[MediaItem]] = []
    private var tiles: [[MediaTileView]] = []
    private var rows: [FileRowView] = []
    private let capsule = UIView()
    private var tileInteractions: [ObjectIdentifier: UIContextMenuInteraction] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        capsule.backgroundColor = UIColor(white: 0, alpha: 0.45)
        capsule.isUserInteractionEnabled = false
        capsule.isHidden = true
        addSubview(capsule)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var hasContent: Bool { !groupItems.isEmpty || rows.contains { !$0.isHidden } }

    /// Every element VoiceOver should read, in order (photos, then files): only the groups this message uses. A reused
    /// cell's spare group keeps its tiles (hidden with it); listing them put a stale photo over this bubble's file rows.
    var accessibleViews: [UIView] {
        var out: [UIView] = []
        for (g, group) in tiles.enumerated() where g < groupViews.count && !groupViews[g].isHidden && g < groupItems.count {
            out += group.filter { !$0.isHidden }
        }
        return out + rows.filter { !$0.isHidden }
    }

    /// Lays out `b`'s photos and file rows (bubble coordinates; the view fills the bubble).
    func configure(_ b: BubbleLayout, messageId: String, style: ChatStyle) {
        self.messageId = messageId
        frame = CGRect(origin: .zero, size: b.frame.size)
        var groups: [MediaGroupLayout] = b.mediaGroups
        var fileRows: [FileRowLayout] = b.fileRows
        for block in b.blocks {
            guard let media = block.media else { continue }
            let o = block.frame.origin
            groups += media.groups.map { g in var c = g; c.frame = g.frame.offsetBy(dx: o.x, dy: o.y); return c }
            fileRows += media.rows.map { r in var c = r; c.frame = r.frame.offsetBy(dx: o.x, dy: o.y); return c }
        }
        isHidden = groups.isEmpty && fileRows.isEmpty
        configureGroups(groups, shape: b.shape)
        configureRows(fileRows, style: style)
        if let cap = b.timeCapsule {
            capsule.isHidden = false
            capsule.frame = cap
            capsule.layer.cornerRadius = cap.height / 2
            bringSubviewToFront(capsule)
        } else {
            capsule.isHidden = true
        }
    }

    private func configureGroups(_ groups: [MediaGroupLayout], shape: BubbleShape.Key) {
        while groupViews.count < groups.count {
            let v = UIView()
            v.clipsToBounds = true
            insertSubview(v, belowSubview: capsule)
            groupViews.append(v)
            tiles.append([])
        }
        groupItems = groups.map { $0.tiles.map(\.item) + $0.more }
        for g in groupViews.indices {
            guard g < groups.count else {
                groupViews[g].isHidden = true
                for t in tiles[g] { t.prepareForReuse(); t.isHidden = true }
                continue
            }
            let group = groups[g]
            let view = groupViews[g]
            view.isHidden = false
            view.frame = group.frame
            if group.tileRadius != nil {
                // A grid: each tile is its own rounded card; nothing clips them together.
                view.layer.mask = nil
                view.layer.cornerRadius = 0
            } else if let radius = group.radius {
                view.layer.mask = nil
                view.layer.cornerRadius = radius
                view.layer.cornerCurve = .continuous
            } else {
                // Clipped by the bubble's own outline (its run corners; never the tail).
                view.layer.cornerRadius = 0
                let mask = (view.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
                var key = shape
                key.tail = false
                var t = CGAffineTransform(translationX: -group.frame.minX, y: -group.frame.minY)
                mask.path = BubbleShape.path(key).copy(using: &t)
                mask.frame = view.bounds
                view.layer.mask = mask
            }
            while tiles[g].count < group.tiles.count {
                let tile = makeTile()
                view.addSubview(tile)
                tiles[g].append(tile)
            }
            for (i, tile) in tiles[g].enumerated() {
                if i < group.tiles.count {
                    tile.isHidden = false
                    // A grid's last tile stands for the photos after it too.
                    tile.configure(group.tiles[i].item, frame: group.tiles[i].frame, fits: group.fits,
                                   more: i == group.tiles.count - 1 ? group.more.count : 0, card: group.tileRadius)
                    tile.accessibilityIdentifier = "chat.media.\(messageId).\(flatIndex(g, i))"
                } else {
                    tile.isHidden = true
                    tile.prepareForReuse()
                }
            }
        }
    }

    private func makeTile() -> MediaTileView {
        let tile = MediaTileView()
        tile.host = self
        tile.addInteraction(UIContextMenuInteraction(delegate: self))
        #if targetEnvironment(macCatalyst)
        tile.addInteraction(UIDragInteraction(delegate: self))   // [mac] #19: drag the photo out
        #endif
        return tile
    }

    private func flatIndex(_ group: Int, _ index: Int) -> Int {
        groupItems.prefix(group).reduce(0) { $0 + $1.count } + index
    }

    private func configureRows(_ layouts: [FileRowLayout], style: ChatStyle) {
        while rows.count < layouts.count {
            let row = FileRowView()
            row.host = self
            #if targetEnvironment(macCatalyst)
            row.addInteraction(UIDragInteraction(delegate: self))   // [mac] #19: drag the file out
            #endif
            insertSubview(row, belowSubview: capsule)
            rows.append(row)
        }
        for (i, row) in rows.enumerated() {
            if i < layouts.count {
                row.isHidden = false
                row.configure(layouts[i], style: style, frame: layouts[i].frame)
                row.accessibilityIdentifier = "chat.file.\(messageId).\(i)"
            } else {
                row.isHidden = true
                row.prepareForReuse()
            }
        }
    }

    func prepareForReuse() {
        for group in tiles { for t in group { t.prepareForReuse() } }
        for r in rows { r.prepareForReuse() }
        capsule.alpha = 1
    }

    /// The gateway link came back: every failed photo shown here retries once (spec §7.4).
    func retryFailedAfterReconnect() {
        for tile in tiles.joined() where !tile.isHidden { tile.retryAfterReconnect() }
    }

    /// Only the photos and rows take touches; the rest of the bubble behaves as before.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        for v in subviews where !v.isHidden && v.isUserInteractionEnabled && v !== capsule {
            if v.frame.contains(point) { return true }
        }
        return false
    }

    /// The tile at a flat photo index (zoom transition source); nil for a photo past a grid's "+N" (it has no tile).
    func tile(at flat: Int) -> MediaTileView? {
        var k = flat
        for (g, group) in tiles.enumerated() where g < groupItems.count {
            let count = groupItems[g].count
            if k < count {
                guard k < group.count, !group[k].isHidden, group[k].window != nil else { return nil }
                return group[k]
            }
            k -= count
        }
        return nil
    }

    // MARK: MediaTileHost

    func tileTapped(_ tile: MediaTileView) {
        guard let delegate = delegateProvider?(), let item = tile.item else { return }
        if tile.phase == .tooLarge {
            delegate.chatCellOpenMediaAsFile(messageId: messageId, item: item)
            return
        }
        if tile.phase == .failed && tile.opensAsLink {
            // "Open image: <name>" (spec §7.7): a URL in Safari, a path in the file preview.
            if case .remote(let url) = item.attachment.source { LinkOpener.openOutside(url) }
            else { delegate.chatCellOpenMediaAsFile(messageId: messageId, item: item) }
            return
        }
        guard !item.rendering else { return }
        // The viewer pages the tapped message's (or reply part's) photos.
        guard let g = tiles.firstIndex(where: { $0.contains { $0 === tile } }), let i = tiles[g].firstIndex(where: { $0 === tile }) else { return }
        let all = groupItems.flatMap { $0 }
        let index = flatIndex(g, i)
        // The zoom back lands on this view's tile only while it still shows this message (a reply streaming on while the
        // viewer is open rebuilds rows and reuses cells).
        let id = messageId
        delegate.chatCellOpenMedia(messageId: messageId, items: all, index: index) { [weak self] k in
            guard let self, self.messageId == id else { return nil }
            return self.tile(at: k)
        }
    }

    func tileLearnedSize(_ tile: MediaTileView, width: Int, height: Int) {
        guard let item = tile.item else { return }
        if item.index >= 0 {
            delegateProvider?()?.chatCellLearnedMediaSize(messageId: messageId, index: item.index, width: width, height: height)
        } else if let key = item.attachment.sizeKey {
            // A reply's picture: its own shape from the next layout on (a stack of screenshots stands tall).
            delegateProvider?()?.chatCellLearnedReplyMediaSize(messageId: messageId, key: key, width: width, height: height)
        }
    }

    func tileUnavailable(_ tile: MediaTileView, error: MediaLoadError) {
        guard let path = tile.item?.attachment.gatewayPath else { return }
        delegateProvider?()?.chatCellMediaUnavailable(messageId: messageId, path: path, reason: MediaUnavailable.words(error))
    }

    // MARK: FileRowHost

    func fileRowTapped(_ row: FileRowView) {
        delegateProvider?()?.chatCellOpenFile(messageId: messageId, row: row)
    }

    func fileRowMenu(_ row: FileRowView) -> UIMenu? {
        delegateProvider?()?.chatCellFileMenu(messageId: messageId, row: row)
    }

    // MARK: Long press on a photo (spec §9.6)

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let tile = interaction.view as? MediaTileView, let item = tile.item, tile.phase == .loaded,
              let menu = delegateProvider?()?.chatCellMediaMenu(messageId: messageId, item: item, tile: tile) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}

#if targetEnvironment(macCatalyst)
// MARK: [mac] Dragging out

/// [mac] Stress test 2026-10-28 #19: a photo or a file row drags out of the chat to the Finder or another app, as in
/// Messages: a loaded photo as its picture, a file as the file (downloaded when the drop asks for it).
extension BubbleMediaView: UIDragInteractionDelegate {
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        if let tile = interaction.view as? MediaTileView {
            guard tile.phase == .loaded, let item = tile.item, let image = tile.imageView.image else { return [] }
            let provider = NSItemProvider(object: image)
            provider.suggestedName = item.attachment.name
            AppLog.trace("chatui", "photo drag started")
            return [UIDragItem(itemProvider: provider)]
        }
        guard let row = interaction.view as? FileRowView,
              let provider = delegateProvider?()?.chatCellFileDragProvider(messageId: messageId, row: row) else { return [] }
        return [UIDragItem(itemProvider: provider)]
    }
}
#endif
