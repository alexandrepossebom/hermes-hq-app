import UIKit

// [session-strip] Owner 2026-11-17: "Is there any way to have active Sessions shown along the top bar on a Bot chat so
// that you can easily move between them?" Three switchers were built and run on his real chats (a pill strip, the
// title's menu, a sideways swipe); he picked the strip. Under the bar of any chat with a bot: that bot's own chat first
// (the tab bar's robot), then its active chats newest first, the one on screen lit. A green dot is a chat at work, a
// blue one a reply not read yet. One tap opens that chat in this one's place, the bar staying put. The strip is drawn
// only when Settings › Chat › Other Chats at the Top is on, together with the New Chat button. Not in a group room or
// a task's page.
// [bot-chat-sessions] Owner 2026-11-18 ("I need some way to show sessions owned by a bot ON the bot chat for the Mac
// app"; of four mock-ups he picked the strip and the right panel together): the Mac draws it too, on unless turned
// off, and slimmer. There it holds only what is live (working, unread, pinned, the chat on screen, the ones gone
// through this run), and "All N" at its end opens the inspector's Chats tab (`BotChatsPanel`), which lists every one.
// The Mac draws them as tabs, not pills (owner 2026-11-18, picking "A · Underline tabs" of four designs: the pills
// read as a second row of buttons): plain words on the bar's own ground, the chat on screen in the label colour with
// a line of the tint under it, the rest grey, a hairline under the row.

/// Settings › Chat › Other Chats at the Top (opt-in).
enum SessionStripPref {
    static let key = "hqn.sessionStrip"
    static let didChange = Notification.Name("hqn.sessionStrip.changed")

    /// Until it is chosen: off on the iPhone and iPad (opt-in), on on the Mac ([bot-chat-sessions]).
    static var standard: Bool { DeviceWord.isMac }

