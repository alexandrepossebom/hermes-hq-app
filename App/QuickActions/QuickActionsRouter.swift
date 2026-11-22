// [quick-actions] The Quick Actions page's ways in and its tiles' ways out (docs/spec/3x-intents.md DECISION I22,
// docs/spec/3x-morepages.md §25). Every way in (the Open Quick Actions shortcut, the `<scheme>://quick-actions` link,
// the Home Screen item, the Mac's Dock menu and ⌘⇧K) lands in `present`: the page as a sheet over
// whatever is on top. Every tile runs through its Shortcuts twin's own handler (`QuickTileRoute`), so a tile and the
// shortcut it stands for can never do different things.

import UIKit

@MainActor enum QuickActionsRouter {
    /// The page's sheet while it is up.
    private static weak var sheet: UINavigationController?

    /// The page as a sheet over the app, once its tabs are up (a shortcut may have launched it). Already up: back to
    /// its first page. `from` names the way in, for the log.
    static func present(from: String) async {
        AppLog.note("quick-actions", "open from \(from)")
        IntentsEvents.note("quick-actions open " + from)
        guard let root = await NewChatRouter.tabs() else {
            AppLog.note("quick-actions", "open: no tabs (signed out?)")
            return
        }
        // A cold launch the shortcut ran on: the last chat is not reopened over (or under) the page.
        MainTabController.launchRestorePending = false
        root.launchChatWatch = nil
        if let sheet, sheet.presentingViewController != nil, !sheet.isBeingDismissed {
            sheet.presentedViewController?.dismiss(animated: false)
            sheet.popToRootViewController(animated: false)
            return
        }
        guard await root.clearForRoute() else { return }
        let page = QuickActionsViewController(inSheet: true)
        let navigation = ChatSheet.wrap(page, title: IntentsText.quickActions, detents: [.medium(), .large()])
        navigation.sheetPresentationController?.selectedDetentIdentifier = .large
        navigation.view.accessibilityIdentifier = "quick-actions.sheet"
        sheet = navigation
        root.present(navigation, animated: true)
    }

    /// Whether the page's sheet is up (the debug state).
    static var isShown: Bool { sheet?.presentingViewController != nil }

    // MARK: What a tile finds around it

