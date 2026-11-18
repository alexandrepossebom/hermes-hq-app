#if targetEnvironment(macCatalyst)
import UIKit

/// [bot-chat-sessions] Owner 2026-11-18 ("I need some way to show sessions owned by a bot ON the bot chat for the Mac
/// app … listed horizontally below the top bar OR in the right side bar? Or maybe both"; he picked both): the
/// inspector's Chats tab. Beside any chat with a bot it lists every chat of that bot's: its own chat and New Chat
/// first, then the rest in groups (Working, Pinned, Today, Yesterday, Earlier), newest first, each with a line of what
/// was last said and when. A green dot is a chat at work, a blue one a reply not read yet; the chat beside the panel
/// is lit. A click opens that chat in the other's place, the panel staying as it is. The strip under the chat's bar
/// (`SessionStrip`) holds only what is live, and its "All N" opens this tab.
final class BotChatsPanel: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Kind: Equatable { case botChat, newChat, chat }

    private struct Row: Equatable {
        var kind: Kind
        var id: String
        var title: String
        var detail: String
        var time: String
        var working = false
        var unread = false
        var current = false
    }

    private struct Section: Equatable {
        var title: String?
        var rows: [Row]
    }

    private weak var screen: ChatViewController?
    private weak var app: AppModel?
    private let table = UITableView(frame: .zero, style: .plain)
    private var sections: [Section] = []
    private var watches: [NSObjectProtocol] = []

    init(screen: ChatViewController, app: AppModel) {
        self.screen = screen
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        watches.forEach { NotificationCenter.default.removeObserver($0) }
        app?.setChatList(self, shown: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.register(BotChatCell.self, forCellReuseIdentifier: "chat")
        table.sectionFooterHeight = 0
        table.accessibilityIdentifier = "mac.inspector.chats"
        InspectorLook.dress(table)
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let center = NotificationCenter.default
        for name in [SessionStrip.listChanged, Theme.didChange] {
            let force = name == Theme.didChange
            watches.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload(force: force) }
            })
        }
        reload(force: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload(force: false)
    }

    /// While the list is on show the chats are read at the on-screen pace (`AppModel.setChatList`).
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        app?.setChatList(self, shown: true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        app?.setChatList(self, shown: false)
    }

    /// Another chat is beside the panel now (one of its rows opened, or a chat of another bot's): its bot's chats, that
    /// one lit.
    func follow(_ next: ChatViewController) {
        screen = next
        if isViewLoaded { reload(force: false) }
    }

    private func reload(force: Bool) {
        guard let app, let screen else { return }
        let next = Self.sections(app: app, model: screen.session)
        guard force || next != sections else { return }
        sections = next
        table.reloadData()
    }

    private static func sections(app: AppModel, model: any ChatSessionModel) -> [Section] {
        let live = model as? LiveChatSession
        let profile = model.profile.isEmpty ? "default" : model.profile
        let bot = app.botStore?.bot(named: profile)
        let onBotChat = live?.isBotChat == true
        let currentId = onBotChat ? nil : live?.storedSessionId
        var top: [Row] = []
        if let bot {
            top.append(Row(kind: .botChat, id: bot.canonicalSessionId ?? "", title: bot.name, detail: "Bot Chat", time: "",
                           working: bot.isWorking, unread: bot.unread && !onBotChat, current: onBotChat))
        }
        top.append(Row(kind: .newChat, id: "", title: "New Chat", detail: "", time: ""))
        var out = [Section(title: nil, rows: top)]
        let chats = SessionStripRules.chats(bot: bot, sessions: app.sessions, profile: profile)
        for group in SessionStripRules.groups(chats) {
            out.append(Section(title: group.title, rows: group.chats.map { chat in
                let working = chat.isRunning || chat.status == .working
                let current = chat.id == currentId
                let said = (chat.preview ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                return Row(kind: .chat, id: chat.id, title: chat.title, detail: working ? (chat.step ?? "Working…") : said,
                           time: ListTime.string(chat.lastActive), working: working, unread: chat.unread && !current, current: current)
            }))
        }
        return out
    }

    // MARK: The table

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chat", for: indexPath)
        let row = sections[indexPath.section].rows[indexPath.row]
        if let cell = cell as? BotChatCell {
            cell.show(title: row.title, detail: row.detail, time: row.time, working: row.working, unread: row.unread,
                      current: row.current, action: row.kind == .newChat)
        }
        switch row.kind {
        case .botChat: cell.accessibilityIdentifier = "mac.inspector.chats.bot"
        case .newChat: cell.accessibilityIdentifier = "mac.inspector.chats.new"
        case .chat: cell.accessibilityIdentifier = "mac.inspector.chats.chat.\(indexPath.section - 1).\(indexPath.row)"
        }
        return cell
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let title = sections[section].title else { return nil }
        let label = UILabel()
        label.font = InspectorLook.detailFont
        label.textColor = HQPalette.label2
        label.text = title
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        let header = UIView()
        header.backgroundColor = HQPalette.groupedPage   // the panel's own colour: a header pinned over rows hides them
        header.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: InspectorLook.margin),
            label.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -InspectorLook.margin),
            label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
        ])
        header.accessibilityIdentifier = "mac.inspector.chats.group.\(title.lowercased())"
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        sections[section].title == nil ? 0 : (InspectorLook.detailFont.lineHeight + 22).rounded(.up)
    }

    /// A row's height from its lines (one for New Chat, two for a chat), 9 pt above and below.
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let row = sections[indexPath.section].rows[indexPath.row]
        let lines = InspectorLook.textFont.lineHeight + (row.detail.isEmpty ? 0 : BotChatCell.lineGap + InspectorLook.detailFont.lineHeight)
        return (lines + 18).rounded(.up)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let app, let screen else { return }
        let row = sections[indexPath.section].rows[indexPath.row]
        switch row.kind {
        case .newChat:
            guard let navigation = screen.navigationController,
                  app.openNewChat(like: screen.session, draft: "", replacing: screen) else { return }
            AppLog.note("chat", "chats tab: New Chat")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                (navigation.topViewController as? ChatViewController)?.focusComposer()
            }
        case .botChat, .chat:
            guard !row.current else { return }
            SessionStrip.open(SessionStripEntry(id: row.id, title: row.title, isBotChat: row.kind == .botChat, working: row.working,
                                                unread: row.unread, current: false), from: screen, app: app)
        }
    }
}

