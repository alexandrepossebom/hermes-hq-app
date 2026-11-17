import UIKit

// Exact media geometry (docs/spec/1x-attachments.md §7.3, §7.5, §7.7): single-photo and grid frames, file rows and the
// generated-image card, all known before any pixel loads (heights never wait for images; spec §7.8). Pure and
// `nonisolated`, measured off the main thread with the rest of `TextLayout`.

/// One photo in a bubble or a reply's media block.
nonisolated struct MediaItem: Hashable, Sendable {
    var attachment: MessageAttachment
    /// Its index among the message's attachments (for the learnt-size write-back); -1 for reply markdown media.
    var index: Int
    /// Account, profile and session (media keys, downloads).
    var context: MediaContext?
    /// VoiceOver label ("Photo, chart.png", or a markdown image's alt text).
    var label: String
    /// An `image_generate` card: its aspect hint when the result has no pixel size, and whether the tool still runs.
    var generated: GeneratedImageInfo? = nil
    var rendering: Bool = false
}

/// One file row.
nonisolated struct FileItem: Hashable, Sendable {
    var attachment: MessageAttachment
    var index: Int
    var context: MediaContext?
    /// "PDF · 2.4 MB", "PDF", "Folder".
    var detail: String
}

/// Photos laid out together (a grid, a single photo, a generated image): their container inside the bubble.
nonisolated struct MediaGroupLayout: @unchecked Sendable {
    /// In bubble coordinates.
    var frame: CGRect
    /// The container's corner radius; nil = clipped by the bubble's own outline (your bubble, a photo-only bubble).
    var radius: CGFloat?
    var tiles: [(item: MediaItem, frame: CGRect)]
    /// The photo is shown whole (aspect fit) on a blur of itself: a tall photo widened for its caption.
    var fits = false
    /// A grid's photos past its last tile: that tile says "+N", and the viewer pages them after the ones shown.
    var more: [MediaItem] = []
    /// A grid: every tile is its own rounded card of this radius, with a hairline edge, its photo kept from the top
    /// (a screenshot's title stays in view). nil = the tiles share the container's outline.
    var tileRadius: CGFloat? = nil
}

/// One file row inside a bubble.
nonisolated struct FileRowLayout: @unchecked Sendable {
    var item: FileItem
    /// In bubble coordinates.
    var frame: CGRect
    var circle: CGRect
    var name: CGRect
    var nameLines: Int
    var detail: CGRect
    var mine: Bool
}

