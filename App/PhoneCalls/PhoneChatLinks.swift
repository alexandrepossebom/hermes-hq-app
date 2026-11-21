// Phone Calls (Beta) and the chat a call belongs to. No gateway change: the agent learns about calls from a note the
// app adds to what a message sends (not to its bubble), proposes one with a link of the app's own, and hears the result
// as the next message, all with what the app already sends and renders.
//   PhoneResultMessage   item 9: the one message a finished call sends into its chat
//   PhoneChatNote        item 13a: the note on a sent message that mentions calling, and stripping it from the bubble
//   PhoneProposal        item 13b: `<scheme>://phone-call?to=…&goal=…`, tapped inside a chat only
//   PhoneChatDelivery    where a result goes in: the chat on screen now, or the next time it opens
//   PhoneAlerts          item 7: local alerts for a question, and for background time running out

import SwiftUI
import UIKit
@preconcurrency import UserNotifications

// MARK: - The result message (item 9)

nonisolated struct PhoneResultMessage: Equatable, Sendable {
    static let header = "Phone call result (sent by Hermes HQ, not typed by the person)"
    /// About this many characters of transcript; the end is kept.
    static let transcriptLimit = 6000
    static let cutMark = "[the start of the transcript was cut]"

    /// What the agent reads.
    let text: String
    /// What the bubble shows: "Call to +1 212 555 0142: finished, 1m 32s".
    let display: String

    init(_ call: PhoneCallRecord) {
        let outcome = phoneOutcomeWords(call.outcome, duration: call.duration)
        display = "Call to \(phoneShown(call.to)): \(outcome)"
        let questions = call.asked.map { "\($0.question) → \($0.answer ?? "(not answered)")" }
        let speech = call.shownLines.map { line -> String in
            switch line.speaker {
            case .assistant: return "Assistant: " + line.text
            case .them: return "Them: " + line.text
            case .you: return "You: " + line.text
            }
        }
        text = [
            Self.header,
            "To: \(call.to)",
            "Goal: \(call.purpose)",
            "Outcome: \(outcome)",
            "Questions the assistant asked and the answers: " + (questions.isEmpty ? "none" : "\n" + questions.joined(separator: "\n")),
            "Transcript:",
            Self.capped(speech.isEmpty ? "(nothing was said)" : speech.joined(separator: "\n")),
        ].joined(separator: "\n")
    }

    /// The transcript's end, about `transcriptLimit` characters, starting at a whole line and marked as cut.
    static func capped(_ transcript: String) -> String {
        guard transcript.count > transcriptLimit else { return transcript }
        var tail = String(transcript.suffix(transcriptLimit))
        if let newline = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: newline)...]) }
        return cutMark + "\n" + tail
    }

    /// The bubble for a stored result message (after a relaunch, or on another device): its To and Outcome lines.
    static func bubble(forStored text: String) -> String? {
        guard text.hasPrefix(header) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let to = lines.first(where: { $0.hasPrefix("To: ") })?.dropFirst(4),
              let outcome = lines.first(where: { $0.hasPrefix("Outcome: ") })?.dropFirst(9) else { return nil }
        return "Call to \(phoneShown(String(to))): \(outcome)"
    }
}

// MARK: - The note on a sent message (item 13a)

