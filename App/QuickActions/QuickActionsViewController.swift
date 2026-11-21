// [quick-actions] The Quick Actions page (docs/spec/3x-morepages.md §25; owner 2026-11-21: "I want everyone to be able
// to build a custom quick action page so every thing they would need is one click away after triggering the shortcut
// to open the quick action"). Tiles in two columns, Small or Wide; one tap runs one (`QuickActionsRouter.run`). Edit
// removes (−), reorders (drag) and adds (＋ Add Action); holding a tile out of Edit offers Small, Wide, Edit… and Remove.
// The list is this device's (`QuickTileStore`, `hqn.quickActions`). Opened as a sheet by every shortcut and link, and
// pushed from More › Quick Actions or shown as a tab.

import SwiftUI
import UIKit

final class QuickActionsViewController: UIViewController, UICollectionViewDelegate {
    /// In the page's own sheet (every shortcut's way in), or pushed / a tab.
    let inSheet: Bool
    private var list = QuickTileList()
    private var collectionView: UICollectionView!
    private lazy var moveHold = UILongPressGestureRecognizer(target: self, action: #selector(moveHeld(_:)))
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private lazy var notice = PageNoticeHost(in: view)
    private var seedWait: Task<Void, Never>?
    /// The starter set is waiting for the roster (the empty state waits with it).
    private var seeding = false
    /// The dashed ＋ Add Action tile's id (shown while editing).
    static let addID = "quick-actions.add"

    init(inSheet: Bool) {
        self.inSheet = inSheet
        super.init(nibName: nil, bundle: nil)
        title = "Quick Actions"
        navigationItem.largeTitleDisplayMode = .never
        if !inSheet { PageChrome.applyListHeader(to: self, title: "Quick Actions") }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private lazy var editItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "Edit", primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.setEditing(!self.isEditing, animated: true)
        })
        item.accessibilityIdentifier = "quick-actions.edit"
        return item
    }()

    /// Single column from AX3 (accessibilityExtraLarge), as the Set Up preview (`typeSize >= .accessibility3`).
    private var stacked: Bool { traitCollection.preferredContentSizeCategory >= .accessibilityExtraLarge }
    private var gap: CGFloat { HQFont.scaled(12) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = inSheet ? HQPalette.sheetPage : HQPalette.groupedPage
        view.accessibilityIdentifier = "quick-actions.page"
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        moveHold.minimumPressDuration = 0.35
        moveHold.isEnabled = false
        collectionView.addGestureRecognizer(moveHold)
        collectionView.accessibilityIdentifier = "quick-actions.grid"
        view.addSubview(collectionView)
        if !inSheet {
            ListBarAppearance.pinTitle(in: self, grouped: true, softEdgeAround: collectionView)
            PageBackdrop.install(in: self, clearing: [collectionView])
        }
        let tileCell = UICollectionView.CellRegistration<QuickTileCell, String> { [weak self] cell, _, id in
            guard let self, let tile = self.list.tiles.first(where: { $0.id == id }) else { return }
            self.configure(cell, tile)
        }
        let addCell = UICollectionView.CellRegistration<QuickTileCell, String> { [weak self] cell, _, _ in
            self?.configureAdd(cell)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { cv, path, id in
            id == Self.addID ? cv.dequeueConfiguredReusableCell(using: addCell, for: path, item: id)
                : cv.dequeueConfiguredReusableCell(using: tileCell, for: path, item: id)
        }
        // A hold-and-drag in Edit (`moveHeld`) is the collection view's interactive movement: it moves the cell and the
        // data source's snapshot together, and the list follows the snapshot.
        dataSource.reorderingHandlers.canReorderItem = { [weak self] id in self?.isEditing == true && id != Self.addID }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            let order = transaction.finalSnapshot.itemIdentifiers.filter { $0 != Self.addID }
            PagesHaptics.selection()
            let byID = Dictionary(self.list.tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.list.tiles = order.compactMap { byID[$0] } + self.list.tiles.filter { !order.contains($0.id) }
            // Saved on the next turn: this runs inside the data source's own apply, and the store's change notice
            // reloads (applying a snapshot there again is refused). The reload lays the widths out again in the new order.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                QuickTileStore.save(self.list)
                self.reload()
            }
            HQAnnounce.say("Moved")
        }
        for name in [QuickTileStore.didChange, Theme.didChange, ServerIssues.didChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _: UITraitCollection) in
            self.reload()
        }
        loadList()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()   // a bot, job or page may have come or gone meanwhile
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isEditing, navigationController?.presentedViewController == nil, presentedViewController == nil {
            setEditing(false, animated: false)
        }
    }

    // MARK: The list

    /// The stored list, or the starter set the first time there's a bot to make it for (the roster may still be on
    /// its way: up to 6 s).
    private func loadList() {
        list = QuickTileStore.load()
        guard list.tiles.isEmpty, !list.seeded else { return reload() }
        seeding = true
        reload()
        seedWait = Task { [weak self] in
            for _ in 0..<30 {
                guard let self else { return }
                if self.seedIfReady() { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            self?.seeding = false
            self?.reload()
        }
    }

    /// Seeds from the roster's first bot once it is known. True: done (seeded, or nothing to seed).
    private func seedIfReady() -> Bool {
        let stored = QuickTileStore.load()
        guard stored.tiles.isEmpty, !stored.seeded else { list = stored; return true }
        guard let root = MainTabController.current, let bot = root.services.bots.first else { return false }
        let shown = QuickTileStore.listToShow(stored, firstBot: (profile: bot.id, name: bot.name))
        if shown.seeded {
            QuickTileStore.save(shown.list)
            AppLog.note("quick-actions", "seeded the starter set")
        }
        list = shown.list
        return true
    }

    private func change(_ edit: (inout QuickTileList) -> Void) {
        edit(&list)
        QuickTileStore.save(list)   // its notice reloads the page
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        let stored = QuickTileStore.load()
        if stored.seeded || !stored.tiles.isEmpty { list = stored }
        if list.tiles.isEmpty, isEditing { return setEditing(false, animated: false) }   // it reloads
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(list.tiles.map(\.id), toSection: 0)
        if isEditing { snapshot.appendItems([Self.addID], toSection: 0) }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.collectionViewLayout.invalidateLayout()
        navigationItem.rightBarButtonItems = list.tiles.isEmpty ? [] : [editItem]
        setNeedsUpdateContentUnavailableConfiguration()
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        guard list.tiles.isEmpty, !seeding else { contentUnavailableConfiguration = nil; return }
        var empty = PageStates.empty(symbol: "square.grid.2x2", title: "No Quick Actions",
                                     text: "Add the actions and pages you use most.")
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory { empty.image = nil }
        var button = UIButton.Configuration.hqMacPush(or: .hqFilled(), capsule: true)
        button.title = "Add Action"
        empty.button = button
        empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.showAdd() }
        contentUnavailableConfiguration = empty
    }

    // MARK: Editing

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        editItem.title = editing ? "Done" : "Edit"
        editItem.style = editing ? .done : .plain
        moveHold.isEnabled = editing
        reload()
        for cell in collectionView.visibleCells { (cell as? QuickTileCell)?.setWiggling(editing) }
        HQAnnounce.say(editing ? "Editing Quick Actions" : nil)
    }

    private func remove(_ id: String) {
        PagesHaptics.selection()
        let name = list.tiles.first { $0.id == id }?.name
        change { $0.remove(id) }
        HQAnnounce.say(name.map { "Removed \($0)" })
    }

    private func setWide(_ id: String, _ wide: Bool) {
        PagesHaptics.selection()
        change { $0.setWide(id, wide) }
    }

    private func step(_ id: String, by delta: Int) -> Bool {
        var moved = false
        change { moved = $0.step(id, by: delta) }
        if moved { PagesHaptics.selection() }
        return moved
    }

    // MARK: Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            self?.section(environment) ?? Self.emptySection()
        }
    }

    private static func emptySection() -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(1)))
        return NSCollectionLayoutSection(group: .vertical(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                           heightDimension: .absolute(1)), subitems: [item]))
    }

    /// Rows of the tiles (and the ＋ tile, always small) as `QuickTileGrid` lays them out.
    private func section(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let ids = dataSource.snapshot().itemIdentifiers
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : ids.count
        var cells = ids.map { id in list.tiles.first { $0.id == id } ?? QuickTile(id: id, kind: .page) }
        while cells.count < count { cells.append(QuickTile(id: UUID().uuidString, kind: .page)) }   // mid-drag
        cells = Array(cells.prefix(count))
        guard !cells.isEmpty else { return Self.emptySection() }
        let half = gap / 2
        let rows = QuickTileGrid.rows(cells, columns: stacked ? 1 : 2).map { row -> NSCollectionLayoutGroup in
            // A row is only as wide as its tiles: a small tile alone before a wide one would otherwise be repeated
            // to fill the row, taking the next tile's place, and every width after it would land one tile off.
            let shares = row.map { index -> CGFloat in stacked || cells[index].wide ? 1 : 0.5 }
            let width = min(1, shares.reduce(0, +))
            let items = shares.map { share -> NSCollectionLayoutItem in
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(share / width),
                                                                    heightDimension: .estimated(120)))
                item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: half, bottom: 0, trailing: half)
                return item
            }
            return NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(width),
                                                                         heightDimension: .estimated(120)), subitems: items)
        }
        let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                        heightDimension: .estimated(CGFloat(rows.count) * 120)),
                                                     subitems: rows)
        group.interItemSpacing = .fixed(gap)
        let section = NSCollectionLayoutSection(group: group)
        let side = max(16, environment.container.effectiveContentSize.width > 700 ? 24 : 16) - half
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: side, bottom: 24, trailing: side)
        return section
    }

    // MARK: Cells

    private func configure(_ cell: QuickTileCell, _ tile: QuickTile) {
        let world = QuickActionsRouter.world()
        let missing = QuickTileRules.missing(tile, world: world)
        let subtitle = tile.subtitle(botName: QuickActionsRouter.botName(tile.bot))
        cell.contentConfiguration = UIHostingConfiguration {
            QuickTileFace(name: tile.name, subtitle: subtitle, symbol: tile.symbol, color: QuickTileLook.color(tile.tint),
                          stacked: stacked, dimmed: missing != nil)
        }
        .margins(.all, 0)
        cell.style(inSheet: inSheet, dashed: false, dimmed: missing != nil)
        cell.accessibilityIdentifier = "quick-tile-\(tile.id)"
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = "\(tile.name), \(subtitle)"
        cell.accessibilityValue = missing == nil ? nil : "Unavailable"
        cell.accessibilityTraits = .button
        cell.accessibilityCustomActions = accessibilityActions(tile)
        cell.onRemove = isEditing ? { [weak self] in self?.remove(tile.id) } : nil
        cell.badgeLabel = "Remove \(tile.name)"
        cell.setWiggling(isEditing)
    }

    private func configureAdd(_ cell: QuickTileCell) {
        cell.contentConfiguration = UIHostingConfiguration {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(Font.hq(.title3).weight(.semibold)).foregroundStyle(Color.hqTint)
                Text("Add Action").font(Font.hq(.headline)).foregroundStyle(Color.hqTintText)
            }
            .frame(maxWidth: .infinity, minHeight: HQFont.scaled(104))
        }
        .margins(.all, 0)
        cell.style(inSheet: inSheet, dashed: true, dimmed: false)
        cell.accessibilityIdentifier = "quick-actions.add-tile"
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = "Add Action"
        cell.accessibilityValue = nil
        cell.accessibilityTraits = .button
        cell.accessibilityCustomActions = nil
        cell.onRemove = nil
        cell.setWiggling(false)
    }

    /// VoiceOver's actions on a tile: Remove, Move Up / Down, Make Wide / Small (and Edit).
    private func accessibilityActions(_ tile: QuickTile) -> [UIAccessibilityCustomAction] {
        let id = tile.id
        var actions = [
            UIAccessibilityCustomAction(name: "Edit") { [weak self] _ in self?.showSetup(editing: id); return true },
            UIAccessibilityCustomAction(name: "Remove") { [weak self] _ in self?.remove(id); return true },
        ]
        let index = list.tiles.firstIndex { $0.id == id } ?? 0
        if index > 0 {
            actions.append(UIAccessibilityCustomAction(name: "Move Up") { [weak self] _ in
                guard self?.step(id, by: -1) == true else { return false }
                HQAnnounce.say("Moved up")
                return true
            })
        }
        if index < list.tiles.count - 1 {
            actions.append(UIAccessibilityCustomAction(name: "Move Down") { [weak self] _ in
                guard self?.step(id, by: 1) == true else { return false }
                HQAnnounce.say("Moved down")
                return true
            })
        }
        actions.append(UIAccessibilityCustomAction(name: tile.wide ? "Make Small" : "Make Wide") { [weak self] _ in
            self?.setWide(id, !tile.wide)
            return true
        })
        return actions
    }

    // MARK: Taps

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        if id == Self.addID { return showAdd() }
        guard let tile = list.tiles.first(where: { $0.id == id }) else { return }
        if isEditing { return showSetup(editing: id) }
        Haptics.play(.selection)
        QuickActionsRouter.run(tile, from: self) { [weak self] said in self?.say(said) }
    }

    /// A background tile's answer: ✓ and what it did, or the reason, on a line under the bar (and said).
    func say(_ said: QuickActionsRouter.Said) {
        switch said {
        case .done(let words):
            PagesHaptics.success()
            notice.show("✓ " + words)
            HQAnnounce.say(words)
        case .failed(let words):
            Haptics.play(.error)
            notice.show(words, seconds: 4)
            HQAnnounce.say(words, priority: .high)
        }
    }

    /// Holding a tile out of Edit: Small, Wide, Edit… and Remove.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        // In Edit a hold picks the tile up to drag (as the Home Screen's jiggle mode); the − badge, a tap (Edit Action)
        // and the VoiceOver actions cover the rest there. The menu would swallow the hold and the drag never starts.
        guard !isEditing, indexPaths.count == 1, let id = dataSource.itemIdentifier(for: indexPaths[0]), id != Self.addID,
              let tile = list.tiles.first(where: { $0.id == id }) else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            let small = UIAction(title: "Small", image: UIImage(systemName: "square"), state: tile.wide ? .off : .on) { _ in
                self?.setWide(id, false)
            }
            let wide = UIAction(title: "Wide", image: UIImage(systemName: "rectangle"), state: tile.wide ? .on : .off) { _ in
                self?.setWide(id, true)
            }
            let edit = UIAction(title: "Edit…", image: UIImage(systemName: "slider.horizontal.3")) { _ in self?.showSetup(editing: id) }
            let remove = UIAction(title: "Remove", image: UIImage(systemName: "minus.circle"), attributes: .destructive) { _ in
                self?.remove(id)
            }
            return UIMenu(children: [UIMenu(options: .displayInline, children: [small, wide]),
                                     UIMenu(options: .displayInline, children: [edit, remove])])
        }
    }

    // MARK: Reordering (hold and drag while editing)

    /// The collection view's interactive movement, driven by a hold in Edit. (Drag and drop was tried first: after a
    /// drop the collection view kept its own mapping of positions, and the Wide widths, laid out by the snapshot's
    /// order, landed on other tiles until the page was rebuilt.)
    @objc private func moveHeld(_ hold: UILongPressGestureRecognizer) {
        let point = hold.location(in: collectionView)
        switch hold.state {
        case .began:
            guard let path = collectionView.indexPathForItem(at: point), dataSource.itemIdentifier(for: path) != Self.addID,
                  collectionView.beginInteractiveMovementForItem(at: path) else { return }
            PagesHaptics.selection()
        case .changed:
            collectionView.updateInteractiveMovementTargetPosition(point)
        case .ended:
            collectionView.endInteractiveMovement()
        default:
            collectionView.cancelInteractiveMovement()
        }
    }

    /// Never past the ＋ tile.
    func collectionView(_ collectionView: UICollectionView, targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
                        atCurrentIndexPath currentIndexPath: IndexPath, toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
        IndexPath(item: min(proposedIndexPath.item, max(0, list.tiles.count - 1)), section: proposedIndexPath.section)
    }

    // MARK: Add and Set Up

    func showAdd() {
        let add = QuickActionAddSheet.make(choices: { [weak self] in self?.pageChoices() ?? [] }) { [weak self] tile in
            self?.change { $0.add(tile) }
            HQAnnounce.say("Added \(tile.name)")
        }
        present(add, animated: true)
    }

    func showSetup(editing id: String) {
        guard let tile = list.tiles.first(where: { $0.id == id }) else { return }
        let setup = QuickActionSetup.sheet(editing: tile) { [weak self] saved in
            self?.change { $0.replace(saved) }
        }
        present(setup, animated: true)
    }

    /// Every page a tile can open (Favorites' choices, Favorites included).
    private func pageChoices() -> [MoreSection] {
        MainTabController.current?.pages?.quickActionChoices() ?? []
    }
}

