// [viewing] Which chat this device has in front of its person, as the add-on is told (hermes-hq-push 0.9.66).
//
// A tester 2026-11-18: with a bot's chat open on the Mac, each reply also alerted the iPhone. Every device already
// keeps quiet about the chat it shows, but no device knew what another showed. Now the device that shows a chat says
// so to the add-on (the chat's id and the bot's name, nothing else), again every 20 s while it stays true, and the
// add-on sends no reply alert for that chat to any device meanwhile. Each report lasts 45 s, so a device that sleeps,
// crashes or loses its link stops counting by itself. Approvals and questions still alert everywhere: a bot waits.

import Foundation

nonisolated enum ViewingRules {
    /// How long one report stands, and how often it is said again.
    static let ttl: TimeInterval = 45
    static let beat: TimeInterval = 20
    /// A Mac's window can sit open in front with nobody at the desk: past this long without a key or the pointer
    /// moving, the Mac stops saying it shows the chat, and the phone alerts again.
    static let macIdle: TimeInterval = 120

    struct Chat: Equatable, Sendable {
        var session: String
        var profile: String
    }

    /// The chat to report, or nil: the app in front, a stored chat on screen, and on a Mac someone at it.
    static func shown(active: Bool, chat: Chat?, mac: Bool, idle: TimeInterval?) -> Chat? {
        guard active, let chat, !chat.session.isEmpty, !chat.profile.isEmpty else { return nil }
        if mac, let idle, idle > macIdle { return nil }
        return chat
    }

    enum Step: Equatable { case report(Chat), clear, nothing }

    /// What to send now. A chat on show is said again at every beat; one that stopped being shown is cleared once.
    static func step(shown: Chat?, reported: Chat?) -> Step {
        if let shown { return .report(shown) }
        return reported == nil ? .nothing : .clear
    }
}