nonisolated enum MediaLayout {
    static let gap: CGFloat = 2
    static let singleMax: CGFloat = 260
    static let singleMaxHeight: CGFloat = 320
    static let singleMinWidth: CGFloat = 150
    static let singleMinHeight: CGFloat = 100
    static let unknownHeight: CGFloat = 195
    static let replyMax: CGFloat = 280
    static let replyRadius: CGFloat = 12

    /// One photo's frame (spec §7.3): ≤ 260 wide, ≤ 320 tall (then ≥ 150 wide), ≥ 100 tall; unknown → 260 × 195.
    static func single(width pw: Int?, height ph: Int?, maxWidth maxW: CGFloat) -> CGSize {
        let cap = min(maxW, singleMax)
        guard let pw, let ph, pw > 0, ph > 0 else { return CGSize(width: floor(cap), height: unknownHeight) }
        var w = cap
        var h = w * CGFloat(ph) / CGFloat(pw)
        if h > singleMaxHeight {
            h = singleMaxHeight
            w = max(singleMinWidth, min(maxW, singleMaxHeight * CGFloat(pw) / CGFloat(ph)))
        }
        if h < singleMinHeight { h = singleMinHeight }
        return CGSize(width: floor(w), height: floor(h))
    }

    // MARK: Photo grids

    /// How many photos a grid shows; with more, the last tile carries "+N" and the viewer pages them all.
    static let gridVisible = 4
    /// A grid is never wider than this (an iPad's or the Mac's column is far wider than a photo block should be).
    static let gridMaxWidth: CGFloat = 520
    /// Between a grid's tiles (each is its own rounded card).
    static let gridGap: CGFloat = 8

    /// Several photos as a grid across the chat's width (owner 2026-11-16: the swipe-through pile showed them "tiny" and
    /// was "hard to get through"; then, of a first grid that followed the photos' shapes, "more like this … like Claude
    /// does it", with a picture of that app's chat). Two columns of square tiles, each its own rounded card, 8 pt apart;
    /// with three photos the first runs across the top at the same height. Four at most: with more, the fourth carries
    /// "+N". Every frame follows from the count and the width alone (grids never wait for pixels). Returns one frame
    /// per shown photo, origin (0, 0), and the whole size.
    static func grid(count: Int, maxWidth: CGFloat) -> (frames: [CGRect], size: CGSize) {
        let n = min(count, gridVisible)
        guard n >= 2 else { return ([], .zero) }
        let width = floor(min(maxWidth, gridMaxWidth))
        let side = floor((width - gridGap) / 2)
        var out: [CGRect] = []
        var y: CGFloat = 0
        if n == 3 {
            out.append(CGRect(x: 0, y: 0, width: width, height: side))
            y = side + gridGap
        }
        for i in 0..<(n - out.count) {
            out.append(CGRect(x: i % 2 == 0 ? 0 : width - side, y: y + CGFloat(i / 2) * (side + gridGap), width: side, height: side))
        }
        return (out, CGSize(width: width, height: out.last?.maxY ?? 0))
    }

    /// The generated-image card (spec §7.7): `w = min(column, 320)`, the result's aspect (else the requested one),
    /// at most 400 tall.
    static func generated(_ info: GeneratedImageInfo, column: CGFloat) -> CGSize {
        let ratio = max(0.1, info.ratio)
        var w = min(column, 320)
        var h = w / ratio
        if h > 400 {
            h = 400
            w = 400 * ratio
        }
        return CGSize(width: floor(w), height: floor(h))
    }

    // MARK: File rows

    static let rowPadV: CGFloat = 12
    static let rowLead: CGFloat = 12
    static let rowTrail: CGFloat = 12
    static let circle: CGFloat = 40
    static let circleGap: CGFloat = 10
    static let rowGap: CGFloat = 4

    static func nameFont(_ style: ChatStyle) -> UIFont {
        HQFont.face(ofSize: min(22, max(15, HQFont.preferred(.subheadline,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: style.category)).pointSize)), weight: .semibold)
    }

    static func detailFont(_ style: ChatStyle) -> UIFont {
        HQFont.preferred(.caption1, compatibleWith: UITraitCollection(preferredContentSizeCategory: style.category))
    }

    /// The width a row wants for its words (one-line name or detail), before capping.
    static func naturalRowWidth(_ item: FileItem, style: ChatStyle, reserve: CGFloat = 0) -> CGFloat {
        let name = ceil((item.attachment.name as NSString).size(withAttributes: [.font: nameFont(style)]).width)
        let detail = ceil((item.detail as NSString).size(withAttributes: [.font: detailFont(style)]).width) + reserve
        return rowLead + circle + circleGap + max(name, detail) + rowTrail
    }

    /// One row at `width` (12 pt top/bottom padding, name up to 2 lines, detail under it; spec §7.3). `reserve`: room
    /// kept at the detail line's trailing end (the bubble's time).
    static func row(_ item: FileItem, at origin: CGPoint, width: CGFloat, mine: Bool, style: ChatStyle, reserve: CGFloat = 0) -> FileRowLayout {
        let nameFont = nameFont(style), detailFont = detailFont(style)
        let textX = rowLead + circle + circleGap
        let textW = max(20, width - textX - rowTrail)
        let line = ceil(nameFont.lineHeight)
        let measured = (item.attachment.name as NSString).boundingRect(with: CGSize(width: textW, height: .greatestFiniteMagnitude),
                                                                       options: [.usesLineFragmentOrigin],
                                                                       attributes: [.font: nameFont], context: nil)
        let lines = measured.height > line * 1.5 ? 2 : 1
        let nameH = line * CGFloat(lines)
        let detailH = ceil(detailFont.lineHeight)
        let textH = nameH + 2 + detailH
        let contentH = max(circle, textH)
        let rowH = rowPadV + contentH + rowPadV
        let circleY = rowPadV + (contentH - circle) / 2
        let textY = rowPadV + (contentH - textH) / 2
        return FileRowLayout(item: item, frame: CGRect(x: origin.x, y: origin.y, width: width, height: ceil(rowH)),
                             circle: CGRect(x: rowLead, y: circleY, width: circle, height: circle),
                             name: CGRect(x: textX, y: textY, width: textW, height: nameH), nameLines: lines,
                             detail: CGRect(x: textX, y: textY + nameH + 2, width: max(0, textW - reserve), height: detailH),
                             mine: mine)
    }

    /// Rows stacked from `y` (4 pt apart) at `width`; the last one keeps `lastReserve` for the time.
    static func rows(_ items: [FileItem], x: CGFloat, y: CGFloat, width: CGFloat, mine: Bool, style: ChatStyle,
                     lastReserve: CGFloat = 0) -> (rows: [FileRowLayout], maxY: CGFloat) {
        var out: [FileRowLayout] = []
        var cursor = y
        for (i, item) in items.enumerated() {
            if i > 0 { cursor += rowGap }
            let r = row(item, at: CGPoint(x: x, y: cursor), width: width, mine: mine, style: style,
                        reserve: i == items.count - 1 ? lastReserve : 0)
            out.append(r)
            cursor = r.frame.maxY
        }
        return (out, cursor)
    }

    // MARK: Fingerprints

    static func hash(_ items: [MediaItem], _ files: [FileItem], into h: inout Hasher) {
        h.combine(items.count)
        for m in items {
            h.combine(m.attachment.kind)
            h.combine(m.attachment.source)
            h.combine(m.attachment.name)
            h.combine(m.attachment.pixelWidth)
            h.combine(m.attachment.pixelHeight)
            h.combine(m.generated)
            h.combine(m.rendering)
        }
        h.combine(files.count)
        for f in files {
            h.combine(f.attachment.kind)
            h.combine(f.attachment.source)
            h.combine(f.attachment.name)
            h.combine(f.detail)
        }
    }
}
