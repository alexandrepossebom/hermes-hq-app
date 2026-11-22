// Phone Calls (Beta): a call's conversation messages as the call sheet shows them. Pure, so it is unit-tested.
// The messages come from get-conversation-messages (samplehostClient.swift). They trail the call by about one exchange:
// samplehost writes them in batches, roughly when the other side finishes a turn (measured 5 to 60 seconds behind).

import Foundation

/// A call's spoken turns, the owner's own lines read back from what the app sent, and the newest open ask_owner.
nonisolated struct PhoneTranscript: Equatable, Sendable {
    nonisolated struct Line: Identifiable, Equatable, Sendable, Codable {
        nonisolated enum Speaker: String, Sendable, Codable { case assistant, them, you }
        let id: String
        let speaker: Speaker
        let text: String
        var isAnswer: Bool? = nil
        var followsVoicemail: Bool? = nil
    }
    nonisolated struct OwnerWords: Hashable { let text: String; let isAnswer: Bool }

    nonisolated struct Question: Equatable, Sendable, Codable {
        let id: String          // the tool call's id, for add_messages `tool_call_id`
        let text: String
        let choices: [String]
        /// Other open tool calls that asked the same question (trimmed, case-insensitive). One answer goes to all.
        var also: [String] = []

        var ids: [String] { [id] + also }
    }
    var lines: [Line] = []
    var question: Question?
    /// Questions the conversation itself shows answered (our tool message names their id).
    var answeredInConversation: Set<String> = []
    /// Every ask_owner call seen, oldest first: its id and its question's words.
    var asked: [(id: String, text: String)] = []
    /// Our answers the conversation returns, by tool call id.
    var answers: [String: String] = [:]

    static func == (a: PhoneTranscript, b: PhoneTranscript) -> Bool {
        a.lines == b.lines && a.question == b.question && a.answeredInConversation == b.answeredInConversation
            && a.asked.map(\.id) == b.asked.map(\.id) && a.asked.map(\.text) == b.asked.map(\.text) && a.answers == b.answers
    }

    /// The system line samplehost writes when nobody speaks for a while. Never shown.
    static let silence = "[long silence]"

    static func read(_ messages: [samplehostMessage], answered: Set<String>) -> PhoneTranscript {
        let ordered = order(messages)
        var result = PhoneTranscript()
        for message in ordered where message.role == "tool" {
            let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = answeredReference(text) {
                result.answeredInConversation.insert(id)
                if let answer = answeredText(text) { result.answers[id] = answer }
            }
        }
        let done = answered.union(result.answeredInConversation)
        var newest: (call: samplehostMessage.ToolCall, key: String)?
        var open: [(id: String, key: String)] = []
        var heardVoicemail = false
        for (index, message) in ordered.enumerated() {
            let raw = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch message.role {
            case "assistant", "user":
                let text = spoken(raw)
                if !text.isEmpty {
                    let assistant = message.role == "assistant"
                    result.lines.append(Line(id: "\(index)|\(message.role)", speaker: assistant ? .assistant : .them,
                                             text: text, followsVoicemail: assistant && heardVoicemail ? true : nil))
                    if !assistant, phoneSoundsLikeVoicemail(text) { heardVoicemail = true }
                }
            case "tool":
                // Our answer, read back as the owner's line. A question asked twice gets one tool message per call
                // in the same request: they show as one line.
                if let answer = answeredText(raw), !answer.isEmpty,
                   result.lines.last.map({ $0.speaker != .you || $0.text != answer }) ?? true {
                    result.lines.append(Line(id: "\(index)|you", speaker: .you, text: answer, isAnswer: true))
                }
                // Anything else from a tool is a receipt (`{"http_status":422,…}`, `{"data":{"result":"ok"}}`): hidden.
            case "system":
                if raw.hasPrefix(PhoneAskOwner.ownerMessagePrefix) {
                    let said = String(raw.dropFirst(PhoneAskOwner.ownerMessagePrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !said.isEmpty { result.lines.append(Line(id: "\(index)|you", speaker: .you, text: said)) }
                }
                // "[long silence]" and our answer's own system note: hidden.
            default:
                break
            }
            for call in message.tool_calls ?? [] where call.function.name == PhoneAskOwner.name {
                let asked = question(call)
                let key = normalized(asked.text)
                result.asked.append((call.id, asked.text))
                newest = (call, key)
                if !done.contains(call.id) { open.append((call.id, key)) }
            }
        }
        if let newest, !done.contains(newest.call.id) {
            var shown = question(newest.call)
            shown.also = open.filter { $0.key == newest.key && $0.id != newest.call.id }.map(\.id)
            result.question = shown
        }
        return result
    }

    /// What a spoken line shows: no `<emotion … />` tags (leading or inline), spaces tidied.
    static func spoken(_ text: String) -> String {
        guard text.contains("<") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let stripped = text.replacing(/<\/?emotion\b[^>]*>/.ignoresCase(), with: "")
        return stripped.replacing(/[ \t]{2,}/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A question's words compared for repeats: trimmed, case-insensitive.
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Oldest first. samplehost doesn't document the order, so messages are sorted by `sent_at`/`created_at` when every
    /// one has a readable time, else kept as sent.
    static func order(_ messages: [samplehostMessage]) -> [samplehostMessage] {
        let dates = messages.map { date($0.sent_at ?? $0.created_at) }
        guard !dates.contains(where: { $0 == nil }) else { return messages }
        return messages.indices.sorted { (dates[$0]!, $0) < (dates[$1]!, $1) }.map { messages[$0] }
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value) ?? PhoneCallEvent.date(value)
    }

    static func question(_ call: samplehostMessage.ToolCall) -> Question {
        let object = call.function.arguments.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
        let asked = (object?["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let choices = (object?["choices"] as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.map { String($0.prefix(60)) }
        var unique: [String] = []
        for choice in choices where !unique.contains(choice) { unique.append(choice) }
        return Question(id: call.id, text: asked.isEmpty ? "The assistant asked for your input." : String(asked.prefix(300)),
                        choices: Array(unique.prefix(6)))
    }

    /// The id in "The owner answered (ref <id>): …".
    static func answeredReference(_ text: String) -> String? {
        let head = PhoneAskOwner.answerPrefix + " (ref "
        guard text.hasPrefix(head), let close = text.range(of: "): ") else { return nil }
        let id = text[text.index(text.startIndex, offsetBy: head.count)..<close.lowerBound]
        return id.isEmpty ? nil : String(id)
    }

    /// The answer in "The owner answered (ref <id>): <answer>".
    static func answeredText(_ text: String) -> String? {
        guard answeredReference(text) != nil, let close = text.range(of: "): ") else { return nil }
        return String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Words a voicemail greeting or an answering service says. Either this or samplehost's machine detection marks a call as
/// voicemail.
nonisolated func phoneSoundsLikeVoicemail(_ text: String) -> Bool {
    let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
    return ["record your message", "at the tone", "after the tone", "after the beep", "leave a message", "leave your message",
            "voicemail", "voice mail", "mailbox", "is not available", "isn't available", "can't take your call",
            "cannot take your call", "unable to take your call"].contains { lower.contains($0) }
}
