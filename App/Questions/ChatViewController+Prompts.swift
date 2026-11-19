import UIKit

// The chat screen's side of the prompt cells (spec 1x §4.2): taps and the countdown go to its prompts controller.

extension ChatViewController: ChatPromptCellHandling {
    func promptCard(_ id: String, tapped button: ApprovalButton) { promptsUI?.cardTapped(id, button) }
    func promptCardShowAll(_ id: String) { promptsUI?.showAll(id) }
    func promptExpiryLabel(clockKey: String, firstSeen: Date) -> String { promptsUI?.expiryLabel(firstSeen: firstSeen) ?? "" }
    func draftCard(_ draft: DraftCardRow, tapped button: DraftButton) { draftCardTapped(draft, button) }   // [drafts]
    func draftCardToggle(rowId: String) { chatCellToggle(rowId: rowId) }
    func clarifyCardAnswer(_ card: SettledClarifyCard) { promptsUI?.answerLater(card) }   // [questions]
    // [asks] askCard(_:chose:), askCardOther, askCardOpen: App/Asks/ChatViewController+Asks.swift.
    /// The conversation a draft answers, in a sheet (the step sheet's blocks, on the app's glass): every message the
    /// bot attached, whole, each under who wrote it and when; a long press copies one. A conversation opens at its
    /// newest message (scroll up to read back); one message opens at its top.
    func draftCardThread(_ draft: DraftCardRow) {
        let thread = draft.draft.thread
        guard !thread.isEmpty else { return }
        let blocks = thread.map { ChatBlocksViewController.Block(label: [$0.from, $0.when].filter { !$0.isEmpty }.joined(separator: " · "), text: $0.text, mono: false) }
        let page = ChatBlocksViewController(heading: nil, blocks: blocks)
        page.view.accessibilityIdentifier = "draft.thread.sheet"
        present(ChatSheet.wrap(page, title: thread.count == 1 ? "Previous Message" : "Conversation"), animated: true)
        guard thread.count > 1 else { return }
        // Once the sheet has its size (it is still rising): the newest message, at the bottom.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak page] in
            guard let scroll = page?.view.subviews.compactMap({ $0 as? UIScrollView }).first else { return }
            scroll.layoutIfNeeded()
            let bottom = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
            scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, bottom)), animated: false)
        }
    }
}

// [questions] A skipped question answered later (HermesKit/Chat/PromptLogic.swift `ClarifyLate`).
extension ChatViewController {
    /// Later answers still waiting behind a running reply: their cards show them as answered too.
    var clarifyLateQueuedTexts: [String] {
        (session as? LiveChatSession)?.queuedMessages.map(\.text).filter { $0.hasPrefix(ClarifyLate.markLead) } ?? []
    }

    /// The chat changed: a card whose later answer arrived (from here, another device, the queue going out) is drawn
    /// again. Returns the messages to rebuild.
    func clarifyLateMessagesToRebuild() -> [String] {
        let messages = session.messages
        let now = ClarifyLate.answers(messages, queued: clarifyLateQueuedTexts)
        guard now != clarifyLateShown else { return [] }
        let changed = Set(now.keys).union(clarifyLateShown.keys).filter { now[$0] != clarifyLateShown[$0] }
        clarifyLateShown = now
        return messages.filter { m in
            m.role == .assistant && m.parts.contains { part in
                guard case .tool(let call) = part, call.name == "clarify",
                      let rows = ClarifySettled.rows(fromSummary: call.summary), !rows.isEmpty else { return false }
                return changed.contains(ClarifyLate.key(rows.map(\.question)))
            }
        }.map(\.id)
    }

    /// The newest settled clarify card asking these questions (`ClarifyLate.key`): its message, and whether a question
    /// on it went unanswered.
    func settledClarify(key: String) -> (messageId: String, hasBlank: Bool)? {
        for message in session.messages.reversed() where message.role == .assistant {
            for part in message.parts {
                guard case .tool(let call) = part, call.name == "clarify",
                      let rows = ClarifySettled.rows(fromSummary: call.summary), !rows.isEmpty,
                      ClarifyLate.key(rows.map(\.question)) == key else { continue }
                return (message.id, rows.contains { $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }
        return nil
    }

    /// Answer Now's Send: the answers go into the chat as a message of yours (its bubble reads as the answers alone);
    /// the card then shows them.
    func sendLateAnswer(_ text: String, messageId: String) {
        AppLog.trace("questions", "late answer sent \(logTag)")
        Haptics.play(.selection)
        // `display` given: the words go out as they are (a task's chat wraps typed words; the mark must lead).
        sendFromCard(text, display: text)
        rebuildMessage(messageId)
    }
}
