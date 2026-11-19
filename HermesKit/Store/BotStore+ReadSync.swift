// [read-sync] A bot's unread dot is shared between this person's devices (a tester, 2026-11-16: "Reading a message in
// one app does not consistently update its unread indicator in the other"). The dot itself stays this device's own
// judgement (`BotUnreadState`: something written to you, never two bots talking); what travels is Hermes's read
// watermark on the bot's chat (`sessions.last_read_at`, the one the Sessions rows' `unread` is computed from):
//
// - A device that reads a bot's chat (an open that applied fresh history, Mark as Read, a turn that ended in front of
//   the person, leaving the chat) writes `PATCH /api/sessions/{id} {"unread": false}` when the watermark, as far as it
//   knows, doesn't yet cover what was seen. Mark as Unread writes `{"unread": true}` (the watermark at 0). A write the
//   gateway couldn't be reached for is owed and goes again; a read-only gateway gets none.
// - The roster doesn't carry the watermark and no list names a bot's hidden chat, so it is read from the chat's own row
//   (`GET /api/sessions/{id}`): for bots showing a dot or waiting for one after every roster and whenever the gateway
//   says its chats changed (`sessions.changed` fires for a watermark write; at most every ten seconds), and for every
//   bot at launch, on a reconnect, and at most every two minutes while chats keep changing (every ten on a gateway
//   that doesn't say when they change).
// - A watermark at or past the chat's newest activity means it was read, on some device: the dot goes. A watermark
//   older than that moves the point the chat's new rows are judged from. A watermark at 0 that wasn't 0 before is a
//   Mark as Unread from another device: the dot shows. A bot seen for the first time (a fresh install) takes the
//   gateway's word instead of starting with nothing.

import Foundation

nonisolated struct BotReadShare: Codable, Sendable, Hashable {
    /// The gateway's watermark for the bot's chat as last learnt or written (server seconds): 0 marked unread, -1 never
    /// read on any device, nil not known.
    var watermark: Double?
    /// A write the gateway hasn't taken yet: the activity read through, or -1 for a Mark as Unread.
    var owed: Double?
}

extension BotStore {
    /// The slack between a message's own time and the chat's activity time (as `BotUnreadState.left`).
    static let readTolerance = 2.0

    func readShare(_ name: String) -> BotReadShare { device.readShare?[name] ?? BotReadShare() }

    private func setReadShare(_ name: String, _ share: BotReadShare) {
        device.readShare = (device.readShare ?? [:]).merging([name: share]) { $1 }
    }

    private func sharesReads(_ profile: RosterProfile) -> RosterSessionRef? {
        guard timing.sharesReads, !stopped, let canonical = profile.canonicalSession, !canonical.id.isEmpty,
              RosterRules.holdsMessages(canonical) else { return nil }
        return canonical
    }

    // MARK: Writes

    /// This device read the bot's chat through `through` (server seconds; the chat's own activity when nil or older).
    /// Written when the watermark isn't known to cover that. `explicit`: the person opened the chat or chose Mark as
    /// Read, so a watermark that may be out of date isn't trusted (`knowsWatermark`: another device may have marked
    /// the chat unread since); the passive reads (a turn seen ending, leaving, the chat staying in front) go by what
    /// is known, or a chat left open would be written every few minutes.
    func shareRead(_ profile: RosterProfile, through: Double? = nil, explicit: Bool = false) {
        guard !readOnlyGateway, !readShareRefused, let canonical = sharesReads(profile) else { return }
        let seen = max(through ?? 0, canonical.lastActive ?? 0)
        guard seen.isFinite, seen > 0 else { return }
        let name = profile.name
        var share = readShare(name)
        if let mark = share.watermark, mark > 0, mark >= seen, !explicit || knowsWatermark(name) { return }
        if share.owed == nil { readPrior[name] = share.watermark }
        share.owed = seen
        share.watermark = seen
        setReadShare(name, share)
        readFreshAt[name] = .now
        persistState()
        sendOwedRead(name)
    }

    /// What this device holds of a bot's watermark is current: learnt or written since the gateway last said its chats
    /// changed (5 s of slack: its own write is one such change), or, on a gateway that doesn't say, within
    /// `readFreshFor`.
    private func knowsWatermark(_ name: String) -> Bool {
        guard let at = readFreshAt[name] else { return false }
        if client.latestReady?["change_events"]?.bool == true { return readChangedAt.map { at + .seconds(5) > $0 } ?? true }
        return ContinuousClock.now - at < timing.readFreshFor
    }

    /// Mark as Unread reaches the other device: the watermark goes to 0.
    func shareUnread(_ profile: RosterProfile) {
        guard !readOnlyGateway, !readShareRefused, sharesReads(profile) != nil else { return }
        let known = readShare(profile.name)
        if known.owed == nil { readPrior[profile.name] = known.watermark }
        setReadShare(profile.name, BotReadShare(watermark: 0, owed: -1))
        readFreshAt[profile.name] = .now
        persistState()
        sendOwedRead(profile.name)
    }