    /// The CURRENT gateway's bots, jobs and pages (nil where they aren't known yet: never "missing").
    static func world(_ root: MainTabController? = MainTabController.current) -> QuickTileWorld {
        var world = QuickTileWorld()
        if let root, root.services.botsLoaded {
            world.bots = Dictionary(root.services.bots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
        let jobs = JobShortcutCatalog.jobs()
        if !jobs.isEmpty { world.jobs = Set(jobs.map(\.key)) }
        if let pages = root?.pages {
            var byID: [String: String] = [:]
            for row in pages.quickActionChoices().flatMap({ $0.rows() }) where byID[row.id] == nil { byID[row.id] = row.title }
            world.pages = byID
        }
        return world
    }

    /// The bot's name on the current roster (nil: not on it, or not known yet).
    static func botName(_ profile: String?, root: MainTabController? = MainTabController.current) -> String? {
        guard let profile, let root else { return nil }
        return root.services.bots.first { $0.id == profile }?.name
    }

    // MARK: Running a tile

    /// What a tap on `tile` did, for the page: nil when the page closed and went somewhere.
    enum Said: Equatable {
        case done(String)
        case failed(String)
    }

    /// Runs `tile` from `page`. A foreground tile closes the page's sheet first and goes; a background one keeps the
    /// page and answers through `say` (✓ or the reason).
    static func run(_ tile: QuickTile, from page: QuickActionsViewController, say: @escaping (Said) -> Void) {
        let root = MainTabController.current
        let route = QuickTileRoute.make(tile, world: world(root))
        AppLog.note("quick-actions", "tap \(tile.kind)")
        IntentsEvents.note("quick-actions tap " + tile.kind)
        switch route {
        case .unavailable(let words):
            say(.failed(words))
        case .runJob(let key, let name):
            guard let record = JobShortcutCatalog.jobs().first(where: { $0.key == key }) else {
                say(.failed("“\(name)” isn’t on this gateway."))
                return
            }
            let time = BackgroundTime.begin("hq.quick-actions.run-job")
            Task {
                let ran = await Result.of { try await RunJobIntent.run(record, wait: false) }
                time.end()
                switch ran {
                case .success:
                    AppLog.note("quick-actions", "run job: started")
                    say(.done("Running \(name)"))
                case .failure(let error):
                    AppLog.note("quick-actions", "run job: refused")
                    say(.failed(words(error)))
                }
            }
        case .sendInBackground(let profile, let message):
            let name = botName(profile, root: root) ?? tile.botName ?? profile
            let time = BackgroundTime.begin("hq.quick-actions.send")
            Task {
                let sent = await Result.of { try await AskBotIntent.send(profile: profile, name: name, message: message, wait: false) }
                time.end()
                switch sent {
                case .success(let answer):
                    AppLog.note("quick-actions", "send: sent")
                    say(.done("Sent to \(answer.target.name)"))
                case .failure(let error):
                    AppLog.note("quick-actions", "send: failed")
                    say(.failed(words(error)))
                }
            }
        default:
            Task { await go(route, tile: tile, from: page, root: root, say: say) }
        }
    }

    /// A foreground route: the page's sheet goes first (the route's own clearing then has nothing to ask about).
    private static func go(_ route: QuickTileRoute, tile: QuickTile, from page: QuickActionsViewController,
                           root: MainTabController?, say: @escaping (Said) -> Void) async {
        // A page tile pushed on the page's own stack (the page is a tab or a More page): it opens there.
        if case .page(let id) = route, !page.inSheet {
            guard let row = row(id, root: root), let next = row.make() else { return say(.failed(missingPage(tile))) }
            page.navigationController?.pushViewController(next, animated: true)
            return
        }
        if page.inSheet { await close(page) }
        guard let root = root ?? MainTabController.current else { return }
        switch route {
        case .newChat(let link):
            await NewChatRouter.open(link)
        case .talk(let profile):
            await NewChatRouter.talk(profile)
        case .memo(let profile):
            guard let record = voiceRecord(profile) else { return notice(missingBot(tile), root: root) }
            RecordVoiceNoteIntent.queue(record)
        case .openChat(let profile):
            guard let record = voiceRecord(profile), OpenBotChatIntent.open(record) else { return notice(missingBot(tile), root: root) }
        case .sendInChat(let profile, let words):
            await NewChatRouter.send(words, inBotChatOf: profile)
        case .newTask(let bot):
            TasksHub.newTask(bot: bot)
        case .page(let id):
            if !openPage(id, root: root) { notice(missingPage(tile), root: root) }
        case .search:
            await IntentsRuntime.shared.route("search", id: "", epoch: nil)
        case .runJob, .sendInBackground, .unavailable:
            break
        }
    }

    private static func close(_ page: QuickActionsViewController) async {
        guard let navigation = page.navigationController, navigation.presentingViewController != nil else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            navigation.dismiss(animated: true) { done.resume() }
        }
    }

    /// The bot's record in the pickers' catalog, in this sign-in (Open Bot Chat's and Record Voice Memo's own records).
    static func voiceRecord(_ profile: String) -> VoiceBotRecord? {
        let key = VoiceBotCatalog.key(profile: profile)
        let hits = VoiceBotCatalog.bots().filter { $0.key == key }
        let digest = ShortcutPolicy.digest()
        return hits.first { record in
            let parts = record.account.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return parts.count == 2 && ShortcutPolicy.accountDigest(url: parts[0], username: parts[1]) == digest
        } ?? hits.first
    }

    private static func row(_ id: String, root: MainTabController?) -> MoreRow? {
        root?.pages?.quickActionChoices().flatMap { $0.rows() }.first { $0.id == id }
    }

    /// A More page, as ⌘, opens one: its own tab when Settings › Tabs gave it one, else More's row.
    @discardableResult static func openPage(_ id: String, root: MainTabController) -> Bool {
        if TabChoice.pageIDs.contains(id), let tab = root.placedTab(tagged: TabChoice.page(id).tag) {
            root.show(tab)
            _ = (tab as? UINavigationController)?.popToRootViewController(animated: false)
            return true
        }
        guard let more = root.pages?.more, let stack = more.navigationController, root.slotIndex(for: stack) != nil else { return false }
        root.show(stack)
        stack.popToRootViewController(animated: false)
        more.loadViewIfNeeded()
        if more.open(rowId: id) != nil { return true }
        // A page More lists under another row: pushed on More's stack.
        guard let next = row(id, root: root)?.make() else { return false }
        stack.pushViewController(next, animated: true)
        return true
    }

    private static func missingBot(_ tile: QuickTile) -> String { "\(tile.botName ?? tile.bot ?? "That bot") isn’t on this gateway." }
    private static func missingPage(_ tile: QuickTile) -> String { "\(tile.pageName ?? tile.name) isn’t on this gateway." }

    private static func notice(_ message: String, root: MainTabController) {
        let alert = UIAlertController(title: "Couldn’t Run That Action", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        (FailureAlert.topmost(root) ?? root).present(alert, animated: true)
    }

    /// A failure in readable words: a shortcut's own (the gateway's refusal), never a type name.
    static func words(_ error: Error) -> String {
        if let local = error as? LocalizedError, let text = local.errorDescription, !text.isEmpty { return text }
        return "That didn’t go through. Try again."
    }
}
