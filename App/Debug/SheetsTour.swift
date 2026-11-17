// [Mac AAA 2026-11-16] DEBUG: `-HQDebugSheetsTour <stops>` (with `-HQDebugMacShots <name>`): the app's "something
// happened" sheets and alerts, one after another in one launch, each photographed as the window
// (`<name>-t<nn>-<stop>.png`) and the sheet or alert on its own (`…-sheet.png`), then the app quits. Stops, comma
// separated:
//   mac:<state>          the Mac app's own update sheet (`MacAppUpdate.demo`: checking, found, downloading, ready, …)
//   hermes:<state>       Update Hermes (`HermesUpdateCenter.demo`: asking, installing, failed, updated, cant, …)
//   addon:<state>        the add-on update sheet (`AddOnUpdate.demo`: asking, installing, both-asking, failed, …)
//   prompt, prompt-empty a one-field prompt (Rename Chat, ready; New Section, empty so its action is off)
//   confirm, failure     a destructive confirmation; a "Couldn't …" alert with Try Again
//   addgateway           Add Gateway… at rest
//   addgateway:<address>|<user>|<password>   …with the form filled and Sign In pressed (wrong password, unreachable)
//   cloud:<demo>         Hermes Cloud… (`-HQDebugCloudShot` states)
//   gateways             Settings › Gateways (Manage Gateways)
//   hold:<seconds>       nothing opened: the window after that wait (a script outside changes the stand-in meanwhile)
// `-HQDebugSheetsTourWait <s>`: how long each stop settles before its picture (default 2.5).

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

@MainActor enum SheetsTour {
    static func runIfAsked(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async -> Bool {
        guard let asked = UserDefaults.standard.string(forKey: "HQDebugSheetsTour"), !asked.isEmpty else { return false }
        let settle = UserDefaults.standard.object(forKey: "HQDebugSheetsTourWait") != nil
            ? UserDefaults.standard.double(forKey: "HQDebugSheetsTourWait") : 2.5
        var log = ""
        // Stops are split on commas outside a `|`-joined argument (an address has none).
        let stops = asked.split(separator: ",").map(String.init)
        for (index, stop) in stops.enumerated() {
            await clear(window)
            let slug = stop.lowercased().prefix(40).map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            let base = "\(name)-t\(String(format: "%02d", index + 1))-\(slug)"
            let wait = await open(stop, window: window, tabs: tabs)
            try? await Task.sleep(for: .seconds(wait ?? settle))
            MacShots.shoot(window, to: folder.appending(path: "\(base).png"))
            let top = topmost(window.rootViewController)
            if let top, let sheet = top.viewIfLoaded?.window, sheet !== window {
                MacShots.shoot(sheet, to: folder.appending(path: "\(base)-sheet.png"))
            } else if let alert = top as? UIAlertController, alert.view.bounds.width > 0 {
                shootView(alert.view, to: folder.appending(path: "\(base)-sheet.png"))
            } else if let sheet = MacAppUpdate.shared.debugSheetWindow, sheet !== window {
                MacShots.shoot(sheet, to: folder.appending(path: "\(base)-sheet.png"))
            }
            if kind(stop) == "gateways", let settings = MacSettingsWindow.scene?.windows.first {
                MacShots.shoot(settings, to: folder.appending(path: "\(base)-settings.png"))
            }
            log += "\(stop): top \(top.map { String(describing: type(of: $0)) } ?? "-")"
            if let size = top?.preferredContentSize, size != .zero { log += " preferred \(Int(size.width))×\(Int(size.height))" }
            if let frame = top?.viewIfLoaded?.window?.bounds { log += " window \(Int(frame.width))×\(Int(frame.height))" }
            if let error = SignInModel.debugLast?.debugError { log += " error \"\(error)\"" }
            log += "\n"
        }
        await clear(window)
        let file = folder.appending(path: "\(name)-sheets.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        MacShots.post(file)
        try? await Task.sleep(for: .seconds(2))
        return true
    }

    /// Opens one stop; returns its own wait when it needs longer than the usual.
    private static func open(_ stop: String, window: UIWindow, tabs: MainTabController) async -> Double? {
        let parts = stop.split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts[0], argument = parts.count > 1 ? parts[1] : ""
        let app = tabs.services as? AppModel
        switch kind {
        case "mac":
            MacAppUpdate.shared.demo(argument)
        case "hermes":
            guard let account = app?.account else { return nil }
            HermesUpdateCenter.shared.demo(argument, name: HermesUpdateCenter.name(account), place: HermesUpdate.place(account))?.show(from: nil)
            return 3.5
        case "addon":
            let bot = app?.bots.first { $0.id == "default" }?.name ?? "Hermes"
            if AddOnUpdate.shared.demo(argument, bot: bot, model: app) { AddOnUpdate.shared.show(from: nil) }
            return 3.5
        case "prompt":
            TextPrompt.present(title: "Rename Chat", text: "Old name", action: "Rename", selectText: true, from: tabs) { _ in }
        case "prompt-empty":
            TextPrompt.present(title: "New Section", placeholder: "Name", action: "Add", from: tabs) { _ in }
        case "confirm":
            TextPrompt.confirm(title: "Delete Chat?", message: "This can’t be undone.", action: "Delete", from: tabs) {}
        case "failure":
            FailureAlert.present(title: "Couldn’t Rename the Chat", reason: "The gateway didn’t answer in time.", from: tabs) {}
        case "addgateway":
            AddGatewayFlow.present(from: tabs, services: tabs.services)
            guard !argument.isEmpty else { return 3 }
            try? await Task.sleep(for: .seconds(1.5))
            let fields = argument.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let model = SignInModel.debugLast else { return nil }
            model.fill(address: fields[0])
            for _ in 0..<40 where !model.waysAreCurrent { try? await Task.sleep(for: .seconds(0.25)) }
            if fields.count > 2 {
                model.username = fields[1]
                model.password = fields[2]
                try? await Task.sleep(for: .seconds(0.5))
                model.signInWithPassword()   // what Sign In does
            }
            return fields.count > 3 ? Double(fields[3]) : 5
        case "cloud":
            CloudGatewayFlow.present(from: tabs, services: tabs.services, demo: argument.isEmpty ? "start" : argument)
            return 3.5
        case "gateways":
            SettingsScreens.presentGateways(from: tabs, services: tabs.services)
            return 3.5
        case "hold":
            return Double(argument) ?? 5
        default:
            break
        }
        return nil
    }

    private static func kind(_ stop: String) -> String { String(stop.split(separator: ":").first ?? "") }

    private static func clear(_ window: UIWindow) async {
        MacAppUpdate.shared.close()
        if window.rootViewController?.presentedViewController != nil {
            window.rootViewController?.dismiss(animated: false)
        }
        try? await Task.sleep(for: .seconds(0.8))
    }

    private static func topmost(_ controller: UIViewController?) -> UIViewController? {
        var top = controller
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top === controller ? nil : top
    }

    private static func shootView(_ view: UIView, to url: URL) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.window?.screen.scale ?? 2
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: url)
        MacShots.post(url)
    }
}
#endif
