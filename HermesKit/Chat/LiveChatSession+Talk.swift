// Live voice in the chat (docs/spec/3x-talk.md §2.3, contract `ChatVoiceTurns`). A spoken turn is an ordinary send:
// the same optimistic bubble, the same 4009 retry window, the same resume-once, the same refusal card. The only
// difference on the wire is `interrupted: true` after a barge-in (§3.6).

import Foundation

extension LiveChatSession: ChatVoiceTurns {
    /// A chat that is gone from the gateway cannot hold a conversation. The groups stream adds its rooms here (T25).
    var allowsTalk: Bool { !chatGone }

    var voiceClient: any GatewayClient { client }

    var canReopen: Bool { menus.isBotChat || storedSessionId != nil || resolvedStoredId != nil }

    func sendSpoken(_ text: String, interrupted: Bool) {
        guard !ChatText.trimmed(text).isEmpty else { return }
        flushDeltas()
        // Spoken over a running reply: the reply stops and these words are the next turn, never a queued message
        // (the desktop's voice conversation does the same).
        let stopped = interruptForVoice()
        if (!queuedMessages.isEmpty && !isQueueParked) || !(interrupted || stopped) {
            // Typed messages are waiting their turn: the usual send keeps the order.
            send(text)
            return
        }
        unparkQueue()
        beginSend(text, queued: false, interrupted: true)
    }

    /// Stops the running reply for a spoken message. True when one was running.
    private func interruptForVoice() -> Bool {
        guard turn.busy else { return false }
        stop()
        return true
    }

    var newestReply: SpokenReply? {
        guard let last = messages.last, last.role == .assistant else { return nil }
        return LiveChatSession.spoken(last)
    }

    func spokenReplies(since: Date) -> [SpokenReply] {
        messages.suffix(Self.recentReplyWindow).compactMap { message -> SpokenReply? in
            guard message.role == .assistant, message.sender == nil, !message.interrupted, message.error == nil, !message.isStreaming,
                  let at = message.timestamp, at >= since else { return nil }
            let reply = LiveChatSession.spoken(message)
            guard !ChatText.trimmed(reply.text).isEmpty, !Self.isInterruptedSentinel(reply.text) else { return nil }
            return reply
        }
    }

    /// How far back from the newest message `spokenReplies` looks.
    static let recentReplyWindow = 24

    /// What Hermes stores for a turn stopped while it waited on the model ("Operation interrupted: waiting for model
    /// response (4.7s elapsed)."); the live stream strips it (04 §5.3), a history read does not.
    nonisolated static func isInterruptedSentinel(_ text: String) -> Bool {
        ChatText.trimmed(text).hasPrefix("Operation interrupted:")
    }

    func spokenText(messageId: String) -> SpokenReply? {
        messages.last { $0.id == messageId && $0.role == .assistant }.map(LiveChatSession.spoken)
    }

    /// The words of one assistant message: its text parts in order (never reasoning, never tools).
    nonisolated static func spoken(_ message: ChatMessage) -> SpokenReply {
        let text = message.parts.compactMap { part -> String? in
            if case .text(let words) = part, !words.isEmpty { return words }
            return nil
        }.joined(separator: "\n\n")
        return SpokenReply(messageId: message.id, text: text, pending: message.isStreaming)
    }

    // [gpt-live] (docs/spec/3x-gpt-live.md §4)

    func sendDelegated(_ text: String, voiceContext: String) {
        guard !ChatText.trimmed(text).isEmpty else { return }
        flushDeltas()
        // A request made while the reply runs goes into it, as typed words do (`session.redirect`): stopping it threw
        // away the work under way (owner, 2026-10-28 20:46: "Operation interrupted" on searches the voice had asked for
        // three seconds before).
        if steersTyped(text, display: nil, attachments: []) {
            steerDelegated(text, voiceContext: voiceContext)
            return
        }
        let stopped = interruptForVoice()
        unparkQueue()
        beginSend(text, queued: false, interrupted: stopped, voiceContext: voiceContext)
    }

    /// The request's bubble shows at once under the running reply. Not taken (the reply ended first, a gateway without
    /// redirect): it goes out as its own request, stopping the reply if one still runs, never into the queue.
    private func steerDelegated(_ text: String, voiceContext: String) {
        let steer = beginSteer(shown: text)
        let previous = typedSteerChain
        typedSteerChain = Task { [weak self] in
            await previous?.value
            guard let self, await self.finishSteer(steer, text: text) == .failed else { return }
            AppLog.note("send", "voice steer \(AppLog.tag(steer.localId)) on \(self.logIds) not taken; sent as its own request")
            let stopped = self.interruptForVoice()
            self.unparkQueue()
            self.beginSend(text, queued: false, interrupted: stopped, voiceContext: voiceContext)
        }
    }

