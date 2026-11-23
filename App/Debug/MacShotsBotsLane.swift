// [mac] DEBUG: `-HQDebugMacShotsBotsLane YES` photographs the lists' scroller beside their rows (owner 2026-11-23:
// "Scroll bar is too busy/touching other stuff"): a short window so each list scrolls, the scroller flashed; with the
// lane and without it (the picture before). Bots (a row chosen, its box drawn), then every other place whose page is
// a list (Jobs, Tasks, Kanban, Artifacts, More…). Each shot logs the list's cells' trailing edges.

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

extension MacShots {
    @MainActor static func botsLaneTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var log = ""
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        guard let bots = tabs.controller(for: .bots), let split = tabs.split else { return }
        // The sidebar folded to its faces, so a list is the column beside it (the owner's layout); unfolded again at the
        // end, as the fold is saved.
        let wasFolded = MacSidebar.isCollapsed
        if !wasFolded { split.macSidebar.toggleCollapsed() }
        defer { if !wasFolded && MacSidebar.isCollapsed { split.macSidebar.toggleCollapsed() } }
        func go(_ controller: UIViewController) async {
            tabs.pick(controller, animated: false)
            split.followSelectedTab()
            (controller as? UINavigationController)?.popToRootViewController(animated: false)
            await wait(2.5)
        }
        func lists(in view: UIView) -> [UICollectionView] {
            ((view as? UICollectionView).map { [$0] } ?? []) + view.subviews.flatMap { lists(in: $0) }
        }
        func shot(_ cv: UICollectionView, _ label: String) async {
            cv.collectionViewLayout.invalidateLayout()
            cv.layoutIfNeeded()
            await wait(0.6)
            cv.flashScrollIndicators()
            await wait(0.15)
            shoot(window, to: folder.appending(path: "\(name)-\(label).png"))
            let edges = cv.visibleCells.map { Int($0.frame.maxX.rounded()) }
            let heads = cv.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader).map { Int($0.frame.maxX.rounded()) }
            log += "\(label): list \(cv.bounds.size) content \(cv.contentSize), lane \(ScrollBarLane.listTrailing), "
                + "cells maxX \(Set(edges).sorted()), headers maxX \(Set(heads).sorted()), list width \(Int(cv.bounds.width))\n"
        }
        func pair(_ cv: UICollectionView, _ slug: String) async {
            await shot(cv, "\(slug)-lane")
            ScrollBarLane.debugOff = true
            await shot(cv, "\(slug)-no-lane")
            ScrollBarLane.debugOff = false
            cv.collectionViewLayout.invalidateLayout()
        }
        let was = window.windowScene?.effectiveGeometry.systemFrame ?? CGRect(x: 60, y: 40, width: 1280, height: 800)
        window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: was.minX, y: was.minY, width: 1100, height: 460))) { _ in }
        await go(bots)
        if let list = (bots as? UINavigationController)?.viewControllers.first as? BotsViewController, let cv = list.collectionView {
            // A row chosen, as in the owner's screenshot: its box runs to the row's trailing inset.
            if let path = (0..<cv.numberOfSections).lazy.compactMap({ s in
                (0..<cv.numberOfItems(inSection: s)).lazy.map { IndexPath(item: $0, section: s) }
                    .first { cv.cellForItem(at: $0)?.bounds.height ?? 0 > 40 }
            }).first {
                cv.selectItem(at: path, animated: false, scrollPosition: [])
            }
            await pair(cv, "bots")
        } else {
            log += "no Bots list\n"
        }
        log += "places: \(tabs.placedTabs.map { $0.tabBarItem.title ?? "?" })\n"
        for place in tabs.placedTabs where place !== bots {
            let title = place.tabBarItem.title ?? "?"
            await go(place)
            let root = (place as? UINavigationController)?.viewControllers.first ?? place
            guard root.isViewLoaded,
                  let cv = lists(in: root.view).filter({ $0.window != nil }).max(by: { $0.bounds.height < $1.bounds.height }) else {
                log += "\(title): no list\n"
                continue
            }
            log += "\(title): \(String(describing: type(of: root)))\n"
            await pair(cv, title.lowercased().map { $0.isLetter ? String($0) : "-" }.joined())
        }
        // The pages More opens (on the Mac, the sidebar's places): each pushed on More's stack and photographed.
        if let more = tabs.pages?.more, let nav = more.navigationController {
            more.loadViewIfNeeded()
            await go(nav)
            if let cv = lists(in: more.view).first { await pair(cv, "more") }
            for id in ["jobs", "tasks", "kanban", "artifacts"] {
                nav.popToRootViewController(animated: false)
                await wait(0.5)
                guard let page = more.open(rowId: id) else { log += "\(id): no row\n"; continue }
                await wait(3)
                guard let cv = lists(in: page.view).filter({ $0.window != nil }).max(by: { $0.bounds.height < $1.bounds.height }) else {
                    log += "\(id): \(String(describing: type(of: page))) no list\n"
                    continue
                }
                log += "\(id): \(String(describing: type(of: page)))\n"
                await pair(cv, id)
            }
            nav.popToRootViewController(animated: false)
        } else {
            log += "no More\n"
        }
        window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: was)) { _ in }
        await wait(1)
        try? log.write(to: folder.appending(path: "\(name)-botslane.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
