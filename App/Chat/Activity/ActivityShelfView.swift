import UIKit

/// One glass surface: a 34 pt pill in a 44 pt touch target, a compact category overview, or one existing detail.
/// The overview scroller is a sibling of detail cards, never an ancestor of their body scrollers.
final class ActivityShelfView: UIView {
    private let glass: UIVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        return UIVisualEffectView(effect: effect)
    }()
    let summaryHeader = ShelfHeader()
    private let overview = UIScrollView()
    private(set) var pieces: [ShelfPieceKind: ShelfPieceView] = [:]
    var onToggle: (() -> Void)?
    var onMetricsChange: (() -> Void)?
    var expanded = false
    var summary = ActivityPill(entries: [])
    var maxCardHeight: CGFloat = 300 { didSet { if maxCardHeight != oldValue { setNeedsLayout() } } }
    var maxHeight: CGFloat = .greatestFiniteMagnitude { didSet { if maxHeight != oldValue { setNeedsLayout() } } }
    static let gap: CGFloat = 6
    static let minCardBody: CGFloat = 60
    private var themeWatch: NSObjectProtocol?
    private var styledExpanded: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        // The header is outside the glass so the invisible 5 pt margins remain tappable.
        addSubview(summaryHeader)
        glass.contentView.addSubview(overview)
        overview.contentInsetAdjustmentBehavior = .never
        overview.alwaysBounceVertical = false
        overview.accessibilityIdentifier = "chat.shelf.scroll"
        summaryHeader.accessibilityIdentifier = "chat.shelf.summary"
        // A command can be arbitrarily long. The inline header stays bounded; VoiceOver keeps the whole step.
        summaryHeader.maximumWrappedLines = 2
        summaryHeader.addTarget(self, action: #selector(toggled), for: .touchUpInside)
        accessibilityIdentifier = "chat.shelf"
        themeWatch = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            // ThemeChrome restores/flattens the glass first. Never restyle the window from layout.
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.styledExpanded = nil
                self?.summaryHeader.updateFonts()
                self?.pieces.values.forEach { $0.header.updateFonts() }
                self?.setNeedsLayout()
                self?.onMetricsChange?()
            } }
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ActivityShelfView, _) in
            view.summaryHeader.updateFonts()
            view.pieces.values.forEach { $0.header.updateFonts() }
            view.onMetricsChange?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    isolated deinit { if let themeWatch { NotificationCenter.default.removeObserver(themeWatch) } }

    @objc private func toggled() { Haptics.play(.selection); onToggle?() }

    func piece(_ kind: ShelfPieceKind, make: () -> ShelfPieceView) -> ShelfPieceView {
        if let p = pieces[kind] { return p }
        let p = make()
        pieces[kind] = p
        overview.addSubview(p)
        return p
    }

    var visiblePieces: [ShelfPieceView] {
        let order = summary.entries.isEmpty ? ShelfPieceKind.allCases : summary.ordered.map(\.kind)
        return order.compactMap { pieces[$0] }.filter(\.isPresent)
    }

    private var detail: ShelfPieceView? { expanded ? visiblePieces.first(where: \.isOpen) : nil }
    var hasActivity: Bool { !visiblePieces.isEmpty || summary.parentIsRunning }
    var hasOpenCard: Bool { expanded }
    var piecesHeight: CGFloat { bounds.height }

    private func cardWidth(_ width: CGFloat) -> CGFloat {
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory { return width }
        if detail?.kind == .subagents { return width }
        return min(width, 300)
    }

    /// Keep the ordinary collapsed pill on one line. Aggregate urgent categories before using ordinary overflow;
    /// expanded details and accessibility text can wrap. VoiceOver keeps every category and its complete count.
    private func prepareHeader(width: CGFloat) {
        let showsStep = expanded && detail == nil && !summary.needsAttention && summary.currentStep != nil
        summaryHeader.requiresFullText = expanded && (summary.needsAttention || showsStep)
        let color: UIColor? = summary.isRunning ? ChatPalette.label2 : nil
        let showsSummary = detail == nil || summary.needsAttention
        summaryHeader.set(words: showsStep ? summary.currentStep! : showsSummary ? summary.words() : "All activity", spinner: detail == nil ? color : nil)
        if detail == nil, summaryHeader.fittingWidth > width, !showsStep {
            summaryHeader.set(words: summary.words(maxSegments: 1), spinner: color)
        }
        summaryHeader.setOpen(expanded, animated: false)
        summaryHeader.accessibilityLabel = showsSummary ? summary.accessibilityLabel : "All activity"
        if showsStep, !summary.entries.isEmpty { summaryHeader.accessibilityLabel = summary.currentStep! + ", " + summary.accessibilityLabel }
        summaryHeader.accessibilityValue = detail != nil ? "detail" : expanded ? "expanded" : "collapsed"
        summaryHeader.accessibilityHint = detail != nil ? "Returns to activity categories" : expanded ? "Collapses activity" : "Shows activity categories"
    }

    func height(for width: CGFloat) -> CGFloat {
        guard hasActivity else { return 0 }
        let w = expanded ? cardWidth(width) : width
        prepareHeader(width: w)
        let header = summaryHeader.height(width: w)
        guard expanded else { return header }
        if let detail {
            // Keep a usable body viewport even when the keyboard leaves less room than both headers.
            let floor = header + detail.header.height(width: w) + Self.minCardBody
            let cap = max(floor, min(maxCardHeight, maxHeight))
            return header + detail.size(for: w, maxCard: cap - header).height
        }
        let cap = max(header + 44, min(maxCardHeight, maxHeight))
        let rows = visiblePieces.reduce(CGFloat.zero) { $0 + $1.header.height(width: w) }
        return min(cap, header + rows)
    }

    /// Detail coordinates are in the glass; overview row coordinates are in its scroller.
    func targetFrames(width: CGFloat) -> [ShelfPieceKind: CGRect] {
        guard expanded else { return [:] }
        let w = cardWidth(width)
        prepareHeader(width: w)
        let header = summaryHeader.height(width: w)
        if let detail {
            return [detail.kind: CGRect(x: 0, y: header, width: w, height: max(44, height(for: width) - header))]
        }
        var y: CGFloat = 0
        var frames: [ShelfPieceKind: CGRect] = [:]
        for p in visiblePieces {
            let h = p.header.height(width: w)
            frames[p.kind] = CGRect(x: 0, y: y, width: w, height: h)
            y += h
        }
        return frames
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let present = hasActivity
        accessibilityElementsHidden = !present
        glass.isHidden = !present
        glass.accessibilityElementsHidden = !present || !expanded
        summaryHeader.isHidden = !present
        guard present else { return }
        let w = expanded ? cardWidth(bounds.width) : bounds.width
        prepareHeader(width: w)
        let headerH = summaryHeader.height(width: w)
        let actualW = expanded ? w : min(w, summaryHeader.fittingWidth)
        let x = ((bounds.width - actualW) / 2).rounded()
        let margin: CGFloat = expanded ? 0 : 5
        glass.frame = CGRect(x: x, y: margin, width: actualW, height: max(0, bounds.height - 2 * margin))
        summaryHeader.frame = CGRect(x: x, y: 0, width: actualW, height: headerH)
        if styledExpanded != expanded {
            styledExpanded = expanded
            if glass.effect is UIGlassEffect {
                let effect = UIGlassEffect(style: .regular)
                effect.isInteractive = !expanded
                effect.tintColor = expanded ? ShelfPieceView.cardTint : nil
                glass.effect = effect
            }
            glass.cornerConfiguration = Theme.isDesktop ? .corners(radius: .fixed(4)) : expanded ? .corners(radius: .fixed(18)) : .capsule()
        }
        overview.isHidden = !expanded || detail != nil
        overview.accessibilityElementsHidden = overview.isHidden
        overview.frame = CGRect(x: 0, y: headerH, width: actualW, height: max(0, bounds.height - headerH))
        let frames = targetFrames(width: bounds.width)
        for p in pieces.values {
            let shown = p.isPresent && expanded && (detail == nil || detail === p)
            p.isHidden = !shown
            p.accessibilityElementsHidden = !shown
            let parent: UIView = detail === p ? glass.contentView : overview
            if p.superview !== parent { parent.addSubview(p) }
            if let frame = frames[p.kind] { p.place(frame) }
        }
        let contentH = detail == nil ? frames.values.map(\.maxY).max() ?? 0 : 0
        overview.contentSize = CGSize(width: actualW, height: contentH)
        overview.isScrollEnabled = contentH > overview.bounds.height
        overview.contentOffset.y = min(overview.contentOffset.y, max(0, contentH - overview.bounds.height))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard hasActivity else { return false }
        return expanded ? glass.frame.contains(point) : summaryHeader.frame.contains(point)
    }

    func chipsTrailingEdge(in view: UIView) -> CGFloat {
        guard hasActivity else { return 0 }
        return convert(summaryHeader.frame, to: view).maxX
    }

    func collapsedWidth(for width: CGFloat) -> CGFloat {
        prepareHeader(width: width)
        return min(width, summaryHeader.fittingWidth)
    }
}

