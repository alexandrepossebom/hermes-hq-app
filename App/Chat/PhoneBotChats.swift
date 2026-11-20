import UIKit

/// The mobile bot chat's full, eligible chat list. The live tabs are only a small subset of this list.
@MainActor enum PhoneBotChats {
    static func present(from screen: ChatViewController, app: AppModel) {
        guard !DeviceWord.isMac, screen.presentedViewController == nil else { return }
        screen.stowKeys()
        let list = PhoneBotChatsController(screen: screen, app: app)
        let profile = screen.session.profile.isEmpty ? "default" : screen.session.profile
        let name = app.botStore?.bot(named: profile)?.name ?? screen.session.title
        let navigation = MenusSheet.wrap(list, title: "Chats with \(name)", closeWord: .done)
        // Unlike a picker this is a list to browse: Done explicitly closes it.
        list.navigationItem.leftBarButtonItem = nil
        let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak list] _ in
            guard let list else { return }
            MenusSheet.close(list) {}
        })
        done.accessibilityIdentifier = "phone-bot-chats.done"
        list.navigationItem.rightBarButtonItem = done
        navigation.view.accessibilityIdentifier = "phone-bot-chats.sheet"
        screen.present(navigation, animated: true)
    }
}

private final class PhoneBotChatsController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private weak var screen: ChatViewController?
    private weak var app: AppModel?
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var groups: [BotChatGroup] = []
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
        view.backgroundColor = HQPalette.groupedPage
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 56
        table.accessibilityIdentifier = "phone-bot-chats.list"
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        for name in [SessionStrip.listChanged, Theme.didChange] {
            watches.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        app?.setChatList(self, shown: true)
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        app?.setChatList(self, shown: false)
    }

    private func reload() {
        guard let app, let screen else { return }
        groups = SessionStripRules.groups(SessionStrip.phoneChats(app: app, model: screen.session))
        table.reloadData()
    }

    func numberOfSections(in tableView: UITableView) -> Int { 1 + groups.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : groups[section - 1].chats.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? nil : groups[section - 1].title
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 && groups.isEmpty ? "No other chats yet." : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = HQPalette.card
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.font = HQFont.preferred(.body)
        content.textProperties.color = HQPalette.label
        content.secondaryTextProperties.font = HQFont.preferred(.caption1)
        content.secondaryTextProperties.color = HQPalette.label2
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.numberOfLines = 2
        if indexPath.section == 0 {
            content.text = "New Chat"
            content.image = UIImage(systemName: "square.and.pencil")
            content.imageProperties.tintColor = HQPalette.tint
            cell.accessibilityIdentifier = "phone-bot-chats.new"
        } else {
            let chat = groups[indexPath.section - 1].chats[indexPath.row]
            let working = chat.isRunning || chat.status == .working
            content.text = chat.title
            let time = ListTime.string(chat.lastActive)
            if working {
                content.secondaryText = chat.step ?? "Working…"
                content.image = SessionStrip.dot(SessionStrip.workingColor)
            } else if chat.unread {
                content.secondaryText = time.isEmpty ? "Unread" : "Unread · \(time)"
                content.image = SessionStrip.dot(SessionStrip.unreadColor)
            } else {
                content.secondaryText = time.isEmpty ? nil : time
                content.image = UIImage(systemName: chat.pinned ? "pin" : "bubble.left")
                content.imageProperties.tintColor = HQPalette.label2
            }
            cell.accessibilityIdentifier = "phone-bot-chats.chat.\(chat.id)"
            cell.accessibilityValue = working ? "Working" : chat.unread ? "Unread" : nil
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let screen, let app else { return }
        if indexPath.section == 0 {
            // Push over the original bot screen, retaining its composer and draft for Back.
            MenusSheet.close(self) {
                guard let navigation = screen.navigationController, navigation.topViewController === screen,
                      app.openNewChat(like: screen.session, draft: "", replacing: screen) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    (navigation.topViewController as? ChatViewController)?.focusComposer()
                }
            }
        } else {
            let chat = groups[indexPath.section - 1].chats[indexPath.row]
            let entry = SessionStripEntry(id: chat.id, title: chat.title, isBotChat: false,
                                          working: chat.isRunning || chat.status == .working,
                                          unread: chat.unread, current: false)
            MenusSheet.close(self) { SessionStrip.open(entry, from: screen, app: app) }
        }
    }
}
