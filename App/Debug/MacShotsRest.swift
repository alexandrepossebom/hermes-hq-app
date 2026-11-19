// [Mac AAA 2026-11-17] DEBUG: `-HQDebugMacShotsRest <stops>` photographs the leftovers of the Mac polish ("the rest"), in
// one run. Stops, comma separated:
//   pane     the right pane with nothing open (More) and the folded Bots list's offline state, at the window's size and
//            at 1000 × 680 (run with `-HQDebugUIScale 150` for the laptop case)
//   states   UIKit empty states with a long line: Sessions and Artifacts searching for nothing
//   tiles    Tiles (run with `-HQDebugTileHostile YES`), then Edit Tiles with Done in the bar, then Done
//   more     Sessions' "Show N More" row (run with `-HQDebugSessionsGroupBy bot`), its 2× crop
//   sidebar  the sidebar's own menu as text (Add to Sidebar), now and with every page placed
//   under    a chat with a long own message under the title's stack: Find; Find with the status words; Find, status
//            and a notice; Search Earlier; each with a 2× crop of the strip under the bar
//   over     over the message box: the "/" list, Commands, the model selector, a question dock, a tray of five
//            pictures; each with a 2× crop of the strip above the box
//   model    the model selector from Chat › Choose Model… at 1280 × 800, then at 1000 × 700 and 820 × 700 with the
//            inspector open (the name steps aside), each with its frame in `<name>-rest.txt`
//   viewer   the photo viewer over a picture of the window and over a white page, with crops of its top and foot
// Pictures `<name>-r<nn>-<label>.png`, crops `…-crop.png`, notes `<name>-rest.txt`.

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

