// [spring-drop] DEBUG-only: a file drag from outside the app held over (or let go on) a bot's row in the Bots list,
// for the attachments end-to-end test. A UI test cannot start a drag in another app, so this stands a drop session
// carrying a real file in for the system's and walks the list's own `SessionFileDrop` with it: the row under it, the
// light, the hold's timer and blink, the open, and (let go) the hand-off into the opened chat's tray.
//
// - `-HQDebugSpringDrop "<abs path>"`        the file the drag carries
// - `-HQDebugSpringDropBot <id>`             the bot's row it goes over (default `default`)
// - `-HQDebugSpringDropMode hold|drop`       rest on the row until it opens (default), or let go on it at once

#if DEBUG
import UIKit
import UniformTypeIdentifiers

@MainActor enum SpringDropDebugHook {
    private static let defaults = UserDefaults.standard

    static func start(_ root: MainTabController) {
        guard let path = defaults.string(forKey: "HQDebugSpringDrop"), !path.isEmpty else { return }
        let bot = defaults.string(forKey: "HQDebugSpringDropBot") ?? "default"
        let mode = defaults.string(forKey: "HQDebugSpringDropMode") ?? "hold"
        let file = URL(fileURLWithPath: path)
        let provider = NSItemProvider(contentsOf: file) ?? NSItemProvider()
        provider.suggestedName = file.lastPathComponent
        let session = DebugFileDropSession(provider: provider)
        wait(root, bot: bot, tries: 120) { list, point in
            session.point = point
            let operation = list.fileDrop.update(session)
            AppLog.note("attach", "debug spring drop: over \(bot) → \(operation == .copy ? "copy" : "no drop")")
            if mode == "drop" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { list.fileDrop.perform(session) }
            }
            // hold: the list's own timer opens the row; the drag then "leaves" with the chat over the list.
        }
    }

    /// Calls `ready` once the Bots list draws `bot`'s row, with the row's middle (the list signed in through the form
    /// is a new one: it is looked up in the window each time).
    private static func wait(_ root: MainTabController, bot: String, tries: Int,
                             ready: @escaping (BotsViewController, CGPoint) -> Void) {
        let tabs = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .compactMap { ($0.rootViewController as? MainTabController) ?? ($0.rootViewController as? RootSplitController)?.tabs }
            .first ?? root
        let list = tabs.botsViewController
        if let point = list.debugRowCenter(bot) { return ready(list, point) }
        guard tries > 0 else { AppLog.note("attach", "debug spring drop: no row for \(bot)"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { wait(root, bot: bot, tries: tries - 1, ready: ready) }
    }
}

/// A drop session from outside the app carrying one file.
@MainActor private final class DebugFileDropSession: NSObject, @MainActor UIDropSession {
    var point = CGPoint.zero
    let items: [UIDragItem]

    init(provider: NSItemProvider) {
        items = [UIDragItem(itemProvider: provider)]
    }

    var localDragSession: UIDragSession? { nil }
    var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .none
    var progress: Progress { Progress() }
    var allowsMoveOperation: Bool { false }
    var isRestrictedToDraggingApplication: Bool { false }
    func location(in view: UIView) -> CGPoint { point }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool { false }
    func loadObjects(ofClass aClass: any NSItemProviderReading.Type, completion: @escaping ([any NSItemProviderReading]) -> Void) -> Progress {
        Progress()
    }
}
#endif
