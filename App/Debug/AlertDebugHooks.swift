// DEBUG hook: an alert's tap without iOS's banner, so a UI test can tap a task's alert or a reply's alert that names its
// bot (the pages fixture has no push service; `xcrun simctl push` needs the notification prompt answered first).
// Compiled out of Release.
//
// - `<scheme>://debug-alert/task/<task id>`                  a task's alert (kind "task"), as `NotificationHub.respond`
//                                                             hands it on: `openTask(id, profile)`
// - `<scheme>://debug-alert/chat/<stored id>?profile=<bot>`  a reply's alert for that chat, its bot named (a real alert
//                                                             always names it; `<scheme>://session/<id>` does not)
//
// A cold launch's URL arrives before the hub's handlers are set: the hub keeps the tap, as it keeps a real one.

#if DEBUG
import UIKit

@MainActor enum AlertDebugHooks {
    static func handle(_ url: URL) -> Bool {
        guard url.host == "debug-alert" else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, !parts[1].isEmpty else { return true }
        let profile = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "profile" }?.value
        AppLog.note("notify", "debug alert \(parts[0])")
        switch parts[0] {
        case "task": NotificationHub.shared.debugTapTask(parts[1], profile: profile)
        case "chat": NotificationHub.shared.open(parts[1], profile: profile)
        default: break
        }
        return true
    }
}

extension NotificationHub {
    /// A task's alert tapped (the hand-off `respond` makes for kind "task").
    func debugTapTask(_ id: String, profile: String?) {
        if let openTask { openTask(id, profile) } else { queueTask(id, profile: profile) }
    }
}
#endif
