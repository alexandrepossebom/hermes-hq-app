// [mac-favorites] DEBUG: `-HQDebugMacShotsTools YES` (owner 2026-11-22: "the kanban icon here is too big", "I don't
// see the Favorites page as an option here … make sure there aren't other pages that we left out"). With the sidebar
// folded, the Tools menu's items (title, icon size, symbol or drawn) as text and as a picture drawn from the same
// items (a system menu can't be photographed); then where each of More's pages is on the Mac (a place, a Tool, the
// Settings window, or MISSING); then Favorites opened from its Tool. `<name>-tools.txt` holds the log.

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

extension MacShots {
    @MainActor static func toolsTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        guard let split = tabs.split else { return }
        let bar = split.macSidebar
        let wasFolded = UserDefaults.standard.bool(forKey: MacSidebar.collapsedKey)
        var log = ""
        if !MacSidebar.isCollapsed { bar.toggleCollapsed() } else { bar.rebuild() }
        try? await Task.sleep(for: .seconds(1.5))

        // The Tools menu, as the folded sidebar's button has it.
        func find(_ view: UIView) -> UIButton? {
            if let button = view as? UIButton, button.accessibilityIdentifier == "mac-sidebar.tools-menu" { return button }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        let actions = (find(bar)?.menu?.children ?? []).compactMap { $0 as? UIAction }
        log += "tools menu: \(actions.count) items\n"
        for action in actions {
            let image = action.image
            let kind = image == nil ? "none" : (image!.isSymbolImage ? "symbol" : "drawn")
            log += "  \(action.title): \(kind) \(image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "-")\n"
        }
        // The menu's rows drawn as a menu draws them: a symbol at the menu's symbol size, a drawn image at its own size.
        let rowHeight: CGFloat = 24, width: CGFloat = 260
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 13)
        let picture = UIGraphicsImageRenderer(size: CGSize(width: width, height: rowHeight * CGFloat(actions.count) + 12)).image { context in
            UIColor(white: 0.16, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: rowHeight * CGFloat(actions.count) + 12))
            for (index, action) in actions.enumerated() {
                let y = 6 + CGFloat(index) * rowHeight
                if var image = action.image {
                    if image.isSymbolImage { image = image.applyingSymbolConfiguration(symbolConfig) ?? image }
                    let tinted = image.withTintColor(.white, renderingMode: .alwaysOriginal)
                    tinted.draw(in: CGRect(x: 12 + (18 - image.size.width) / 2, y: y + (rowHeight - image.size.height) / 2,
                                           width: image.size.width, height: image.size.height))
                }
                (action.title as NSString).draw(at: CGPoint(x: 40, y: y + 4),
                                                withAttributes: [.font: HQFont.face(ofSize: 13), .foregroundColor: UIColor.white])
            }
        }
        let png = folder.appending(path: "\(name)-tools-menu.png")
        try? picture.pngData()?.write(to: png)
        post(png)

        // Every More page, and where it is on the Mac.
        let placed = Set(tabs.placedTabs.compactMap(\.tabBarItem.accessibilityIdentifier))
        let tools = Set(tabs.pages?.toolIDs ?? [])
        log += "\nMore pages on the Mac:\n"
        var missing = 0
        var seen = Set<String>()
        for section in tabs.pages?.moreSections() ?? [] {
            for row in section.rows() where row.card == nil && seen.insert(row.id).inserted {
                let where_: String
                if tools.contains(row.id) { where_ = "Tool" }
                else if placed.contains("tab-page-\(row.id)") { where_ = "place" }
                else if MacOpenQuickly.settingsWindowPage(tabs, row.id) != nil { where_ = "Settings window" }
                else if row.id == "jobs" || row.id == "kanban" || row.id == "artifacts" || row.id == PagesTabs.botsRowID {
                    where_ = "main place (hidden)"
                } else { where_ = "MISSING"; missing += 1 }
                log += "  [\(section.id)] \(row.id) \(row.title): \(where_)\n"
            }
        }
        log += "missing: \(missing)\n"

        // Favorites opened from its Tool.
        if let tab = tabs.placedTab(tagged: PagesTabs.placeTag(QuickTileStore.rowID)) {
            tabs.show(tab)
            split.followSelectedTab()
            try? await Task.sleep(for: .seconds(2))
            let top = (tabs.selectedViewController as? UINavigationController)?.topViewController
            log += "\nfavorites: on show \(tabs.selectedViewController?.tabBarItem.title ?? "-") top \(top.map { String(describing: type(of: $0)) } ?? "-")\n"
            shoot(window, to: folder.appending(path: "\(name)-favorites.png"))
        } else {
            log += "\nfavorites: no Tool\n"
        }
        bar.toggleCollapsed()
        try? await Task.sleep(for: .seconds(1.2))
        shoot(window, to: folder.appending(path: "\(name)-open.png"))
        UserDefaults.standard.set(wasFolded, forKey: MacSidebar.collapsedKey)
        let file = folder.appending(path: "\(name)-tools.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        post(file)
        try? await Task.sleep(for: .seconds(1))
    }
}
#endif
