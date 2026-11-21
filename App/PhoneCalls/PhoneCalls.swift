// Phone Calls (Beta) screens. App-only: requests go straight to samplehost (samplehostClient.swift) with the owner's key from
// this device's Keychain. Nothing here talks to the gateway. Each HQ account has its own key and its own calls
// (PhoneCallController.shared(for:), PhoneCallController.swift), so switching accounts never shows another account's
// key or calls. The controller watches every call; these screens only show it.

import SwiftUI

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
    @State private var ownerName = ""
    @State private var recordCalls = false
    @State private var sendResults = true
    @State private var error: String?
    @State private var busy = false
    @State private var loaded = false
    @State private var confirmClear = false
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
            || setup.name != ownerName.trimmingCharacters(in: .whitespacesAndNewlines) || setup.records != recordCalls
            || setup.sendsResults != sendResults
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
                    TextField("Your name (said on calls)", text: $ownerName)
                        .textContentType(.name).autocorrectionDisabled()
                        .accessibilityIdentifier("phone.settings.name")
                } header: { Text("Calls") } footer: {
                    Text("The voice connection must be the Call Control application your number uses. Each call gives your assistant this call's purpose, its opening line and an ask_owner tool. With a name, the assistant says it is calling on your behalf. \(PhoneLimits.stayCopy)")
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
                Section {
                    Toggle("Record calls", isOn: $recordCalls).accessibilityIdentifier("phone.settings.record")
                } footer: {
                    Text("Recording is a setting on the chosen samplehost assistant, and Hermes HQ changes that setting there. When it is on, the assistant says the call is recorded. Recordings stay in your samplehost account.")
                }
                Section {
                    Toggle("Send call results to the chat", isOn: $sendResults).accessibilityIdentifier("phone.settings.results")
                } footer: {
                    Text("When a call ends, Hermes HQ sends what happened (the outcome, questions and answers, and the transcript) into the chat the call was made from, so your agent knows.")
                }
                Section {
                    Button("Save") { save() }.disabled(busy || !changed || number.isEmpty || connection.isEmpty || assistant.isEmpty)
                        .accessibilityIdentifier("phone.settings.save")
                }
                if setup?.ready == true {
                    Section {
                        NavigationLink("Check my setup") { PhoneSetupCheckView(accountID: accountID).navigationTitle("Check my setup") }
                            .accessibilityIdentifier("phone.settings.check")
                        NavigationLink("Call history") { PhoneHistoryView(accountID: accountID).navigationTitle("Call history") }
                            .accessibilityIdentifier("phone.settings.history")
                        Button("Clear call history", role: .destructive) { confirmClear = true }
                            .disabled(!controller.calls.contains { !$0.active })
                            .accessibilityIdentifier("phone.settings.clear-history")
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("phone.settings.error") } }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .task { await load() }
        .onDisappear { key = "" }
        .confirmationDialog("Clear call history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear call history", role: .destructive) { controller.clearHistory() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Ended calls and their transcripts leave this device. Nothing changes in samplehost.")
        }
    }

    private func apply(_ value: PhoneSetup?) {
        setup = value
        number = value?.fromNumber ?? ""; connection = value?.connectionID ?? ""; assistant = value?.assistantID ?? ""
        ownerName = value?.name ?? ""; recordCalls = value?.records ?? false; sendResults = value?.sendsResults ?? true
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

    /// Saves the choices, then makes the assistant's recording match the switch (wire fact 9). A failed match is
    /// shown; the choices stay saved and the next dial tries again (and won't dial if it fails).
    private func save() {
        guard !busy, var next = setup else { return }
        next.fromNumber = number; next.connectionID = connection; next.assistantID = assistant
        next.assistantName = assistants.first { $0.id == assistant }?.name
        let name = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        next.ownerName = name.isEmpty ? nil : name
        next.recordCalls = recordCalls
        next.sendResults = sendResults
        do { try store.save(next, for: accountID); apply(next); error = nil } catch {
            self.error = "Couldn't save the selection in the Keychain."
            return
        }
        guard next.ready, let assistantID = next.assistantID else { return }
        busy = true
        let api = samplehostAPI(key: next.apiKey), on = next.records
        Task {
            defer { busy = false }
            let matched = await Result.of { try await api.matchRecording(assistantID: assistantID, on: on) }
            if case .failure(let failure) = matched {
                error = "Saved, but the assistant's recording couldn't be set to \(on ? "on" : "off"). Calls won't go out until it can. " + phoneMessage(failure)
            }
        }
    }

    private func disconnect() {
        guard !busy, setup != nil else { return }
        busy = true
        Task {
            defer { busy = false }
            await controller.endAll()
            controller.forgetHistory()
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
    let profile: String?
    @State private var controller: PhoneCallController
    @State private var to = ""
    @State private var purpose = ""
    @State private var voicemail: PhoneVoicemailChoice = .hangUp
    @State private var suggested = false
    @State private var answers: [String: String] = [:]
    @State private var messages: [String: String] = [:]
    @State private var error: String?
    @State private var confirming = false
    @State private var busy = false

    init(accountID: String, sessionID: String, profile: String? = nil, proposal: PhoneProposal? = nil) {
        self.accountID = accountID; self.sessionID = sessionID; self.profile = profile
        _controller = State(initialValue: .shared(for: accountID))
        if let proposal {
            _to = State(initialValue: proposal.to)
            _purpose = State(initialValue: proposal.goal)
            _voicemail = State(initialValue: proposal.voicemail)
            _suggested = State(initialValue: true)
        }
    }

    private var destination: String { phoneDestination(to, from: controller.setup?.fromNumber) }
    private var trimmedPurpose: String { purpose.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var recorded: Bool { controller.setup?.records ?? false }

    var body: some View {
        NavigationStack {
            Form {
                if controller.ready {
                    Section {
                        if suggested {
                            Label("Suggested by your agent", systemImage: "sparkles").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                .accessibilityIdentifier("phone.suggested")
                        }
                        TextField("To (+15550100123)", text: $to).keyboardType(.phonePad).accessibilityIdentifier("phone.to")
                        TextField("Purpose and instructions", text: $purpose, axis: .vertical).accessibilityIdentifier("phone.purpose")
                        Picker("If voicemail answers", selection: $voicemail) {
                            ForEach(PhoneVoicemailChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .accessibilityIdentifier("phone.voicemail")
                        Button("Review call") { confirming = true }
                            .disabled(!phoneIsE164(destination) || trimmedPurpose.isEmpty || busy || controller.hasActiveCall)
                    } header: { Text("New call") } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if !to.isEmpty && !phoneIsE164(destination) {
                                Text("Enter a full phone number, like 615 555 0123, or +44 and the number for other countries.")
                                    .foregroundStyle(.red).accessibilityIdentifier("phone.to.hint")
                            }
                            Text("From \(controller.setup?.fromNumber ?? "your samplehost number"). \(PhoneLimits.stayCopy) Calls are billed to your samplehost account.")
                        }
                    }
                } else {
                    Section { Text("Connect samplehost in Settings › Phone Calls (Beta) to place calls.") }
                }
                let mine = Array(controller.calls(for: sessionID).reversed())
                ForEach(Array(mine.enumerated()), id: \.element.id) { index, call in
                    PhoneCallSection(controller: controller, call: call, answers: $answers, messages: $messages,
                                     lagNote: index == 0)
                }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("phone.error") } }
            }
            .hqGroupedPage()   // [desktoplook] the page follows the skin
            .navigationTitle("Phone Calls")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("phone.close") } }
            .confirmationDialog("Call \(destination)?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Place call (billed to samplehost)") { start() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Purpose: \(trimmedPurpose)\nFrom: \(controller.setup?.fromNumber ?? "")\nIf voicemail answers: \(voicemail.title)\n\(recorded ? "This call is recorded." : "Not recorded.")\nAn AI assistant talks for you. \(PhoneLimits.stayCopy) Only call people who expect it.")
            }
            .onAppear { controller.sheetAppeared(sessionID) }
            .onDisappear { controller.sheetDisappeared(sessionID) }
        }
    }

    private func start() {
        guard !busy else { return }
        busy = true; error = nil
        let number = destination, goal = trimmedPurpose, choice = voicemail, fromAgent = suggested
        Task {
            defer { busy = false }
            do {
                try await controller.place(sessionID: sessionID, profile: profile, to: number, purpose: goal,
                                           voicemail: choice, suggested: fromAgent)
                to = ""; purpose = ""; voicemail = .hangUp; suggested = false
            } catch { self.error = phoneMessage(error) }
        }
    }
}

