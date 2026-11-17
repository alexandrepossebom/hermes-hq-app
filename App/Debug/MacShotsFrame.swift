// [Mac AAA 2026-11-16] DEBUG: `-HQDebugMacShotsFrame YES`, the window's frame at many sizes (round 2, "frame"): the
// sidebar's foot and top fades from the smallest window to a tall one at 1280 and 1000 wide, ⌘9 (the last Tool) at
// each, the folded rail at the smallest and a tall height, and a wide 1800 window. `<name>-frame.txt` lists each
// list's offset and fades so a cut row can be read without a picture.

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

extension MacShots {
    @MainActor static func frameTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        guard let split = tabs.split else { return }
        let bar = split.macSidebar
        var log = ""
        func size(_ width: CGFloat, _ height: CGFloat) async {
            window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 60, y: 40, width: width, height: height))) { _ in }
            try? await Task.sleep(for: .seconds(1.3))
        }
        func snap(_ label: String) {
            log += "\(label): window \(window.bounds.size)\n" + bar.debugLists + "\n"
            shoot(window, to: folder.appending(path: "\(name)-\(label).png"))
        }
        let delegate = UIApplication.shared.delegate as? AppDelegate
        func select(_ number: Int) async {
            let command = UIKeyCommand(title: "?", action: KeyCommands.selectTab, input: String(number + 1), modifierFlags: .command, propertyList: number)
            delegate?.hqSelectTab(command)
            try? await Task.sleep(for: .seconds(1))
        }
        if let first = tabs.services.bots.first?.id { tabs.botsViewController.open(first) }
        try? await Task.sleep(for: .seconds(1.5))
        for width in [1280, 1000] as [CGFloat] {
            for height in [480, 560, 640, 720, 800, 900] as [CGFloat] {
                await size(width, height)
                snap("w\(Int(width))-h\(Int(height))")
                await select(8)
                snap("w\(Int(width))-h\(Int(height))-cmd9")
                await select(0)
            }
        }
        await size(1280, 800)
        bar.debugHover(place: 1)
        try? await Task.sleep(for: .seconds(0.5))
        snap("hover")
        await size(1800, 1000)
        snap("wide-1800")
        bar.toggleCollapsed()
        try? await Task.sleep(for: .seconds(1))
        snap("wide-1800-folded")
        await size(1000, 480)
        snap("folded-small")
        await size(1000, 900)
        snap("folded-tall")
        bar.toggleCollapsed()
        await size(1280, 800)
        let url = folder.appending(path: "\(name)-frame.txt")
        try? log.write(to: url, atomically: true, encoding: .utf8)
        post(url)
        try? await Task.sleep(for: .seconds(2))
    }
}
#endif