    /// The chat in front of the person saw a turn end (the app in front, the bot's own chat): read through now.
    func noteReadOnScreen(profile name: String, sessionId: String) {
        guard isAppActive, let profile = profile(named: name), isChatInFront(profile, sessionId: sessionId),
              !device.unread.isMarked(profile) else { return }
        shareRead(profile, through: Date().timeIntervalSince1970)
    }

    /// One write per bot at a time. `retry`: a read owed from earlier is only still true while the chat hasn't moved
    /// since: newer rows were never seen, and "read now" would cover them.
    private func sendOwedRead(_ name: String, retry: Bool = false) {
        guard !readWritesOut.contains(name), !stopped, !readOnlyGateway, !readShareRefused, let owed = readShare(name).owed,
              let profile = profile(named: name), let canonical = sharesReads(profile) else { return }
        if retry, owed >= 0, (canonical.lastActive ?? 0) > owed + Self.readTolerance {
            AppLog.trace("bots", "read sync \(name): the chat moved since it was read, the owed read is dropped")
            setReadShare(name, BotReadShare())
            persistState()
            return
        }
        readWritesOut.insert(name)
        let client = self.client, id = canonical.id
        Task { [weak self] in
            var failure: (any Error)?
            do {
                try await SessionWrite.patch(client, id: id, profile: name, ["unread": .bool(owed < 0)])
            } catch {
                failure = error
            }
            self?.readWriteEnded(name, owed: owed, error: failure)
        }
    }

    private func readWriteEnded(_ name: String, owed: Double, error: (any Error)?) {
        readWritesOut.remove(name)
        guard !stopped else { return }
        var share = readShare(name)
        if let error {
            if let refusal = error as? HTTPError {
                // The gateway answered: it won't take this. An older Hermes that refuses every edit while its gateway
                // owns the profile (SessionWrite's maintenance refusal), or one that doesn't know the field, is not
                // asked again this run; the dots stay this device's own, as before.
                AppLog.note("bots", "read sync \(name): the gateway refused the write (HTTP \(refusal.status))")
                if [405, 409, 422, 501].contains(refusal.status) { readShareRefused = true }
                // Back to what was known before this write (a 0 learnt earlier is not news again).
                share = BotReadShare(watermark: readPrior[name] ?? nil, owed: nil)
            } else if error is CancellationError {
                share = BotReadShare(watermark: readPrior[name] ?? nil, owed: nil)
            } else {
                AppLog.trace("bots", "read sync \(name): not sent, owed")       // offline: `retryOwedReads`
            }
        } else {
            AppLog.trace("bots", "read sync \(name): \(owed < 0 ? "unread" : "read") written")
            if share.owed == owed { share.owed = nil }
            readFreshAt[name] = .now
        }
        if share != readShare(name) {
            setReadShare(name, share)
            persistState()
        }
        if error == nil, share.owed != nil { sendOwedRead(name) }      // a newer read was noted meanwhile
    }

    /// Writes the gateway couldn't be reached for go again (after every roster, and when the link is back).
    func retryOwedReads() {
        guard timing.sharesReads, let shares = device.readShare else { return }
        for (name, share) in shares where share.owed != nil { sendOwedRead(name, retry: true) }
    }

    // MARK: Learning the watermark

