// [mac-switch] DEBUG: `-HQDebugMacShotsSessions YES` photographs Sessions' pill row on the Mac (the Bots | Projects
// switch, New and Working, the pills): the Bots side, a bot picked, the Projects side, a project's page, back to Bots,
// a project's row on the Bots side opening its page, and the same in a narrow window (the list at its narrowest).

#if DEBUG && targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

extension MacShots {
    @MainActor static func sessionsTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var log = ""
        func snap(_ label: String) {
            shoot(window, to: folder.appending(path: "\(name)-\(label).png"))
            log += "\(label): window \(window.bounds.size)\n"
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        guard let controller = tabs.controller(for: .sessions) else { return }
        tabs.pick(controller)
        tabs.split?.followSelectedTab()
        await wait(3)
        guard let list = (controller as? UINavigationController)?.viewControllers.first as? SessionsViewController else {
            log += "no Sessions list\n"
            return
        }
        for (pass, width) in [(1, CGFloat(1500)), (2, CGFloat(1100))] {
            let frame = window.windowScene?.effectiveGeometry.systemFrame ?? CGRect(x: 60, y: 40, width: 1280, height: 800)
            window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: frame.minX, y: frame.minY, width: width, height: 820))) { _ in }
            await wait(2)
            list.pickPills(.bots)
            await wait(1.5)
            snap("\(pass)a-bots")
            if pass == 1 { drawScopeMenu(list, window: window, to: folder.appending(path: "\(name)-menu-bots.png")) }
            if let bot = tabs.services.bots.dropFirst(2).first?.id {
                list.pickBot(bot)
                await wait(1.5)
                snap("\(pass)a2-bot-picked")
                list.pickBot(nil)
                await wait(1)
            }
            list.pickPills(.projects)
            await wait(1.5)
            snap("\(pass)b-projects")
            if pass == 1 { drawScopeMenu(list, window: window, to: folder.appending(path: "\(name)-menu-projects.png")) }
            if let key = list.debugProjectKeys.first {
                list.pickProject(key)
                await wait(1.5)
                snap("\(pass)c-project-page")
                // [mac-coding-project] The same page as a Coding Project (the ⋯'s switch, set here as the menu sets
                // it): the header's pull request counts and each row's mark; then the ⓘ's guide. Switched back off.
                if let store = list.store {
                    let was = store.isCodingProject(key)
                    store.setCodingProject(key, true)
                    list.reload(animated: false)
                    await wait(6)
                    snap("\(pass)c2-project-page-coding")
                    log += "coding \(pass): \(list.debugProjectPRWords(key))\n"
                    if pass == 1 {
                        let guide = ChatSheet.wrap(UIHostingController(rootView: ProjectIconGuide(coding: true)), title: "Project Icons", detents: [.large()])
                        list.present(guide, animated: false)
                        await wait(2)
                        // A Mac sheet is a window of its own.
                        if let sheet = guide.viewIfLoaded?.window {
                            shoot(sheet, to: folder.appending(path: "\(name)-1c3-icon-guide.png"))
                            log += "1c3-icon-guide: window \(sheet.bounds.size), own window \(sheet !== window)\n"
                        }
                        guide.dismiss(animated: false)
                        await wait(1)
                    }
                    store.setCodingProject(key, was)
                    list.reload(animated: false)
                    await wait(1)
                }
            }
            list.pickPills(.bots)
            await wait(1.5)
            snap("\(pass)d-back-to-bots")
            if let key = list.debugProjectKeys.first {
                list.toggleGroup(SessionListPipeline.projectPrefix + key)
                await wait(1.5)
                snap("\(pass)e-row-opens-page")
                list.pickPills(.bots)
                await wait(1.5)
            }
        }
        // [mac-pane-narrow] The pane dragged narrow (a tester 2026-11-19: the header ran off both edges): the header's
        // shorter forms, at a middling width and at the pane's narrowest, on both sides of the switch.
        let keys = [RootSplitController.listWidthKey, RootSplitController.narrowListWidthKey]
        let kept = keys.map { UserDefaults.standard.object(forKey: $0) }
        for (label, width) in [("3a-pane-380", 380.0), ("3b-pane-narrowest", 320.0)] {
            for key in keys { UserDefaults.standard.set(width, forKey: key) }
            tabs.split?.view.setNeedsLayout()
            list.pickPills(.bots)
            await wait(1.5)
            snap("\(label)-bots")
            list.pickPills(.projects)
            await wait(1.5)
            snap("\(label)-projects")
        }
        for (key, value) in zip(keys, kept) { UserDefaults.standard.set(value, forKey: key) }
        list.pickPills(.bots)
        let url = folder.appending(path: "\(name)-sessions.txt")
        try? log.write(to: url, atomically: true, encoding: .utf8)
        post(url)
        await wait(1)
    }

    /// [mac-scope-menu] The bot / project menu's real rows (the tour can't open a system menu), drawn as a menu draws
    /// them: check, picture, title, grey subtitle, rules between sections, a submenu's ▸.
    @MainActor static func drawScopeMenu(_ list: SessionsViewController, window: UIWindow, to url: URL) {
        let dark = window.traitCollection.userInterfaceStyle == .dark
        var rows: [(check: Bool, image: UIImage?, title: String, subtitle: String?, sub: Bool, rule: Bool)] = []
        func walk(_ elements: [UIMenuElement]) {
            for element in elements {
                if let menu = element as? UIMenu, menu.options.contains(.displayInline) {
                    if !rows.isEmpty, rows.last?.rule == false { rows.append((false, nil, "", nil, false, true)) }
                    walk(menu.children)
                    rows.append((false, nil, "", nil, false, true))
                } else if let menu = element as? UIMenu {
                    rows.append((false, menu.image, menu.title, nil, true, false))
                } else if let action = element as? UIAction {
                    rows.append((action.state == .on, action.image, action.title, action.subtitle, false, false))
                }
            }
        }
        walk(list.debugScopeMenu(dark: dark))
        while rows.last?.rule == true { rows.removeLast() }
        let width: CGFloat = 250
        let height = rows.reduce(CGFloat(10)) { $0 + ($1.rule ? 11 : $1.subtitle == nil ? 24 : 36) }
        let ink: UIColor = dark ? .white : .black, grey: UIColor = dark ? UIColor(white: 0.62, alpha: 1) : UIColor(white: 0.45, alpha: 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            let card = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerRadius: 9)
            (dark ? UIColor(white: 0.17, alpha: 1) : UIColor(white: 0.97, alpha: 1)).setFill()
            card.fill()
            var y: CGFloat = 5
            for row in rows {
                if row.rule {
                    (dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.1)).setFill()
                    UIRectFill(CGRect(x: 10, y: y + 5, width: width - 20, height: 1))
                    y += 11
                    continue
                }
                let h: CGFloat = row.subtitle == nil ? 24 : 36
                if row.check {
                    ("✓" as NSString).draw(at: CGPoint(x: 9, y: y + (row.subtitle == nil ? 4 : 10)),
                                           withAttributes: [.font: HQFont.face(ofSize: 13, weight: .semibold), .foregroundColor: ink])
                }
                if let picture = row.image {
                    let drawn = picture.renderingMode == .alwaysOriginal ? picture : picture.withTintColor(ink, renderingMode: .alwaysOriginal)
                    let side: CGFloat = 17
                    let fit = min(side / max(drawn.size.width, 1), side / max(drawn.size.height, 1))
                    let size = CGSize(width: drawn.size.width * fit, height: drawn.size.height * fit)
                    drawn.draw(in: CGRect(x: 26 + (side - size.width) / 2, y: y + (h - size.height) / 2, width: size.width, height: size.height))
                }
                (row.title as NSString).draw(at: CGPoint(x: 52, y: y + (row.subtitle == nil ? 4 : 3)),
                                             withAttributes: [.font: HQFont.face(ofSize: 13), .foregroundColor: ink])
                if let subtitle = row.subtitle {
                    (subtitle as NSString).draw(at: CGPoint(x: 52, y: y + 19),
                                                withAttributes: [.font: HQFont.face(ofSize: 11), .foregroundColor: grey])
                }
                if row.sub {
                    ("›" as NSString).draw(at: CGPoint(x: width - 20, y: y + 2),
                                           withAttributes: [.font: HQFont.face(ofSize: 15, weight: .semibold), .foregroundColor: grey])
                }
                y += h
            }
        }
        try? image.pngData()?.write(to: url)
    }
}
#endif
