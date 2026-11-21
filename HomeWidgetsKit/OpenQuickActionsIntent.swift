// [quick-actions] "Open Quick Actions" (docs/spec/3x-intents.md DECISION I22): the Quick Actions page, from the Action
// Button, Siri, Spotlight and the Shortcuts app. Compiled into the app AND the widget extension (HomeWidgetsKit is in
// both targets' sources), so a Control Center control could name it later (none ships: the simulator's control gallery
// never listed one, 2026-11-21). The extension never runs it, so nothing here touches app code: the app sets
// `QuickActionsOpener.handler` at launch.

import AppIntents
import Foundation

@MainActor enum QuickActionsOpener {
    /// The app's way to show the page (set at launch; nil in the widget extension). `from` names the way in, for the log.
    static var handler: ((_ from: String) -> Void)?
    /// An open asked for before the handler was set (a cold launch): the app takes it when it sets the handler.
    private(set) static var pending: String?

    static func open(from: String) {
        if let handler { handler(from) } else { pending = from }
    }

    /// The app's launch: the handler, and any open that waited for it.
    static func install(_ handler: @escaping (_ from: String) -> Void) {
        self.handler = handler
        if let waiting = pending {
            pending = nil
            handler(waiting)
        }
    }
}

// A plain `struct` for the reason given at `RecordVoiceNoteIntent`.
struct OpenQuickActionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Actions"
    static let description: IntentDescription? = IntentDescription(
        "Open your Quick Actions page: the actions and pages you put there, one tap each.", categoryName: "Chat")
    /// DECISION I2's rule: the app comes forward at once.
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let isDiscoverable = true

    @MainActor func perform() async throws -> some IntentResult {
        QuickActionsOpener.open(from: "intent")
        return .result()
    }
}
