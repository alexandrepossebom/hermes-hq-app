// [favorites] Favorites › + › Add Pages (docs/spec/3x-morepages.md §24): every page Favorites can list, in More's
// groups and order, each with its + or its tick. A tap adds the page at the end of Favorites, or takes it off again.

import UIKit

final class FavoritesPickerViewController: UIViewController, UICollectionViewDelegate {
    private let pages: () -> [MoreSection]
    private var sections: [(section: MoreSection, rows: [MoreRow])] = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!

    init(pages: @escaping () -> [MoreSection]) {
        self.pages = pages
        super.init(nibName: nil, bundle: nil)
        title = "Add Pages"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.hqPlaceClose(.hqClose(.done, action: UIAction { [weak self] _ in self?.dismiss(animated: true) }))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.sheetPage
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.backgroundColor = .clear
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = config
            if let self, index < self.sections.count, self.sections[index].section.header == nil { config.headerMode = .none }
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.backgroundColor = .clear
        collectionView.accessibilityIdentifier = "favorites.picker"
        view.addSubview(collectionView)
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, item in
            guard let row = self?.row(item) else { return }
            if Theme.isDesktop {   // [desktoplook2] flat rows in an outlined box, as More's
                cell.configurationUpdateHandler = { cell, state in cell.backgroundConfiguration = DesktopLayout.rowBackground(state) }
            } else if cell.configurationUpdateHandler != nil {
                cell.configurationUpdateHandler = nil
                cell.backgroundConfiguration = cell.defaultBackgroundConfiguration()
            }
            let chosen = FavoritePages.contains(row.id)
            cell.contentConfiguration = MoreViewController.rowContent(row, status: nil)
            let mark = UIImageView(image: UIImage(systemName: chosen ? "checkmark.circle.fill" : "plus.circle",
                                                  withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3)))
            mark.tintColor = HQPalette.tint
            mark.adjustsImageSizeForAccessibilityContentSizeCategory = true
            cell.accessories = [.customView(configuration: .init(customView: mark, placement: .trailing(), reservedLayoutWidth: .actual))]
            cell.accessibilityIdentifier = "favorites-pick-\(row.id)"
            cell.accessibilityLabel = row.title
            cell.accessibilityValue = chosen ? "In Favorites" : nil
            cell.accessibilityHint = chosen ? "Takes it off Favorites." : "Adds it to Favorites."
            cell.accessibilityTraits = chosen ? [.button, .selected] : [.button]
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, path in
            header.contentConfiguration = MoreViewController.headerContent(self.flatMap {
                path.section < $0.sections.count ? $0.sections[path.section].section.header : nil
            })
        }
        dataSource = UICollectionViewDiffableDataSource<String, String>(collectionView: collectionView) { cv, path, item in
            cv.dequeueConfiguredReusableCell(using: cell, for: path, item: item)
        }
        dataSource.supplementaryViewProvider = { cv, _, path in cv.dequeueConfiguredReusableSupplementary(using: header, for: path) }
        reload()
        DesktopListOutliner.attach(to: collectionView)
    }

    private func reload() {
        sections = pages().map { ($0, $0.rows()) }.filter { !$0.rows.isEmpty }
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for (section, rows) in sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(rows.map { section.id + "/" + $0.id }, toSection: section.id)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func row(_ item: String) -> MoreRow? {
        let parts = item.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return sections.first { $0.section.id == parts[0] }?.rows.first { $0.id == parts[1] }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath), let row = row(item) else { return }
        PagesHaptics.selection()
        if FavoritePages.contains(row.id) { FavoritePages.remove(row.id) } else { FavoritePages.add(row.id) }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([item])
        dataSource.apply(snapshot, animatingDifferences: false)
        HQAnnounce.say(FavoritePages.contains(row.id) ? "Added" : "Removed")
    }
}