/// One row of the Chats tab: a title with its time at the end, a grey line under it, and a dot in the margin for a
/// chat at work (green) or with a reply not read yet (blue).
private final class BotChatCell: UITableViewCell {
    private let dot = UIView()
    private let glyph = UIImageView()
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let detailLabel = UILabel()
    private let lines = UIStackView()
    static let lineGap: CGFloat = 2
    private var lit = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        dot.layer.cornerRadius = 3.5
        dot.isHidden = true
        glyph.contentMode = .scaleAspectFit
        glyph.isHidden = true
        glyph.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        titleLabel.font = InspectorLook.textFont
        titleLabel.textColor = HQPalette.label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.font = InspectorLook.detailFont
        timeLabel.textColor = HQPalette.label2
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.font = InspectorLook.detailFont
        detailLabel.textColor = HQPalette.label2
        detailLabel.lineBreakMode = .byTruncatingTail
        let first = UIStackView(arrangedSubviews: [glyph, titleLabel, timeLabel])
        first.axis = .horizontal
        first.spacing = 8
        first.alignment = .center
        lines.axis = .vertical
        lines.spacing = Self.lineGap
        lines.addArrangedSubview(first)
        lines.addArrangedSubview(detailLabel)
        for sub in [dot, lines] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: InspectorLook.margin),
            lines.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -InspectorLook.margin),
            lines.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: InspectorLook.margin / 2),
            dot.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(title: String, detail: String, time: String, working: Bool, unread: Bool, current: Bool, action: Bool) {
        titleLabel.text = title
        titleLabel.textColor = action ? ChatPalette.tint : HQPalette.label
        glyph.isHidden = !action
        glyph.tintColor = ChatPalette.tint
        timeLabel.text = time
        timeLabel.isHidden = time.isEmpty
        detailLabel.text = detail
        detailLabel.isHidden = detail.isEmpty
        dot.isHidden = !(working || unread)
        dot.backgroundColor = working ? SessionStrip.workingColor : SessionStrip.unreadColor
        lit = current
        backgroundColor = current ? HQPalette.cellPressed : .clear   // the cell's, edge to edge (its content view stops short of the scroller)
        accessibilityLabel = [title, working ? "Working" : nil, unread ? "New reply" : nil, detail.isEmpty ? nil : detail,
                              time.isEmpty ? nil : time].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = current ? [.button, .selected] : .button
        isAccessibilityElement = true
    }

    /// The row under the pointer lights a little, as the sidebar's rows do.
    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        let over = hover.state == .began || hover.state == .changed
        backgroundColor = lit ? HQPalette.cellPressed : over ? HQPalette.cellPressed.withAlphaComponent(0.5) : .clear
    }
}
#endif
