// [threads] A thread runs with no screen of its own: the bot chat it hangs in draws it (docs/spec/3x-threads.md §4).

import Foundation

extension LiveChatSession {
    /// Opens the chat (or keeps it open) and hears the gateway without a screen. It is never the app's focused chat
    /// (`observing` stays false: nothing is marked read or seen for it), and the app model holds it like a chat still
    /// sending its queue, so opening it from anywhere gives this same chat.
    func listenOffScreen() {
        threadHold = true
        // On a screen already: `stopObserving` keeps it listening for as long as the hold stands.
        guard !observing else { return }
        if !drainingAway {
            drainingAway = true
            ticker.revive()
            if eventTask == nil { subscribe() }
            onDrainingAwayChange?(true)
        }
        if !started { beginOpen(failedOpen: false) }
    }

    /// The hold ends: off screen it stops listening once its reply has ended (`endAwayDrainIfDone`).
    func endThreadHold() { threadHold = false }

    /// §9: typed words this chat could not take went on in a thread. Their bubble leaves this chat (the thread draws
    /// them), with no "Couldn’t Send" card and nothing handed back. Messages queued behind it are held, as after any
    /// send that did not go out here: they are not sent into a chat that is not taking them.
    func sendWentToThread(_ localId: String) {
        AppLog.note("send", "send \(AppLog.tag(localId)) went on in a thread: \(logIds) could not take it now")
        removeMessage(localId)
        if turn.userAnchorId == localId { turn.userAnchorId = nil; turn.anchorPromptKey = nil }
        if turn.preparingSendId == localId { turn.preparingSendId = nil }
        parkQueue()
        settleFlags()
        changes.markState()
        scheduleFlush()
        onNotice?(ThreadRules.busyNotice)
    }

    /// §9: the thread could not send those words either (the gateway took no new chat, the link went): they come back
    /// to this chat's message box with the reason, as a send refused here does.
    func threadSendCameBack(_ text: String, reason: String) {
        AppLog.note("send", "a thread's send came back to \(logIds): \(AppLog.scrub(String(reason.prefix(100))))")
        sendFailure = SendFailure.make(reason: reason)
        changes.markState()
        scheduleFlush()
        returnWordsToDraft(text)
        onDraftReturned?(text, reason.isEmpty ? "Your message wasn’t sent." : reason)
    }

    /// Why the chat could not open or send, in words for the thread's line; nil while all is well.
    var threadProblem: String? {
        if case .failed(let reason) = openPhase { return reason }
        return messages.last(where: { $0.role == .user })?.error
    }
}
