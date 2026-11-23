// [mac] DEBUG: `-HQDebugMacShotsBotsLane YES` photographs the Bots list's scroller beside its rows (owner 2026-11-23:
// "Scroll bar is too busy/touching other stuff"): a short window so the list scrolls, a row chosen (its box drawn),
// the scroller flashed; with the lane and without it (the picture before). Each shot logs the rows' trailing edges.

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

extension MacShots {
    @MainActor static func botsLaneTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var log = ""
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        guard let bots = tabs.controller(for: .bots), let split = tabs.split else { return }
        // The sidebar folded to its faces, so the Bots list is the column beside it (the owner's layout); unfolded
        // again at the end, as the fold is saved.
        let wasFolded = MacSidebar.isCollapsed
        if !wasFolded { split.macSidebar.toggleCollapsed() }
        defer { if !wasFolded && MacSidebar.isCollapsed { split.macSidebar.toggleCollapsed() } }
        tabs.pick(bots)
        split.followSelectedTab()
        let was = window.windowScene?.effectiveGeometry.systemFrame ?? CGRect(x: 60, y: 40, width: 1280, height: 800)
        window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: was.minX, y: was.minY, width: 1100, height: 460))) { _ in }
        await wait(3)
        guard let list = (bots as? UINavigationController)?.viewControllers.first as? BotsViewController,
              let cv = list.collectionView else {
            try? "no Bots list\n".write(to: folder.appending(path: "\(name)-botslane.txt"), atomically: true, encoding: .utf8)
            return
        }
        // A row chosen, as in the owner's screenshot: its box runs to the row's trailing inset.
        if let path = (0..<cv.numberOfSections).lazy.compactMap({ s in
            (0..<cv.numberOfItems(inSection: s)).lazy.map { IndexPath(item: $0, section: s) }
                .first { cv.cellForItem(at: $0)?.bounds.height ?? 0 > 40 }
        }).first {
            cv.selectItem(at: path, animated: false, scrollPosition: [])
        }
        func shot(_ label: String) async {
            cv.collectionViewLayout.invalidateLayout()
            cv.layoutIfNeeded()
            await wait(0.6)
            cv.flashScrollIndicators()
            await wait(0.15)
            shoot(window, to: folder.appending(path: "\(name)-\(label).png"))
            let edges = cv.visibleCells.map { Int($0.frame.maxX.rounded()) }
            log += "\(label): list \(cv.bounds.size) content \(cv.contentSize), lane \(ScrollBarLane.listTrailing), "
                + "cells maxX \(Set(edges).sorted()), list width \(Int(cv.bounds.width))\n"
        }
        await shot("bots-lane")
        ScrollBarLane.debugOff = true
        await shot("bots-no-lane")
        ScrollBarLane.debugOff = false
        cv.collectionViewLayout.invalidateLayout()
        window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: was)) { _ in }
        await wait(1)
        try? log.write(to: folder.appending(path: "\(name)-botslane.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