/// One tile: its face (a hosted SwiftUI view), its card, and Edit's − badge and wiggle.
final class QuickTileCell: UICollectionViewCell {
    static let radius: CGFloat = 18
    var onRemove: (() -> Void)? { didSet { badge.isHidden = onRemove == nil } }
    var badgeLabel: String? { didSet { badge.accessibilityLabel = badgeLabel } }
    private let badge = UIButton(type: .system)
    private let dash = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "minus.circle.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold))
        config.contentInsets = .zero
        badge.configuration = config
        badge.tintColor = HQPalette.red
        badge.backgroundColor = .white
        badge.layer.cornerRadius = 12
        badge.isHidden = true
        badge.accessibilityIdentifier = "quick-tile.remove"
        badge.addAction(UIAction { [weak self] _ in self?.onRemove?() }, for: .primaryActionTriggered)
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badge.centerYAnchor.constraint(equalTo: topAnchor, constant: 6),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
        ])
        dash.fillColor = UIColor.clear.cgColor
        dash.lineWidth = 1.5
        dash.lineDashPattern = [6, 4]
        layer.addSublayer(dash)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The card: the sheet's card in the page's sheet, the page's card when pushed; outlined in the Desktop Look. The
    /// ＋ tile is a dashed outline on nothing.
    func style(inSheet: Bool, dashed: Bool, dimmed: Bool) {
        var background = UIBackgroundConfiguration.clear()
        background.cornerRadius = Self.radius
        if !dashed {
            let card = inSheet ? HQPalette.sheetCard : HQPalette.card
            background.backgroundColor = dimmed ? card.withAlphaComponent(0.5) : card
            if Theme.isDesktop {
                background.strokeColor = HQPalette.cardEdge
                background.strokeWidth = 1
            }
        }
        backgroundConfiguration = background
        dash.isHidden = !dashed
        dash.strokeColor = HQPalette.tint.resolvedColor(with: traitCollection).cgColor
        bringSubviewToFront(badge)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dash.frame = bounds
        dash.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: Self.radius).cgPath
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        dash.strokeColor = HQPalette.tint.resolvedColor(with: traitCollection).cgColor
    }

    /// Edit's wiggle: only while Reduce Motion (and power saving) leave decoration on.
    func setWiggling(_ on: Bool) {
        layer.removeAnimation(forKey: "wiggle")
        guard on, !HQMotion.decorativeStill else { return }
        let wiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        let angle = 1.2 * Double.pi / 180
        wiggle.values = [-angle, angle, -angle]
        wiggle.duration = 0.28 + Double.random(in: 0...0.06)
        wiggle.repeatCount = .infinity
        wiggle.isAdditive = true
        wiggle.timeOffset = Double.random(in: 0...0.2)
        layer.add(wiggle, forKey: "wiggle")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRemove = nil
        layer.removeAnimation(forKey: "wiggle")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if !badge.isHidden, badge.frame.insetBy(dx: -8, dy: -8).contains(point) { return true }
        return super.point(inside: point, with: event)
    }
}
