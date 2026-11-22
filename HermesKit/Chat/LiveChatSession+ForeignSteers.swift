// [foreign-steer] A message sent into a running reply from another device shows here while the reply still runs.
//
// A tester 2026-11-19: the same chat open on an iPhone and a Mac; a message sent from the iPhone while the bot was
// replying showed on the iPhone at once, and on the Mac only when the reply ended or was stopped. Hermes tells nobody
// when it takes such a message: it publishes no event for it, and the chat's history read is cut after the turn's
// prompt while the turn runs (so stored partial rows never show beside the live bubble), which cuts the message too.
// What Hermes does keep is the running turn's own record, which `session.activate` answers at any time without a
// history read: `inflight.corrections` (the messages steered into the turn) and `queued.user` (one it holds for after).
//
// So while a turn runs in the chat on screen, each `sessions.changed` (Hermes sends one whenever the turn stores a
// row) is also a reason to ask for that record, at most once every few seconds, and to draw what it holds that the
// chat doesn't show: the message's bubble under the reply as it stands, with whatever the bot says next below it, the
// way the sending device draws its own (`beginSteer`). Nothing else of the answer is applied: the turn's state and its
// reply text stay the stream's. The end-of-turn read then puts the stored rows in their places, as it always has.

import Foundation

nonisolated enum ForeignSteerRules {
    /// The least time between two looks.
    static let gap: TimeInterval = 3

    /// The steers of `corrections`, in order, that `shown` (the user messages drawn after the turn's prompt, oldest
    /// first) doesn't show yet. Each shown message accounts for one steer, or for several that Hermes joined into one
    /// stored row, so the same words sent twice are two bubbles.
    static func missing(_ corrections: InflightCorrections, shown: [String]) -> [String] {
        var next = 0
        var held: Int?
        var out: [String] = []
        for text in corrections.texts {
            if let held, corrections.covers(shown[held], text) { continue }
            if let found = (next..<shown.count).first(where: { corrections.covers(shown[$0], text) }) {
                held = shown[found].contains(InflightCorrections.joinMarker) ? found : nil
                next = found + 1
            } else {
                held = nil
                out.append(text)
            }
        }
        return out
    }
}

extension LiveChatSession {
    /// A turn runs in the chat on screen and the gateway says something moved: look for another device's message, now
    /// or when the gap since the last look has passed.
    func scheduleSteerLook() {
        guard observing, openSettled, turn.busy, turn.turnLive, turn.waitingForOwner == nil, runtimeSessionId != nil,
              !activating, !reconnectOwnsTail else { return }
        guard steerLookTask == nil else { steerLookOwed = true; return }
        let wait = lastSteerLookAt.map { max(0, ForeignSteerRules.gap - Date().timeIntervalSince($0)) } ?? 0
        steerLookTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            await self?.lookForForeignSteers()
            guard let self else { return }
            self.steerLookTask = nil
            if self.steerLookOwed { self.steerLookOwed = false; self.scheduleSteerLook() }
        }
    }

    private func lookForForeignSteers() async {
        guard observing, turn.busy, turn.turnLive, !activating, let rid = runtimeSessionId else { return }
        let started = turn.turnStartedAt
        lastSteerLookAt = Date()
        var params: [String: JSONValue] = ["session_id": .string(rid), "cols": 96, "omit_messages": true]
        if let profileParam { params["profile"] = .string(profileParam) }
        guard let snapshot = try? await client.call("session.activate", .object(params), timeout: .seconds(15)) else { return }
        // The same turn, still running here and there: anything else is the stream's or a reconnect's to settle.
        guard observing, turn.busy, turn.turnLive, !activating, runtimeSessionId == rid, turn.turnStartedAt == started,
              snapshot["running"]?.bool == true, (snapshot["session_id"]?.nonEmptyString ?? rid) == rid else { return }
        applyForeignSteers(snapshot)
    }

    /// Draws the snapshot's steers and held prompt that the chat doesn't show. Internal for the tests.
    func applyForeignSteers(_ snapshot: JSONValue) {
        var added = 0
        if let inflight = snapshot["inflight"]?.object, let corrections = InflightCorrections(inflight) {
            let anchor = turnAnchorIndex()
            let shown = messages[(anchor + 1)...].filter { $0.role == .user }.map(\.plainText)
            for text in ForeignSteerRules.missing(corrections, shown: shown) {
                // As the sending device draws its own: the live reply is sealed where it stands, the message goes
                // under it, and what the bot says next starts a bubble below.
                flushDeltas()
                if let sid = turn.streamId, indexById[sid] != nil { updateMessage(sid) { $0.isStreaming = false } }
                turn.streamId = nil
                turn.openPart = nil
                localCounter += 1
                let id = "local-user-correction-\(localCounter)"
                appendMessage(ChatMessage(id: id, role: .user, parts: [.text(PhoneChatText.shown(text))], timestamp: Date(), rowId: nil,
                                          phoneResultText: PhoneChatText.resultText(text)))
                turn.correctionIds.insert(id)
                added += 1
            }
        }
        // A message Hermes holds for after this reply (sent from another device while it ran).
        if let queued = snapshot["queued"]?["user"]?.nonEmptyString,
           !queuedMessages.contains(where: { Hydration.userDisplayKey($0.text) == Hydration.userDisplayKey(queued) }),
           !messages.suffix(4).contains(where: { $0.role == .user && Hydration.userDisplayKey($0.plainText) == Hydration.userDisplayKey(queued) }) {
            localCounter += 1
            appendMessage(ChatMessage(id: "local-user-queued-\(localCounter)", role: .user, parts: [.text(PhoneChatText.shown(queued))], timestamp: Date(), rowId: nil,
                                          phoneResultText: PhoneChatText.resultText(queued)))
            added += 1
        }
        guard added > 0 else { return }
        AppLog.trace("turn", "foreign steer \(logIds): \(added) message(s) from another device drawn under the running reply")
        changes.markState()
        scheduleFlush()
    }
}
