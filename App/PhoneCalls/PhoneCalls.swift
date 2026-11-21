// Phone Calls (Beta) screens and call state. App-only: requests go straight to samplehost (samplehostClient.swift) with the
// owner's key from this device's Keychain. Nothing here talks to the gateway. Each HQ account has its own key and its
// own calls (PhoneCallController.shared(for:)), so switching accounts never shows another account's key or calls.

import SwiftUI

// A retry must replay the exact approved intent, not reuse its id for edited fields.
struct PhoneStartIntent: Equatable {
    let session: String, destination: String, goal: String
}
struct PhoneStartRetry {
    private(set) var pending: (intent: PhoneStartIntent, id: String)?
    mutating func id(for intent: PhoneStartIntent) -> String {
        if let pending, pending.intent == intent { return pending.id }
        let id = UUID().uuidString
        pending = (intent, id)
        return id
    }
    mutating func completed() { pending = nil }
}

/// `+` and 7 to 15 digits, the first not 0.
nonisolated func phoneIsE164(_ value: String) -> Bool {
    value.wholeMatch(of: /\+[1-9][0-9]{6,14}/) != nil
}

/// What the To field means as a dialable number. Spaces, dashes, dots and brackets are dropped. Calling from a +1
/// (North American) number, a plain 10-digit number, or 11 digits starting with 1, is a +1 number (owner 2026-11-21:
/// a 10-digit number left Review Call greyed out). Anything else must be typed with its `+` country code.
nonisolated func phoneDestination(_ typed: String, from: String?) -> String {
    let kept = typed.filter { !$0.isWhitespace && !"-().".contains($0) }
    guard !kept.hasPrefix("+"), (from ?? "").hasPrefix("+1"), kept.allSatisfy({ ("0"..."9").contains($0) }) else { return kept }
    if kept.count == 10, kept.first != "0", kept.first != "1" { return "+1" + kept }
    if kept.count == 11, kept.first == "1" { return "+" + kept }
    return kept
}

/// When the app hangs up itself if samplehost's `time_limit_secs` somehow didn't: 60 s after the conversation first shows
/// (it is made at pickup), and never later than ring time + 60 s after dialing.
nonisolated func phoneHangupDeadline(placedAt: Date, liveAt: Date?) -> Date {
    let ceiling = placedAt.addingTimeInterval(TimeInterval(PhoneLimits.ringSeconds + PhoneLimits.callSeconds))
    guard let liveAt else { return ceiling }
    return min(ceiling, liveAt.addingTimeInterval(TimeInterval(PhoneLimits.callSeconds)))
}

// MARK: - Reading a conversation