    static var isOn: Bool {
        // `bool(forKey:)` also reads a launch argument's "NO" (a string in the argument domain).
        get { UserDefaults.standard.object(forKey: key) == nil ? standard : UserDefaults.standard.bool(forKey: key) }
        set {
            guard newValue != isOn else { return }
            if newValue == standard { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(newValue, forKey: key) }
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

    /// Every chat of the bot's a person would call one (never archived, a job's run, a tool's, nor its own Bot Chat),
    /// newest first: what the strip picks from, and what the Mac's Chats tab lists.
    static func chats(bot: Bot?, sessions: [SessionSummary], profile: String) -> [SessionSummary] {
        sessions
            .filter { sameBot($0.profile, profile) && !$0.archived && $0.source != "cron" && $0.source != "tool"
                && $0.id != bot?.canonicalSessionId }
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    /// The bot's own chat, then its active chats (working, unread, pinned, the one on screen, touched in the last day,
    /// or `kept`: already a pill this run, so a chat you just went through doesn't drop out as you move on; never
    /// archived, a job's run or a tool's), newest first. `recent` false (the Mac, whose Chats tab lists the rest):
    /// a chat only touched in the last day is not one of them.
    static func entries(bot: Bot?, sessions: [SessionSummary], profile: String, currentId: String?, onBotChat: Bool,
                        kept: Set<String> = [], recent: Bool = true, now: Date = Date()) -> [SessionStripEntry] {
        var out: [SessionStripEntry] = []
        if let bot {
            out.append(SessionStripEntry(id: bot.canonicalSessionId ?? "", title: bot.name, isBotChat: true,
                                         working: bot.isWorking, unread: bot.unread && !onBotChat, current: onBotChat))
        }
        let chats = chats(bot: bot, sessions: sessions, profile: profile)
            .filter { $0.id == currentId || kept.contains($0.id) || $0.isRunning || $0.status == .working || $0.unread || $0.pinned
                || (recent && now.timeIntervalSince($0.lastActive ?? .distantPast) < activeFor) }
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

/// [bot-chat-sessions] One group of the Mac's Chats tab.
nonisolated struct BotChatGroup: Equatable, Sendable {
    var title: String
    var chats: [SessionSummary]
}

extension SessionStripRules {
    /// The Chats tab's groups, each chat in the first that fits: Working, Pinned, Today, Yesterday, Earlier. The
    /// chats keep the order they came in (newest first); an empty group is left out.
    static func groups(_ chats: [SessionSummary], now: Date = Date(), calendar: Calendar = .current) -> [BotChatGroup] {
        let titles = ["Working", "Pinned", "Today", "Yesterday", "Earlier"]
        var held: [[SessionSummary]] = Array(repeating: [], count: titles.count)
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
        for chat in chats {
            let at = chat.lastActive ?? .distantPast
            let index = chat.isRunning || chat.status == .working ? 0 : chat.pinned ? 1 : at >= today ? 2 : at >= yesterday ? 3 : 4
            held[index].append(chat)
        }
        return zip(titles, held).filter { !$0.1.isEmpty }.map { BotChatGroup(title: $0.0, chats: $0.1) }
    }
}

@MainActor enum SessionStrip {
    /// Posted when the chats or the bots change (AppModel): every strip on screen reads its pills again.
    static let listChanged = Notification.Name("hq.sessionStrip.listChanged")

    /// Offers the strip to a chat screen as it is made (`AppModel.makeChatScreen`). It takes the slot under the bar
    /// when the chat first appears, so a task's page, which puts its own panel there, keeps it.
    static func offer(to screen: ChatViewController, model: any ChatSessionModel, app: AppModel) {
        guard model is LiveChatSession, !(model is ChatRoomSurface) else { return }
        screen.makeTopStrip = { [weak screen, weak app] in
            // A task keeps its one chat: none over the Mac's task pane either (a chat with no panel of the task's on it).
            guard let screen, let app, screen.menus?.isTaskChat != true else { return nil }
            return SessionStripController(screen: screen, app: app)
        }
        #if targetEnvironment(macCatalyst)
        // [bot-chat-sessions] The inspector's Chats tab beside this chat: every chat of its bot's.
        screen.makeChatsPanel = { [weak screen, weak app] in
            guard let screen, let app else { return nil }
            return BotChatsPanel(screen: screen, app: app)
        }
        #endif
    }

    /// How many chats the bot has besides its own ("All N", and whether the Mac draws the strip at all).
    static func count(app: AppModel, model: any ChatSessionModel) -> Int {
        let profile = model.profile.isEmpty ? "default" : model.profile
        return SessionStripRules.chats(bot: app.botStore?.bot(named: profile), sessions: app.sessions, profile: profile).count
    }

    /// Chats that have been a pill this run, by bot (kept in memory only).
    private static var shownBefore: [String: Set<String>] = [:]

    static func entries(app: AppModel, model: any ChatSessionModel) -> [SessionStripEntry] {
        let live = model as? LiveChatSession
        let profile = model.profile.isEmpty ? "default" : model.profile
        let entries = SessionStripRules.entries(bot: app.botStore?.bot(named: profile), sessions: app.sessions, profile: profile,
                                                currentId: live?.storedSessionId, onBotChat: live?.isBotChat == true,
                                                kept: shownBefore[profile] ?? [], recent: !DeviceWord.isMac)
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
        // In two panes the lists' marks and the Mac's inspector follow the chat now beside them.
        AppModel.markPane(navigation)
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
final class SessionStripController: UIViewController, UIScrollViewDelegate {
    private weak var screen: ChatViewController?
    private weak var app: AppModel?
    private let backing = ChatEdgeStandIn()
    private let scroller = UIScrollView()
    private let row = UIStackView()
    private let newChat = UIButton(configuration: .glass())
    /// [bot-chat-sessions] The Mac's "All N": every chat of the bot's, in the inspector's Chats tab.
    private let allChats = UIButton(configuration: .glass())
    private var allCount = -1
    private lazy var scrollerToNew = scroller.trailingAnchor.constraint(equalTo: newChat.leadingAnchor, constant: -7)
    private lazy var scrollerToAll = scroller.trailingAnchor.constraint(equalTo: allChats.leadingAnchor, constant: -7)
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

    isolated deinit {
        watches.forEach { NotificationCenter.default.removeObserver($0) }
        app?.setChatList(self, shown: false)
    }

    /// [bot-chat-sessions] On screen (the Mac reads the chats at the on-screen pace while its strip is drawn).
    private var appeared = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        appeared = false
        app?.setChatList(self, shown: false)
    }

    private var font: UIFont {
        UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: HQFont.system(ofSize: 14, weight: .medium), maximumPointSize: 18)
    }
    /// [bot-chat-sessions] The Mac's look: words with a line under the chat on screen (pills elsewhere).
    private var tabs: Bool { DeviceWord.isMac }
    private let rule = UIView()
    /// The tabs fade out at an edge they run past (words cut square at the row's end read as a fault); none at an
    /// edge with nothing beyond it.
    private let fade = CAGradientLayer()

    private func placeFade() {
        guard tabs else { return }
        let width = scroller.bounds.width
        guard width > 0 else { return }
        let reach: CGFloat = 22
        let before = scroller.contentOffset.x > 1
        let after = scroller.contentOffset.x < scroller.contentSize.width - width - 1
        let clear = UIColor.clear.cgColor, solid = UIColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = scroller.bounds   // the mask moves with the scrolled content: kept over what shows
        fade.colors = [before ? clear : solid, solid, solid, after ? clear : solid]
        fade.locations = [0, NSNumber(value: Double(reach / width)), NSNumber(value: Double(1 - reach / width)), 1]
        CATransaction.commit()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { placeFade() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        placeFade()
    }
    private var pillHeight: CGFloat { tabs ? max(34, ceil(font.lineHeight) + 18) : max(34, ceil(font.lineHeight) + 14) }
    private var stripHeight: CGFloat { tabs ? pillHeight : pillHeight + 12 }

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
        if tabs {
            scroller.delegate = self
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
            scroller.layer.mask = fade
        }
        view.addSubview(scroller)
        var newConfig = UIButton.Configuration.hqGlass()
        newConfig.cornerStyle = .capsule
        newConfig.image = UIImage(systemName: "plus")
        newConfig.baseForegroundColor = ChatPalette.label
        newConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        if tabs {
            newConfig = .plain()
            newConfig.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
            newConfig.baseForegroundColor = ChatPalette.tint
            newConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        }
        newChat.configuration = newConfig
        newChat.isPointerInteractionEnabled = true
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
        allChats.translatesAutoresizingMaskIntoConstraints = false
        allChats.accessibilityIdentifier = "chat.strip.all"
        allChats.isHidden = true
        allChats.isPointerInteractionEnabled = true
        allChats.setContentCompressionResistancePriority(.required, for: .horizontal)
        allChats.setContentHuggingPriority(.required, for: .horizontal)
        allChats.addAction(UIAction { [weak self] _ in self?.showAll() }, for: .primaryActionTriggered)
        view.addSubview(allChats)
        row.axis = .horizontal
        row.spacing = tabs ? 18 : 7
        rule.backgroundColor = ChatPalette.separator
        rule.isUserInteractionEnabled = false
        rule.isHidden = !tabs
        rule.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rule)
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        NSLayoutConstraint.activate([
            backing.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backing.topAnchor.constraint(equalTo: view.topAnchor, constant: -6),
            backing.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 16),
            scroller.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollerToNew,
            allChats.trailingAnchor.constraint(equalTo: newChat.leadingAnchor, constant: -7),
            allChats.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: tabs ? 0 : -1),
            scroller.topAnchor.constraint(equalTo: view.topAnchor),
            scroller.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            newChat.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            newChat.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: tabs ? 0 : -1),
            newChat.widthAnchor.constraint(equalToConstant: tabs ? 34 : 44),
            rule.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: HQShape.pixel(traitCollection.displayScale)),
            newChat.heightAnchor.constraint(equalToConstant: 44),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.centerYAnchor.constraint(equalTo: scroller.frameLayoutGuide.centerYAnchor, constant: tabs ? 0 : -1),
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
                self.allCount = -1
                self.reload()
            }
        })
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (strip: SessionStripController, _) in
            strip.shown = []
            strip.allCount = -1
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
        // The Mac: only for a bot with a chat besides its own (its sidebar already says whose chat this is).
        let others = DeviceWord.isMac ? SessionStrip.count(app: app, model: screen.session) : 0
        let drawn = DeviceWord.isMac ? others > 0 || entries.count >= SessionStripRules.fewest : !entries.isEmpty
        let height: CGFloat = SessionStripPref.isOn && drawn ? stripHeight : 0
        showAllCount(height > 0 ? others : 0)
        if DeviceWord.isMac { app.setChatList(self, shown: appeared && height > 0) }
        screen.setTopAccessoryHeight(height, insets: true, animated: view.window != nil && !HQMotion.reduced)
        view.isHidden = height == 0
        guard entries != shown else { return }
        shown = entries
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, entry) in entries.enumerated() { row.addArrangedSubview(pill(entry, index: index)) }
        if tabs { DispatchQueue.main.async { [weak self] in self?.view.layoutIfNeeded(); self?.placeFade() } }
        if height > 0, !placedCurrent || !personScrolled {
            placedCurrent = true
            DispatchQueue.main.async { [weak self] in self?.showCurrent() }
        }
    }

    /// [bot-chat-sessions] "All 14" at the strip's end, on the Mac, while the bot has chats besides its own.
    private func showAllCount(_ count: Int) {
        guard count != allCount else { return }
        allCount = count
        let shows = count > 0
        allChats.isHidden = !shows
        scrollerToNew.isActive = !shows
        scrollerToAll.isActive = shows
        guard shows else { return }
        var config: UIButton.Configuration = tabs ? .plain() : .hqGlass()
        config.cornerStyle = .capsule
        config.contentInsets = tabs ? NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 4)
            : NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 10)
        config.attributedTitle = AttributedString("All \(count)", attributes: AttributeContainer([.font: font]))
        config.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.baseForegroundColor = tabs ? ChatPalette.label2 : ChatPalette.label
        allChats.configuration = config
        allChats.accessibilityLabel = "All chats, \(count)"
        allChats.toolTip = "All Chats"
    }

    private func showAll() {
        guard let screen else { return }
        #if targetEnvironment(macCatalyst)
        if let inspector = MacInspector.beside(screen) {
            inspector.show(.chats)
            AppLog.note("chat", "strip: All opened the Chats tab")
            return
        }
        #endif
        // No panel beside the chat (a window too small for two panes): Sessions, with this bot's chip picked.
        guard let root = MainTabController.current else { return }
        let profile = screen.session.profile.isEmpty ? "default" : screen.session.profile
        root.select(.sessions)
        let list = root.sessionsViewController
        list.navigationController?.popToRootViewController(animated: false)
        list.pickBot(profile)
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

    /// [bot-chat-sessions] The Mac's tab: its words (the bot's own chat reads "Bot Chat": the bar above names the bot),
    /// a dot before them for a chat at work or with a reply not read, and the tint's line under the chat on screen.
    private func tab(_ entry: SessionStripEntry) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
        config.imagePadding = 6
        config.titleLineBreakMode = .byTruncatingTail
        let face = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: HQFont.system(ofSize: 14, weight: entry.current ? .semibold : .regular),
                                                                    maximumPointSize: 18)
        config.attributedTitle = AttributedString(entry.isBotChat ? "Bot Chat" : entry.title, attributes: AttributeContainer([.font: face]))
        if entry.working {
            config.image = SessionStrip.dot(SessionStrip.workingColor)
        } else if entry.unread {
            config.image = SessionStrip.dot(SessionStrip.unreadColor)
        }
        config.baseForegroundColor = entry.current ? ChatPalette.label : ChatPalette.label2
        let button = UIButton(configuration: config)
        button.isPointerInteractionEnabled = true
        button.heightAnchor.constraint(equalToConstant: pillHeight).isActive = true
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        if entry.current {
            let line = UIView()
            line.backgroundColor = ChatPalette.tint
            line.isUserInteractionEnabled = false
            line.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                line.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                line.heightAnchor.constraint(equalToConstant: 2),
            ])
        }
        return button
    }

    private func pill(_ entry: SessionStripEntry, index: Int) -> UIButton {
        let button = tabs ? tab(entry) : glassPill(entry)
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

    private func glassPill(_ entry: SessionStripEntry) -> UIButton {
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
        // A pill made after the screen's own pass (`PointerEffects.install`) answers the pointer too (the Mac, the iPad).
        button.isPointerInteractionEnabled = true
        button.heightAnchor.constraint(equalToConstant: pillHeight).isActive = true
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        return button
    }
}
