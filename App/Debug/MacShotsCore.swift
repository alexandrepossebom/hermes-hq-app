// [Mac AAA 2026-11-16] DEBUG: `-HQDebugMacShotsCore YES`, the chat pane in one run (the rich stand-in): the first
// bot's chat a screen at a time, the inspector's four tabs, Chat Info, the message box with many lines, the loading
// skeleton, a brand-new chat's intro, then the chat in a wide (1800) and a narrow (1000) window.
// `-HQDebugCoreSteps <list>` (comma-separated: pages, tabs, info, box, loading, intro, new, table, sizes) runs only those parts.

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

extension MacShots {
    @MainActor private static var coreTourStarted = false

    @MainActor static func coreTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        // Once: a second scene connecting (a sheet's window) would start a second tour beside the first.
        guard !coreTourStarted else { while true { try? await Task.sleep(for: .seconds(60)) } }
        coreTourStarted = true
        let only = UserDefaults.standard.string(forKey: "HQDebugCoreSteps").map { Set($0.split(separator: ",").map(String.init)) }
        func runs(_ part: String) -> Bool { only?.contains(part) ?? true }
        var step = 0
        func snap(_ label: String, _ target: UIWindow? = nil, wait: Double = 1.2) async {
            try? await Task.sleep(for: .seconds(wait))
            step += 1
            shoot(target ?? window, to: folder.appending(path: "\(name)-\(String(format: "%02d", step))-\(label).png"))
        }
        func sheetWindow() -> UIWindow? {
            var top = window.rootViewController
            while let next = top?.presentedViewController { top = next }
            guard let other = top?.viewIfLoaded?.window, other !== window else { return nil }
            return other
        }
        tabs.selectedIndex = 0
        try? await Task.sleep(for: .seconds(1))
        guard let bot = tabs.services.bots.first, let split = tabs.split else { return }
        tabs.botsViewController.open(bot.id)
        try? await Task.sleep(for: .seconds(3.5))
        guard let chat = find(ChatViewController.self, in: window.rootViewController) else { return }
        if runs("pages") {
            for page in 0..<7 {
                await snap("page-\(page)")
                let before = chat.tableView.contentOffset.y
                chat.debugScroll(by: chat.tableView.bounds.height * 0.8)
                try? await Task.sleep(for: .seconds(0.6))
                if abs(chat.tableView.contentOffset.y - before) < 2 { break }
            }
            chat.debugScrollToNewest()
        }
        if runs("tabs") {
            if !MacInspector.isShown { split.inspector.toggle() }
            for tab in MacInspector.Tab.allCases {
                split.inspector.show(tab)
                await snap("inspector-\(tab.title.lowercased())", wait: 1.8)
            }
        }
        if runs("info"), let menus = chat.menus {
            menus.info()
            try? await Task.sleep(for: .seconds(1.8))
            await snap("chat-info", sheetWindow(), wait: 0.2)
            chat.presentedViewController?.dismiss(animated: false)
            try? await Task.sleep(for: .seconds(1))
        }
        if runs("box") {
            chat.composer.textView.becomeFirstResponder()
            chat.composer.textView.insertText("A first line of a longer message\nwith a second line\nand a third\nand a fourth that runs on a little "
                + "further than the others so that it wraps across the message box at the default window")
            await snap("box-lines")
            chat.composer.textView.selectAll(nil)
            chat.composer.textView.deleteBackward()
            chat.composer.textView.insertText("Hello")
            await snap("box-typed")
            chat.composer.textView.selectAll(nil)
            chat.composer.textView.deleteBackward()
            chat.composer.textView.resignFirstResponder()
        }
        if runs("loading") {
            chat.debugShowPlaceholder(.loading)
            await snap("loading")
            chat.debugShowPlaceholder(nil)
        }
        if runs("intro") {
            chat.debugShowIntro()
            await snap("intro")
            chat.debugShowPlaceholder(nil)
        }
        if runs("new") {
            tabs.botsViewController.openNewChat(bot)
            await snap("new-chat", wait: 3)
            if let fresh = find(ChatViewController.self, in: window.rootViewController), fresh !== chat {
                fresh.navigationController?.popViewController(animated: false)
            }
            tabs.botsViewController.open(bot.id)
            try? await Task.sleep(for: .seconds(2.5))
        }
        if runs("table"), let chat = find(ChatViewController.self, in: window.rootViewController) {
            func blocks(in view: UIView) -> [BlockView] {
                (view as? BlockView).map { [$0] } ?? view.subviews.flatMap { blocks(in: $0) }
            }
            // A screen at a time toward older rows until a table card's Expand takes the click.
            var opened = false
            for _ in 0..<10 where !opened {
                let cards = chat.tableView.visibleCells.flatMap { blocks(in: $0) }
                opened = cards.contains { $0.expandTableIfHit(CGPoint(x: 1, y: 1)) }
                if !opened {
                    chat.debugScroll(by: chat.tableView.bounds.height * 0.6)
                    try? await Task.sleep(for: .seconds(0.6))
                }
            }
            if opened {
                await snap("table-page", wait: 1.8)
                chat.navigationController?.popToViewController(chat, animated: false)
                try? await Task.sleep(for: .seconds(1))
                chat.debugScrollToNewest()
            }
        }
        if runs("sizes") {
            let frame = window.windowScene?.effectiveGeometry.systemFrame ?? CGRect(x: 80, y: 80, width: 1280, height: 800)
            for (w, h, label) in [(1800.0, 1000.0, "wide"), (1000.0, 700.0, "narrow")] {
                window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 0, y: 0, width: w, height: h))) { _ in }
                await snap(label, wait: 2.5)
            }
            window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
            try? await Task.sleep(for: .seconds(1.5))
        }
        try? await Task.sleep(for: .seconds(2))
    }
}
#endif
