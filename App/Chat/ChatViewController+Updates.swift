import UIKit

// [updates] A group's line ("With Home · 18 messages", "Helper finished · 12 more") opens its sheet
// (UpdatesSheet.swift). The chat behind it stays exactly as it is.

extension ChatViewController {
    /// The line was tapped.
    func presentUpdates(line row: ChatRow) {
        Haptics.play(.selection)
        // Find's match is one of this line's folded replies: the sheet opens at it.
        openUpdates(lineId: row.id, at: updatesFound?.line == row.id ? updatesFound?.member : nil)
    }

    /// Opens the sheet of the line `lineId`, at the member `member` when one is named (Find landed on a folded reply).
    func openUpdates(lineId: String, at member: String?) {
        guard let row = rows.first(where: { $0.id == lineId }) ?? model.allRows.first(where: { $0.id == lineId }),
              let opened = UpdateGroups.opened(line: row.id, messageId: row.messageId, input: input()) else { return }
        // Already open on this line (Find stepping through a talk's folded replies): it moves to the next one.
        if let sheet = updatesSheet, updatesLine?.id == lineId, sheet.viewIfLoaded?.window != nil {
            sheet.update(opened)
            if let member { sheet.show(member) }
            return
        }
        guard presentedViewController == nil else { return }
        view.endEditing(true)
        let page = UpdatesSheetViewController(opened: opened, focus: member, hooks: updatesHooks())
        updatesSheet = page
        updatesLine = (row.id, row.messageId)
        // [ipad] In two panes it hangs off its line, pointing at it.
        let cell = tableView.visibleCells.compactMap { $0 as? ChatToolCell }.first { $0.rowId == lineId }
        // `bar: false`: the line it points at already says its name and count.
        PanePopover.hangNext(on: cell?.groupAnchor, from: self, size: CGSize(width: 420, height: 560), bar: false)
        let sheet = ChatSheet.wrap(page, title: opened.title)
        if sheet.modalPresentationStyle == .popover, let popover = sheet.popoverPresentationController {
            // Never over the chat's title or the message box: it keeps between them.
            popover.popoverLayoutMargins = UIEdgeInsets(top: view.safeAreaInsets.top + 6, left: 10,
                                                        bottom: max(view.safeAreaInsets.bottom, view.bounds.maxY - composer.frame.minY) + 6,
                                                        right: 10)
        }
        present(sheet, animated: true)
    }

    /// The chat's rows changed: an open sheet shows what its line holds now. A line that is gone (its run is one
    /// update now, or its first message left the chat) leaves the sheet as it was.
    func refreshUpdatesSheet() {
        guard updatesSheet != nil, !updatesRefreshQueued else { return }
        updatesRefreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.updatesRefreshQueued = false
            guard let sheet = self.updatesSheet, let line = self.updatesLine, sheet.viewIfLoaded?.window != nil,
                  let opened = UpdateGroups.opened(line: line.id, messageId: line.messageId, input: self.input()) else { return }
            sheet.update(opened)
        }
    }

    private func updatesHooks() -> UpdatesSheetViewController.Hooks {
        UpdatesSheetViewController.Hooks(
            stepPage: { [weak self] messageId, call in
                guard let self else { return nil }
                let page = self.activity.stepDetail(messageId: messageId, call: call)
                page.title = StepDetailViewController.title(call)
                return page
            },
            stepsPage: { [weak self] messageId, calls in
                let list = StepsListViewController(steps: calls.map { .init(messageId: messageId, call: $0) }, live: false)
                list.openStep = { [weak self] step in
                    guard let self else { return UIViewController() }
                    let page = self.activity.stepDetail(messageId: step.messageId, call: step.call)
                    page.title = StepDetailViewController.title(step.call)
                    return page
                }
                return list
            },
            openFile: { [weak self] path in self?.activityCellOpenFile(path: path) },
            reviewChanges: { [weak self] in
                // The Changes page takes the sheet's place.
                self?.dismiss(animated: true) { self?.activityCellReviewChanges(highlighting: nil) }
            },
            openLink: { [weak self] url, page in
                guard let self else { return }
                if MarkdownMedia.ref(fromLink: url) != nil {
                    // A picture or a file the words name: the chat opens it, in the sheet's place.
                    self.dismiss(animated: true) { self.chatCellOpen(url: url) }
                } else if self.openFileLink(url) {
                    return
                } else {
                    LinkOpener.open(url, from: page)
                }
            },
            menu: { [weak self] member, source in self?.updatesMenu(member, source: source) })
    }

    /// Held on a member's card: Copy, Read Aloud and Share of its words (a work line, a files member and a note have
    /// none).
    private func updatesMenu(_ member: UpdateMemberRow, source: UIView) -> UIMenu? {
        guard let result = member.result else { return nil }
        let text = RowHoldMenu.resultText(title: result.title, result: result.result, delivery: result.delivery || result.cron)
        guard !text.isEmpty else { return nil }
        let copy = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak source] _ in
            UIPasteboard.general.string = text
            Haptics.play(.success)
            MenusHUD.show("Copied", in: source?.window)
        }
        copy.accessibilityIdentifier = "row.copy"
        var children: [UIMenuElement] = [copy]
        if voice.talkReadsAloud {
            let reading = voice.talkIsReading(messageId: member.messageId) == true
            let read = UIAction(title: reading ? "Stop Reading" : "Read Aloud",
                                image: UIImage(systemName: reading ? "stop.circle" : "speaker.wave.2")) { [weak self] _ in
                self?.voice.talkToggleRead(messageId: member.messageId, text: text)
            }
            read.accessibilityIdentifier = "row.readAloud"
            children.append(read)
        }
        let share = UIAction(title: MenuWords.share, image: UIImage(systemName: "square.and.arrow.up")) { [weak self, weak source] _ in
            self?.menus?.shareMessage(text, from: source)
        }
        share.accessibilityIdentifier = "row.share"
        children.append(share)
        return UIMenu(children: children)
    }
}
