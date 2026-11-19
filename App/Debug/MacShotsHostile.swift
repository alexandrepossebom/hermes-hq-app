// [Mac glass 2026-11-17] DEBUG: `-HQDebugMacShotsHostile <stops>` photographs every frosted, blurred and Liquid Glass
// surface the Mac shows with content passing under it, for the owner's "the bottom backdrop filter thing picks up ALL
// of the color from a text bubble". Run it with `-HQDebugHostile YES` (long own messages, HostileContent.swift), the
// message colour he uses (`-HQDebugMessageColour '#000000'` light, `'#FFFFFF'` dark) and `-HQDebugGlassCensus YES`
// (every surface listed, `<tour>-glass-census.jsonl`). Stops, comma separated (`all` for every one):
//   places   each place in the sidebar at rest, then its list scrolled so rows sit under its bar (and a crop of the bar)
//   chat     the first two bots' chats, newest, then a long own message moved up under the top bar a step at a time
//   over     over a chat whose long message sits under them: Open Quickly, Commands, Models, the "/" list, Find, the
//            status line and a notice under the title, another chat's reply peeking in at the top, the Undo pill (and the Undo pill over Sessions' rows)
// Each picture is the whole window (`<tour>-h<n>-<label>.png`) and, where a surface is named, a 2× crop of it
// (`-crop.png`).

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

