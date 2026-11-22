// [sidebar-divider] DEBUG: `-HQDebugMacShotsDivider YES` (owner 2026-11-22: "add additional … page options on the left
// sidebar … a little divider line … to separate them from the main icons"). Two pages that can join the sidebar are
// added (one saved between the main places, to check they still gather under the line), then the sidebar is
// photographed open, folded to faces and folded with names; `<name>-divider.txt` logs the order, the ⌘ keys and which
// moves are on. What was stored (tabs, the fold, the names) goes back at the end: the Debug app shares its container.

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

extension MacShots {
    @MainActor static func dividerTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        guard let split = tabs.split else { return }
        let bar = split.macSidebar
        let stored = UserDefaults.standard.object(forKey: TabOrder.key)
        let wasFolded = UserDefaults.standard.bool(forKey: MacSidebar.collapsedKey)
        let wasNamed = MacSidebar.railNamed
        var log = "stored before: \(stored.map { "\($0)" } ?? "nothing (default)")\n"
        func state(_ label: String) {
            let places = tabs.placedTabs
            log += "\(label): [\(places.map { ($0.tabBarItem.title ?? "?") + (bar.isTool($0) ? "(tool)" : "") }.joined(separator: ", "))]\n"
            log += "  ⌘ keys: " + places.enumerated().compactMap { index, controller in
                KeyCommands.shortcut(forTab: index, among: places.map { $0.tabBarItem.tag }).map { "⌘\($0) \(controller.tabBarItem.title ?? "?")" }
            }.joined(separator: ", ") + "\n"
            log += "  divider: \(bar.debugDivider)\n"
        }
        func shoot(_ label: String) async {
            try? await Task.sleep(for: .seconds(1.2))
            state(label)
            MacShots.shoot(window, to: folder.appending(path: "\(name)-\(label).png"))
        }
        if MacSidebar.isCollapsed { bar.toggleCollapsed() }
        await shoot("0-default")

        let pages = SidebarEditing.addable().filter { if case .page = $0.choice { true } else { false } }.prefix(2).map(\.choice)
        log += "adding: \(pages.map(\.key))\n"
        var order = TabOrder.tabs.filter { if case .main = $0 { true } else { false } }
        if pages.count == 2 { order.insert(pages[0], at: min(1, order.count)); order.append(pages[1]) } else { order += pages }
        TabOrder.tabs = order
        log += "saved: \(TabOrder.tabs.map(\.key))\n"
        await shoot("1-open")
        for choice in TabOrder.tabs {
            log += "  can move \(choice.key): up \(SidebarEditing.canMove(choice, by: -1)) down \(SidebarEditing.canMove(choice, by: 1))\n"
        }
        if let first = pages.first {
            SidebarEditing.move(first, before: .main(.sessions))   // a page dropped among the main places stays under the line
            try? await Task.sleep(for: .seconds(0.6))
            state("dropped \(first.key) above Sessions")
        }
        MacSidebar.railNamed = false
        bar.toggleCollapsed()
        await shoot("2-folded")
        MacSidebar.railNamed = true
        bar.rebuild()
        await shoot("3-folded-named")

        MacSidebar.railNamed = wasNamed
        if MacSidebar.isCollapsed != wasFolded { bar.toggleCollapsed() }
        UserDefaults.standard.set(wasFolded, forKey: MacSidebar.collapsedKey)
        if let stored { UserDefaults.standard.set(stored, forKey: TabOrder.key) } else { UserDefaults.standard.removeObject(forKey: TabOrder.key) }
        log += "restored: \(UserDefaults.standard.object(forKey: TabOrder.key).map { "\($0)" } ?? "nothing (default)")\n"
        try? log.write(to: folder.appending(path: "\(name)-divider.txt"), atomically: true, encoding: .utf8)
        post(folder.appending(path: "\(name)-divider.txt"))
        try? await Task.sleep(for: .seconds(1.5))
    }
}
#endif
