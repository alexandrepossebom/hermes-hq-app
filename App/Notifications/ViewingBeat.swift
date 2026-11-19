// [viewing] Tells the add-on which chat this device has in front of its person (HermesKit/Push/ViewingRules.swift),
// so a reply being read here alerts no other device. Only the chat's id and its bot's name leave the device.

import UIKit
#if targetEnvironment(macCatalyst)
import CoreGraphics
#endif

@MainActor final class ViewingBeat {
    /// The chat on screen right now (nil on a list).
    var chat: () -> ViewingRules.Chat? = { nil }
    private var timer: Timer?
    private var reported: ViewingRules.Chat?
    private var sending = false
    private var again = false

    /// Something changed (a chat came or went, the app came to the front or left it): say so now.
    func poke() {
        watchFront()
        if timer == nil {
            let timer = Timer(timeInterval: ViewingRules.beat, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            timer.tolerance = 3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        tick()
    }

    /// Signed out, or another gateway: what was reported belonged to the old one.
    func reset() {
        timer?.invalidate()
        timer = nil
        reported = nil
    }

    /// The app is in front. On the Mac UIKit's own state stays "active" while another app is in front and this one's
    /// window shows behind it (measured 2026-11-19), so AppKit is asked.
    static var inFront: Bool {
        #if targetEnvironment(macCatalyst)
        if let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
           let active = app.value(forKey: "isActive") as? Bool {
            return active
        }
        #endif
        return UIApplication.shared.applicationState == .active
    }

    private var watching = false
    /// [mac] Another app coming to the front, or this one coming back, is not a scene change there.
    private func watchFront() {
        #if targetEnvironment(macCatalyst)
        guard !watching else { return }
        watching = true
        for name in ["NSApplicationDidResignActiveNotification", "NSApplicationDidBecomeActiveNotification"] {
            NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.poke() }
            }
        }
        #endif
    }

    private var idle: TimeInterval? {
        #if targetEnvironment(macCatalyst)
        // Any key, click or pointer move on this Mac, in any app.
        guard let any = CGEventType(rawValue: ~0) else { return nil }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        #else
        return nil
        #endif
    }

    private func tick() {
        guard !sending else { again = true; return }
        let shown = ViewingRules.shown(active: Self.inFront, chat: chat(),
                                       mac: DeviceWord.isMac, idle: idle)
        let step = ViewingRules.step(shown: shown, reported: reported)
        guard step != .nothing else {
            // Nothing on show and nothing to take back: the timer rests until the next poke. A Mac with the chat in
            // front and nobody at it keeps looking, so the first key or pointer move counts again.
            if chat() == nil || !Self.inFront {
                timer?.invalidate()
                timer = nil
            }
            return
        }
        sending = true
        Task { [weak self] in
            switch step {
            case .report(let chat):
                if await PushRegistrar.shared.reportViewing(chat) { self?.reported = chat } else { self?.reported = nil }
            case .clear:
                await PushRegistrar.shared.clearViewing()
                self?.reported = nil
            case .nothing: break
            }
            guard let self else { return }
            self.sending = false
            if self.again { self.again = false; self.tick() }
        }
    }
}

extension PushRegistrar {
    /// PUT /viewing/<device>. False when the add-on has no such route (older than 0.9.66: asked again in an hour) or
    /// can't be reached. Works whether or not this device takes alerts itself.
    func reportViewing(_ chat: ViewingRules.Chat) async -> Bool {
        guard let call, let owner, Date() >= viewingAbsentUntil else { return false }
        let body: [String: Any] = ["session": chat.session, "profile": chat.profile, "ttl": ViewingRules.ttl]
        let result = await sendViewing(call, account: owner, "PUT", body)
        if result == 404 || result == 405 { viewingAbsentUntil = Date().addingTimeInterval(3600) }
        return result == 200
    }

    func clearViewing() async {
        guard let call, let owner, Date() >= viewingAbsentUntil else { return }
        _ = await sendViewing(call, account: owner, "DELETE", nil)
    }
}
