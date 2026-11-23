import UIKit

// [background] The Background tasks card on the chat's shelf (owner 2026-11-15: "Shouldn't that background work be shown
// the same as subagents do?"). A bot that starts a command in the background (a test run, a build) ends its turn and
// looked idle while the command ran. The chip sits beside Subagents on the same glass; opened, it lists each running
// command: a spinner, its name (BackgroundTaskText.title, not a bare `cd …`), how long it has run, the newest line it printed, and Stop behind a menu (one
// tap would end a long test run by accident). Read from `process.list` (`ChatActivityController.backgroundPoll`).

final class BackgroundTasksBody: UIView, ShelfMeasuredBody {
    private var revision = ShelfRevision()
    var layoutRevision: Int { revision.value }
    /// Stop was chosen for this command (its id).
    var onStop: ((String) -> Void)?
    private let stack = UIStackView()
    private var rows: [String: BackgroundTaskRow] = [:]
    private var order: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        accessibilityIdentifier = "chat.background.list"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `stopping`: ids whose Stop went out (their row says "Stopping…").
    func update(_ commands: [BackgroundProcess], stopping: Set<String>) {
        var h = Hasher()
        for c in commands { h.combine(c.id); h.combine(c.headline); h.combine(c.detailLine); h.combine(c.lastLine.isEmpty) }
        revision.note(h.finalize())
        let ids = commands.map(\.id)
        for (id, row) in rows where !ids.contains(id) { row.removeFromSuperview(); rows[id] = nil }
        for command in commands {
            let row = rows[command.id] ?? {
                let r = BackgroundTaskRow()
                r.onStop = { [weak self] id in self?.onStop?(id) }
                rows[command.id] = r
                return r
            }()
            row.update(command, stopping: stopping.contains(command.id))
        }
        if ids != order {
            order = ids
            for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
            for id in ids { if let r = rows[id] { stack.addArrangedSubview(r) } }
        }
    }
}

/// One running job: spinner · its name (2 lines) · time · ⋯ (Stop); who runs it and where; the newest output line, or
/// an honest quiet line (`BackgroundProcess.headline` / `detailLine` / `statusLine`).
final class BackgroundTaskRow: UIView {
    var onStop: ((String) -> Void)?
    private let spinner = GlyphSpinner(style: .braille, color: ChatPalette.label2, size: HQFont.symbolSize(15, like: .subheadline, cap: 24))
    private let title = ShelfText.label(ShelfText.footnoteBold, lines: 2)
    private let detail = ShelfText.label(ShelfText.footnote, color: ChatPalette.label2, lines: 1)
    private let subtitle = ShelfText.label(ShelfText.footnote, color: ChatPalette.label2, lines: 1)
    private var subtitleUnderTitle: NSLayoutConstraint!
    private var subtitleUnderDetail: NSLayoutConstraint!
    private let timer = UILabel()
    private let more = UIButton(type: .system)
    private var command: BackgroundProcess?

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingTail
        title.accessibilityIdentifier = "chat.background.title"
        subtitle.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingMiddle
        detail.accessibilityIdentifier = "chat.background.detail"
        subtitle.font = HQFont.monoFace(ofSize: ShelfText.caption.pointSize, weight: .regular)
        subtitle.accessibilityIdentifier = "chat.background.output"
        timer.font = HQFont.monoDigitFace(ofSize: ShelfText.footnote.pointSize, weight: .regular)
        timer.textColor = ChatPalette.label2
        timer.textAlignment = .right
        timer.setContentHuggingPriority(.required, for: .horizontal)
        timer.setContentCompressionResistancePriority(.required, for: .horizontal)
        more.setImage(SubagentLook.image("ellipsis.circle", size: HQFont.symbolSize(17, like: .subheadline, cap: 26), weight: .regular), for: .normal)
        more.tintColor = ChatPalette.label2
        more.showsMenuAsPrimaryAction = true
        more.accessibilityLabel = "Task Actions"
        more.accessibilityIdentifier = "chat.background.more"
        for v: UIView in [spinner, title, detail, subtitle, timer, more] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        spinner.isUserInteractionEnabled = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            spinner.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: timer.leadingAnchor, constant: -8),
            timer.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            timer.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -4),
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            more.centerYAnchor.constraint(equalTo: centerYAnchor),
            more.widthAnchor.constraint(equalToConstant: 44),
            more.heightAnchor.constraint(equalToConstant: 44),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -4),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -4),
            subtitle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        subtitleUnderTitle = subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3)
        subtitleUnderDetail = subtitle.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 3)
        subtitleUnderTitle.isActive = true
        accessibilityIdentifier = "chat.background.row"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ command: BackgroundProcess, stopping: Bool) {
        self.command = command
        let name = command.headline
        if title.text != name { title.text = name }
        let place = command.detailLine
        if detail.text != place { detail.text = place }
        detail.isHidden = place == nil
        subtitleUnderTitle.isActive = place == nil
        subtitleUnderDetail.isActive = place != nil
        title.numberOfLines = ShelfText.isLarge ? 0 : 2
        let line = stopping ? "Stopping…" : command.statusLine
        if subtitle.text != line { subtitle.text = line }
        let time = command.uptimeSeconds.map(BackgroundProcess.duration) ?? ""
        if timer.text != time { timer.text = time }
        spinner.isHidden = stopping
        more.isEnabled = !stopping
        let id = command.id
        more.menu = UIMenu(children: [
            UIAction(title: "Copy Command", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = command.command },
            UIAction(title: "Stop Task", image: UIImage(systemName: "stop.circle"), attributes: .destructive) { [weak self] _ in
                self?.onStop?(id)
            },
        ])
        title.accessibilityLabel = "\(name), running" + (time.isEmpty ? "" : " for \(time)")
        subtitle.accessibilityLabel = line
    }
}
