// [Mac AAA 2026-11-16] DEBUG: `-HQDebugMacShotsLists YES`, the list places in one run (morepages or sessions2
// fixture): Sessions (a chat open, a search, grouped by bot and by project), Jobs (a job open, a search), Tasks (a task
// open, Upcoming, Inbox), Kanban, Artifacts (Unavailable open), then the window at 1000 × 700 for each list. One run
// per look instead of a dozen one-picture runs.

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

extension MacShots {
    @MainActor static func listsTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var step = 0
        func snap(_ label: String) async {
            try? await Task.sleep(for: .seconds(1.5))
            step += 1
            shoot(window, to: folder.appending(path: "\(name)-\(String(format: "%02d", step))-\(label).png"))
        }
        func open(_ title: String) async -> UIViewController? {
            var found: UIViewController?
            for _ in 0..<10 where found == nil {
                found = tabs.placedTabs.first { $0.tabBarItem.title == title }
                if found == nil { try? await Task.sleep(for: .seconds(1)) }
            }
            guard let place = found else { AppLog.note("mac", "lists tour: no \(title) place"); return nil }
            tabs.pick(place, animated: false)
            tabs.split?.followSelectedTab()
            (place as? UINavigationController)?.popToRootViewController(animated: false)
            try? await Task.sleep(for: .seconds(2.5))
            return place
        }
        func search(_ page: UIViewController?, _ text: String?) async {
            guard let page else { return }
            if let text {
                KeyCommands.openSearch(page)
                try? await Task.sleep(for: .seconds(0.8))
                guard let controller = page.navigationItem.searchController else { return }
                controller.searchBar.text = text
                controller.searchResultsUpdater?.updateSearchResults(for: controller)
            } else if let controller = page.navigationItem.searchController {
                controller.searchBar.text = ""
                controller.searchResultsUpdater?.updateSearchResults(for: controller)
                controller.isActive = false
            }
        }
        /// Clicks the first row whose accessibility identifier starts with `prefix`, as a click would.
        func click(_ list: UICollectionView?, _ prefix: String) {
            guard let list else { return }
            for cell in list.visibleCells where (cell.accessibilityIdentifier ?? "").hasPrefix(prefix) {
                if let path = list.indexPath(for: cell) { list.delegate?.collectionView?(list, didSelectItemAt: path); return }
            }
        }
        func list(_ controller: UIViewController?) -> UICollectionView? {
            controller?.viewIfLoaded.flatMap { findView(UICollectionView.self, in: $0) }
        }
        /// The pointer's hover on the visible row `prefix` names, the `index`th of them (top to bottom).
        func hover(_ list: UICollectionView?, _ prefix: String, _ index: Int) {
            guard let list else { return }
            let rows = list.visibleCells.filter { ($0.accessibilityIdentifier ?? "").hasPrefix(prefix) }.sorted { $0.frame.minY < $1.frame.minY }
            MacHover.debugHover(list, row: rows.indices.contains(index) ? rows[index] : nil)
        }
        let shrink = UserDefaults.standard.bool(forKey: "HQDebugListsNarrow")
        let frame = window.windowScene?.effectiveGeometry.systemFrame ?? CGRect(x: 80, y: 80, width: 1280, height: 800)
        if shrink {
            window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: frame.minX, y: frame.minY, width: 1000, height: 700))) { _ in }
        }
        try? await Task.sleep(for: .seconds(4))

        if await open("Sessions") != nil {
            let sessions = tabs.sessionsViewController
            hover(list(sessions), "session-row-", 2)
            await snap("sessions")
            hover(list(sessions), "", -1)
            if let first = sessions.paneOrder.first { sessions.open(first) }
            await snap("sessions-open")
            await search(sessions, "note")
            await snap("sessions-search")
            await search(sessions, "zzqx")
            await snap("sessions-search-none")
            await search(sessions, nil)
            if let store = sessions.store {
                store.setView { $0.groupBy = .bot }
                await snap("sessions-bybot")
                store.setView { $0.groupBy = .project }
                await snap("sessions-byproject")
                store.setView { $0.groupBy = .date }
            }
        }
        if let place = await open("Jobs"), let jobs = find(JobsViewController.self, in: place) {
            hover(list(jobs), "job-row-", 1)
            await snap("jobs")
            hover(list(jobs), "", -1)
            await search(jobs, "check")
            await snap("jobs-search")
            await search(jobs, nil)
            try? await Task.sleep(for: .seconds(1.5))   // the rows come back after the search closes
            click(list(jobs), "job-row-")
            await snap("jobs-open")
            // [Mac AAA 2026-11-16] (lists L14) open job → search → cancel, then Tasks: the job's page must not stay.
            await search(jobs, "check")
            try? await Task.sleep(for: .seconds(1))
            await search(jobs, nil)
            jobs.actions.newJob(from: jobs, blueprint: nil)
            try? await Task.sleep(for: .seconds(2.5))
            await snap("jobs-new")
            if let sheet = window.rootViewController?.presentedViewController {
                let format = UIGraphicsImageRendererFormat()
                format.scale = window.screen.scale
                let image = UIGraphicsImageRenderer(bounds: sheet.view.bounds, format: format).image { _ in
                    _ = sheet.view.drawHierarchy(in: sheet.view.bounds, afterScreenUpdates: true)
                }
                let url = folder.appending(path: "\(name)-\(String(format: "%02d", step))-jobs-new-sheet.png")
                try? image.pngData()?.write(to: url)
                post(url)
                sheet.dismiss(animated: false)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        if let place = await open("Tasks"), let tasks = find(TasksViewController.self, in: place) {
            hover(list(tasks), "", 4)
            await snap("tasks")
            hover(list(tasks), "", -1)
            if let task = tasks.store.tasks.first(where: { !$0.isDone }) { tasks.openTask(task.id) }
            await snap("tasks-open")
            tabs.split?.closeDetail(animated: false)
            tasks.show(.upcoming)
            await snap("tasks-upcoming")
            tasks.show(.inbox)
            await snap("tasks-inbox")
            tasks.show(.today)
        }
        if await open("Kanban") != nil { await snap("kanban") }
        if let place = await open("Artifacts"), let artifacts = find(ArtifactsViewController.self, in: place) {
            await snap("artifacts")
            click(list(artifacts), "artifacts.unavailable")
            await snap("artifacts-unavailable")
        }
        if shrink { window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in } }
        try? await Task.sleep(for: .seconds(1))
    }
}
#endif
