// [mac-switch] DEBUG: `-HQDebugMacShotsSessions YES` photographs Sessions' pill row on the Mac (the Bots | Projects
// switch, New and Working, the pills): the Bots side, a bot picked, the Projects side, a project's page, back to Bots,
// a project's row on the Bots side opening its page, and the same in a narrow window (the list at its narrowest).

#if DEBUG && targetEnvironment(macCatalyst)
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
            if let key = list.debugProjectKeys.first {
                list.pickProject(key)
                await wait(1.5)
                snap("\(pass)c-project-page")
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
}
#endif
