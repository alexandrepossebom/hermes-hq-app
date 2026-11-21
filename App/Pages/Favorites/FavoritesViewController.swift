// [favorites] More › Favorites (docs/spec/3x-morepages.md §24): the More pages you chose, drawn as More draws its rows,
// each opening on this page's own stack. + opens Add Pages (every page, in More's groups); Edit removes and reorders,
// and a row swipes away. The choice is this device's (`FavoritePages`), as the tab order is. A tester,
// 2026-11-20: the pages she uses most were buried under More. It can be a tab of its own from Settings › Tabs.

import UIKit

final class FavoritesViewController: UIViewController, UICollectionViewDelegate {
    /// Every page Favorites can list, in More's groups (`PagesTabs.favoriteChoices`).
    private let pages: () -> [MoreSection]
    private var rows: [MoreRow] = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init(pages: @escaping () -> [MoreSection]) {
        self.pages = pages
        super.init(nibName: nil, bundle: nil)
        PageChrome.applyListHeader(to: self, title: "Favorites")
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private lazy var addItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self] _ in self?.showPicker() })
        item.accessibilityLabel = "Add Pages"
        item.accessibilityIdentifier = "favorites.add"
        DesktopBars.markThin(item)
        return item
    }()

    private lazy var editItem: UIBarButtonItem = {
        let item = editButtonItem
        item.accessibilityIdentifier = "favorites.edit"
        return item
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.groupedPage
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.backgroundColor = .clear   // [backdrop-cards] the page under it follows the skin (as More)
        config.trailingSwipeActionsConfigurationProvider = { [weak self] path in
            guard let self, let id = self.dataSource.itemIdentifier(for: path) else { return nil }
            let remove = UIContextualAction(style: .destructive, title: "Remove") { _, _, done in
                self.remove(id)
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [remove])
        }
        let layout = UICollectionViewCompositionalLayout { [weak self] _, environment in
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            if let self, BackdropCards.on(self) { section.contentInsets.top = 22 }   // where More's first card starts
            return section
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "favorites.list"
        collectionView.backgroundColor = HQPalette.groupedPage
        view.addSubview(collectionView)
        ListBarAppearance.pinTitle(in: self, grouped: true, softEdgeAround: collectionView)
        PageBackdrop.install(in: self, clearing: [collectionView])
        BackdropPlates.attach(to: collectionView, ink: { [weak self] in PageBackdrop.inkStyle(on: self) }) { [weak self] in
            PageBackdrop.showsPicture(on: self)
        }
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let row = self.rows.first(where: { $0.id == id }) else { return }
            if Theme.isDesktop {   // [desktoplook2] flat rows in an outlined box, as More's
                cell.configurationUpdateHandler = { cell, state in cell.backgroundConfiguration = DesktopLayout.rowBackground(state) }
            } else if cell.configurationUpdateHandler != nil {
                cell.configurationUpdateHandler = nil
                cell.backgroundConfiguration = cell.defaultBackgroundConfiguration()
            }
            let status = row.status?()
            cell.contentConfiguration = MoreViewController.rowContent(row, status: status)
            cell.accessories = [
                .delete(displayed: .whenEditing, actionHandler: { [weak self] in self?.remove(id) }),
                .reorder(displayed: .whenEditing),
                .disclosureIndicator(displayed: .whenNotEditing),
            ]
            cell.accessibilityIdentifier = "favorites-row-\(row.id)"
            cell.accessibilityLabel = status.map { "\(row.title), \($0.spoken)" }
            cell.accessibilityValue = status?.text
        }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { cv, path, id in
            cv.dequeueConfiguredReusableCell(using: cell, for: path, item: id)
        }
        dataSource.reorderingHandlers.canReorderItem = { [weak self] _ in self?.isEditing == true }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            let order = transaction.finalSnapshot.itemIdentifiers
            FavoritePages.reorder(shown: order)
            PagesHaptics.selection()
            self.reload()
        }
        for name in [FavoritePages.didChange, Theme.didChange, ServerIssues.didChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reload()
                    DesktopListOutliner.attach(to: self.collectionView)
                }
            }
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()   // a page may have come or gone on this gateway meanwhile
        DesktopListOutliner.attach(to: collectionView)
        if let selected = collectionView.indexPathsForSelectedItems?.first {
            transitionCoordinator?.animate(alongsideTransition: { _ in self.collectionView.deselectItem(at: selected, animated: true) })
            if transitionCoordinator == nil { collectionView.deselectItem(at: selected, animated: animated) }
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        collectionView.isEditing = editing
    }

    /// The chosen pages this gateway has, in the chosen order (a page it lacks stays chosen, unlisted).
    static func shown(_ ids: [String], in sections: [MoreSection]) -> [MoreRow] {
        var byID: [String: MoreRow] = [:]
        for row in sections.flatMap({ $0.rows() }) where byID[row.id] == nil { byID[row.id] = row }
        return ids.compactMap { byID[$0] }
    }

    func reload() {
        guard isViewLoaded else { return }
        rows = Self.shown(FavoritePages.ids, in: pages())
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        if !rows.isEmpty {
            snapshot.appendSections([0])
            snapshot.appendItems(rows.map(\.id), toSection: 0)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        if rows.isEmpty, isEditing { setEditing(false, animated: false) }
        navigationItem.rightBarButtonItems = rows.isEmpty ? [addItem] : [addItem, editItem]
        setNeedsUpdateContentUnavailableConfiguration()
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        guard rows.isEmpty else { contentUnavailableConfiguration = nil; return }
        var empty = PageStates.empty(symbol: "star", title: "No Favorites",
                                     text: "Add the pages you use most, and they’re one tap away here.")
        // At the largest text sizes the picture goes: the words and the button need the room.
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory { empty.image = nil }
        var button = UIButton.Configuration.hqMacPush(or: .hqFilled(), capsule: true)
        button.title = "Add Pages"
        empty.button = button
        empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.showPicker() }
        contentUnavailableConfiguration = empty
    }

    private func remove(_ id: String) {
        PagesHaptics.selection()
        FavoritePages.remove(id)   // the change notice reloads the list
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isEditing, let id = dataSource.itemIdentifier(for: indexPath), let row = rows.first(where: { $0.id == id }),
              let page = row.make() else {
            collectionView.deselectItem(at: indexPath, animated: true)
            return
        }
        navigationController?.pushViewController(page, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool { !isEditing }

    /// Holding a row: open it, or take it off the list.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard !isEditing, indexPaths.count == 1, let id = dataSource.itemIdentifier(for: indexPaths[0]) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: "Remove from Favorites", image: UIImage(systemName: "star.slash"), attributes: .destructive) { _ in
                self?.remove(id)
            }])
        }
    }

    // MARK: Add Pages

    func showPicker() {
        if isEditing { setEditing(false, animated: true) }
        let picker = FavoritesPickerViewController(pages: pages)
        let navigation = UINavigationController(rootViewController: picker)
        SheetStyle.apply(navigation, from: self)
        present(navigation, animated: true)
    }
}