nonisolated enum PhoneChatNote {
    /// The note, with the app's own link scheme.
    static func text(scheme: String = AppIdentity.current.urlScheme) -> String {
        "(Hermes HQ: this person can place AI phone calls from the app. To propose one, put a markdown link on its own "
            + "line in your reply: [Call +12125550142](\(scheme)://phone-call?to=%2B12125550142&goal=<URL-encoded goal in "
            + "plain words>). Use the full number with + and country code. Optional &voicemail=leave to leave a message if "
            + "voicemail answers. They approve it with a tap and the call's result comes back as their next message. Never "
            + "say a call was made before that result arrives. If you don't have the number, ask for it or look it up first.)"
    }

    /// A typed message that mentions calling (whole words, any case).
    static func mentionsCalling(_ typed: String) -> Bool {
        typed.contains(/\b(?:call|calls|calling|phone|ring|dial|voicemail)\b/.ignoresCase())
    }

    /// The note a typed message carries, when Phone Calls is ready for this account and the words mention calling.
    static func note(for typed: String, ready: Bool, scheme: String = AppIdentity.current.urlScheme) -> String? {
        guard ready, mentionsCalling(typed), !typed.contains(text(scheme: scheme)) else { return nil }
        return text(scheme: scheme)
    }

    /// The stored message without the note (nil when it has none): what the owner's bubble shows.
    static func stripped(_ stored: String, scheme: String = AppIdentity.current.urlScheme) -> String? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = text(scheme: scheme)
        guard trimmed.hasSuffix(note) else { return nil }
        let words = String(trimmed.dropLast(note.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }
}

/// Stored user messages the chat shows differently (SentTitles.title(forStored:)): a result message as its short line,
/// a message with the note without it.
nonisolated enum PhoneChatText {
    static func bubble(forStored text: String) -> String? {
        PhoneResultMessage.bubble(forStored: text) ?? PhoneChatNote.stripped(text)
    }
    /// Cheap check before any message is rewritten.
    static func rewrites(_ text: String) -> Bool {
        text.hasPrefix(PhoneResultMessage.header) || text.contains("://phone-call?to=")
    }
}

// MARK: - The agent's proposal (item 13b)

nonisolated struct PhoneProposal: Equatable, Sendable {
    let to: String
    let goal: String
    let voicemail: PhoneVoicemailChoice

    static let kind = "phone-call"
    static let maxGoal = 500

    /// One of the app's links (its scheme, or `hermes`) whose host is `phone-call`, valid or not.
    static func isLink(_ url: URL, scheme: String = AppIdentity.current.urlScheme) -> Bool {
        guard let given = url.scheme?.lowercased(), given == scheme.lowercased() || given == "hermes" else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased() == kind
    }

    /// A proposal only counts as a tap inside a chat. From outside the app (another app, a web page, a widget) it is
    /// refused, or anyone could pre-fill a call.
    static func refusesOutside(_ url: URL, scheme: String = AppIdentity.current.urlScheme) -> Bool { isLink(url, scheme: scheme) }

    /// A valid proposal: `to` dialable after `phoneDestination`, a goal of 1 to 500 characters, optional
    /// `voicemail=leave`. Unknown query items are ignored; anything invalid is nil.
    static func parse(_ url: URL, from: String? = nil, scheme: String = AppIdentity.current.urlScheme) -> PhoneProposal? {
        guard isLink(url, scheme: scheme), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.path.isEmpty || parts.path == "/", parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let rawTo = value("to") else { return nil }
        let to = phoneDestination(rawTo, from: from)
        guard phoneIsE164(to) else { return nil }
        let goal = (value("goal") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...maxGoal).contains(goal.count), !goal.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" }) else { return nil }
        return PhoneProposal(to: to, goal: goal, voicemail: value("voicemail")?.lowercased() == "leave" ? .leaveMessage : .hangUp)
    }

    /// What VoiceOver reads for a reply: each valid proposal link `[text](…phone-call?…)` becomes the words the bubble
    /// draws, "Call +1 212 555 0142. <goal>", instead of the link's own text. Invalid links are left as they are.
    static func spoken(_ markdown: String, scheme: String = AppIdentity.current.urlScheme) -> String {
        guard markdown.contains("phone-call") else { return markdown }
        let ns = markdown as NSString
        var out = markdown
        for match in linkPattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let url = URL(string: ns.substring(with: match.range(at: 1))), let proposal = parse(url, scheme: scheme),
                  let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: "Call \(phoneShown(proposal.to)). \(proposal.goal)")
        }
        return out
    }
    private static let linkPattern = try! NSRegularExpression(pattern: #"\[[^\]\n]*\]\(([A-Za-z][A-Za-z0-9+.-]*://phone-call[^)\s]*)\)"#)

    /// The glyph a proposal link starts with in a chat, so it reads as an action, not a web page.
    static func glyph(font: UIFont, color: UIColor) -> NSAttributedString {
        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        guard let image = UIImage(systemName: "phone.fill", withConfiguration: config)?.withTintColor(color, renderingMode: .alwaysOriginal)
        else { return NSAttributedString() }
        let attachment = NSTextAttachment(image: image)
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
        let out = NSMutableAttributedString(attachment: attachment)
        out.append(NSAttributedString(string: "\u{2009}", attributes: [.font: font]))
        return out
    }
}

/// The key a call is filed under for its chat: the stored id where known.
@MainActor enum PhoneCallChat {
    static func key(_ live: LiveChatSession) -> String? { live.storedSessionId ?? live.resolvedStoredId ?? live.runtimeSessionId }
    static func matches(_ live: LiveChatSession, _ key: String) -> Bool {
        [live.storedSessionId, live.resolvedStoredId, live.runtimeSessionId].contains(key)
    }

    /// A tap on a link inside a chat. A proposal opens this chat's call sheet filled in; nothing dials until the
    /// owner confirms there. Answers whether the link was a proposal (valid or not).
    static func open(_ url: URL, from chat: ChatViewController) -> Bool {
        guard PhoneProposal.isLink(url) else { return false }
        guard let live = chat.session as? LiveChatSession, let key = key(live) else {
            LinkOpener.notice(DeepLink.unavailable(device: DeviceWord.name), from: chat)
            return true
        }
        let controller = PhoneCallController.shared(for: live.client.account.id)
        guard let proposal = PhoneProposal.parse(url, from: controller.setup?.fromNumber) else {
            AppLog.note("phone", "proposal link refused: not valid")
            LinkOpener.notice(DeepLink.unavailable(device: DeviceWord.name), from: chat)
            return true
        }
        guard controller.ready else {
            LinkOpener.notice("Phone Calls isn't set up yet. Set it up in Settings › Phone Calls (Beta), then tap the call again.", from: chat)
            return true
        }
        AppLog.note("phone", "proposal opened")
        present(account: live.client.account.id, session: key, profile: live.profile, proposal: proposal, from: chat)
        return true
    }