extension MacShots {
    @MainActor static func restTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL, stops: String) async {
        let wanted = Set(stops.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        var step = 0
        var log = ""
        func slug(_ label: String) -> String { label.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined() }
        func top() -> UIViewController? {
            var c = window.rootViewController
            while let next = c?.presentedViewController { c = next }
            return c
        }
        func snap(_ label: String, crop: CGRect? = nil, wait: Double = 1.2) async {
            try? await Task.sleep(for: .seconds(wait))
            step += 1
            let base = "\(name)-r\(String(format: "%02d", step))-\(slug(label))"
            shoot(window, to: folder.appending(path: "\(base).png"))
            if let crop, !crop.isEmpty {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2 * window.screen.scale
                let rect = crop.intersection(window.bounds)
                let image = UIGraphicsImageRenderer(bounds: rect, format: format).image { _ in
                    _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let url = folder.appending(path: "\(base)-crop.png")
                try? image.pngData()?.write(to: url)
                post(url)
            }
            log += "r\(step) \(label): presented \(top().map { String(describing: type(of: $0)) } ?? "-")\n"
        }
        func resize(_ w: CGFloat, _ h: CGFloat) async {
            window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 60, y: 60, width: w, height: h))) { _ in }
            try? await Task.sleep(for: .seconds(1.5))
        }
        func place(_ title: String) -> UIViewController? { tabs.placedTabs.first { $0.tabBarItem.title == title } }
        func go(_ controller: UIViewController?) async {
            guard let controller else { return }
            tabs.pick(controller, animated: false)
            tabs.split?.followSelectedTab()
            (controller as? UINavigationController)?.popToRootViewController(animated: false)
            try? await Task.sleep(for: .seconds(1.8))
        }
        func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
        }
        func describe(_ view: UIView?) -> String {
            guard let view, view.window != nil else { return "none" }
            let f = view.convert(view.bounds, to: window)
            return String(format: "%@ (%.1f, %.1f, %.1f × %.1f)%@", String(describing: type(of: view)), f.minX, f.minY, f.width, f.height,
                          view.isHidden ? " hidden" : "")
        }

        if wanted.contains("pane") {
            await go(tabs.controller(for: .more) ?? place("More"))
            await snap("nothing open")
            BotsViewController.debugOffline = true
            await go(tabs.controller(for: .bots))
            NotificationCenter.default.post(name: DetailPlaceholderViewController.listStateChanged, object: tabs.botsViewController)
            await snap("offline")
            await resize(1000, 680)
            await snap("offline laptop")
            BotsViewController.debugOffline = false
            NotificationCenter.default.post(name: DetailPlaceholderViewController.listStateChanged, object: tabs.botsViewController)
            await go(tabs.controller(for: .more) ?? place("More"))
            await snap("nothing open laptop")
            await resize(1280, 800)
        }

        if wanted.contains("states") {
            for (title, words) in [("Sessions", "zzqq nothing like this"), ("Artifacts", "zzqq nothing like this")] {
                guard let page = place(title) else { log += "no place \(title)\n"; continue }
                await go(page)
                let root = (page as? UINavigationController)?.viewControllers.first ?? page
                if let search = root.navigationItem.searchController {
                    search.isActive = true
                    search.searchBar.text = words
                    search.searchResultsUpdater?.updateSearchResults(for: search)
                } else if let field = views(UISearchTextField.self, in: page.view).first(where: { $0.window != nil }) {
                    field.becomeFirstResponder()
                    field.insertText(words)
                    field.sendActions(for: .editingChanged)
                }
                await snap("\(title) search miss", wait: 2)
                await resize(1000, 680)
                await snap("\(title) search miss laptop")
                await resize(1280, 800)
                root.navigationItem.searchController?.isActive = false
                window.endEditing(true)
            }
        }

        if wanted.contains("tiles"), let page = place("Tiles") {
            // Four tiles to draw on (pinned from Artifacts, as the grids tour does; the stand-in has none pinned).
            if let artifacts = place("Artifacts") {
                await go(artifacts)
                let list = (artifacts as? UINavigationController)?.viewControllers.first as? ArtifactsViewController ?? find(ArtifactsViewController.self, in: artifacts)
                list?.debugPin(["index.html", "report.pdf", "plan.md", "export.csv", "Open Planning"])
                try? await Task.sleep(for: .seconds(2))
            }
            await go(page)
            await snap("tiles", wait: 3)
            let tiles = (page as? UINavigationController)?.viewControllers.first as? ArtifactsViewController ?? find(ArtifactsViewController.self, in: page)
            tiles?.debugEditTiles(true)
            await snap("edit tiles", wait: 1.5)
            await snap("edit tiles bar", crop: CGRect(x: page.view.convert(page.view.bounds, to: window).minX, y: 0,
                                                      width: page.view.bounds.width, height: 110), wait: 0.2)
            tiles?.debugEditTiles(false)
            await snap("edit tiles done", wait: 1.2)
        }

        if wanted.contains("more"), let page = place("Sessions") {
            await go(page)
            try? await Task.sleep(for: .seconds(1.5))
            let list = views(UICollectionView.self, in: page.view).filter { $0.window != nil }.max { $0.bounds.height < $1.bounds.height }
            var found: UIView?
            for _ in 0..<12 {
                found = views(UICollectionViewCell.self, in: page.view).first { $0.accessibilityIdentifier == "sessions.showMore" && $0.window != nil }
                if found != nil { break }
                if let list { list.setContentOffset(CGPoint(x: 0, y: min(list.contentOffset.y + 300, max(0, list.contentSize.height - list.bounds.height))), animated: false) }
                try? await Task.sleep(for: .seconds(0.6))
            }
            if let found, let list {
                let frame = found.convert(found.bounds, to: list)
                list.scrollRectToVisible(frame.insetBy(dx: 0, dy: -160), animated: false)
                try? await Task.sleep(for: .seconds(0.8))
            }
            log += "show more: \(describe(found))\n"
            let crop = found.map { $0.convert($0.bounds, to: window).insetBy(dx: -24, dy: -120) }
            await snap("show more", crop: crop)
        }

        if wanted.contains("sidebar") {
            func dump(_ menu: UIMenu, depth: Int = 0) -> String {
                menu.children.map { element -> String in
                    let pad = String(repeating: "  ", count: depth)
                    if let sub = element as? UIMenu { return "\(pad)[\(sub.title)]\n" + dump(sub, depth: depth + 1) }
                    if let action = element as? UIAction { return "\(pad)\(action.title)\(action.attributes.contains(.disabled) ? " (dimmed)" : "")\n" }
                    return "\(pad)?\n"
                }.joined()
            }
            log += "sidebar menu now:\n" + dump(SidebarEditing.spaceMenu())
            let added = SidebarEditing.addable()
            for place in added { SidebarEditing.add(place.choice) }
            try? await Task.sleep(for: .seconds(1))
            log += "sidebar menu with every page placed (\(added.count) added):\n" + dump(SidebarEditing.spaceMenu())
            await snap("sidebar every page placed")
            // The sidebar's order is kept in the app's own settings, which every tour on this Mac shares: put it back.
            for place in added { SidebarEditing.remove(place.choice) }
            try? await Task.sleep(for: .seconds(0.5))
        }

        func openChat() async -> ChatViewController? {
            await go(tabs.controller(for: .bots))
            let wanted = UserDefaults.standard.string(forKey: "HQDebugFloatBot") ?? "default"
            guard let bot = tabs.services.bots.first(where: { $0.id == wanted }) ?? tabs.services.bots.first else { return nil }
            tabs.botsViewController.open(bot.id)
            try? await Task.sleep(for: .seconds(3.5))
            return find(ChatViewController.self, in: window.rootViewController)
        }
        func headStrip(_ chat: ChatViewController) -> CGRect {
            let f = chat.view.convert(chat.view.bounds, to: window)
            return CGRect(x: f.minX, y: 0, width: f.width, height: 260)
        }
        func footStrip(_ chat: ChatViewController, _ height: CGFloat = 320) -> CGRect {
            let f = chat.view.convert(chat.view.bounds, to: window)
            return CGRect(x: f.minX, y: f.maxY - height, width: f.width, height: height)
        }

        if wanted.contains("under"), let chat = await openChat() {
            // A long own message under the title's stack: older a part-screen at a time until one is there.
            chat.debugScroll(by: chat.tableView.bounds.height * 0.35)
            chat.showFind()
            await snap("find", crop: headStrip(chat), wait: 1.5)
            window.endEditing(true)
            chat.debugStatus("Waiting for the current reply…")
            await snap("find and status", crop: headStrip(chat))
            chat.showNotice("Model changed to Fixture Model", duration: 30, spinner: false)
            await snap("find status notice", crop: headStrip(chat))
            chat.debugStatus(nil)
            await snap("find and notice", crop: headStrip(chat))
            chat.hideNotice()
            UIApplication.shared.sendAction(KeyCommands.escape, to: UIApplication.shared.delegate, from: nil, for: nil)
            try? await Task.sleep(for: .seconds(0.8))
            chat.findController?.close()
            try? await Task.sleep(for: .seconds(0.8))
            chat.debugEarlier(.idle)
            await snap("search earlier", crop: headStrip(chat))
            chat.debugStatus("Reconnecting…")
            await snap("search earlier and status", crop: headStrip(chat))
            chat.debugStatus(nil)
            chat.debugEarlier(.hidden)
            await snap("under bar rest", crop: headStrip(chat))
        }

        if wanted.contains("over"), let chat = await openChat(), let menus = chat.menus {
            chat.debugScroll(by: chat.tableView.bounds.height * 0.3)
            chat.focusComposer()
            chat.composer.textView.insertText("/")
            await snap("slash list", crop: footStrip(chat, 420), wait: 2)
            chat.composer.text = ""
            window.endEditing(true)
            try? await Task.sleep(for: .seconds(0.6))
            menus.presentCommandsSheet()
            await snap("commands", crop: footStrip(chat, 640), wait: 2.5)
            (top() as? MacPickPanel)?.close()
            try? await Task.sleep(for: .seconds(1))
            menus.presentModelPanel()
            await snap("model selector", crop: footStrip(chat, 640), wait: 2.5)
            (top() as? MacPickPanel)?.close()
            try? await Task.sleep(for: .seconds(1))
            if let attachments = chat.attachments {
                let files = FileManager.default.temporaryDirectory.appending(path: "rest-tour", directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
                var urls: [URL] = []
                for (index, colour) in [UIColor.systemGreen, .black, .white, .systemRed, .systemBlue].enumerated() {
                    let url = files.appending(path: "Picture \(index + 1).png")
                    let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 180)).image { context in
                        colour.setFill(); context.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
                    }
                    try? image.pngData()?.write(to: url)
                    urls.append(url)
                }
                attachments.debugDrop([urls[0]].compactMap { NSItemProvider(contentsOf: $0) })
                await snap("tray one", crop: footStrip(chat), wait: 2.5)
                attachments.debugDrop(urls.dropFirst().compactMap { NSItemProvider(contentsOf: $0) })
                await snap("tray five", crop: footStrip(chat), wait: 3)
            }
            let prompt = ClarifyPrompt(id: "rest-dock", questions: [
                ClarifyQuestion(qid: "q0", question: "Which branch should I deploy to staging before the release review?",
                                choices: ["main (Recommended)", "release/2026-11", "feat/glass-phone"], multiSelect: false),
                ClarifyQuestion(qid: "q1", question: "Anything else for the release notes?", choices: nil, multiSelect: false),
            ])
            chat.showPromptDock(QuestionDockView(prompt: prompt, draft: ClarifyDraft()), animated: true)
            await snap("question dock", crop: footStrip(chat, 460), wait: 2)
            chat.showPromptDock(nil, animated: false)
            try? await Task.sleep(for: .seconds(0.6))
        }

        if wanted.contains("model"), let chat = await openChat(), let menus = chat.menus {
            for (w, h) in [(CGFloat(1280), CGFloat(800)), (1000, 700), (820, 700)] {
                await resize(w, h)
                let chip = chat.composer.modelChip
                log += String(format: "window %.0f × %.0f: chat %@; chip %@\n", w, h, describe(chat.view), describe(chip.isHidden ? nil : chip))
                menus.presentModelPanel()
                try? await Task.sleep(for: .seconds(2.5))
                if let panel = top() as? MacPickPanel {
                    log += "  panel \(NSCoder.string(for: panel.view.convert(panel.debugPanelFrame, to: window)))\n"
                }
                await snap("model selector \(Int(w))", crop: footStrip(chat, 660), wait: 0.2)
                (top() as? MacPickPanel)?.close()
                try? await Task.sleep(for: .seconds(1))
            }
            await resize(1280, 800)
        }

        // `switchrow`: Sessions' pill row under the bar (the Bots | Projects switch) with rows scrolled 0, 20, 60 and 240 pt
        // under it, on the Bots side, with a bot picked and on the Projects side, then the same at the list's narrowest.
        if wanted.contains("switchrow"), let page = place("Sessions") {
            await go(page)
            let list = (page as? UINavigationController)?.viewControllers.first as? SessionsViewController ?? find(SessionsViewController.self, in: page)
            func scrolled(_ label: String) async {
                guard let list, let table = views(UICollectionView.self, in: list.view).filter({ $0.window != nil })
                        .max(by: { $0.bounds.height < $1.bounds.height }) else { return }
                for amount: CGFloat in [0, 20, 60, 240] {
                    table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top + amount), animated: false)
                    let f = list.view.convert(list.view.bounds, to: window)
                    await snap("\(label) \(Int(amount))", crop: CGRect(x: f.minX, y: 0, width: f.width, height: 230), wait: 0.9)
                }
                table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
            }
            for (w, h) in [(CGFloat(1280), CGFloat(800)), (900, 640)] {
                if w < 1280 { await resize(w, h) }
                list?.pickPills(.bots)
                await scrolled("bots \(Int(w))")
                if let bot = tabs.services.bots.first?.id {
                    list?.pickBot(bot)
                    await scrolled("bot picked \(Int(w))")
                    list?.pickBot(nil)
                }
                list?.pickPills(.projects)
                await scrolled("projects \(Int(w))")
                list?.pickPills(.bots)
            }
            await resize(1280, 800)
        }

        // `taskmodel`: run with `-HQPagesTab 116 -HQPagesOpenTask "<title>"` (morepages): the task's chat beside it, where
        // the model's name has stepped aside; Chat › Choose Model… there.
        if wanted.contains("taskmodel") {
            try? await Task.sleep(for: .seconds(4))
            func chats(_ c: UIViewController?) -> [ChatViewController] {
                guard let c else { return [] }
                return ((c as? ChatViewController).map { [$0] } ?? []) + c.children.flatMap(chats) + chats(c.presentedViewController)
            }
            let shown = chats(window.rootViewController).filter { $0.view.window != nil }
            log += "chats on show: \(shown.map { describe($0.view) })\n"
            if let chat = shown.min(by: { $0.view.bounds.width < $1.view.bounds.width }), let menus = chat.menus {
                let chip = chat.composer.modelChip
                log += "task chat \(describe(chat.view)); chip \(describe(chip.isHidden ? nil : chip))\n"
                await snap("task chat", wait: 0.5)
                menus.presentModelPanel()
                try? await Task.sleep(for: .seconds(2.5))
                if let panel = top() as? MacPickPanel {
                    log += "  panel \(NSCoder.string(for: panel.view.convert(panel.debugPanelFrame, to: window)))\n"
                }
                await snap("task chat model selector", wait: 0.3)
                (top() as? MacPickPanel)?.close()
            }
        }

        // `viewer`: the photo viewer over a picture of the window itself (a screenshot of the app, the owner's report
        // 2026-11-18), then over a white page, each with 2× crops of the strips under the top bar and over the toolbar
        // and the frames of Done, the bars and the photo in the log.
        if wanted.contains("viewer") {
            await go(tabs.controller(for: .bots))
            let shot = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "viewer-photo-app.png")
            let format = UIGraphicsImageRendererFormat()
            format.scale = window.screen.scale
            let app = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try? app.pngData()?.write(to: shot)
            let white = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "viewer-photo-white.png")
            let page = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1000)).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
                let words: [NSAttributedString.Key: Any] = [.font: HQFont.face(size: 44, weight: .semibold, family: nil), .foregroundColor: UIColor.darkGray]
                ("A white page edge to edge" as NSString).draw(at: CGPoint(x: 40, y: 20), withAttributes: words)
                ("Its foot" as NSString).draw(at: CGPoint(x: 40, y: 920), withAttributes: words)
            }
            try? page.pngData()?.write(to: white)
            let context = MediaContext(accountId: MediaContext.demoAccount, profile: "default")
            let items = [(shot, app.size, "app"), (white, page.size, "white")].map { url, size, label in
                MediaItem(attachment: MessageAttachment(kind: .image, source: .gateway(path: url.path), name: url.lastPathComponent,
                                                        pixelWidth: Int(size.width * app.scale), pixelHeight: Int(size.height * app.scale)),
                          index: 0, context: context, label: "Photo, \(label)")
            }
            for index in items.indices {
                guard let presenter = top() else { continue }
                MediaViewerController.present(from: presenter, items: items, index: index) { _ in nil }
                try? await Task.sleep(for: .seconds(2.5))
                if let nav = top() as? UINavigationController, let toolbar = nav.toolbar {
                    let bar = nav.navigationBar
                    let close = views(UIButton.self, in: nav.view).first { $0.window != nil && ($0.configuration?.title == "Done" || $0.accessibilityLabel == "Close") }
                    let photo = views(UIImageView.self, in: nav.view).filter { $0.window != nil && $0.image != nil && $0.bounds.width > 200 }.max { $0.bounds.width < $1.bounds.width }
                    log += "viewer \(items[index].label): bar \(describe(bar)); toolbar \(describe(toolbar)); close \(describe(close)); photo \(describe(photo))\n"
                    let barFoot = bar.convert(bar.bounds, to: window).maxY
                    let toolTop = toolbar.convert(toolbar.bounds, to: window).minY
                    await snap("viewer \(index + 1)")
                    await snap("viewer \(index + 1) top", crop: CGRect(x: 0, y: 0, width: window.bounds.width, height: barFoot + 40), wait: 0.2)
                    await snap("viewer \(index + 1) foot", crop: CGRect(x: 0, y: toolTop - 40, width: window.bounds.width,
                                                                       height: window.bounds.height - toolTop + 40), wait: 0.2)
                }
                top()?.dismiss(animated: false)
                try? await Task.sleep(for: .seconds(1))
            }
        }

        let file = folder.appending(path: "\(name)-rest.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        post(file)
        try? await Task.sleep(for: .seconds(3))
    }
}
#endif
