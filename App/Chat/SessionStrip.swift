import UIKit

// [session-strip] Owner 2026-11-17: "Is there any way to have active Sessions shown along the top bar on a Bot chat so
// that you can easily move between them?" Three switchers were built and run on his real chats (a pill strip, the
// title's menu, a sideways swipe); he picked the strip. Under the bar of any chat with a bot: that bot's own chat first
// (the tab bar's robot), then its active chats newest first, the one on screen lit. A green dot is a chat at work, a
// blue one a reply not read yet. One tap opens that chat in this one's place, the bar staying put. The strip is drawn
// only when Settings › Chat › Other Chats at the Top is on, together with the New Chat button. Not on the
// Mac (its sidebar lists the chats beside the chat already), nor in a group room or a task's page.

/// Settings › Chat › Other Chats at the Top (opt-in).
enum SessionStripPref {
    static let key = "hqn.sessionStrip"
    static let didChange = Notification.Name("hqn.sessionStrip.changed")

    static var isOn: Bool {
        // `bool(forKey:)` also reads a launch argument's "NO" (a string in the argument domain).
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            guard newValue != isOn else { return }
            if newValue { UserDefaults.standard.set(true, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            AppLog.note("settings", "Other Chats at the Top set to \(newValue)")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

/// One pill.
nonisolated struct SessionStripEntry: Equatable, Sendable {
    var id: String          // the stored session id ("" for a bot chat the roster hasn't named yet)
    var title: String
    var isBotChat: Bool
    var working: Bool
    var unread: Bool
    var current: Bool
}

nonisolated enum SessionStripRules {
    /// A chat touched this recently counts as active.
    static let activeFor: TimeInterval = 24 * 3600
    /// The most pills (the chat on screen is always among them).
    static let most = 8
    /// Fewer than this and the strip is not drawn.
    static let fewest = 2

    static func sameBot(_ a: String, _ b: String) -> Bool { (a.isEmpty ? "default" : a) == (b.isEmpty ? "default" : b) }

    /// The bot's own chat, then its active chats (working, unread, pinned, the one on screen, touched in the last day,
    /// or `kept`: already a pill this run, so a chat you just went through doesn't drop out as you move on; never
    /// archived, a job's run or a tool's), newest first.
    static func entries(bot: Bot?, sessions: [SessionSummary], profile: String, currentId: String?, onBotChat: Bool,
                        kept: Set<String> = [], now: Date = Date()) -> [SessionStripEntry] {
        var out: [SessionStripEntry] = []
        if let bot {
            out.append(SessionStripEntry(id: bot.canonicalSessionId ?? "", title: bot.name, isBotChat: true,
                                         working: bot.isWorking, unread: bot.unread && !onBotChat, current: onBotChat))
        }
        let chats = sessions
            .filter { sameBot($0.profile, profile) && !$0.archived && $0.source != "cron" && $0.source != "tool"
                && $0.id != bot?.canonicalSessionId }
            .filter { $0.id == currentId || kept.contains($0.id) || $0.isRunning || $0.status == .working || $0.unread || $0.pinned
                || now.timeIntervalSince($0.lastActive ?? .distantPast) < activeFor }
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        for chat in chats {
            let isCurrent = !onBotChat && chat.id == currentId
            guard isCurrent || out.count < most else { continue }
            out.append(SessionStripEntry(id: chat.id, title: chat.title, isBotChat: false,
                                         working: chat.isRunning || chat.status == .working,
                                         unread: chat.unread && !isCurrent, current: isCurrent))
        }
        return out
    }
}

@MainActor enum SessionStrip {
    /// Posted when the chats or the bots change (AppModel): every strip on screen reads its pills again.
    static let listChanged = Notification.Name("hq.sessionStrip.listChanged")

    /// Offers the strip to a chat screen as it is made (`AppModel.makeChatScreen`). It takes the slot under the bar
    /// when the chat first appears, so a task's page, which puts its own panel there, keeps it.
    static func offer(to screen: ChatViewController, model: any ChatSessionModel, app: AppModel) {
        guard !DeviceWord.isMac, model is LiveChatSession, !(model is ChatRoomSurface) else { return }
        screen.makeTopStrip = { [weak screen, weak app] in
            guard let screen, let app else { return nil }
            return SessionStripController(screen: screen, app: app)
        }
    }

    /// Chats that have been a pill this run, by bot (kept in memory only).
    private static var shownBefore: [String: Set<String>] = [:]

    static func entries(app: AppModel, model: any ChatSessionModel) -> [SessionStripEntry] {
        let live = model as? LiveChatSession
        let profile = model.profile.isEmpty ? "default" : model.profile
        let entries = SessionStripRules.entries(bot: app.botStore?.bot(named: profile), sessions: app.sessions, profile: profile,
                                                currentId: live?.storedSessionId, onBotChat: live?.isBotChat == true,
                                                kept: shownBefore[profile] ?? [])
        shownBefore[profile, default: []].formUnion(entries.filter { !$0.isBotChat }.map(\.id))
        return entries
    }

    /// That chat opens in this one's place: a quick fade, the bar and the strip staying where they are.
    static func open(_ entry: SessionStripEntry, from screen: ChatViewController, app: AppModel) {
        guard !entry.current, let navigation = screen.navigationController else { return }
        let profile = screen.session.profile.isEmpty ? "default" : screen.session.profile
        let model: any ChatSessionModel
        if entry.isBotChat {
            guard let bot = app.botStore?.bot(named: profile) else { return }
            model = app.chat(for: bot)
        } else {
            guard let summary = app.sessions.first(where: { $0.id == entry.id }) else { return }
            model = app.chat(for: summary)
        }
        let next = app.makeChatScreen(model)
        next.hidesBottomBarWhenPushed = true
        next.navigationItem.largeTitleDisplayMode = .never
        var stack = navigation.viewControllers
        if let index = stack.firstIndex(where: { $0 === screen }) { stack.remove(at: index) }
        stack.append(next)
        if !HQMotion.reduced {
            let fade = CATransition()
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.type = .fade
            navigation.view.layer.add(fade, forKey: "hq.sessionStrip")
        }
        navigation.setViewControllers(stack, animated: false)
        AppLog.note("chat", "strip: opened \(entry.isBotChat ? "the bot's chat" : "chat \(AppLog.tag(entry.id))")")
    }

    static let workingColor = UIColor.systemGreen
    static let unreadColor = UIColor.systemBlue

    static func dot(_ color: UIColor, side: CGFloat = 7) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    /// The tab bar's robot, at a pill's size.
    static func robot(side: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            TabIcons.bot.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }.withRenderingMode(.alwaysTemplate)
    }
}

/// The row of pills under the bar; 0 tall (and nothing drawn) while it is off or the bot has one chat to show.
final class SessionStripController: UIViewController {
    private weak var screen: ChatViewController?
    private weak var app: AppModel?
    private let backing = ChatEdgeStandIn()
    private let scroller = UIScrollView()
    private let row = UIStackView()
    private let newChat = UIButton(configuration: .glass())
    private var shown: [SessionStripEntry] = []
    private var watches: [NSObjectProtocol] = []
    /// The pill of the chat on screen is kept in view as the pills change, until the person scrolls the strip.
    private var personScrolled = false
    private var placedCurrent = false

    init(screen: ChatViewController, app: AppModel) {
        self.screen = screen
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit { watches.forEach { NotificationCenter.default.removeObserver($0) } }

    private var font: UIFont {
        UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: HQFont.system(ofSize: 14, weight: .medium), maximumPointSize: 18)
    }
    private var pillHeight: CGFloat { max(34, ceil(font.lineHeight) + 14) }
    private var stripHeight: CGFloat { pillHeight + 12 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "chat.strip"
        // The chat's own soft top edge, carried on under the pills: the rows scroll up under it, as under the bar.
        backing.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backing)
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = true
        scroller.clipsToBounds = true
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.panGestureRecognizer.addTarget(self, action: #selector(scrolledByPerson))
        view.addSubview(scroller)
        var newConfig = UIButton.Configuration.glass()
        newConfig.cornerStyle = .capsule
        newConfig.image = UIImage(systemName: "plus")
        newConfig.baseForegroundColor = ChatPalette.label
        newConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        newChat.configuration = newConfig
        newChat.translatesAutoresizingMaskIntoConstraints = false
        newChat.accessibilityIdentifier = "chat.strip.new"
        newChat.accessibilityLabel = "New Chat"
        newChat.addAction(UIAction { [weak self] _ in
            guard let self, let screen = self.screen, let app = self.app, let navigation = screen.navigationController else { return }
            guard app.openNewChat(like: screen.session, draft: "", replacing: screen) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                (navigation.topViewController as? ChatViewController)?.focusComposer()
            }
        }, for: .primaryActionTriggered)
        view.addSubview(newChat)
        row.axis = .horizontal
        row.spacing = 7
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        NSLayoutConstraint.activate([
            backing.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backing.topAnchor.constraint(equalTo: view.topAnchor, constant: -6),
            backing.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 16),
            scroller.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: newChat.leadingAnchor, constant: -7),
            scroller.topAnchor.constraint(equalTo: view.topAnchor),
            scroller.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            newChat.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            newChat.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -1),
            newChat.widthAnchor.constraint(equalToConstant: 44),
            newChat.heightAnchor.constraint(equalToConstant: 44),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.centerYAnchor.constraint(equalTo: scroller.frameLayoutGuide.centerYAnchor, constant: -1),
        ])
        applyLook()
        let center = NotificationCenter.default
        for name in [SessionStrip.listChanged, SessionStripPref.didChange] {
            watches.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
        watches.append(center.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyLook()
                self.shown = []      // the pills again, in the look's colours
                self.reload()
            }
        })
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (strip: SessionStripController, _) in
            strip.shown = []
            strip.reload()
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    /// The Desktop Look's chat edge is the hard frosted band; the iOS look's the soft fade (as the chat's own edge).
    private func applyLook() {
        backing.hard = Theme.isDesktop
        backing.keeps = !Theme.isDesktop
    }