/// One call: its status, transcript, the assistant's question, "Tell the assistant", and Hang up.
struct PhoneCallSection: View {
    let controller: PhoneCallController
    let call: PhoneCallRecord
    @Binding var answers: [String: String]
    @Binding var messages: [String: String]
    /// Says once in the sheet that the transcript trails the call.
    var lagNote = false
    var readOnly = false

    var body: some View {
        Section {
            Text(call.statusText).font(Font.hq(.headline)).accessibilityIdentifier("phone.call.status")
            Text(call.purpose).font(Font.hq(.callout)).foregroundStyle(Color.hqLabel2)
            Text([call.recorded ? "Recorded" : "Not recorded", call.suggested ? "Suggested by your agent" : nil,
                  "If voicemail answers: \(call.voicemailChoice.title.lowercased())"].compactMap { $0 }.joined(separator: " · "))
                .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).accessibilityIdentifier("phone.call.recorded")
            if let note = call.straightToVoicemailNote {
                Text(note).font(Font.hq(.footnote)).accessibilityIdentifier("phone.call.voicemail-note")
            }
            if let note = call.endNote { Text(note).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).accessibilityIdentifier("phone.call.end-note") }
            ForEach(call.shownLines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.speaker(line.speaker)).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
                    Text(line.text)
                }
                .accessibilityElement(children: .combine)
            }
            if let question = call.question, call.active, !readOnly {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The assistant asks you").font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
                    Text(question.text).font(Font.hq(.body).weight(.semibold)).accessibilityIdentifier("phone.question")
                }
                if call.sendingAnswer == question.id {
                    Text("Sending your answer…")
                } else {
                    ForEach(question.choices, id: \.self) { choice in
                        Button(choice) { respond(question, choice) }
                    }
                    TextField("Your answer", text: Binding(get: { answers[call.id] ?? "" }, set: { answers[call.id] = $0 }))
                        .accessibilityIdentifier("phone.answer")
                    Button("Send answer") { respond(question, answers[call.id] ?? "") }
                        .disabled((answers[call.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let last = call.lastAnswer { Text("You answered: \(last)").font(Font.hq(.footnote)) }
            if call.active, call.state != .ending, !readOnly {
                // One line with a Send key: with the keyboard up, a tap on the Send row below can be spent closing it.
                TextField("Tell the assistant", text: Binding(get: { messages[call.id] ?? "" }, set: { messages[call.id] = $0 }))
                    .submitLabel(.send).onSubmit { tell() }
                    .accessibilityIdentifier("phone.tell")
                Button(call.sendingMessage ? "Sending…" : "Send") { tell() }
                    .disabled(call.sendingMessage || (messages[call.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("phone.tell.send")
            }
            if let issue = call.issue { Text(issue).font(Font.hq(.footnote)).foregroundStyle(.red).accessibilityIdentifier("phone.call.issue") }
            if call.active, !readOnly {
                Button("Hang up", role: .destructive) { Task { await controller.hangup(call.id) } }
                    .disabled(call.state == .ending)
            }
        } header: {
            Text("Call to \(phoneShown(call.to)) · \(call.placedAt.formatted(date: .abbreviated, time: .shortened))")
        } footer: {
            if lagNote, call.active || !call.lines.isEmpty {
                Text("The transcript can run a few seconds behind the call.").accessibilityIdentifier("phone.lag-note")
            }
        }
    }

    static func speaker(_ speaker: PhoneTranscript.Line.Speaker) -> String {
        switch speaker {
        case .assistant: return "Assistant"
        case .them: return "Them"
        case .you: return "You"
        }
    }

    private func respond(_ question: PhoneTranscript.Question, _ value: String) {
        let id = call.id
        Task {
            await controller.answer(id, question: question, with: value)
            if controller.call(id)?.answered.contains(question.id) == true { answers[id] = nil }
        }
    }

    private func tell() {
        let id = call.id, words = messages[call.id] ?? ""
        Task {
            if await controller.tell(id, words) { messages[id] = nil }
        }
    }
}

// MARK: - Settings › Phone Calls › Call history

struct PhoneHistoryView: View {
    let accountID: String
    private var controller: PhoneCallController { .shared(for: accountID) }

    var body: some View {
        let calls = controller.calls.sorted { $0.placedAt > $1.placedAt }
        Form {
            if calls.isEmpty {
                Section { Text("No calls yet.").foregroundStyle(Color.hqLabel2) }
            } else {
                Section {
                    ForEach(calls) { call in
                        NavigationLink {
                            PhoneHistoryDetailView(accountID: accountID, callID: call.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(phoneShown(call.to)).font(Font.hq(.body))
                                Text("\(call.placedAt.formatted(date: .abbreviated, time: .shortened)) · \(call.statusText)")
                                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .accessibilityIdentifier("phone.history.row")
                    }
                } footer: {
                    Text("Kept on this device for this account: the newest \(PhoneHistoryStore.maxCalls) calls.")
                }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
    }
}

struct PhoneHistoryDetailView: View {
    let accountID: String
    let callID: String
    @State private var answers: [String: String] = [:]
    @State private var messages: [String: String] = [:]
    private var controller: PhoneCallController { .shared(for: accountID) }

    var body: some View {
        Form {
            if let call = controller.call(callID) {
                PhoneCallSection(controller: controller, call: call, answers: $answers, messages: $messages, readOnly: true)
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .navigationTitle("Call")
    }
}
