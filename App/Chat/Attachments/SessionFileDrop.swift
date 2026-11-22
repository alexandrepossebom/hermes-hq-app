// [spring-drop] Owner 2026-11-22: "I need to be able to drag files on to a session so that if you hold on the session
// long enough it will open the session and let you drop that file in to that session. This same functionality exists
// in almost every other app." Files dragged from outside the app (the Finder, Files, Photos, another app on the iPad)
// over a listed chat light that chat's row; held there `SpringHold.delay` the row blinks and the chat opens under the
// drag, the way the Finder's folders and Mail's mailboxes spring open, and the chat's own drop target
// (`AttachmentDropTarget`) takes the files from there. Let go over the row itself and the chat opens with the files
// already in its tray (`DroppedFilesHandOff`). Every list of chats does it: Sessions, Bots (the bots' own chats and the
// chats under them), the Mac's sidebar, the inspector's Chats tab and the strip of chats under a bot chat's bar.
// A drag from inside the app (a row being moved, a message's photo) is left to the list's own drop handling.

import UIKit

/// When a file drag held over a row springs it open. Pure, so the timing is unit-tested without a drag.
nonisolated struct SpringHold: Equatable {
    /// How long a drag rests on a row before it opens: the Mac's spring-loading delay at its middle setting.
    static let delay: TimeInterval = 0.7

    /// The row under the drag (nil: none).
    private(set) var key: String?
    /// When the drag came onto `key`.
    private(set) var since: Date?
    /// The row this drag already opened: resting on it again does nothing until the drag leaves it.
    private(set) var opened: String?

    /// The drag is over `key` now. True when that is a different row than before (the light moves).
    @discardableResult
    mutating func over(_ key: String?, at now: Date) -> Bool {
        guard key != self.key else { return false }
        self.key = key
        since = key == nil ? nil : now
        if key != opened { opened = nil }
        return true
    }

    /// The row to open now, if the drag has rested on it long enough and has not opened it already.
    func due(at now: Date, delay: TimeInterval = SpringHold.delay) -> String? {
        guard let key, let since, key != opened, now.timeIntervalSince(since) >= delay - 0.001 else { return nil }
        return key
    }

    /// The row opened: marked spent until the drag leaves it.
    mutating func didOpen(_ key: String) { opened = key }

    /// The drag left the list or ended.
    mutating func reset() { self = SpringHold() }
}

/// Files dropped onto a chat's row, waiting for that chat's screen to take them into its tray.
@MainActor enum DroppedFilesHandOff {
    /// Which chat the files are for.
    enum Chat: Equatable {
        /// A listed chat, by its profile (empty: any) and stored session id.
        case session(profile: String, id: String)
        /// A bot's own chat, by the bot's profile.
        case botChat(profile: String)
        /// The chat already on show in this screen (the inspector's lit row, the strip's own tab).
        case screen(ObjectIdentifier)
    }

    private static var waiting: (chat: Chat, providers: [NSItemProvider], until: Date)?

    /// Holds `providers` for `chat` for a few seconds, then looks for its screen already on show (the chat beside the
    /// list in two panes needs no push, so no new screen comes to take them).
    static func offer(_ providers: [NSItemProvider], to chat: Chat) {
        guard !providers.isEmpty else { return }
        waiting = (chat, providers, Date().addingTimeInterval(6))
        AppLog.note("attach", "spring drop: \(providers.count) held for the chat it opens")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { sweep() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { sweep() }
    }

    /// A chat screen on show: it takes the waiting files when they are its own.
    static func claim(_ screen: ChatViewController) {
        guard let held = waiting else { return }
        guard held.until > Date() else { waiting = nil; return }
        guard matches(held.chat, screen) else { return }
        waiting = nil
        screen.attachDropped(held.providers)
    }

    static func matches(_ chat: Chat, _ screen: ChatViewController) -> Bool {
        switch chat {
        case .screen(let id):
            return ObjectIdentifier(screen) == id
        case .session(let profile, let id):
            if let live = screen.session as? LiveChatSession {
                return live.storedSessionId == id && (profile.isEmpty || live.profile == profile)
            }
            return false
        case .botChat(let profile):
            if let live = screen.session as? LiveChatSession { return live.profile == profile && live.isBotChat }
            return false
        }
    }

    /// The chat screens in the app's windows that are on show (the top of their navigation stacks).
    private static func sweep() {
        guard waiting != nil else { return }
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                for screen in shownChats(in: window.rootViewController) { claim(screen) }
            }
        }
    }

    private static func shownChats(in root: UIViewController?) -> [ChatViewController] {
        guard let root else { return [] }
        var found: [ChatViewController] = []
        if let chat = root as? ChatViewController, chat.viewIfLoaded?.window != nil { found.append(chat) }
        for child in root.children { found += shownChats(in: child) }
        if let presented = root.presentedViewController, presented.presentingViewController === root { found += shownChats(in: presented) }
        return found
    }

    #if DEBUG
    static var debugWaiting: Chat? { waiting?.chat }
    #endif
}

/// One list's part in a file drag: which row is under it, the light on that row, the hold that opens it and the drop
/// onto it. A list with a drop delegate of its own calls `update`/`exit`/`perform` from it; a plain view uses
/// `SessionFileDropInteraction`.
@MainActor final class SessionFileDrop {
    /// A chat's row under the drag.
    struct Target {
        /// The row's identity within its list.
        var key: String
        /// The view drawn as the row (the light is laid over it).
        var view: UIView
        /// The part of `view` to light (nil: all of it).
        var rect: CGRect? = nil
        var cornerRadius: CGFloat = 12
        /// The chat the row opens, for the files let go over the row.
        var chat: DroppedFilesHandOff.Chat
        /// Opens the row's chat, as a click on it does.
        var open: () -> Void
    }