    static func present(account: String, session: String, profile: String?, proposal: PhoneProposal? = nil, from host: UIViewController) {
        let sheet = UIHostingController(rootView: PhoneCallView(accountID: account, sessionID: session, profile: profile, proposal: proposal))
        sheet.view.accessibilityIdentifier = "phone.sheet"
        host.present(sheet, animated: true)
    }
}

// MARK: - Delivering a result (item 9)

/// The road a result takes into its chat: `LiveChatSession.send(_:display:)`, which queues behind a running reply as
/// any message does. Only a chat on screen whose open settled takes it; otherwise it waits and goes in the next time
/// that chat opens (`chatReady`).
@MainActor enum PhoneChatDelivery {
    private final class Box { weak var chat: LiveChatSession?; init(_ chat: LiveChatSession) { self.chat = chat } }
    private static var chats: [Box] = []

    /// A sender for the chat on screen that a call belongs to, or nil.
    static func sender(account: String, call: PhoneCallRecord) -> ((PhoneResultMessage) -> Void)? {
        chats.removeAll { $0.chat == nil }
        guard let live = chats.compactMap(\.chat).first(where: { chat in
            chat.client.account.id == account && chat.observing && (chat.openSettled || chat.openFinished)
                && PhoneCallChat.matches(chat, call.sessionID)
        }) else { return nil }
        return { [weak live] message in if let live { send(message, into: live) } }
    }

    /// A chat's open settled (AppModel.chatOpened): it can take results now, and any waiting for it go in.
    static func chatReady(_ live: LiveChatSession) {
        chats.removeAll { $0.chat == nil || $0.chat === live }
        chats.append(Box(live))
        let controller = PhoneCallController.shared(for: live.client.account.id)
        controller.deliverPending(matching: { PhoneCallChat.matches(live, $0.sessionID) }) { [weak live] message in
            if let live { send(message, into: live) }
        }
    }

    private static func send(_ message: PhoneResultMessage, into live: LiveChatSession) {
        LiveChatSession.sentTitles.note(text: message.text, title: message.display)
        live.send(message.text, display: message.display)
    }
}

// MARK: - Alerts (item 7)

nonisolated enum PhoneAlert: Equatable, Sendable {
    case question(account: String, session: String, profile: String?, call: String, text: String)
    case stillGoing(account: String, session: String, profile: String?, call: String)
}

/// Local alerts in the app's own way (NotificationHub shows them as banners and routes their tap here). Nothing new is
/// asked: without permission already given, no alert.
@MainActor enum PhoneAlerts {
    /// The local alert's key in `userInfo` (the call's id).
    nonisolated static let alertKey = "phoneCall"

    static func content(_ alert: PhoneAlert) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.threadIdentifier = "hq.phone-call"
        switch alert {
        case let .question(account, session, profile, call, text):
            content.title = "Phone call"
            content.body = "The assistant on your call asks: \(text)"
            content.userInfo = [alertKey: call, "account": account, "session": session, "profile": profile ?? ""]
            content.interruptionLevel = .timeSensitive
        case let .stillGoing(account, session, profile, call):
            content.title = "Phone call"
            content.body = "Your call is still going. Open Hermes HQ to follow it and answer questions."
            content.userInfo = [alertKey: call, "account": account, "session": session, "profile": profile ?? ""]
        }
        return content
    }

    static func post(_ alert: PhoneAlert) {
        let content = content(alert)
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                AppLog.note("phone", "alert skipped: no permission")
                return
            }
            try? await center.add(UNNotificationRequest(identifier: "phone-call." + UUID().uuidString, content: content, trigger: nil))
            AppLog.note("phone", "alert posted")
        }
    }

    /// A tapped alert: that chat, then its call sheet over it (same account only).
    static func open(_ info: [AnyHashable: Any]) {
        guard let session = info["session"] as? String, !session.isEmpty, let account = info["account"] as? String else { return }
        let profile = (info["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        NotificationHub.shared.open(session, profile: profile)
        Task {
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let root = MainTabController.current, let chat = root.chatOnShow,
                      let live = chat.session as? LiveChatSession, live.client.account.id == account,
                      PhoneCallChat.matches(live, session), chat.viewIfLoaded?.window != nil else { continue }
                if chat.presentedViewController == nil { PhoneCallChat.present(account: account, session: session, profile: profile, from: chat) }
                return
            }
            AppLog.note("phone", "alert: the chat didn't open in time")
        }
    }
}
