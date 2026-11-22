// [tile-widgets] Where a Home Screen widget's tap takes the app (`WidgetLink`, HomeWidgetsKit/WidgetLinks.swift),
// handled by SceneDelegate.open before the app's other links:
//   widget/tile      that tile opened as a tap on it in Tiles opens it (the Tiles page first); a tile since unpinned,
//                    or one of another account's, opens the Tiles page
//   widget/tiles     the Tiles page
//   widget/tasks     the Tasks page; widget/task that task's sheet; widget/new-task the New Task sheet
//   widget/open      the app, as it was
// Signed out there are no tabs: the app opens on its sign-in, and the link is dropped.

import UIKit

@MainActor enum WidgetRouter {
    /// A `widget` link. False: not one of ours.
    static func handle(_ url: URL) -> Bool {
        guard let link = WidgetLink.parse(url, scheme: AppIdentity.current.urlScheme) else {
            // Ours by its host, but not a link this build reads: the app opens, nothing more (never "isn't available").
            return url.scheme?.lowercased() == AppIdentity.current.urlScheme.lowercased() && url.host?.lowercased() == "widget"
        }
        AppLog.note("widgets", "opened from a widget: \(logWord(link))")
        Task { await open(link) }
        return true
    }

    private static func logWord(_ link: WidgetLink) -> String {
        switch link {
        case .tile: "tile"
        case .tiles: "tiles"
        case .tasks: "tasks"
        case .task: "task"
        case .newTask: "new task"
        case .open: "open"
        }
    }

    static func open(_ link: WidgetLink) async {
        guard link != .open else { return }
        guard let root = await tabs() else { AppLog.note("widgets", "no tabs to open the widget's link in"); return }
        guard await root.clearForRoute() else { AppLog.note("widgets", "a sheet kept the widget's link from opening"); return }
        switch link {
        case .tile(let key, let account):
            guard let page = showTiles(root) else { AppLog.note("widgets", "no Tiles page to open the widget's tile on"); return }
            guard account == TileWidgetWriter.shared.accountKey else {
                AppLog.note("widgets", "the widget's tile is another account's: Tiles shown")
                return
            }
            page.loadViewIfNeeded()
            // As a cold launch's lists settle, then the tile opens over Tiles (a tile since unpinned: Tiles alone).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if !page.openTile(widgetKey: key) { AppLog.note("widgets", "the widget's tile isn't pinned now: Tiles shown") }
            }
        case .tiles:
            _ = showTiles(root)
        case .tasks:
            TasksHub.showPage()
        case .task(let id, let account):
            guard account == TileWidgetWriter.shared.accountKey else { TasksHub.showPage(); return }
            TasksHub.open(taskID: id)
        case .newTask:
            guard let page = TasksHub.showPage() else { return }
            page.loadViewIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { page.newTask() }
        case .open:
            break
        }
    }

    /// The Tiles page on show: its tab when it has one, else More's row (as `TasksHub.showPage`).
    @discardableResult
    static func showTiles(_ root: MainTabController) -> ArtifactsViewController? {
        if let tab = root.placedTab(tagged: TabChoice.page("pinned").tag) {
            root.show(tab)
            guard let stack = tab as? UINavigationController else { return nil }
            stack.popToRootViewController(animated: false)
            return stack.viewControllers.first as? ArtifactsViewController
        }
        guard let more = root.pages?.more, let stack = more.navigationController, let index = root.slotIndex(for: stack) else {
            AppLog.note("widgets", "Tiles: no More (\(root.pages?.more == nil ? "no page" : root.pages?.more?.navigationController == nil ? "no stack" : "no slot"))")
            return nil
        }
        root.selectedIndex = index
        if let page = stack.topViewController as? ArtifactsViewController, page.pinnedOnly { return page }
        stack.popToRootViewController(animated: false)
        more.loadViewIfNeeded()
        more.open(rowId: "pinned")
        if let page = stack.topViewController as? ArtifactsViewController, page.pinnedOnly { return page }
        // More's list wasn't read yet in this state (the app back from the background with another More page on top):
        // the Tiles page as its row makes it.
        guard let page = root.pages?.makePinned() as? ArtifactsViewController else {
            AppLog.note("widgets", "Tiles: no Tiles page in More")
            return nil
        }
        stack.pushViewController(page, animated: false)
        return page
    }

    /// The tabs once they are on screen (a widget's tap may have launched the app): up to 10 s.
    private static func tabs() async -> MainTabController? {
        for _ in 0..<50 {
            if let root = MainTabController.current, root.pages?.more != nil { return root }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return MainTabController.current
    }
}