    /// The gateway says its chats changed (a watermark write is one such change), or the link came back: the
    /// watermarks are read again, at most every `readLearnGap`. Not while the app is off screen (the roster read on the
    /// way back does it).
    func readsMayHaveChanged(sweep: Bool = false) {
        guard timing.sharesReads, !stopped else { return }
        readChangedAt = .now
        // Off screen nothing is read; whatever changed meanwhile is found by the roster read on the way back.
        if sweep || !isAppActive { readSweptAt = nil }
        guard isAppActive, readLearnTask == nil else { return }
        let wait = readLearntAt.map { max(.zero, timing.readLearnGap - (ContinuousClock.now - $0)) } ?? .zero
        readLearnTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            self.readLearnTask = nil
            self.learnReads(sweeps: true)
        }
    }

    /// Queues a read of the watermark for every bot it can change the dot of: those showing one or waiting for one,
    /// those seen for the first time, and (`sweeps`, at most every `gap`) every bot with a chat, which is how a
    /// Mark as Unread made elsewhere is found.
    func learnReads(sweeps: Bool, gap: Duration? = nil) {
        guard timing.sharesReads, !stopped, !readShareAbsent, phase == .full else { return }
        readLearntAt = .now
        let every = gap ?? timing.readSweepGap
        let sweep = sweeps && (readSweptAt.map { ContinuousClock.now - $0 >= every } ?? true)
        if sweep {
            readSweptAt = .now
        } else if sweeps, readSweepTask == nil, let last = readSweptAt {
            // Something changed since the last read of every bot: the next one follows when it falls due, so a Mark
            // as Unread made elsewhere is found even when nothing else changes afterwards. Off screen it waits for
            // the roster read on the way back.
            readSweepTask = Task { [weak self] in
                try? await Task.sleep(until: last + every, clock: .continuous)
                guard let self, !Task.isCancelled else { return }
                self.readSweepTask = nil
                if self.isAppActive { self.learnReads(sweeps: true, gap: gap) } else { self.readSweptAt = nil }
            }
        }
        for profile in profiles {
            guard sharesReads(profile) != nil else { continue }
            let name = profile.name
            let dotted = device.unread.isMarked(profile) || device.unread.held(name) != nil
            guard dotted || sweep || readFirstSight.contains(name) else { continue }
            if !readLearnQueue.contains(name), !readLearnsOut.contains(name) { readLearnQueue.append(name) }
        }
        pumpReadLearns()
    }

    private func pumpReadLearns() {
        while readLearnsOut.count < 2, !readLearnQueue.isEmpty {
            let name = readLearnQueue.removeFirst()
            guard !stopped, let profile = profile(named: name), let canonical = sharesReads(profile) else { continue }
            readLearnsOut.insert(name)
            let client = self.client
            let path = "/api/sessions/\(HistoryRequest.encodePathSegment(canonical.openId))"
            Task { [weak self] in
                // The chat's own row. `last_read_at`: a number, null (never read anywhere), or missing altogether on
                // a Hermes older than read state.
                var answer: BotReadAnswer = .failed
                if let data = try? await client.get(path, [URLQueryItem(name: "profile", value: name)]),
                   let row = (try? JSONValue.parseFast(data))?.object {
                    if let value = row["last_read_at"] {
                        answer = .mark(RosterText.number(value).flatMap { $0 >= 0 ? $0 : nil } ?? -1)
                    } else {
                        answer = .unsupported
                    }
                }
                self?.readLearnt(name, answer)
            }
        }
    }

    enum BotReadAnswer: Sendable, Equatable { case failed, unsupported, mark(Double) }

    /// The gateway's watermark for a bot's chat arrived. See the head of this file for what each value does.
    func readLearnt(_ name: String, _ answer: BotReadAnswer) {
        readLearnsOut.remove(name)
        defer { pumpReadLearns() }
        guard !stopped else { return }
        let mark: Double
        switch answer {
        case .failed: return
        case .unsupported:
            // No read state on this Hermes: nothing to learn, this run.
            if !readShareAbsent { AppLog.note("bots", "read sync: this gateway keeps no read watermark; dots stay on this device") }
            readShareAbsent = true
            readLearnQueue = []
            return
        case .mark(let value): mark = value
        }
        let first = readFirstSight.remove(name) != nil
        guard let profile = profile(named: name), let canonical = profile.canonicalSession else { return }
        var share = readShare(name)
        // This device's own write is on its way: its answer is the newer word.
        guard share.owed == nil, !readWritesOut.contains(name) else { return }
        let before = share.watermark
        share.watermark = mark
        readFreshAt[name] = .now
        var saved = false
        if share != readShare(name) {
            setReadShare(name, share)
            saved = true
        }
        let activity = canonical.lastActive ?? 0
        let inFront = isChatInFront(profile, sessionId: nil)
        let marked = device.unread.isMarked(profile), waiting = device.unread.held(name) != nil
        let holds = timing.readsBotSaid && RosterRules.holdsMessages(canonical)
        var changed = false
        if mark > 0 {
            // Read on some device through `mark`: nothing up to there earns a dot here any more.
            device.unread.left(name, seenThrough: mark, tolerance: 0)
            if mark + Self.readTolerance >= activity {
                if marked || waiting {
                    AppLog.trace("bots", "read sync \(name): read on another device, the dot goes")
                    device.unread.acknowledge(profile)
                    unreadHeldAt[name] = nil
                    changed = true
                }
            } else if !inFront, canonical.messageCount != 0, (marked && before != mark) || (first && !marked && !waiting) {
                // The chat moved after it was last read: a dot set for what was read since is judged again from the
                // read on, and a bot met for the first time takes the gateway's word, both only for something written
                // to you ([botunread]: the tail read settles it). Where the tail can't be read, the dot stands.
                if holds {
                    device.unread.rejudge(profile, since: mark)
                    unreadHeldAt[name] = .now
                    changed = true
                } else if !marked {
                    device.unread.mark(profile)
                    changed = true
                }
            }
        } else if mark == 0, before != 0, !inFront, !marked, canonical.messageCount != 0 {
            AppLog.trace("bots", "read sync \(name): marked unread on another device")
            device.unread.mark(profile)
            unreadHeldAt[name] = nil
            changed = true
        }
        guard changed || saved else { return }
        persistState()
        if changed {
            rebuild()
            refreshBotSaid()        // a bot now waiting is owed a read of its chat
        }
    }
}