    /// The row under `point` (in the list's own view) for a file drag; nil where no chat would open.
    var target: (CGPoint) -> Target? = { _ in nil }
    /// The list's view, where the drag's location is measured.
    weak var list: UIView?

    private var hold = SpringHold()
    private var current: Target?
    private var timer: Timer?
    private var light: SpringLight?

    init(list: UIView? = nil) { self.list = list }

    /// Files from outside the app that a chat can take (a drag from inside the app is the list's own).
    static func files(_ session: UIDropSession) -> [NSItemProvider] {
        guard session.localDragSession == nil else { return [] }
        return session.items.map(\.itemProvider).filter { AttachmentDrop.attachable($0.registeredTypeIdentifiers) }
    }

    static func carriesFiles(_ session: UIDropSession) -> Bool {
        session.localDragSession == nil && session.items.contains { AttachmentDrop.attachable($0.itemProvider.registeredTypeIdentifiers) }
    }

    /// The drag moved. `.copy` over a chat's row (the badge says the files go there), `.cancel` elsewhere.
    func update(_ session: UIDropSession) -> UIDropOperation {
        guard Self.carriesFiles(session), let list else { exit(); return .cancel }
        let found = target(session.location(in: list))
        if hold.over(found?.key, at: Date()) {
            current = found
            showLight(on: found)
            timer?.invalidate()
            timer = nil
            if found != nil {
                Haptics.play(.selection)
                let timer = Timer(timeInterval: SpringHold.delay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.springIfDue() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        } else if let found {
            current = found   // the same row, maybe redrawn: keep its view fresh
            if light?.superview !== found.view { showLight(on: found) }
        }
        return found == nil ? .cancel : .copy
    }

    /// The drag left the list, or ended.
    func exit() {
        timer?.invalidate()
        timer = nil
        hold.reset()
        current = nil
        showLight(on: nil)
    }

    /// The drag let go: over a chat's row its files go to that chat, which opens. False when it was not over one.
    @discardableResult
    func perform(_ session: UIDropSession) -> Bool {
        let providers = Self.files(session)
        let found = list.flatMap { target(session.location(in: $0)) } ?? current
        exit()
        guard let found, !providers.isEmpty else { return false }
        Haptics.play(.soft)
        AppLog.note("attach", "spring drop: \(providers.count) let go on a chat's row")
        DroppedFilesHandOff.offer(providers, to: found.chat)
        found.open()
        return true
    }

    private func springIfDue() {
        timer = nil
        guard let key = hold.due(at: Date()), let target = current, target.key == key else { return }
        hold.didOpen(key)
        AppLog.note("attach", "spring drop: held on a chat's row, opening it")
        Haptics.play(.light)
        let opening = light
        let go = { [weak self] in
            // The drag may have left the row meanwhile (the list scrolled, the drag ended): only the row still lit.
            guard let self, self.current?.key == key else { return }
            target.open()
            if opening === self.light { self.showLight(on: nil) }
        }
        if let opening { opening.blink(go) } else { go() }
    }

    private func showLight(on target: Target?) {
        guard let target else {
            light?.fadeAway()
            light = nil
            return
        }
        if let light, light.superview === target.view {
            light.frame = target.rect ?? target.view.bounds
            return
        }
        light?.fadeAway()
        let shown = SpringLight(frame: target.rect ?? target.view.bounds, cornerRadius: target.cornerRadius)
        if target.rect == nil { shown.autoresizingMask = [.flexibleWidth, .flexibleHeight] }
        target.view.addSubview(shown)
        shown.appear()
        light = shown
    }

    #if DEBUG
    /// Unit tests: the row the hold would open now, `after` seconds on it.
    var debugHold: SpringHold { hold }
    var debugLit: Bool { light != nil }
    #endif
}

/// `SessionFileDrop` for a view with no drop delegate of its own (the inspector's table, the strip of chats).
@MainActor final class SessionFileDropInteraction: NSObject, UIDropInteractionDelegate {
    let drop: SessionFileDrop

    init(drop: SessionFileDrop) {
        self.drop = drop
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        SessionFileDrop.carriesFiles(session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: drop.update(session))
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) { drop.exit() }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) { drop.exit() }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        drop.perform(session)
    }
}

/// The light on a row a file drag is over: a tinted fill inside a tint outline, as a list's drop target is drawn.
/// Held long enough it blinks twice before the chat opens (the Finder's spring-loaded folder); under Reduce Motion it
/// stays lit instead. Touches pass through.
final class SpringLight: UIView {
    init(frame: CGRect, cornerRadius: CGFloat) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "sessions.springDropLight"
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 2
        apply()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in self.apply() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        apply()
    }

    private func apply() {
        let color = tintColor.resolvedColor(with: traitCollection)
        layer.borderColor = color.cgColor
        backgroundColor = color.withAlphaComponent(0.16)
    }

    func appear() {
        alpha = 0
        UIView.animate(withDuration: HQMotion.quick) { self.alpha = 1 }   // motion-ok: opacity only
    }

    func fadeAway() {
        UIView.animate(withDuration: HQMotion.quick, animations: { self.alpha = 0 }, completion: { _ in self.removeFromSuperview() })   // motion-ok: opacity only
    }

    /// Two quick blinks, then `done`. Under Reduce Motion `done` at once.
    func blink(_ done: @escaping () -> Void) {
        guard !HQMotion.reduced, window != nil else { return done() }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 0.15, 1, 0.15, 1]
        blink.duration = 0.32
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        layer.add(blink, forKey: "hq.springBlink")
        CATransaction.commit()
    }
}