    var onDelegationRefused: (() -> Void)? {
        get { onVoiceLiveRefused }
        set { onVoiceLiveRefused = newValue }
    }

    var runningToolTitle: String? {
        guard let last = messages.last, last.role == .assistant, last.isStreaming else { return nil }
        for part in last.parts.reversed() {
            if case .tool(let call) = part, call.state == .running { return call.title.isEmpty ? call.name : call.title }
        }
        return nil
    }

    var spokenHistory: [(assistant: Bool, text: String)] { LiveChatSession.spokenTurns(messages) }

    nonisolated static func spokenTurns(_ messages: [ChatMessage]) -> [(assistant: Bool, text: String)] {
        messages.compactMap { message -> (assistant: Bool, text: String)? in
            switch message.role {
            case .user:
                let words = message.parts.compactMap { part -> String? in
                    if case .text(let text) = part { return text }
                    return nil
                }.joined(separator: "\n")
                return words.isEmpty ? nil : (false, words)
            case .assistant:
                let words = SpeechText.sanitizeForSpeech(LiveChatSession.spoken(message).text)
                return words.isEmpty ? nil : (true, words)
            case .system:
                return nil
            }
        }
    }

    /// How long a conversation's start waits for the chat to finish opening, and for the read further back.
    static let seedOpenWait: Duration = .seconds(3)
    static let seedReadWait: Duration = .seconds(2)
    /// Backend rows the read further back asks for (tool rows count, so this is a few dozen turns).
    static let seedReadRows = 120

    /// The seed of a live voice session. Two things left the voice knowing next to nothing of the chat (owner,
    /// 2026-11-16): Talk from a bot's menu started before the chat had loaded (an empty seed), and a loaded chat holds
    /// one page of 24 backend rows, often three or four turns. So the open is waited for, and when the chat goes
    /// further back than what is loaded and the seed has room, one read fetches more. The transcript is not touched.
    func spokenSeed() async -> [(assistant: Bool, text: String)] {
        let deadline = ContinuousClock.now + Self.seedOpenWait
        while ContinuousClock.now < deadline, !(openSettled || openFinished), !chatGone {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let loaded = spokenHistory
        let budget = LiveVoiceWire.wideSeed
        let filled = loaded.count >= budget.messages
            || loaded.reduce(0) { $0 + min($1.text.count, budget.perTurn) } >= budget.chars
        guard !filled, hasOlder || loaded.isEmpty, let stored = readSessionId else { return loaded }
        var request = HistoryRequest(storedSessionId: stored, profile: profileParam, limit: Self.seedReadRows)
        request.inlineImages = false
        let client = self.client, features = perfFeatures
        let read = Task { try? await HistoryAPI.fetchAndFold(client: client, request: request, features: features, cut: true) }
        let limit = Task { try? await Task.sleep(for: Self.seedReadWait); read.cancel() }
        let page = await read.value
        limit.cancel()
        guard let page else {
            AppLog.note("talk", "voice seed \(logIds): the read further back didn't answer; \(loaded.count) loaded turns used")
            return loaded
        }
        let further = LiveChatSession.spokenTurns(page.1.messages)
        // A reply still streaming or a message just sent is only in what is loaded.
        return further.count > loaded.count ? further : loaded
    }

    var openQuestion: VoiceQuestion? {
        guard let clarify = prompts.clarify, !clarify.sending else { return nil }
        let open = clarify.questions.filter { clarify.lockedAnswers[$0.qid] == nil }
        guard !open.isEmpty else { return nil }
        return VoiceQuestion(id: clarify.id, spoken: VoiceQuestionText.spoken(open))
    }

    func answerQuestion(_ id: String, spoken: String) {
        guard let clarify = prompts.clarify, clarify.id == id else { return }
        let answers = clarify.questions.map { question -> (qid: String, answer: String?) in
            if let locked = clarify.lockedAnswers[question.qid] { return (question.qid, locked) }
            return (question.qid, VoiceQuestionText.answer(spoken, to: question))
        }
        Task { [weak self] in
            do {
                try await self?.sendClarify(id, answers: answers)
            } catch {
                AppLog.note("talk", "spoken answer to a question not sent: \(AppLog.scrub(String(describing: error)))")
            }
        }
    }

    /// `voiceHold` changed (called from its `didSet`): a chat left on screen-less hold lets go once the conversation ends.
    func voiceHoldChanged() {
        if !voiceHold { endAwayDrainIfDone() }
    }
}
