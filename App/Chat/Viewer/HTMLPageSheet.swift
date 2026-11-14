import UIKit
import WebKit

// An HTML page a bot made, opened from a chat (a page card, a `MEDIA:` page, a file row): drawn live with its scripts
// running, the way the desktop app draws `::preview` in the reply
// (`V:components/assistant-ui/inline-preview-directive.tsx`). Quick Look shows HTML without running scripts, so a chart
// drawn by script opened blank or frozen (owner, a bot's follow-up chart, 2026-10-31). This overrides D-P8 ("no
// WKWebView") for pages; a web view is made only when a page opens or is pictured.
//
// Locked down like the desktop's sandboxed frame: no cookies or storage kept (a non-persistent store), the page reads
// only its own folder, and a tapped link leaves for the in-app Safari view instead of replacing the page.
//
// Widgets talk back as on the desktop: `window.hermes.send(prompt)` or `data-hermes-send="prompt"` on anything
// clickable sends the prompt to the chat's bot as a hidden turn (no bubble), and the page reloads when that turn ends,
// since the bot answers by rewriting the file. A sentence, not a payload (500 characters), at human speed.

final class HTMLPageSheet: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
    /// Where the page lives on the bot's computer, so it can be read again; nil for a file already on the phone.
    struct Source {
        var path: String
        var context: MediaContext
        /// Sends a prompt to the chat's bot with no bubble; nil when the page wasn't opened from a chat.
        var send: ((String) -> Void)?
        var botName: String
        /// [tasks] A page that isn't a file (a task's Task Page, drawn by the add-on): reads it again, in place of
        /// downloading `path`.
        var read: (@MainActor () async throws -> URL)? = nil
    }

    /// [tiles] A page opened from Tiles: its name as the title and the file under it (owner 2026-11-03: a plain name,
    /// "show that it's an HTML file if you click it"), with when it was updated, and a clock button for its Updates.
    struct Tile {
        var name: String
        var fileName: String
        /// "Updated 5 min ago · hourly", nil when no job keeps it updated.
        var status: () async -> String?
        var menu: (UIViewController) -> UIMenu
        /// [live-tiles] The tile's buttons go to its bot (prompt, the sheet, done when the bot is): false when refused
        /// (it says why). A page opened from Tiles has no chat to send in.
        var send: ((String, UIViewController, @escaping () -> Void) -> Bool)? = nil
        var botName: String? = nil
        /// [tile-versions] The page is an earlier version of a tile, opened from Versions: no Updates button; `verb`
        /// ("Roll Back", nil for the version that shows) puts it back on the tile.
        struct Version {
            var verb: String?
            var rollBack: (UIViewController) -> Void
        }
        var version: Version? = nil
        /// [tiles] The tile's pin: when its job runs (`TileUpdates.ran`), the open page is read again in place.
        var id: String? = nil
        /// [tiles] The page's own background as its tile's picture shows it: the sheet opens in it.
        var backdrop: UIColor? = nil
    }

    static let maxIntentLength = 500
    private static let intentGap: TimeInterval = 1.0

    /// nil while a tile opened before its page was on this Mac is still being read (`openTile`).
    private var file: URL?
    private let source: Source?
    private let tile: Tile?
    private var webView: WKWebView?
    /// [tiles] The page has drawn once: until then the web view is hidden behind a spinner, so the sheet never shows
    /// its own empty colour and then the page's (Mac pass 2026-11-14: a black sheet, then a white page snapping in).
    private var painted = false
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let status = UILabel()
    /// [glass-audit] Floating over the page: Liquid Glass (flattened in the Desktop Look by ThemeChrome).
    private let statusBar = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private var lastIntent = Date.distantPast
    private var waitingForReply = false
    /// The theme the page was handed (`prelude`), so a change of look hands it the new one.
    private var handedPrelude: String?
    /// [tiles] Where the page was scrolled when it was drawn again (the bot rewrote it, a look change): put back once
    /// it has drawn, so an update in place doesn't throw the reader to the top.
    private var keptScroll: [Double]?
    private var shareItem: UIBarButtonItem?
    /// [tiles] The tile's page was read from the bot's computer (nil: not yet, or it failed with no copy to show).
    private var tileRead: (() -> Void)?
    private var statusClock: Task<Void, Never>?

    /// The page's buttons can send: opened from a chat, or as a tile.
    private var talks: Bool { source?.send != nil || tile?.send != nil }

    static func opens(_ url: URL) -> Bool { opens(name: url.lastPathComponent) }

    nonisolated static func opens(name: String) -> Bool {
        ["html", "htm"].contains((name as NSString).pathExtension.lowercased())
    }

    @discardableResult
    static func present(_ url: URL, source: Source? = nil, tile: Tile? = nil, title: String? = nil,
                        from vc: UIViewController) -> HTMLPageSheet {
        show(url, source: source, tile: tile, title: title ?? tile?.name ?? url.lastPathComponent, from: vc)
    }

    private static func show(_ url: URL?, source: Source?, tile: Tile?, title: String, from vc: UIViewController) -> HTMLPageSheet {
        let page = HTMLPageSheet(file: url, source: source, tile: tile)
        AppLog.trace("chatui", "html page opened live, talk-back \(source?.send != nil || tile?.send != nil ? "on" : "off")\(tile != nil ? ", as a tile" : "")\(url == nil ? ", page still reading" : "")")
        let sheet = ChatSheet.wrap(page, title: title, detents: [.large()])
        // [ipad-polish] A page made for a browser, not a phone's width. [tiles] On the Mac: the document page size
        // (`SheetStyle.macPage`, the size a note's sheet takes too), 960 wide at most, as tall as the window allows, the
        // same every time; `macFit` below keeps it with the window as the window is resized.
        #if targetEnvironment(macCatalyst)
        SheetStyle.macPage(sheet, width: 960, from: vc)
        #else
        SheetStyle.widen(sheet, to: 960, from: vc)
        #endif
        vc.present(sheet, animated: true)
        return page
    }

    #if targetEnvironment(macCatalyst)
    /// The page's size in a window this size: `SheetStyle.macPage`'s (960 wide at most, 80 a side; as tall as the
    /// window allows, never past it), so a resize keeps the size it opened at.
    private static func macFit(_ window: CGSize) -> CGSize {
        CGSize(width: max(620, min(960, window.width - 160)),
               height: min(window.height - 80, max(480, min(window.height - 180, 1100))))
    }

    /// [tiles] Mac pass 2026-11-14: the size was worked out once, when the page opened, so a page opened in a small
    /// window stayed small when the window grew, and one opened in a big window ran past a window made smaller. It
    /// follows the window now.
    private var windowWatch: WindowSizeProbe?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard windowWatch == nil, let sheet = navigationController, sheet.modalPresentationStyle == .formSheet,
              let container = sheet.presentationController?.containerView else { return }
        // The sheet's container is the window's size; a probe filling it hears every resize (UIWindowScene's
        // effectiveGeometry wasn't reported to an observer on the Mac).
        let probe = WindowSizeProbe(frame: container.bounds)
        probe.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        probe.isUserInteractionEnabled = false
        probe.changed = { [weak sheet] size in
            guard let sheet, size.width > 0, size.height > 0 else { return }
            let fit = Self.macFit(size)
            if sheet.preferredContentSize != fit { sheet.preferredContentSize = fit }
        }
        container.insertSubview(probe, at: 0)
        windowWatch = probe
    }
    #endif

    /// [tiles] A tile or pinned page opens at once: from the copy already on this Mac (the Tiles page drew it), read
    /// again behind it and drawn again only if the bot changed it. It used to wait, with nothing on screen, for the page
    /// to download again before the sheet even started to open (Mac pass 2026-11-14: three seconds of nothing on a slow
    /// gateway, and a second click cancelled it). Never read yet: the sheet opens with a spinner, and says why if the
    /// page can't be read, with Try Again.
    @discardableResult
    static func openTile(path: String, name: String, context: MediaContext, tile: Tile, from vc: UIViewController) -> HTMLPageSheet {
        let store = MediaLoader.shared.store(for: context.accountId)
        let kept = store.cachedFile(MediaStore.gatewayKey(accountId: context.accountId, profile: context.profile, path: path), name: name)
        let page = show(kept, source: FilePreviewPresenter.pageSource(path, context, from: vc), tile: tile, title: tile.name, from: vc)
        page.tileRead = { [weak page] in
            if let page, !page.painted, let backdrop = tile.backdrop { page.view.backgroundColor = backdrop; page.inkBar(for: backdrop) }
            page?.spinner.startAnimating()
            page?.readTile(path: path, name: name, context: context)
        }
        page.readTile(path: path, name: name, context: context)
        return page
    }

    /// The tile's page from the bot's computer; drawn again only when it differs from the copy shown.
    private func readTile(path: String, name: String, context: MediaContext) {
        contentUnavailableConfiguration = nil
        let shown = file.flatMap { try? Data(contentsOf: $0) }
        Task { [weak self] in
            do {
                // A copy already showing stays on a failure, and says so (below): the loader's own fall-back to it was silent.
                let url = try await MediaLoader.shared.file(path: path, name: name, context: context, progressKey: "page|" + path,
                                                            fresh: true, keptOnFailure: shown == nil)
                guard let self else { return }
                let changed = shown == nil || url != self.file || (try? Data(contentsOf: url)) != shown
                self.file = url
                self.shareItem?.isEnabled = true
                if changed { self.load() }
                AppLog.trace("chatui", "tile page read again, \(changed ? "changed: drawn again" : "unchanged")")
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                if self.file != nil {
                    // A kept copy shows: it stays, and says it may be old (Mac pass 2026-11-14: nothing said so).
                    AppLog.note("chatui", "tile page could not be read again, the kept copy stays")
                    self.show(Self.lastCopyNotice(error), for: 5)
                    return
                }
                AppLog.note("chatui", "tile page could not be read: \((error as? MediaLoadError).map { String(describing: $0) } ?? "\(type(of: error))")")
                self.spinner.stopAnimating()
                // [tiles] Mac pass round 3: the notice sat on the tile's own colour (a light page in dark mode), its
                // words in the app's light ink, all but unreadable. Nothing of the page shows: the sheet's own colour.
                self.view.backgroundColor = ChatPalette.page
                self.navigationController?.navigationBar.overrideUserInterfaceStyle = .unspecified
                var notice = UIContentUnavailableConfiguration.empty()
                notice.image = UIImage(systemName: "exclamationmark.triangle")
                notice.text = "Couldn’t Open \(self.tile?.name ?? name)"
                notice.secondaryText = (error as? MediaLoadError)?.fileMessage ?? MediaLoadError.unreachable.fileMessage
                var button = UIButton.Configuration.bordered()
                button.title = "Try Again"
                notice.button = button
                notice.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.tileRead?() }
                self.contentUnavailableConfiguration = notice
                self.shareItem?.isEnabled = false   // [tiles] nothing to share yet
            }
        }
    }

    /// [tiles] A page that couldn't be read again while its last copy shows.
    private static func lastCopyNotice(_ error: any Error) -> String {
        error as? MediaLoadError == .notFound ? "This page isn’t on your gateway anymore · showing the last copy"
                                              : "Couldn’t reach your gateway · showing the last copy"
    }

    init(file: URL?, source: Source?, tile: Tile? = nil) {
        self.file = file
        self.source = source
        self.tile = tile
        super.init(nibName: nil, bundle: nil)
    }

    deinit { statusClock?.cancel() }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A page's web view: the theme prelude and `window.hermes` first, nothing kept. `handler` takes the page's sends;
    /// without one `send` answers that it can't send from here.
    static func makeWebView(traits: UITraitCollection, handler: WKScriptMessageHandler? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let content = config.userContentController
        content.addUserScript(WKUserScript(source: prelude(traits, talks: handler != nil), injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        if let handler { content.add(WeakHandler(handler), name: "hermes") }
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        return web
    }

    // MARK: A ready web view

    /// [tiles] A web view made ahead, its page process already running, for the next page to open on. A new web view
    /// spent most of a second starting its process before the page could draw: a second of black sheet and a spinner
    /// on every tile opened (Mac pass 2026-11-14, measured: paint about 1 s after the click). Mac only: the iPhone
    /// opens pages full screen, one at a time.
    private static var spare: WKWebView?

    static func prewarm(traits: UITraitCollection) {
        #if targetEnvironment(macCatalyst)
        guard spare == nil else { return }
        let web = makeWebView(traits: traits)
        web.loadHTMLString("<!doctype html><html></html>", baseURL: nil)
        spare = web
        #endif
    }

    /// The ready web view (nil when there is none), its sends handed to `handler`.
    private static func takeSpare(traits: UITraitCollection, handler: WKScriptMessageHandler?) -> WKWebView? {
        guard let web = spare else { return nil }
        spare = nil
        let content = web.configuration.userContentController
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: prelude(traits, talks: handler != nil), injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        if let handler { content.add(WeakHandler(handler), name: "hermes") }
        // The next one, once this sheet has opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { prewarm(traits: traits) }
        return web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = tile?.backdrop ?? ChatPalette.page
        let web = Self.takeSpare(traits: traitCollection, handler: talks ? self : nil)
            ?? Self.makeWebView(traits: traitCollection, handler: talks ? self : nil)
        web.navigationDelegate = self
        web.accessibilityIdentifier = "html.page"
        // The page's window is the part of the sheet that shows, from under the title bar to above the home bar: a
        // tile fills its window exactly (100vh, no scrolling), so a window running up under the bar hid its top (owner
        // 2026-11-03, the revenue tile opened from Tiles: its headline cut off).
        web.translatesAutoresizingMaskIntoConstraints = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.alpha = 0   // [tiles] shown once the page has drawn (`didFinish`)
        view.addSubview(web)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        webView = web
        // Not loaded yet: the sheet takes the app's own look (Appearance, a skin) only once it is on screen, and a
        // page handed the phone's look kept it (2026-11-05: white cards, dark words on the dark sheet with the app set
        // to Dark and the phone to Light). `viewIsAppearing` hands it the theme and loads it.

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.cornerConfiguration = .capsule()
        shadeStatusBar()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (page: HTMLPageSheet, _) in
            page.shadeStatusBar()
            page.handTheme()
        }
        statusBar.isHidden = status.text == nil   // [tiles] a read that failed before the sheet loaded has said so already
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = HQFont.preferred(.footnote)
        status.adjustsFontForContentSizeCategory = true
        // [glass-audit] the label's own ink, as BrowserPill: the glass flips it light or dark for the page behind.
        status.numberOfLines = 2
        status.textAlignment = .center
        statusBar.contentView.addSubview(status)
        view.addSubview(statusBar)
        NSLayoutConstraint.activate([
            statusBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            statusBar.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
            status.leadingAnchor.constraint(equalTo: statusBar.contentView.leadingAnchor, constant: 14),
            status.trailingAnchor.constraint(equalTo: statusBar.contentView.trailingAnchor, constant: -14),
            status.topAnchor.constraint(equalTo: statusBar.contentView.topAnchor, constant: 8),
            status.bottomAnchor.constraint(equalTo: statusBar.contentView.bottomAnchor, constant: -8),
        ])

        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: UIAction { [weak self] _ in
            guard let self, let file = self.file else { return }
            FilePreviewPresenter.shared.share(file, from: self, anchor: nil)
        })
        share.accessibilityLabel = "Share"
        share.isEnabled = file != nil   // [tiles] a tile still being read has nothing to share yet
        shareItem = share
        var items = navigationItem.rightBarButtonItems ?? []
        items.append(share)
        if source != nil {
            let reload = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), primaryAction: UIAction { [weak self] _ in
                self?.readAgain(note: nil)
            })
            reload.accessibilityLabel = "Reload"
            items.append(reload)
        }
        // [tiles] Its Updates on a clock button; the file and when it was updated under its name.
        if let tile {
            if let version = tile.version {
                // [tile-versions] An earlier version: Roll Back where the tile has its Updates.
                if let verb = version.verb {
                    let back = UIBarButtonItem(title: verb, primaryAction: UIAction { [weak self] _ in
                        guard let self else { return }
                        version.rollBack(self)
                    })
                    back.style = .prominent
                    back.accessibilityIdentifier = "tile.version.rollback"
                    items.insert(back, at: 0)
                }
            } else {
                let updates = UIBarButtonItem(image: UIImage(systemName: "clock.arrow.circlepath"), menu: tile.menu(self))
                updates.accessibilityLabel = "Updates"
                updates.accessibilityIdentifier = "tile.updates.button"
                items.append(updates)
            }
            navigationItem.subtitle = tile.fileName
            // [tiles] "updated 5 min ago" kept current while it's open, not frozen at the moment it opened.
            statusClock = Task { [weak self] in
                while !Task.isCancelled {
                    self?.readStatus()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
        navigationItem.rightBarButtonItems = items

        if source != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(turnEnded(_:)), name: PageSnapshots.turnEnded, object: nil)
        }
        if tile?.id != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(tileRan(_:)), name: TileUpdates.ran, object: nil)
        }
        #if DEBUG
        if UserDefaults.standard.string(forKey: "HQDebugTour") == "htmlstatus" { show("Sent to Hermes — waiting for a reply…") }
        #endif
        // [tiles] A spinner only when drawing takes a moment: a page from this Mac's copy draws before it would show.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.painted, self.contentUnavailableConfiguration == nil else { return }
            self.spinner.startAnimating()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if !painted, let backdrop = tile?.backdrop { inkBar(for: backdrop) }   // [tiles] the bar reads on the page's colour at once
        handTheme()
    }

    /// The theme for the look the sheet shows now, and the page drawn with it (again, when the look changed).
    private func handTheme() {
        guard let webView, viewIfLoaded?.window != nil else { return }
        let script = Self.prelude(traitCollection, talks: talks)
        guard script != handedPrelude else { return }
        handedPrelude = script
        let content = webView.configuration.userContentController
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        load()
    }

    private func load() {
        // The first load waits for the theme (`handTheme`); a tile still being read loads when it lands (`readTile`).
        guard handedPrelude != nil, let file, let webView else { return }
        guard painted else { webView.loadPageFile(file); return }
        // [tiles] Drawn again in place: where it was scrolled is put back once it has drawn (`didFinish`).
        webView.evaluateJavaScript("[scrollX, scrollY]") { [weak self, weak webView] value, _ in
            guard let self, let webView, let file = self.file else { return }
            if let at = value as? [Double], at.contains(where: { $0 > 0 }) { self.keptScroll = at }
            webView.loadPageFile(file)
        }
    }

    /// [tiles] The tile's line under its name: its file, and when its job last updated it.
    private func readStatus() {
        guard let tile else { return }
        Task { [weak self] in
            guard let status = await tile.status(), let self else { return }
            self.navigationItem.subtitle = tile.fileName + " · " + status
        }
    }

    /// [tiles] The tile's job has just run (the Tiles page saw it, `TileUpdates.refresh`): the open page is read again
    /// and drawn in place, and its line says so (Mac pass 2026-11-14: it kept the old numbers until ↻).
    @objc private func tileRan(_ note: Notification) {
        guard let id = tile?.id, note.object as? String == id else { return }
        AppLog.trace("chatui", "open tile's job ran: read again in place")
        readAgain(note: "Updated")
        readStatus()
    }

    @objc private func turnEnded(_ note: Notification) {
        guard (note.object as? ContextBox)?.context == source?.context, waitingForReply else { return }
        waitingForReply = false
        readAgain(note: "Updated")
    }

    /// The page from the bot's computer again (the bot may have rewritten it), then drawn again.
    func readAgain(note: String?) {
        // [tiles] A tile that couldn't be read yet: ↻ is Try Again.
        if file == nil, let tileRead { tileRead(); return }
        guard let source else { load(); return }
        let showing = file != nil
        Task { [weak self] in
            let url: URL?
            var failure: (any Error)?
            if let read = source.read {
                url = try? await read()
            } else {
                // [tiles] A failure says so: ↻ on a gateway that can't be reached drew the same copy and said "Updated"
                // (Mac pass 2026-11-14).
                do {
                    url = try await MediaLoader.shared.file(path: source.path, name: self?.file?.lastPathComponent ?? "",
                                                            context: source.context, progressKey: "page|" + source.path,
                                                            fresh: true, keptOnFailure: !showing)
                } catch {
                    url = nil
                    failure = error
                }
            }
            guard let self else { return }
            if let failure, showing, !(failure is CancellationError) {
                self.show(Self.lastCopyNotice(failure), for: 5)
                return
            }
            if let url { self.file = url; self.shareItem?.isEnabled = true }
            self.load()
            if let note { self.show(note, for: 2) }
        }
    }

    /// [glass-audit] Dark glass turns light grey over a bright page, and white words on it measured 2.5:1: in dark the
    /// glass is shaded black 35 %, as the chat's pills were (thinking-row backing, round 3).
    private func shadeStatusBar() {
        let effect = UIGlassEffect(style: .regular)
        if traitCollection.userInterfaceStyle == .dark { effect.tintColor = UIColor.black.withAlphaComponent(0.35) }
        statusBar.effect = effect
    }

    private func show(_ text: String?, for seconds: Double? = nil) {
        status.text = text
        statusBar.isHidden = text == nil
        guard let seconds, let text else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if self?.status.text == text { self?.show(nil) }
        }
    }

    // MARK: Talk-back

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "hermes", message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let id = body["id"] as? Int else { return }
        let prompt = (body["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func ack(_ ok: Bool, _ error: String? = nil) {
            let result = ok ? "{ok:true}" : "{ok:false,error:'\(error ?? "undelivered")'}"
            webView?.evaluateJavaScript("window.__hermesAck && window.__hermesAck(\(id), \(result))")
        }
        guard talks else { ack(false, "undelivered"); return }
        guard !prompt.isEmpty else { ack(false, "empty"); return }
        // Rejected, never cut: a sliced payload reaches the bot as garbage while the page thinks it sent.
        guard prompt.count <= Self.maxIntentLength else { ack(false, "too_long"); return }
        guard Date().timeIntervalSince(lastIntent) >= Self.intentGap else { ack(false, "throttled"); return }
        lastIntent = Date()
        if let send = tile?.send {
            // [live-tiles] As the tile: its bot rewrites the file, read again when it's done.
            let sent = send(prompt, self) { [weak self] in
                guard let self, self.waitingForReply else { return }
                self.waitingForReply = false
                self.readAgain(note: "Updated")
            }
            guard sent else { ack(false, "undelivered"); return }
        } else {
            source?.send?(prompt)
        }
        AppLog.trace("chatui", "html page sent a hidden prompt (\(prompt.count) chars)")
        waitingForReply = true
        show("Sent to \(tile?.botName ?? source?.botName ?? "the bot") · the page updates when it answers")
        ack(true)
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        // The page itself (and its own #anchors) loads here; any other address opens outside it.
        if url.isFileURL, url.path == file?.path { decisionHandler(.allow); return }
        if action.navigationType == .linkActivated { LinkOpener.open(url, from: self) }
        decisionHandler(action.targetFrame?.isMainFrame == false && !url.isFileURL ? .allow : .cancel)
    }

    /// The bands above and below the page's window take the page's own background (a grey tile page in a white sheet).
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("""
            (() => { const b = getComputedStyle(document.body).backgroundColor;
              return /rgba\\(.*, 0\\)$|transparent/.test(b) ? getComputedStyle(document.documentElement).backgroundColor : b })()
            """) { [weak self] value, _ in
            guard let self else { return }
            if let at = self.keptScroll {
                self.keptScroll = nil
                // Twice: once now, once after the next frame (a page that draws its charts by script grows then).
                let js = "scrollTo(\(at[0]),\(at[1]));requestAnimationFrame(function(){scrollTo(\(at[0]),\(at[1]))})"
                webView.evaluateJavaScript(js)
            }
            let colour = (value as? String).flatMap(Self.cssColour)
            // [tiles] The first draw fades in over its own colour, the spinner gone; later ones (a look change, the bot
            // rewrote it) swap in place.
            if !self.painted {
                self.painted = true
                self.spinner.stopAnimating()
                UIView.animate(withDuration: 0.15) {
                    webView.alpha = 1
                    if let colour { self.view.backgroundColor = colour }
                }
            }
            guard let colour else { return }
            self.view.backgroundColor = colour
            // The bar's words and buttons in the ink that reads on the page's colour: white on a light tile in dark mode
            // was all but invisible (2026-11-03).
            self.inkBar(for: colour)
        }
    }

    private func inkBar(for colour: UIColor) {
        var white: CGFloat = 0
        colour.getWhite(&white, alpha: nil)
        navigationController?.navigationBar.overrideUserInterfaceStyle = white > 0.6 ? .light : white < 0.35 ? .dark : .unspecified
        #if targetEnvironment(macCatalyst)
        // [macpass-popups r3] The Mac bar is opaque in the look's own colour: in the Desktop Look dark its near-black
        // stood as a band over a slate tile. The bar takes the page's colour instead, its title fonts kept.
        guard let bar = navigationController?.navigationBar else { return }
        let look = (navigationItem.standardAppearance ?? bar.standardAppearance).copy()
        look.backgroundEffect = nil
        look.backgroundColor = colour
        look.shadowColor = .clear
        navigationItem.standardAppearance = look
        navigationItem.scrollEdgeAppearance = look
        navigationItem.compactAppearance = look
        #endif
    }

    /// [tiles] A page that fails to draw still shows what it has, not a spinner forever.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { reveal(webView, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { reveal(webView, error) }

    private func reveal(_ webView: WKWebView, _ error: any Error) {
        // A load the next one replaced (the theme handed, the page read again) is not a failure.
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled || ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        guard !painted else { return }
        painted = true
        spinner.stopAnimating()
        webView.alpha = 1
    }

    /// `rgb(…)`/`rgba(…)` as a colour; nil for a clear one (the page paints nothing: the sheet's own stays).
    static func cssColour(_ css: String) -> UIColor? {
        let numbers = css.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap(Double.init)
        guard numbers.count >= 3 else { return nil }
        let alpha = numbers.count >= 4 ? numbers[3] : 1
        guard alpha > 0.5 else { return nil }
        return UIColor(red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: 1)
    }

    // MARK: Prelude

    /// The desktop frame's theme names (`--foreground`, `--muted-foreground`, `--accent`, `--border`, `--card`), the
    /// system font, no margins, a clear background and pictures and drawings no wider than the screen, set first so
    /// the page's own styles win. A drawing of a fixed size wider than the screen (Otto's chart: an 840-wide `<svg>`
    /// with no viewBox, cut off at attempt 6) is scaled down to fit. A page that paints its own background keeps its
    /// controls in its own light or dark (a white page in a dark app drew a black slider track). Its words too: a page that paints a light
    /// background in a dark app (or the other way) and sets no text colour of its own gets the theme's ink for its own
    /// look, not the app's (2026-11-03: a light tile's words were light grey on white in dark mode). Then `window.hermes.send` (posting to the app, or answering that it can't).
    static func prelude(_ traits: UITraitCollection, talks: Bool) -> String {
        func css(_ dynamic: UIColor) -> String {
            let color = dynamic.resolvedColor(with: traits)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return "rgba(\(Int(r * 255)),\(Int(g * 255)),\(Int(b * 255)),\(String(format: "%.3f", a)))"
        }
        // In :where() (no weight): a page's own rules win, even `*{padding:0}` (owner 2026-11-02: a dashboard sized
        // 100vw x 100vh got the 16 pt sides on top and ran wider than its window).
        let style = """
        :root{--foreground:\(css(ChatPalette.label));--muted-foreground:\(css(ChatPalette.label2));\
        --accent:\(css(ChatPalette.tint));--border:\(css(ChatPalette.separator));--card:\(css(ChatPalette.elevated));\
        --hq-radius:\(ThemeTable.desktopLook ? Int(DesktopRows.radius) : 16)px;\
        color-scheme:\(traits.userInterfaceStyle == .dark ? "dark" : "light");color:var(--foreground);\
        font-family:-apple-system,system-ui,sans-serif;-webkit-text-size-adjust:100%}\
        :where(html,body){margin:0;padding:0;background:transparent}:where(body){padding:12px 16px;box-sizing:border-box}\
        :where(img,svg,canvas,video){max-width:100%}:where(svg[viewBox]){height:auto}
        """
        let escaped = style.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
        let send = talks ? """
        var n=0,w={};window.__hermesAck=function(id,r){var f=w[id];delete w[id];if(f)f(r)};\
        window.hermes={send:function(p){return new Promise(function(res){var id=++n;w[id]=res;\
        try{window.webkit.messageHandlers.hermes.postMessage({id:id,prompt:String(p)})}catch(e){delete w[id];res({ok:false,error:'undelivered'})}})}};\
        document.addEventListener('click',function(e){var t=e.target&&e.target.closest&&e.target.closest('[data-hermes-send]');\
        if(t){e.preventDefault();window.hermes.send(t.getAttribute('data-hermes-send'))}},true);
        """ : "window.hermes={send:function(){return Promise.resolve({ok:false,error:'undelivered'})}};"
        return """
        (function(){var m=document.querySelector('meta[name=viewport]');if(!m){m=document.createElement('meta');m.name='viewport';\
        m.content='width=device-width,initial-scale=1';(document.head||document.documentElement).appendChild(m)}\
        var s=document.createElement('style');s.textContent=`\(escaped)`;\
        (document.head||document.documentElement).prepend(s);\(send)\
        function fit(){var vw=document.documentElement.clientWidth;\
        document.querySelectorAll('svg[width][height]:not([viewBox])').forEach(function(g){\
        var w=parseFloat(g.getAttribute('width')),h=parseFloat(g.getAttribute('height'));\
        if(w>0&&h>0&&w>vw-8){g.setAttribute('viewBox','0 0 '+w+' '+h);g.setAttribute('preserveAspectRatio','xMinYMin meet');\
        g.style.width='100%';g.style.height='auto'}})}\
        function scheme(){var c=getComputedStyle(document.body).backgroundColor,m=c&&c.match(/[\\d.]+/g);\
        if(!m||m.length<3||(m.length>3&&+m[3]<0.5)){c=getComputedStyle(document.documentElement).backgroundColor;m=c&&c.match(/[\\d.]+/g)}\
        if(m&&m.length>=3&&!(m.length>3&&+m[3]<0.5)){var l=(0.299*m[0]+0.587*m[1]+0.114*m[2])/255;\
        var light=l>0.5,r=document.documentElement.style;r.colorScheme=light?'light':'dark';\
        if(light===\(traits.userInterfaceStyle == .dark)){r.setProperty('--foreground',light?'#1c1c1e':'#f2f2f7');\
        r.setProperty('--muted-foreground',light?'rgba(60,60,67,0.75)':'rgba(235,235,245,0.7)')}}}\
        document.addEventListener('DOMContentLoaded',function(){fit();scheme();new MutationObserver(fit).observe(document.body,\
        {subtree:true,childList:true,attributes:true,attributeFilter:['width','height']})});})();
        """
    }
}

/// The page's message handler without the web view keeping the page's sheet alive.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Keeps a page where it is: it and its own #anchors load, a tapped link opens in the in-app Safari view.
final class PageLinkGuard: NSObject, WKNavigationDelegate {
    private let file: URL
    private weak var host: UIViewController?

    init(file: URL, host: UIViewController) {
        self.file = file
        self.host = host
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.isFileURL, url.path == file.path { decisionHandler(.allow); return }
        if action.navigationType == .linkActivated, let host { LinkOpener.open(url, from: host) }
        decisionHandler(action.targetFrame?.isMainFrame == false && !url.isFileURL ? .allow : .cancel)
    }
}

#if targetEnvironment(macCatalyst)
/// [tiles] Says when its size changes: laid out to fill a sheet's container, it hears the window being resized.
final class WindowSizeProbe: UIView {
    var changed: ((CGSize) -> Void)?
    private var last = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != last else { return }
        last = bounds.size
        changed?(bounds.size)
    }
}
#endif