/// A category row and its existing detail body. The shelf supplies the single glass backing.
/// Keep this a plain view: an effect view's accessibility traversal can expose its folded children.
final class ShelfPieceView: UIView {
    let kind: ShelfPieceKind
    let header = ShelfHeader()
    let scroll = UIScrollView()
    /// The body (subagents, tasks or goal content); laid out with Auto Layout inside the scroller.
    let body: UIView
    private(set) var isOpen = false
    /// Shown (false while hidden or fading out).
    private(set) var isPresent = false
    /// While a leaving piece fades: its top's distance above the shelf's (pinned) bottom, kept while the shelf shrinks.
    var leavingFromBottom: CGFloat?
    var onToggle: (() -> Void)?

    override var accessibilityElements: [Any]? {
        get {
            guard isPresent, !isHidden, !accessibilityElementsHidden else { return [] }
            // Explicit containers bypass a child's hidden flag: omit folded bodies and hidden actions entirely.
            var elements: [Any] = [header]
            if isOpen {
                if !header.more.isHidden { elements.append(header.more) }
                elements.append(scroll)
            }
            return elements
        }
        set { super.accessibilityElements = newValue }
    }

    init(kind: ShelfPieceKind, body: UIView) {
        self.kind = kind
        self.body = body
        super.init(frame: .zero)
        isHidden = true
        accessibilityElementsHidden = true
        alpha = 0
        cornerConfiguration = .capsule()
        header.addTarget(self, action: #selector(toggled), for: .touchUpInside)
        addSubview(header)
        // The goal's ⋯ sits over the header's trailing end, a sibling (the header is one accessibility element).
        addSubview(header.more)
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = true
        scroll.accessibilityIdentifier = "chat.shelf.detail.\(kind)"
        scroll.isHidden = true
        scroll.accessibilityElementsHidden = true
        scroll.alpha = 0
        addSubview(scroll)
        body.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
        ])
        // The category's corner shape follows the shared backing when the look changes.
        themeWatch = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyCorners() } }
        }
    }

    private var themeWatch: NSObjectProtocol?
    isolated deinit { if let themeWatch { NotificationCenter.default.removeObserver(themeWatch) } }

    /// Capsule chip, 18 pt card; the Desktop Look's 4 pt corners either way (its flat panels).
    private func applyCorners() {
        cornerConfiguration = Theme.isDesktop ? .corners(radius: .fixed(4)) : isOpen ? .corners(radius: .fixed(18)) : .capsule()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func toggled() {
        Haptics.play(.selection)
        onToggle?()
    }

    func place(_ frame: CGRect) {
        let size = frame.size
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if bounds.size != size { bounds = CGRect(origin: .zero, size: size) }
        if self.center != center { self.center = center }
    }

    /// Chip: the header's own width; card: the shelf's width, the header and as much body as fits.
    func size(for width: CGFloat, maxCard: CGFloat, compact: Bool = false) -> CGSize {
        let headerH = header.height(width: width, compact: compact && !isOpen)
        guard isOpen else { return CGSize(width: min(width, header.fittingWidth), height: headerH) }
        let bodyH = bodyHeight(width: width)
        return CGSize(width: width, height: min(maxCard, headerH + bodyH))
    }

    /// The least an opened card shrinks to when the shelf runs out of room: its header and a little body (it scrolls).
    func minCardHeight(width: CGFloat) -> CGFloat {
        let headerH = header.height(width: width)
        return headerH + min(bodyHeight(width: width), ActivityShelfView.minCardBody)
    }

    /// The body's fitting height, measured once per content change (`ShelfMeasuredBody.layoutRevision`), width and
    /// text size.
    private var measured: (width: CGFloat, revision: Int, category: UIContentSizeCategory, height: CGFloat)?

    func bodyHeight(width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let revision = (body as? ShelfMeasuredBody)?.layoutRevision
        let category = traitCollection.preferredContentSizeCategory
        if let m = measured, let revision, m.revision == revision, m.width == width, m.category == category { return m.height }
        let size = body.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = ceil(size.height)
        if let revision { measured = (width, revision, category, height) }
        return height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let headerH = header.height(width: bounds.width, compact: header.compact && !isOpen)
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerH)
        header.more.frame = CGRect(x: bounds.width - 44, y: (headerH - 44) / 2, width: 44, height: 44)
        scroll.frame = CGRect(x: 0, y: headerH, width: bounds.width, height: max(0, bounds.height - headerH))
    }

    /// Appear (0.2 s fade + scale 0.9 → 1) or leave (0.18 s fade).
    func setPresent(_ present: Bool, animated: Bool) {
        guard present != isPresent else { return }
        isPresent = present
        let motion = animated && window != nil && !HQMotion.reduced
        if present {
            leavingFromBottom = nil
            isHidden = false
            if motion {
                alpha = 0
                transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
                UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {   // motion-ok: `motion` is false under Reduce Motion
                    self.alpha = 1
                    self.transform = .identity
                }
            } else {
                alpha = 1
                transform = .identity
            }
        } else if motion {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseIn, .allowUserInteraction]) {   // motion-ok: `motion` is false under Reduce Motion
                self.alpha = 0
            } completion: { _ in if !self.isPresent { self.isHidden = true; self.leavingFromBottom = nil } }
        } else {
            alpha = 0
            isHidden = true
            leavingFromBottom = nil
        }
        GlyphTicker.shared.setNeedsUpdate()
    }

    /// Chip ↔ card. The frame morphs with the shelf's spring; the body fades in after it settles.
    /// The opened card's glass tint: the page colour at half strength in light, nothing in dark.
    static let cardTint = UIColor { @Sendable traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0)
            : ChatPalette.page.resolvedColor(with: traits).withAlphaComponent(0.55)   // the theme's page, not fixed white (audit 10-17)
    }

    func setOpen(_ open: Bool, animated: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        scroll.accessibilityElementsHidden = !open
        applyCorners()
        header.setOpen(open, animated: animated)
        GlyphTicker.shared.setNeedsUpdate()
        if open {
            scroll.isHidden = false
            scroll.contentOffset = .zero
            if animated && !HQMotion.reduced {
                scroll.alpha = 0
                UIView.animate(withDuration: 0.15, delay: 0.2, options: [.allowUserInteraction]) { self.scroll.alpha = 1 }
            } else {
                scroll.alpha = 1
            }
        } else {
            scroll.alpha = 0
            scroll.isHidden = true
        }
    }
}