extension MacShots {
    @MainActor static func hostileTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL, stops: String) async {
        let wanted = Set(stops.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        func wants(_ stop: String) -> Bool { wanted.contains("all") || wanted.contains(stop) || wanted.contains("YES") }
        var step = 0
        var log = ""
        func slug(_ label: String) -> String { label.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined() }
        func top() -> UIViewController? {
            var c = window.rootViewController
            while let next = c?.presentedViewController { c = next }
            return c
        }
        /// The whole window (and any other window up, a Mac sheet's), and a 2× crop of `crop` (window points) when given.
        func snap(_ label: String, crop: CGRect? = nil) {
            step += 1
            let base = "\(name)-h\(String(format: "%02d", step))-\(slug(label))"
            shoot(window, to: folder.appending(path: "\(base).png"))
            let others = (window.windowScene?.windows ?? []).filter {
                $0 !== window && !$0.isHidden && $0.bounds.width > 40 && !String(describing: type(of: $0)).contains("TextEffects")
                    && !String(describing: type(of: $0)).contains("Keyboard")
            }
            for (index, other) in others.enumerated() { shoot(other, to: folder.appending(path: "\(base)-w\(index).png")) }
            if let crop, !crop.isEmpty {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2 * window.screen.scale
                let rect = crop.insetBy(dx: -24, dy: -24).intersection(window.bounds)
                let image = UIGraphicsImageRenderer(bounds: rect, format: format).image { _ in
                    _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let url = folder.appending(path: "\(base)-crop.png")
                try? image.pngData()?.write(to: url)
                post(url)
            }
            log += "h\(step) \(label): presented \(top().map { String(describing: type(of: $0)) } ?? "-")\n"
            // [Mac AAA 2026-11-17] Every bar on show (calls-pill): the light or dark its window / controller asks for
            // ("own"), what the bar and everything on it is drawn in, and whether the bar's own style is set.
            for bar in barsOnShow() { log += "    bar: \(barLine(bar))\n" }
            // [Mac AAA 2026-11-17] The chat's top bar: its light / dark and what feeds it (calls-pill).
            if let chat = find(ChatViewController.self, in: window.rootViewController), chat.view.window != nil {
                log += "    top bar: \(chat.debugTopBarReport)\n"
            }
        }
        func barsOnShow() -> [UINavigationBar] {
            func bars(_ v: UIView) -> [UINavigationBar] { ((v as? UINavigationBar).map { [$0] } ?? []) + v.subviews.flatMap(bars) }
            return (window.windowScene?.windows ?? [window]).flatMap { bars($0) }
                .filter { $0.window != nil && !$0.isHidden && $0.alpha > 0.01 && $0.bounds.width > 40 }
        }
        func barLine(_ bar: UINavigationBar) -> String {
            func style(_ v: UIView?) -> String { v.map { $0.traitCollection.userInterfaceStyle == .dark ? "dark" : "light" } ?? "-" }
            func all(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(all) }
            let name = bar.topItem?.title ?? bar.topItem.map { String(describing: type(of: $0)) } ?? "?"
            let onBar = all(bar).filter { $0 is UIControl || $0 is UILabel || $0 is UISearchTextField }
            let darkCount = onBar.filter { $0.traitCollection.userInterfaceStyle == .dark }.count
            let pinned = bar.overrideUserInterfaceStyle == .unspecified ? "unset" : (bar.overrideUserInterfaceStyle == .dark ? "dark" : "light")
            return "\"\(name)\" own \(style(bar.superview)) drawn \(style(bar)) pin \(pinned); on it \(onBar.count) views, "
                + "\(darkCount) dark, \(onBar.count - darkCount) light; title view \(style(bar.topItem?.titleView))"
        }
        func biggestList(_ view: UIView) -> UIScrollView? {
            func lists(_ v: UIView) -> [UIScrollView] { ((v as? UIScrollView).map { [$0] } ?? []) + v.subviews.flatMap(lists) }
            // Any list, long or not: an offset set in code isn't held to the content, so a short list's rows still
            // reach under its bar.
            return lists(view).filter { $0.window != nil && !$0.isHidden && $0.isScrollEnabled && $0.bounds.height > 200 }
                .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        }
        /// The band at the top of `list` (its bar and what sits under it), in window points.
        func barBand(_ list: UIScrollView) -> CGRect {
            let frame = list.convert(list.bounds, to: window)
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: list.adjustedContentInset.top + 60)
        }

        if wants("places") {
            for place in tabs.placedTabs {
                let title = place.tabBarItem.title ?? "place"
                tabs.pick(place, animated: false)
                tabs.split?.followSelectedTab()
                (place as? UINavigationController)?.popToRootViewController(animated: false)
                try? await Task.sleep(for: .seconds(2.2))
                snap("\(title) rest")
                if let list = biggestList(place.view) {
                    let rest = list.contentOffset
                    for amount: CGFloat in [60, 240] {
                        list.setContentOffset(CGPoint(x: rest.x, y: -list.adjustedContentInset.top + amount), animated: false)
                        try? await Task.sleep(for: .seconds(0.9))
                        snap("\(title) scrolled \(Int(amount))", crop: barBand(list))
                    }
                    list.setContentOffset(rest, animated: false)
                }
            }
        }

        func openChat(_ index: Int) async -> ChatViewController? {
            if let bots = tabs.controller(for: .bots) { tabs.pick(bots, animated: false); tabs.split?.followSelectedTab() }
            try? await Task.sleep(for: .seconds(0.8))
            let bots = tabs.services.bots.filter { !$0.hidden }
            guard bots.indices.contains(index) else { return nil }
            tabs.botsViewController.open(bots[index].id)
            try? await Task.sleep(for: .seconds(3))
            return find(ChatViewController.self, in: window.rootViewController)
        }
        /// The chat moved so its newest own message reaches the top bar: older a part-screen at a time.
        func walkUp(_ chat: ChatViewController, _ label: String, steps: Int) async {
            let band = CGRect(x: chat.view.convert(chat.view.bounds, to: window).minX, y: 0,
                              width: chat.view.bounds.width, height: 140)
            // `-HQDebugHostileHold <s>` (calls-pill): how long each step rests before its picture (default 0.9 s), so a
            // message can sit under the bar for the system to read it.
            let hold = max(0.9, UserDefaults.standard.double(forKey: "HQDebugHostileHold"))
            for page in 0..<steps {
                chat.debugScroll(by: chat.tableView.bounds.height * 0.3)
                try? await Task.sleep(for: .seconds(hold))
                snap("\(label) up \(page)", crop: band)
            }
        }

        if wants("chat") {
            for index in 0..<2 {
                guard let chat = await openChat(index) else { continue }
                snap("chat \(index) newest")
                await walkUp(chat, "chat \(index)", steps: 4)
            }
        }

        if wants("over"), let chat = await openChat(0), let menus = chat.menus {
            chat.debugScroll(by: chat.tableView.bounds.height * 0.35)
            try? await Task.sleep(for: .seconds(0.8))
            func panelFrame() -> CGRect? { (top() as? MacPickPanel)?.debugPanelFrame }
            UIApplication.shared.sendAction(KeyCommands.openQuickly, to: UIApplication.shared.delegate, from: nil, for: nil)
            try? await Task.sleep(for: .seconds(1.5))
            snap("open quickly")
            top()?.dismiss(animated: false)
            try? await Task.sleep(for: .seconds(0.8))
            menus.presentCommandsSheet()
            try? await Task.sleep(for: .seconds(2.5))
            snap("commands", crop: panelFrame())
            (top() as? MacPickPanel)?.close()
            try? await Task.sleep(for: .seconds(1))
            menus.presentModelSheet(query: nil)
            try? await Task.sleep(for: .seconds(2.5))
            snap("models", crop: panelFrame())
            (top() as? MacPickPanel)?.close()
            try? await Task.sleep(for: .seconds(1))
            chat.focusComposer()
            chat.composer.textView.insertText("/")
            try? await Task.sleep(for: .seconds(2))
            snap("slash list")
            chat.composer.text = ""
            try? await Task.sleep(for: .seconds(0.6))
            chat.showFind()
            try? await Task.sleep(for: .seconds(1.2))
            snap("find", crop: CGRect(x: chat.view.convert(chat.view.bounds, to: window).minX, y: 0, width: chat.view.bounds.width, height: 160))
            UIApplication.shared.sendAction(KeyCommands.escape, to: UIApplication.shared.delegate, from: nil, for: nil)
            try? await Task.sleep(for: .seconds(0.8))
            // The small glass under the title: the status line and a notice, over the long message.
            let head = CGRect(x: chat.view.convert(chat.view.bounds, to: window).minX, y: 0, width: chat.view.bounds.width, height: 200)
            if let status = findView(ChatStatusPill.self, in: chat.view) {
                status.set("Working on the quarterly numbers")
                status.alpha = 1
            }
            chat.showNotice("Model changed to Fixture Model", duration: 30, spinner: false)
            try? await Task.sleep(for: .seconds(1.2))
            snap("status and notice", crop: head)
            findView(ChatStatusPill.self, in: chat.view)?.set(nil)
            // Another chat's reply dropping in at the window's top, over the long message.
            ReplyPeek.shared.show(PeekAlert(name: "Sam", body: "The venue confirmed Friday at noon; the deposit is due Monday.",
                                            session: "hostile-peek", profile: nil, face: nil), in: window) { _ in }
            try? await Task.sleep(for: .seconds(1.5))
            snap("reply peek", crop: CGRect(x: 0, y: 0, width: window.bounds.width, height: 160))
            ReplyPeek.shared.dismiss(up: true)
            try? await Task.sleep(for: .seconds(0.8))
            // The Undo pill over the chat, then over a list with rows under it.
            UndoPill.show(label: "Archived “Quarterly budget”", in: chat, onUndo: {})
            try? await Task.sleep(for: .seconds(1))
            if let pill = UndoPill.current { snap("undo over chat", crop: pill.convert(pill.bounds, to: window)) }
            if let sessions = tabs.controller(for: .sessions) {
                tabs.pick(sessions, animated: false)
                tabs.split?.followSelectedTab()
                try? await Task.sleep(for: .seconds(1.5))
                if let list = biggestList(sessions.view) {
                    list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top + 30), animated: false)
                }
                UndoPill.show(label: "Archived “Quarterly budget”", in: sessions.children.first ?? sessions, onUndo: {})
                try? await Task.sleep(for: .seconds(1))
                if let pill = UndoPill.current { snap("undo over sessions", crop: pill.convert(pill.bounds, to: window)) }
            }
        }

        let file = folder.appending(path: "\(name)-hostile.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        post(file)
        try? await Task.sleep(for: .seconds(3))   // the census's last post and the last upload land
    }
}
#endif
