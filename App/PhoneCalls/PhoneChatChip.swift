import UIKit

// The chat's call chip (owner 2026-11-21: "We need a notification of some sort on the chat when a bot is on the
// phone ... click it [to] open a pop up that [lets] you do whatever you could need to do or see"). While this chat has
// a call on, a chip sits on the chat's shelf above the composer, beside the browser and tasks chips: "Calling
// +1 212 555 0142", "On a call with ...", or, in orange, "The call needs your answer" when the assistant asked
// something. A tap opens the call sheet (transcript, the question, Tell the assistant, Hang up). It goes when the
// call ends. It follows the call itself, not the reply: a call outlives the reply that started it.

/// What the chip says for a chat's calls (nil: no call on).
func phoneChipWords(_ calls: [PhoneCallRecord]) -> (words: String, asking: Bool)? {
    guard let call = calls.last(where: \.active) else { return nil }
    if call.question != nil { return ("The call needs your answer", true) }
    let number = phoneShown(call.to)
    switch call.state {
    case .calling: return ("Calling \(number)", false)
    case .ending: return ("Ending the call to \(number)", false)
    default: return (call.voicemail ? "Voicemail answered \(number)" : "On a call with \(number)", false)
    }
}

@MainActor final class PhoneChatChip {
    private weak var chat: ChatViewController?
    private weak var live: LiveChatSession?
    private let controller: PhoneCallController

    static func install(on chat: ChatViewController, live: LiveChatSession) {
        let chip = PhoneChatChip(chat: chat, live: live)
        chat.activity.phoneCard = chip
        chat.activity.onPhoneChip = { [weak chip] in chip?.open() }
        chip.watch()
    }

    private init(chat: ChatViewController, live: LiveChatSession) {
        self.chat = chat
        self.live = live
        controller = .shared(for: live.client.account.id)
    }

    /// Reads the calls and asks to be told when they change (the controller is @Observable).
    private func watch() {
        guard let chat, let live else { return }
        let chip = withObservationTracking {
            // A new chat has no stored id until its first turn: every id it goes by is tried.
            phoneChipWords(controller.calls.filter { PhoneCallChat.matches(live, $0.sessionID) })
        } onChange: { [weak self] in
            Task { @MainActor in self?.watch() }
        }
        if chip?.words != chat.activity.phoneChip?.words || chip?.asking != chat.activity.phoneChip?.asking {
            AppLog.note("phone", chip == nil ? "chat chip gone" : chip?.asking == true ? "chat chip asks" : "chat chip shown")
            chat.activity.phoneChip = chip
        }
    }

    private func open() {
        guard let chat, let live, chat.presentedViewController == nil,
              let call = controller.calls.last(where: { $0.active && PhoneCallChat.matches(live, $0.sessionID) }) else { return }
        AppLog.note("phone", "chat chip tapped")
        PhoneCallChat.present(account: live.client.account.id, session: call.sessionID, profile: live.profile, from: chat)
    }
}