/// The chip's words, its spinner and a chevron (turned down when open); the goal adds a leading tone dot and a trailing ⋯
/// once open. 44 pt tall, Subheadline (capped at 22), 14 pt leading / 10 pt trailing.
final class ShelfHeader: UIControl {
    let label = UILabel()
    let chevron = UIImageView()
    private(set) var spinner: GlyphSpinner?
    let leadingDot = UIView()
    /// [browser] A symbol before the words (the browser chip's globe), shown whenever it has an image.
    let leadingIcon = UIImageView()
    let more = UIButton(type: .system)
    private var open = false
    /// An urgent summary must remain readable even at a narrow ordinary text size.
    var requiresFullText = false {
        didSet { label.numberOfLines = wrapsNow ? maximumWrappedLines : 1 }
    }
    var maximumWrappedLines = 0 {
        didSet { label.numberOfLines = wrapsNow ? maximumWrappedLines : 1; setNeedsLayout() }
    }
    var showsMore = false { didSet { more.isHidden = !(showsMore && open); setNeedsLayout() } }
    var showsLeadingDot = false { didSet { leadingDot.isHidden = !(showsLeadingDot && open); setNeedsLayout() } }
    /// UX study #230: a folded chip keeps to one line even at accessibility sizes (the shelf ran out of room).
    var compact = false {
        didSet { guard compact != oldValue else { return }; label.numberOfLines = wrapsNow ? maximumWrappedLines : 1; setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textColor = ChatPalette.label
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isUserInteractionEnabled = false
        addSubview(label)
        chevron.contentMode = .center
        chevron.tintColor = ChatPalette.label2
        chevron.isUserInteractionEnabled = false
        addSubview(chevron)
        leadingDot.layer.cornerRadius = 4
        leadingDot.isHidden = true
        leadingDot.isUserInteractionEnabled = false
        addSubview(leadingDot)
        leadingIcon.contentMode = .center
        leadingIcon.isHidden = true
        leadingIcon.isUserInteractionEnabled = false
        addSubview(leadingIcon)
        more.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        more.tintColor = ChatPalette.label2
        more.isHidden = true
        more.accessibilityLabel = "Goal Actions"
        more.showsMenuAsPrimaryAction = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Shows details"
        updateFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ShelfHeader, _) in
            view.updateFonts()
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var isLarge: Bool { traitCollection.preferredContentSizeCategory.isAccessibilityCategory }
    /// The words may wrap: a folded chip at accessibility sizes.
    var wraps: Bool { isLarge && !open }
    /// They wrap now (an open card's header always may; a chip unless told to keep to one line).
    private var wrapsNow: Bool { requiresFullText || (isLarge && !(compact && !open)) }

    fileprivate func updateFonts() {
        let size = min(HQFont.preferred(.subheadline, compatibleWith: traitCollection).pointSize, 22)
        label.font = HQFont.face(ofSize: size)
        label.numberOfLines = wrapsNow ? maximumWrappedLines : 1
        let config = UIImage.SymbolConfiguration(pointSize: (size * 0.7).rounded(), weight: .semibold)
        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: config)
        // The ⋯ grows with the words too (it stayed at the system's default size while the chevron followed them).
        more.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: size, weight: .semibold), forImageIn: .normal)
        spinner?.font = HQFont.monoFace(ofSize: size, weight: .regular)
    }

    /// The words and whether a spinner (in `color`) follows them.
    func set(words: String, spinner color: UIColor?) {
        if label.text != words { label.text = words; setNeedsLayout() }
        if let color {
            if spinner == nil {
                let s = GlyphSpinner(style: .braille, color: color, size: label.font.pointSize, prescaled: true)
                s.isUserInteractionEnabled = false
                addSubview(s)
                spinner = s
                setNeedsLayout()
            }
            spinner?.textColor = color
        } else if let s = spinner {
            s.removeFromSuperview()
            spinner = nil
            setNeedsLayout()
        }
        accessibilityLabel = words + (color != nil ? ", running" : "")
        accessibilityValue = open ? "expanded" : "collapsed"
    }

    func setOpen(_ open: Bool, animated: Bool) {
        self.open = open
        label.numberOfLines = wrapsNow ? maximumWrappedLines : 1
        more.isHidden = !(showsMore && open)
        leadingDot.isHidden = !(showsLeadingDot && open)
        accessibilityValue = open ? "expanded" : "collapsed"
        let turn = { self.chevron.transform = open ? CGAffineTransform(rotationAngle: .pi / 2) : .identity }
        if animated && !HQMotion.reduced { UIView.animate(withDuration: 0.25, animations: turn) } else { turn() }
        setNeedsLayout()
    }

    /// 44 pt; at accessibility sizes the words wrap and the header grows.
    func height(width: CGFloat?, compact: Bool = false) -> CGFloat {
        guard isLarge || requiresFullText else { return 44 }
        if compact { return max(44, ceil(label.font.lineHeight) + 20) }
        let w = availableLabelWidth(in: width ?? 340)
        let text = label.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        return max(44, ceil(text) + 20)
    }

    /// Measurement and placement must reserve the same space for the goal's dot, actions and optional spinner.
    private func availableLabelWidth(in width: CGFloat) -> CGFloat {
        let leading: CGFloat = 14 + (leadingDot.isHidden ? 0 : 16) + (leadingIcon.isHidden ? 0 : 28)
        let trailing: CGFloat = more.isHidden ? 10 : 44
        let chevW = (chevron.image?.size.width ?? 8) + 4
        let spinW = spinner.map { $0.intrinsicContentSize.width } ?? 0
        return max(1, width - leading - trailing - chevW - 2 - (spinW > 0 ? spinW + 4 : 0) - 4)
    }

    /// Words + spinner + chevron + paddings.
    var fittingWidth: CGFloat {
        let words = ceil(label.intrinsicContentSize.width)
        let spin = spinner.map { $0.intrinsicContentSize.width + 4 } ?? 0
        let chev: CGFloat = 2 + (chevron.image?.size.width ?? 8) + 4
        let icon: CGFloat = leadingIcon.isHidden ? 0 : 22 + 6
        return 14 + icon + words + 4 + spin + chev + 10
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        var x: CGFloat = 14
        if !leadingDot.isHidden {
            leadingDot.frame = CGRect(x: x, y: (h - 8) / 2, width: 8, height: 8)
            x += 8 + 8
        }
        if !leadingIcon.isHidden {
            leadingIcon.frame = CGRect(x: x, y: (h - 22) / 2, width: 22, height: 22)
            x += 22 + 6
        }
        let chevW = (chevron.image?.size.width ?? 8) + 4
        let spinW = spinner.map { $0.intrinsicContentSize.width } ?? 0
        let available = availableLabelWidth(in: bounds.width)
        if let s = spinner {
            s.frame = CGRect(x: x, y: (h - spinW) / 2, width: spinW, height: spinW)
            x += spinW + 4
        }
        let wordsW = max(1, min(available, ceil(label.intrinsicContentSize.width)))
        let labelH = wrapsNow ? ceil(label.sizeThatFits(CGSize(width: wordsW, height: .greatestFiniteMagnitude)).height) : ceil(label.font.lineHeight)
        label.frame = CGRect(x: x, y: (h - labelH) / 2, width: wordsW, height: labelH)
        x = label.frame.maxX + 4
        chevron.frame = CGRect(x: x + 2, y: (h - 16) / 2, width: chevW - 4, height: 16)
    }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }
}