    @objc private func scrolledByPerson() { personScrolled = true }

    private func reload() {
        guard let app, let screen else { return }
        let entries = SessionStripPref.isOn ? SessionStrip.entries(app: app, model: screen.session) : []
        let height: CGFloat = SessionStripPref.isOn && !entries.isEmpty ? stripHeight : 0
        screen.setTopAccessoryHeight(height, insets: true, animated: view.window != nil && !HQMotion.reduced)
        view.isHidden = height == 0
        guard entries != shown else { return }
        shown = entries
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, entry) in entries.enumerated() { row.addArrangedSubview(pill(entry, index: index)) }
        if height > 0, !placedCurrent || !personScrolled {
            placedCurrent = true
            DispatchQueue.main.async { [weak self] in self?.showCurrent() }
        }
    }

    /// The chat on screen sits a little in from the leading edge, the pill before it peeking (there is more that way).
    private func showCurrent() {
        view.layoutIfNeeded()
        guard let index = shown.firstIndex(where: \.current), index > 0, index < row.arrangedSubviews.count,
              !scroller.isTracking, !scroller.isDecelerating else { return }
        let pill = row.convert(row.arrangedSubviews[index].frame, to: scroller)
        let most = max(0, scroller.contentSize.width - scroller.bounds.width)
        let leading = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? max(0, most - (scroller.contentSize.width - pill.maxX - 56)) : pill.minX - 56
        scroller.setContentOffset(CGPoint(x: min(most, max(0, leading)), y: 0), animated: false)
    }

    private func pill(_ entry: SessionStripEntry, index: Int) -> UIButton {
        var config: UIButton.Configuration = entry.current ? .prominentGlass() : .glass()
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        config.imagePadding = 6
        config.titleLineBreakMode = .byTruncatingTail
        config.attributedTitle = AttributedString(entry.title, attributes: AttributeContainer([.font: font]))
        if entry.isBotChat {
            config.image = SessionStrip.robot(side: round(font.pointSize + 2))
        } else if entry.working {
            config.image = SessionStrip.dot(SessionStrip.workingColor)
        } else if entry.unread {
            config.image = SessionStrip.dot(SessionStrip.unreadColor)
        }
        if entry.current { config.baseBackgroundColor = ChatPalette.tint } else { config.baseForegroundColor = ChatPalette.label }
        let button = UIButton(configuration: config)
        button.heightAnchor.constraint(equalToConstant: pillHeight).isActive = true
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        button.accessibilityIdentifier = "chat.strip.pill.\(index)"
        button.accessibilityLabel = [entry.title, entry.isBotChat ? "Bot Chat" : nil, entry.working ? "Working" : nil,
                                     entry.unread ? "New reply" : nil].compactMap { $0 }.joined(separator: ", ")
        if entry.current { button.accessibilityTraits.insert(.selected) }
        button.addAction(UIAction { [weak self] _ in
            guard let self, let screen = self.screen, let app = self.app else { return }
            Haptics.play(.selection)
            SessionStrip.open(entry, from: screen, app: app)
        }, for: .primaryActionTriggered)
        return button
    }
}