/// A call's conversation messages as the sheet shows them: the spoken turns and the newest unanswered ask_owner.
nonisolated struct PhoneTranscript: Equatable, Sendable {
    nonisolated struct Line: Identifiable, Equatable, Sendable {
        enum Speaker: Sendable { case assistant, them }
        let id: String
        let speaker: Speaker
        let text: String
    }
    nonisolated struct Question: Equatable, Sendable {
        let id: String          // the tool call's id, for add_messages `tool_call_id`
        let text: String
        let choices: [String]
    }
    var lines: [Line] = []
    var question: Question?
    /// Questions the conversation itself shows answered (our tool message names their id).
    var answeredInConversation: Set<String> = []

    static func read(_ messages: [samplehostMessage], answered: Set<String>) -> PhoneTranscript {
        let ordered = order(messages)
        var result = PhoneTranscript()
        for message in ordered where message.role == "tool" {
            if let id = answeredReference(message.text ?? "") { result.answeredInConversation.insert(id) }
        }
        let done = answered.union(result.answeredInConversation)
        for (index, message) in ordered.enumerated() {
            let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if message.role == "assistant" || message.role == "user", !text.isEmpty {
                result.lines.append(Line(id: "\(index)|\(message.role)", speaker: message.role == "assistant" ? .assistant : .them, text: text))
            }
            for call in message.tool_calls ?? [] where call.function.name == PhoneAskOwner.name {
                result.question = done.contains(call.id) ? nil : question(call)
            }
        }
        return result
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
        return iso.date(from: value)
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
}

// MARK: - Calls

struct PhoneCallRecord: Identifiable, Equatable {
    enum State: Equatable { case calling, live, ending, ended }
    let id: String              // samplehost call_control_id
    let sessionID: String
    let to: String
    let purpose: String
    let placedAt: Date
    let hangupCommandID: String
    var state: State = .calling
    var conversationID: String?
    var liveAt: Date?
    var seenAlive = false
    var lines: [PhoneTranscript.Line] = []
    var question: PhoneTranscript.Question?
    var answered: Set<String> = []
    var answerCommandIDs: [String: String] = [:]
    var sendingAnswer: String?
    var lastAnswer: String?
    var issue: String?
    var endNote: String?

    var active: Bool { state != .ended }
    var statusText: String {
        switch state {
        case .calling: return "Calling…"
        case .live: return "Live"
        case .ending: return "Ending…"
        case .ended: return endNote.map { "Ended · \($0)" } ?? "Ended"
        }
    }
}

/// One HQ account's calls. Polls only while a sheet asks (`poll`) and only calls that are still going.
@MainActor @Observable final class PhoneCallController {
    private static var byAccount: [String: PhoneCallController] = [:]
    static func shared(for accountID: String) -> PhoneCallController {
        if let existing = byAccount[accountID] { return existing }
        let made = PhoneCallController(accountID: accountID)
        byAccount[accountID] = made
        return made
    }

    let accountID: String
    let store: PhoneKeyStore
    /// The client for a key (tests swap in a stubbed URLSession).
    var makeAPI: (String) -> samplehostAPI = { samplehostAPI(key: $0) }
    var now: () -> Date = { Date() }
    var pollInterval: Duration = .milliseconds(1500)
    private(set) var calls: [PhoneCallRecord] = []
    private var dialRetry = PhoneStartRetry()
    @ObservationIgnored private var watchdogs: [String: Task<Void, Never>] = [:]

    init(accountID: String, store: PhoneKeyStore = .app) {
        self.accountID = accountID; self.store = store
    }

    var setup: PhoneSetup? { store.load(for: accountID) }
    var ready: Bool { setup?.ready == true }
    var hasActiveCall: Bool { calls.contains(where: \.active) }
    func calls(for sessionID: String) -> [PhoneCallRecord] { calls.filter { $0.sessionID == sessionID } }

    private var api: samplehostAPI? { setup.map { makeAPI($0.apiKey) } }
    private func index(_ id: String) -> Int? { calls.firstIndex { $0.id == id } }

    /// Dials after the owner confirmed. Throws a readable failure; a retry of the same intent reuses its command_id.
    @discardableResult
    func place(sessionID: String, to: String, purpose: String) async throws -> String {
        guard let setup, setup.ready, let from = setup.fromNumber, let connection = setup.connectionID,
              let assistant = setup.assistantID else {
            throw samplehostError.provider("Phone Calls isn't set up. Connect samplehost in Settings first.")
        }
        let api = makeAPI(setup.apiKey)
        guard !hasActiveCall else { throw samplehostError.provider("Another call is still going. Hang it up first.") }
        let commandID = dialRetry.id(for: PhoneStartIntent(session: sessionID, destination: to, goal: purpose))
        let request = PhoneDialRequest(to: to, from: from, connectionID: connection, assistantID: assistant,
                                       purpose: purpose, commandID: commandID)
        let id = try await api.dial(request)
        dialRetry.completed()
        if index(id) == nil {
            calls.append(PhoneCallRecord(id: id, sessionID: sessionID, to: to, purpose: purpose, placedAt: now(),
                                         hangupCommandID: UUID().uuidString))
        }
        startWatchdog(id)
        return id
    }

    /// Refreshes this session's live calls every `pollInterval` until the task is cancelled (the sheet closed).
    func poll(sessionID: String) async {
        while !Task.isCancelled {
            for call in calls where call.sessionID == sessionID && call.active { await refresh(call.id) }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// One look at a call: its conversation (found by call_control_id), the messages, and whether it is alive.
    func refresh(_ id: String) async {
        guard let api, let call = calls.first(where: { $0.id == id }), call.active else { return }
        do {
            var conversation = call.conversationID
            if conversation == nil { conversation = try await api.conversationID(callControlID: id) }
            if let conversation {
                let messages = try await api.messages(conversationID: conversation)
                guard let i = index(id) else { return }
                let transcript = PhoneTranscript.read(messages, answered: calls[i].answered)
                calls[i].conversationID = conversation
                calls[i].lines = transcript.lines
                calls[i].answered.formUnion(transcript.answeredInConversation)
                if calls[i].sendingAnswer == nil { calls[i].question = transcript.question }
                if calls[i].liveAt == nil { calls[i].liveAt = now() }
                if calls[i].state == .calling { calls[i].state = .live }
            }
            let alive = try await api.isAlive(callControlID: id)
            guard let i = index(id) else { return }
            calls[i].issue = nil
            if alive == true { calls[i].seenAlive = true; return }
            let ringOver = now().timeIntervalSince(calls[i].placedAt) > TimeInterval(PhoneLimits.ringSeconds + 10)
            if calls[i].seenAlive || calls[i].conversationID != nil || ringOver { finish(id, note: nil) }
        } catch {
            guard let i = index(id) else { return }
            calls[i].issue = phoneMessage(error)
        }
    }

    /// Sends the owner's answer to the assistant on the call (tool result + system note, trigger_response).
    func answer(_ id: String, question: PhoneTranscript.Question, with text: String) async {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api, let i = index(id), calls[i].active, calls[i].state != .ending, !answer.isEmpty,
              calls[i].sendingAnswer == nil, calls[i].question?.id == question.id,
              !calls[i].answered.contains(question.id) else { return }
        let commandID = calls[i].answerCommandIDs[question.id] ?? UUID().uuidString
        calls[i].answerCommandIDs[question.id] = commandID
        calls[i].sendingAnswer = question.id
        do {
            try await api.deliverAnswer(callControlID: id, toolCallID: question.id, question: question.text,
                                        answer: answer, commandID: commandID)
            guard let j = index(id) else { return }
            calls[j].answered.insert(question.id)
            calls[j].question = nil
            calls[j].lastAnswer = answer
            calls[j].sendingAnswer = nil
            calls[j].issue = nil
        } catch {
            guard let j = index(id) else { return }
            calls[j].sendingAnswer = nil
            if case samplehostError.callEnded = error { finish(id, note: nil) } else { calls[j].issue = phoneMessage(error) }
        }
    }

    /// Hangs up once. Repeated taps while it's ending and taps after it ended send nothing.
    func hangup(_ id: String, automatic: Bool = false) async {
        guard let api, let i = index(id), calls[i].active, calls[i].state != .ending else { return }
        let before = calls[i].state
        calls[i].state = .ending
        do {
            try await api.hangup(callControlID: id, commandID: calls[i].hangupCommandID)
            finish(id, note: automatic ? "\(PhoneLimits.callSeconds)-second limit" : "you hung up")
        } catch {
            guard let j = index(id) else { return }
            calls[j].state = before
            calls[j].issue = phoneMessage(error)
        }
    }

    /// Hangs up every live call (Disconnect), then forgets them.
    func endAll() async {
        for call in calls where call.active { await hangup(call.id) }
        for task in watchdogs.values { task.cancel() }
        watchdogs = [:]
        calls = []
    }

    private func finish(_ id: String, note: String?) {
        guard let i = index(id) else { return }
        calls[i].state = .ended
        if calls[i].endNote == nil { calls[i].endNote = note }
        calls[i].question = nil
        watchdogs.removeValue(forKey: id)?.cancel()
    }

    /// The app-side backup for `time_limit_secs`: hangs up at `phoneHangupDeadline` while the app runs.
    private func startWatchdog(_ id: String) {
        watchdogs[id]?.cancel()
        watchdogs[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let call = self.calls.first(where: { $0.id == id }), call.active else { return }
                if self.now() >= phoneHangupDeadline(placedAt: call.placedAt, liveAt: call.liveAt) {
                    await self.hangup(id, automatic: true)
                    if self.calls.first(where: { $0.id == id })?.active != true { return }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

// MARK: - Settings › Phone Calls (Beta)

struct PhoneSettingsView: View {
    let accountID: String
    @State private var setup: PhoneSetup?
    @State private var numbers: [samplehostNumber] = []
    @State private var assistants: [samplehostAssistant] = []
    @State private var key = ""
    @State private var number = ""
    @State private var connection = ""
    @State private var assistant = ""
    @State private var error: String?
    @State private var busy = false
    @State private var loaded = false
    /// One create-assistant operation per page visit: a retried tap reuses it, so samplehost never makes two.
    @State private var createKey = UUID().uuidString

    private var store: PhoneKeyStore { .app }
    private var controller: PhoneCallController { .shared(for: accountID) }
    private var connections: [(id: String, name: String)] {
        var seen = Set<String>()
        return numbers.compactMap { n in
            guard let id = n.connection_id, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return (id, n.connection_name.flatMap { $0.isEmpty ? nil : $0 } ?? id)
        }
    }
    private var changed: Bool {
        guard let setup else { return false }
        return setup.fromNumber != number || setup.connectionID != connection || setup.assistantID != assistant
    }

    var body: some View {
        Form {
            Section {
                Text(setup == nil ? "Not connected" : setup?.ready == true ? "Ready" : "Connected, choose a number and assistant")
                    .accessibilityIdentifier("phone.settings.status")
                if setup == nil {
                    SecureField("samplehost API key", text: $key)
                        .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Connect") { connect() }.disabled(key.isEmpty || busy)
                } else {
                    Button("Disconnect", role: .destructive) { disconnect() }.disabled(busy)
                }
            } header: { Text("samplehost") } footer: {
                Text("Hermes HQ calls samplehost directly with your key. It stays in this device's Keychain for this account and is never sent to your gateway. Calls are billed to your samplehost account.")
            }
            if setup != nil {
                Section {
                    Picker("From number", selection: $number) {
                        Text("Select").tag("")
                        ForEach(numbers) { Text($0.phone_number).tag($0.phone_number) }
                    }
                    .onChange(of: number) { _, picked in
                        if let id = numbers.first(where: { $0.phone_number == picked })?.connection_id, !id.isEmpty { connection = id }
                    }
                    Picker("Voice connection", selection: $connection) {
                        Text("Select").tag("")
                        ForEach(connections, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker("AI Assistant", selection: $assistant) {
                        Text("Select").tag("")
                        ForEach(assistants) { Text($0.name).tag($0.id) }
                    }
                    Button("Save") { save() }.disabled(busy || !changed || number.isEmpty || connection.isEmpty || assistant.isEmpty)
                } header: { Text("Calls") } footer: {
                    Text("The voice connection must be the Call Control application your number uses. Each call gives your assistant this call's purpose and an ask_owner tool; its stored settings aren't changed. Calls end after \(PhoneLimits.callSeconds) seconds.")
                }
                if numbers.isEmpty && loaded {
                    Section { Text("No active phone numbers on this samplehost account.").font(Font.hq(.footnote)) }
                }
                if assistants.isEmpty && loaded {
                    Section {
                        Text("This samplehost account has no AI Assistants yet. Hermes HQ can make one for you, named \(PhoneAskOwner.assistantName).")
                            .font(Font.hq(.footnote))
                        Button("Create Assistant") { createAssistant() }.disabled(busy)
                            .accessibilityIdentifier("phone.settings.create-assistant")
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .task { await load() }
        .onDisappear { key = "" }
    }

    private func apply(_ value: PhoneSetup?) {
        setup = value
        number = value?.fromNumber ?? ""; connection = value?.connectionID ?? ""; assistant = value?.assistantID ?? ""
    }

    private func fetch(_ api: samplehostAPI) async throws {
        numbers = try await api.phoneNumbers()
        assistants = try await api.assistants()
        pickOnlyAssistant()
    }

    /// With exactly one assistant on the account there is nothing to choose: take it.
    private func pickOnlyAssistant() {
        if assistant.isEmpty, assistants.count == 1 { assistant = assistants[0].id }
    }

    private func createAssistant() {
        guard !busy, let stored = setup else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let made = try await samplehostAPI(key: stored.apiKey).createAssistant(idempotencyKey: createKey)
                if !assistants.contains(made) { assistants.append(made) }
                assistant = made.id
                if !number.isEmpty, !connection.isEmpty { busy = false; save() }
            } catch { self.error = phoneMessage(error) }
        }
    }

    private func load() async {
        let stored = store.load(for: accountID)
        apply(stored)
        guard let stored else { loaded = true; return }
        do { try await fetch(samplehostAPI(key: stored.apiKey)); error = nil } catch { self.error = phoneMessage(error) }
        loaded = true
    }

    private func connect() {
        guard !busy, !key.isEmpty, setup == nil else { return }
        let submitted = key.trimmingCharacters(in: .whitespacesAndNewlines)
        key = ""; busy = true; error = nil
        Task {
            defer { busy = false }
            let api = samplehostAPI(key: submitted)
            do {
                numbers = try await api.phoneNumbers()   // the read-only check that the key works
                var fresh = PhoneSetup(apiKey: submitted)
                if numbers.count == 1 { fresh.fromNumber = numbers[0].phone_number; fresh.connectionID = numbers[0].connection_id }
                try store.save(fresh, for: accountID)
                apply(fresh)
                if numbers.count != 1 { number = ""; connection = "" }
                assistants = try await api.assistants()
                pickOnlyAssistant()
                if fresh.ready == false, !number.isEmpty, !connection.isEmpty, !assistant.isEmpty { busy = false; save() }
            } catch {
                self.error = (error as? PhoneKeyStoreError) != nil ? "Couldn't save the key in the Keychain." : phoneMessage(error)
            }
        }
    }

    private func save() {
        guard !busy, var next = setup else { return }
        next.fromNumber = number; next.connectionID = connection; next.assistantID = assistant
        next.assistantName = assistants.first { $0.id == assistant }?.name
        do { try store.save(next, for: accountID); apply(next); error = nil } catch { self.error = "Couldn't save the selection in the Keychain." }
    }

    private func disconnect() {
        guard !busy, setup != nil else { return }
        busy = true
        Task {
            defer { busy = false }
            await controller.endAll()
            store.delete(for: accountID)
            apply(nil); numbers = []; assistants = []; error = nil
        }
    }
}

// MARK: - The call sheet (from a chat)

struct PhoneCallView: View {
    @Environment(\.dismiss) private var dismiss
    let accountID: String
    let sessionID: String
    @State private var controller: PhoneCallController
    @State private var to = ""
    @State private var purpose = ""
    @State private var answers: [String: String] = [:]
    @State private var error: String?
    @State private var confirming = false
    @State private var busy = false

    init(accountID: String, sessionID: String) {
        self.accountID = accountID; self.sessionID = sessionID
        _controller = State(initialValue: .shared(for: accountID))
    }

    private var destination: String { phoneDestination(to, from: controller.setup?.fromNumber) }
    private var trimmedPurpose: String { purpose.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                if controller.ready {
                    Section {
                        TextField("To (+15550100123)", text: $to).keyboardType(.phonePad).accessibilityIdentifier("phone.to")
                        TextField("Purpose and instructions", text: $purpose, axis: .vertical).accessibilityIdentifier("phone.purpose")
                        Button("Review call") { confirming = true }
                            .disabled(!phoneIsE164(destination) || trimmedPurpose.isEmpty || busy || controller.hasActiveCall)
                    } header: { Text("New call") } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if !to.isEmpty && !phoneIsE164(destination) {
                                Text("Enter a full phone number, like 615 555 0123, or +44 and the number for other countries.")
                                    .foregroundStyle(.red).accessibilityIdentifier("phone.to.hint")
                            }
                            Text("From \(controller.setup?.fromNumber ?? "your samplehost number"). Calls end after \(PhoneLimits.callSeconds) seconds and are billed to your samplehost account.")
                        }
                    }
                } else {
                    Section { Text("Connect samplehost in Settings › Phone Calls (Beta) to place calls.") }
                }
                ForEach(controller.calls(for: sessionID).reversed()) { call in callSection(call) }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .hqGroupedPage()   // [desktoplook] the page follows the skin
            .navigationTitle("Phone Calls")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("phone.close") } }
            .confirmationDialog("Call \(destination)?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Place call (billed to samplehost)") { start() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Purpose: \(trimmedPurpose)\nFrom: \(controller.setup?.fromNumber ?? "")\nAn AI assistant talks for you. The call ends after \(PhoneLimits.callSeconds) seconds. Only call people who expect it.")
            }
            .task { await controller.poll(sessionID: sessionID) }
        }
    }

    @ViewBuilder private func callSection(_ call: PhoneCallRecord) -> some View {
        Section {
            Text(call.statusText).font(Font.hq(.headline)).accessibilityIdentifier("phone.call.status")
            Text(call.purpose).font(Font.hq(.callout)).foregroundStyle(Color.hqLabel2)
            ForEach(call.lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.speaker == .assistant ? "Assistant" : "Them").font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
                    Text(line.text)
                }
            }
            if let question = call.question, call.active {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The assistant asks you").font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
                    Text(question.text).font(Font.hq(.body).weight(.semibold))
                }
                if call.sendingAnswer == question.id {
                    Text("Sending your answer…")
                } else {
                    ForEach(question.choices, id: \.self) { choice in
                        Button(choice) { respond(call, question, choice) }
                    }
                    TextField("Your answer", text: Binding(get: { answers[call.id] ?? "" }, set: { answers[call.id] = $0 }))
                        .accessibilityIdentifier("phone.answer")
                    Button("Send answer") { respond(call, question, answers[call.id] ?? "") }
                        .disabled((answers[call.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let last = call.lastAnswer { Text("You answered: \(last)").font(Font.hq(.footnote)) }
            if let issue = call.issue { Text(issue).font(Font.hq(.footnote)).foregroundStyle(.red) }
            if call.active {
                Button("Hang up", role: .destructive) { Task { await controller.hangup(call.id) } }
                    .disabled(call.state == .ending)
            }
        } header: { Text("Call to \(call.to)") }
    }

    private func start() {
        guard !busy else { return }
        busy = true; error = nil
        let number = destination, goal = trimmedPurpose
        Task {
            defer { busy = false }
            do {
                try await controller.place(sessionID: sessionID, to: number, purpose: goal)
                to = ""; purpose = ""
                if let id = controller.calls(for: sessionID).last?.id { await controller.refresh(id) }
            } catch { self.error = phoneMessage(error) }
        }
    }

    private func respond(_ call: PhoneCallRecord, _ question: PhoneTranscript.Question, _ value: String) {
        Task {
            await controller.answer(call.id, question: question, with: value)
            if controller.calls.first(where: { $0.id == call.id })?.answered.contains(question.id) == true { answers[call.id] = nil }
        }
    }
}
