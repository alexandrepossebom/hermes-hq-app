// [Mac AAA 2026-11-16] DEBUG: `-HQDebugProbe http://127.0.0.1:<port>` (with `-HQDebugMacShots <name>` and a long
// `-HQDebugMacShotsWait`): while a held tour waits, the app asks that address for one command at a time (GET /next)
// and answers each with a file sent where the tour's pictures go (`MacShots.post`), then GET /done. It lets a script
// check what the photo tours cannot: the menu bar's enabled state, where the keyboard focus is, which controls on
// screen have no hover, no tip or no VoiceOver name (a census), the cursor, while the script presses keys and moves a
// pointer of its own by events posted to this app alone (the Mac's real pointer never moves).
//
// Commands (one per line; the reply file is `<tour>-<name>.<ext>`):
//   shoot <name>    every visible window drawn, `<name>.png` (the main one) and `<name>-<n>.png` (the others)
//   census <name>   every control and tappable view on screen: name, tip, hover, enabled; faults first
//   focus <name>    each window's first responder and focused item, which window is key
//   menus <name>    the menu bar as AppKit has it after an update: titles, keys, enabled, ticks
//   state <name>    the windows, the root's panes and what is presented
//   cursor <name>   which system cursor shows now
//   keys <name>     [Mac AAA 2026-11-17] what the keys act on: the message box's words and whether it has the
//                   keyboard, the / list's marked row, the list the arrows walk (its order, the row open, whether its
//                   marked row is in view), the Terminal's tabs
//   shortcuts <name> Help › Keyboard Shortcuts' sections and rows, as the sheet would list them now
//   set <key> <value> a launch default changed while the app runs (`HQDebugTypeToChat insert`; "-" removes it)
//   quit            ends the app (the tour's wait is long)

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

@MainActor enum MacProbe {
    private static var started = false

    static func startIfAsked(_ window: UIWindow) {
        guard !started, let base = UserDefaults.standard.string(forKey: "HQDebugProbe").flatMap(URL.init(string:)),
              let name = UserDefaults.standard.string(forKey: "HQDebugMacShots") else { return }
        started = true
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "mac-shots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(0.3))
                guard let (data, _) = try? await URLSession.shared.data(from: base.appending(path: "next")),
                      let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !line.isEmpty else { continue }
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                let verb = parts[0], arg = parts.count > 1 ? parts[1] : "x"
                let file = folder.appending(path: "\(name)-\(arg)")
                switch verb {
                case "shoot": shootAll(window, to: file)
                case "census": write(census(), to: file, "txt")
                case "focus": write(focus(), to: file, "txt")
                case "menus": write(menus(), to: file, "txt")
                case "state": write(state(window), to: file, "txt")
                case "cursor": write(cursor(), to: file, "txt")
                case "keys": write(keys(), to: file, "txt")
                case "shortcuts": write(shortcuts(), to: file, "txt")
                case "set":
                    let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
                    if bits.count == 2 { UserDefaults.standard.set(bits[1] == "-" ? nil : bits[1], forKey: bits[0]) }
                case "press":
                    // press <file> <label>
                    let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
                    write(press(bits.count > 1 ? bits[1] : ""), to: folder.appending(path: "\(name)-\(bits[0])"), "txt")
                case "release": release()
                case "find":
                    // find <file> <label>: the screen middle of the first view so named, as "x y" ("none" when absent)
                    let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
                    write(find(bits.count > 1 ? bits[1] : ""), to: folder.appending(path: "\(name)-\(bits[0])"), "txt")
                case "quit":
                    _ = try? await URLSession.shared.data(from: base.appending(path: "done").appending(path: line))
                    exit(0)
                default: break
                }
                try? await Task.sleep(for: .seconds(0.4))   // the upload
                _ = try? await URLSession.shared.data(from: base.appending(path: "done").appending(path: line))
            }
        }
    }

    private static func write(_ text: String, to file: URL, _ ext: String) {
        let url = file.appendingPathExtension(ext)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        MacShots.post(url)
    }

    private static var windows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .filter { !$0.isHidden && $0.bounds.width > 50 && !(String(describing: type(of: $0)).contains("Keyboard"))
                && !(String(describing: type(of: $0)).contains("TextEffects")) }
    }

    private static func shootAll(_ launch: UIWindow, to file: URL) {
        let main = MacShots.mainWindow(fallback: launch)
        MacShots.shoot(main, to: file.appendingPathExtension("png"))
        // A Mac sheet is a window of its own, which the scene's list may not hold.
        var top = main.rootViewController
        while let next = top?.presentedViewController { top = next }
        var others = windows.filter { $0 !== main }
        if let sheet = top?.viewIfLoaded?.window, sheet !== main, !others.contains(where: { $0 === sheet }) { others.insert(sheet, at: 0) }
        for (index, window) in others.enumerated() {
            MacShots.shoot(window, to: URL(fileURLWithPath: file.path + "-\(index + 1).png"))
        }
    }

    // MARK: - Screen points

    /// The NSWindow behind a UIWindow: its frame on screen and the UI's scale (points per screen point).
    private static func screenFrame(_ window: UIWindow) -> (frame: CGRect, scale: CGFloat, screenHeight: CGFloat)? {
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
              let all = app.value(forKey: "windows") as? [NSObject] else { return nil }
        // The NSWindow of the same size at the UI's scale (1 / 0.77).
        for ns in all {
            guard let frame = (ns.value(forKey: "frame") as? NSValue)?.cgRectValue, frame.width > 50,
                  (ns.value(forKey: "visible") as? Bool) == true else { continue }
            if abs(window.bounds.width / frame.width - 1.2987) < 0.02, abs(window.bounds.height / frame.height - 1.2987) < 0.03 {
                let screen = (ns.value(forKey: "screen") as? NSObject)?.value(forKey: "frame") as? NSValue
                let primary = ((NSClassFromString("NSScreen") as? NSObject.Type)?.value(forKey: "screens") as? [NSObject])?.first
                let height = (primary?.value(forKey: "frame") as? NSValue)?.cgRectValue.height ?? screen?.cgRectValue.height ?? 0
                return (frame, window.bounds.width / frame.width, height)
            }
        }
        return nil
    }

    /// A rect in the window's points as global screen points, top-left origin (where a CGEvent goes).
    private static func onScreen(_ rect: CGRect, in window: UIWindow) -> CGRect? {
        guard let (frame, scale, height) = screenFrame(window) else { return nil }
        let top = height - frame.maxY
        return CGRect(x: frame.minX + rect.minX / scale, y: top + rect.minY / scale, width: rect.width / scale, height: rect.height / scale)
    }

    // MARK: - Census

    private static func words(_ view: UIView) -> String {
        if let button = view as? UIButton, let title = button.currentTitle ?? button.configuration?.title, !title.isEmpty { return title }
        if let label = view as? UILabel { return label.text ?? "" }
        var found: [String] = []
        func walk(_ v: UIView, _ depth: Int) {
            guard depth < 5, found.count < 3 else { return }
            for sub in v.subviews where !sub.isHidden && sub.alpha > 0.01 {
                if let label = sub as? UILabel, let text = label.text, !text.isEmpty { found.append(text) }
                else if let button = sub as? UIButton, let title = button.currentTitle, !title.isEmpty { found.append(title) }
                walk(sub, depth + 1)
            }
        }
        walk(view, 0)
        return found.joined(separator: " / ")
    }

    /// The tip the pointer would get over the view's middle: its own, an own interaction's, else the window's
    /// (`MacToolTips`, which walks up from the view under that point).
    private static func tip(_ view: UIView, in window: UIWindow) -> String? {
        if let control = view as? UIControl, let tip = control.toolTip, !tip.isEmpty { return tip }
        var current: UIView? = view
        for _ in 0..<3 {
            if let tip = current?.interactions.compactMap({ ($0 as? UIToolTipInteraction)?.defaultToolTip }).first(where: { !$0.isEmpty }) { return tip }
            current = current?.superview
        }
        let centre = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
        if let interaction = window.interactions.compactMap({ $0 as? UIToolTipInteraction }).first,
           let config = interaction.delegate?.toolTipInteraction?(interaction, configurationAt: centre) {
            return config.toolTip
        }
        // A tip on a view under the middle (the sidebar's rows set their own).
        var hit = window.hitTest(centre, with: nil)
        for _ in 0..<4 {
            if let tip = hit?.interactions.compactMap({ ($0 as? UIToolTipInteraction)?.defaultToolTip }).first(where: { !$0.isEmpty }) { return tip }
            if let control = hit as? UIControl, let tip = control.toolTip, !tip.isEmpty { return tip }
            hit = hit?.superview
        }
        return nil
    }

    /// Whether the pointer gets an answer over the view: the scout's own rule for small controls, a hover recognizer
    /// on the view or just above it (`MacHover.surface`, `ButtonHover`), a row of a list (`MacHover.rows`).
    private static func hover(_ view: UIView) -> String? {
        if let control = view as? UIControl, !(control is UITextField || control is UISwitch || control is UISegmentedControl || control is UISlider),
           control.bounds.width <= 72, control.bounds.height <= 72 { return "scout" }
        var current: UIView? = view
        for depth in 0..<3 where !(current is UIWindow) {
            if current?.gestureRecognizers?.contains(where: { $0 is UIHoverGestureRecognizer && $0.isEnabled }) == true { return depth == 0 ? "own" : "parent\(depth)" }
            if current?.interactions.contains(where: { $0 is UIPointerInteraction }) == true { return "pointer\(depth)" }
            current = current?.superview
        }
        var up = view.superview
        while let here = up {
            if here is UICollectionViewCell || here is UITableViewCell { return "row" }
            up = here.superview
        }
        return nil
    }

    private static func census() -> String {
        var faults: [String] = [], all: [String] = [], hosting: [String] = []
        for window in windows {
            let title = window.windowScene?.title ?? ""
            all.append("== window \(type(of: window)) \(window.bounds.size) '\(title)' key \(window.isKeyWindow)")
            func walk(_ view: UIView) {
                guard !view.isHidden, view.alpha > 0.01 else { return }
                let frame = view.convert(view.bounds, to: window)
                guard frame.intersects(window.bounds), frame.width > 1, frame.height > 1 else { return }
                let type = String(describing: Swift.type(of: view))
                if type.contains("HostingView") || type.contains("_UIHostingView") { hosting.append("\(type) \(frame.integral)") }
                let control = view as? UIControl
                let taps = view.gestureRecognizers?.contains { ($0 is UITapGestureRecognizer || $0 is UILongPressGestureRecognizer) && $0.isEnabled } == true
                let menu = view.interactions.contains { $0 is UIContextMenuInteraction }
                let tappable = (control != nil && view.isUserInteractionEnabled) || (taps && view.isUserInteractionEnabled) || view.accessibilityTraits.contains(.button)
                // Containers that take a click somewhere inside (a window, a bar, a SwiftUI host, a whole pane) are not
                // controls of their own.
                let container = view is UIWindow || view is UINavigationBar || view is UIToolbar || type.contains("HostingView")
                    || (control == nil && frame.width * frame.height > 250_000)
                let barButton = type.contains("BarButton")   // a bar's buttons are private classes (`_UIButtonBarButton`)
                if tappable, !container, !(view is UITextView), !(type.hasPrefix("_")) || barButton {
                    let shown = words(view)
                    let label = view.accessibilityLabel ?? ""
                    let tipText = tip(view, in: window)
                    let hov = hover(view)
                    let enabled = control?.isEnabled ?? true
                    let screen = onScreen(frame, in: window)
                    var issues: [String] = []
                    let field = view is UITextField || view is UISwitch || view is UISegmentedControl || view is UISlider
                    if shown.isEmpty && label.isEmpty && !field { issues.append("NO-NAME") }
                    if shown.isEmpty && (tipText ?? "").isEmpty && !field { issues.append("NO-TIP") }
                    if hov == nil && enabled && !field { issues.append("NO-HOVER") }
                    let line = "\(type) at \(frame.integral) screen \(screen.map { "\(Int($0.midX)),\(Int($0.midY))" } ?? "-") words '\(shown.prefix(40))' label '\(label.prefix(40))' tip '\(tipText ?? "")' hover \(hov ?? "none") enabled \(enabled)\(taps ? " taps" : "")\(menu ? " menu" : "")"
                    all.append((issues.isEmpty ? "  ok " : "  !! \(issues.joined(separator: ",")) ") + line)
                    if !issues.isEmpty { faults.append("\(issues.joined(separator: ",")) \(line)") }
                }
                for sub in view.subviews { walk(sub) }
            }
            walk(window)
        }
        return "FAULTS \(faults.count)\n" + faults.joined(separator: "\n") + "\n\nSWIFTUI HOSTS (check by accessibility)\n"
            + hosting.joined(separator: "\n") + "\n\nALL\n" + all.joined(separator: "\n") + "\n"
    }

    /// The first view on show so named: its VoiceOver name or words start with `label` (the nearest row, control or
    /// tappable view holding it); "@class:<type>:<n>" the n-th view of that type; "@cell:<n>:<min x>" the n-th row (top to
    /// bottom) of any list whose rows start right of <min x>. The front window (a sheet, Settings) first.
    private static func locate(_ label: String) -> (UIView, UIWindow)? {
        for window in windows.reversed() {
            var found: [UIView] = []
            func walk(_ view: UIView) {
                guard !view.isHidden, view.alpha > 0.01 else { return }
                let frame = view.convert(view.bounds, to: window)
                guard frame.intersects(window.bounds) else { return }
                if label.hasPrefix("@class:") {
                    let wanted = label.split(separator: ":").dropFirst().first.map(String.init) ?? ""
                    if String(describing: type(of: view)).contains(wanted) { found.append(view) }
                } else if label.hasPrefix("@cell:") {
                    if view is UICollectionViewCell || view is UITableViewCell {
                        let minX = label.split(separator: ":").dropFirst(2).first.flatMap { Double($0) } ?? 0
                        if frame.minX >= minX, window.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)), frame.height > 8 { found.append(view) }
                        return
                    }
                } else if found.isEmpty, !label.isEmpty {
                    let name = view.accessibilityLabel ?? ""
                    let text = (view as? UILabel)?.text ?? (view as? UIButton)?.currentTitle ?? ""
                    if name.hasPrefix(label) || text.hasPrefix(label) {
                        var target: UIView = view
                        var up: UIView? = view
                        while let here = up, !(here is UIWindow) {
                            if here is UICollectionViewCell || here is UITableViewCell || here is UIControl
                                || here.gestureRecognizers?.contains(where: { $0 is UITapGestureRecognizer }) == true { target = here; break }
                            up = here.superview
                        }
                        found.append(target)
                        return
                    }
                }
                view.subviews.forEach(walk)
            }
            walk(window)
            var index = 1
            if label.hasPrefix("@") { index = Int(label.split(separator: ":").dropFirst(label.hasPrefix("@class:") ? 2 : 1).first ?? "1") ?? 1 }
            if label.hasPrefix("@cell:") {
                found.sort { let a = $0.convert($0.bounds, to: window), b = $1.convert($1.bounds, to: window)
                    return a.minY == b.minY ? a.minX < b.minX : a.minY < b.minY }
            }
            if found.indices.contains(index - 1) { return (found[index - 1], window) }
        }
        return nil
    }

    private static func find(_ label: String) -> String {
        guard let (view, window) = locate(label) else { return "none" }
        let frame = view.convert(view.bounds, to: window)
        guard let screen = onScreen(frame, in: window) else { return "none" }
        return "\(Int(screen.midX)) \(Int(screen.midY)) \(type(of: view)) \(frame.integral) '\(view.accessibilityLabel?.prefix(40) ?? "")'"
    }

    /// The pressed look, as the mouse button held down on it would give (posted mouse-downs do not hold): a control
    /// or row highlighted, a surface's press. `release` lets every one go.
    private static var held: [UIView] = []
    private static func press(_ label: String) -> String {
        guard let (view, _) = locate(label) else { return "none" }
        if let control = view as? UIControl { control.isHighlighted = true }
        else if let cell = view as? UICollectionViewCell { cell.isHighlighted = true }
        else if let cell = view as? UITableViewCell { cell.setHighlighted(true, animated: false) }
        else { PointerEffects.press(view, true) }
        held.append(view)
        return "pressed \(type(of: view)) '\(view.accessibilityLabel ?? "")'"
    }

    private static func release() {
        for view in held {
            if let control = view as? UIControl { control.isHighlighted = false }
            else if let cell = view as? UICollectionViewCell { cell.isHighlighted = false }
            else if let cell = view as? UITableViewCell { cell.setHighlighted(false, animated: false) }
            else { PointerEffects.press(view, false) }
        }
        held.removeAll()
    }

    // MARK: - Focus, menus, state, cursor

    private static func describe(_ responder: UIResponder?) -> String {
        guard let responder else { return "none" }
        var text = String(describing: type(of: responder))
        if let view = responder as? UIView {
            text += " label '\(view.accessibilityLabel ?? "")'"
            if let field = view as? UITextField { text += " placeholder '\(field.placeholder ?? "")' text '\(field.text?.prefix(30) ?? "")'" }
            if let field = view as? UITextView { text += " text '\(field.text.prefix(30))'" }
            var up = view.next
            while let next = up, !(next is UIViewController) { up = next.next }
            if let controller = up { text += " in \(type(of: controller))" }
        }
        return text
    }

    private static func focus() -> String {
        var out = ""
        let nsapp = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject
        out += "app active \((nsapp?.value(forKey: "active") as? Bool).map(String.init) ?? "?")\n"
        let key = nsapp?.value(forKey: "keyWindow") as? NSObject
        out += "AppKit key window: '\((key?.value(forKey: "title") as? String) ?? "none")' \(((key?.value(forKey: "frame") as? NSValue)?.cgRectValue).map { "\($0.size)" } ?? "")\n"
        for window in windows {
            var first: UIResponder?
            func find(_ view: UIView) { if first != nil { return }; if view.isFirstResponder { first = view; return }; view.subviews.forEach(find) }
            find(window)
            if first == nil {
                var top = window.rootViewController
                while let next = top?.presentedViewController { top = next }
                if top?.isFirstResponder == true { first = top }
            }
            let item = UIFocusSystem.focusSystem(for: window)?.focusedItem
            out += "window \(type(of: window)) '\(window.windowScene?.title ?? "")' key \(window.isKeyWindow)\n"
            out += "  first responder: \(describe(first))\n"
            out += "  focused item: \(item.map { describe($0 as? UIResponder) + " (\(type(of: $0)))" } ?? "none")\n"
        }
        return out
    }

    private static func menus() -> String {
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
              let main = app.value(forKey: "mainMenu") as? NSObject else { return "no main menu" }
        var out = ""
        func mods(_ mask: UInt) -> String {
            var s = ""
            if mask & (1 << 18) != 0 { s += "⌃" }
            if mask & (1 << 19) != 0 { s += "⌥" }
            if mask & (1 << 17) != 0 { s += "⇧" }
            if mask & (1 << 20) != 0 { s += "⌘" }
            return s
        }
        func dump(_ menu: NSObject, _ depth: Int) {
            menu.perform(NSSelectorFromString("update"))
            for item in (menu.value(forKey: "itemArray") as? [NSObject]) ?? [] {
                let pad = String(repeating: "  ", count: depth)
                if item.value(forKey: "separatorItem") as? Bool == true { out += pad + "----\n"; continue }
                let title = item.value(forKey: "title") as? String ?? ""
                let key = item.value(forKey: "keyEquivalent") as? String ?? ""
                let mask = (item.value(forKey: "keyEquivalentModifierMask") as? NSNumber)?.uintValue ?? 0
                let enabled = item.value(forKey: "enabled") as? Bool ?? true
                let hidden = item.value(forKey: "hidden") as? Bool ?? false
                let state = (item.value(forKey: "state") as? NSNumber)?.intValue ?? 0
                guard !hidden else { continue }
                let shown = key.isEmpty ? "" : "  [\(mods(mask))\(key == "\u{8}" ? "⌫" : key.uppercased() == key ? key : key)]"
                out += pad + (enabled ? "" : "(off) ") + (state == 1 ? "✓ " : "") + title + shown + "\n"
                if let sub = item.value(forKey: "submenu") as? NSObject, depth < 3 { dump(sub, depth + 1) }
            }
        }
        dump(main, 0)
        return out
    }

    private static func state(_ launch: UIWindow) -> String {
        var out = ""
        for window in windows {
            out += "window \(type(of: window)) \(window.bounds.size) '\(window.windowScene?.title ?? "")' key \(window.isKeyWindow)\n"
            func walk(_ controller: UIViewController?, _ depth: Int) {
                guard let controller, depth < 8 else { return }
                let pad = String(repeating: "  ", count: depth + 1)
                var line = "\(type(of: controller))"
                if !(controller.title ?? "").isEmpty { line += " '\(controller.title!)'" }
                if let view = controller.viewIfLoaded { line += " \(view.isHidden ? "hidden " : "")\(view.convert(view.bounds, to: window).integral)" }
                out += pad + line + "\n"
                if let nav = controller as? UINavigationController {
                    out += pad + "  stack: \(nav.viewControllers.map { String(describing: type(of: $0)) }.joined(separator: " > "))\n"
                }
                for child in controller.children where child.viewIfLoaded?.window != nil { walk(child, depth + 1) }
                if let presented = controller.presentedViewController, presented.presentingViewController === controller {
                    out += pad + "presents:\n"
                    walk(presented, depth + 1)
                }
            }
            walk(window.rootViewController, 0)
        }
        return out
    }

    /// [Mac AAA 2026-11-17] What the keys act on now (calls-keys: Q1, Q2, Q3, Q10).
    private static func keys() -> String {
        var out = ""
        guard let root = KeyCommands.root else { return "no main page\n" }
        let first = root.view.window?.hqFirstResponder
        out += "main window AppKit key: \(root.view.window?.hqIsAppKitKey == true)\n"
        out += "first responder: \(first.map { String(describing: type(of: $0)) } ?? "none")\n"
        out += "presented: \(KeyCommands.presented(root).map { String(describing: type(of: $0)) } ?? "none")\n"
        if let chat = root.chatOnShow {
            out += "chat on show: '\(chat.title ?? "")'\n"
            out += "message box: '\(chat.composer.text)' (has keyboard: \(chat.composer.textView.isFirstResponder), "
                + "marked text: \(chat.composer.textView.markedTextRange != nil))\n"
            if let drawer = chat.drawer {
                out += "/ list: \(drawer.isOpen ? "open" : "closed"), marked row: \(drawer.debugMarkedTitle.map { "'\($0)'" } ?? "none")\n"
            }
        } else {
            out += "chat on show: none\n"
        }
        out += "list on show: \(KeyCommands.listOnShow(root).map { String(describing: type(of: $0)) } ?? "none")\n"
        if let detail = root.split?.detail.topViewController {
            var line = "right pane: \(type(of: detail))"
            if let job = detail as? JobDetailViewController { line += " job \(job.jobKey)" }
            if let task = TodoSheet.model(of: detail)?.taskID { line += " task \(task)" }
            out += line + "\n"
        }
        if let walk = KeyCommands.walkList(root) {
            let shown = walk.order.prefix(12).map { $0 == walk.current ? "[\($0)]" : $0 }
            out += "arrows walk \(walk.order.count) rows: \(shown.joined(separator: " · "))\(walk.order.count > 12 ? " …" : "")\n"
            out += "open now: \(walk.current ?? "none") (row \(walk.current.flatMap { walk.order.firstIndex(of: $0) }.map { "\($0 + 1)" } ?? "-"))\n"
        } else {
            out += "arrows walk: nothing\n"
        }
        if let list = (KeyCommands.listOnShow(root)?.viewIfLoaded).flatMap(findList), let path = list.indexPathsForSelectedItems?.first,
           let row = list.layoutAttributesForItem(at: path) {
            let visible = list.bounds.inset(by: list.adjustedContentInset)
            out += "marked row \(path.section).\(path.item): \(visible.contains(row.frame) ? "in view" : "OUT OF VIEW") (row y \(Int(row.frame.minY)), view \(Int(visible.minY))–\(Int(visible.maxY)))\n"
        }
        if let (list, path) = KeyCommands.focusedRow(root) { out += "keyboard focus ring on row \(path.section).\(path.item) of \(type(of: list))\n" }
        out += "Terminal in front: \(TerminalViewController.front.map(\.debugTabs) ?? "no")\n"
        return out
    }

    private static func findList(_ view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for child in view.subviews { if let found = findList(child) { return found } }
        return nil
    }

    private static func shortcuts() -> String {
        KeyShortcutsSheet.sections().map { section in
            "\(section.title)\n" + section.rows.map { "  \($0.title)   \($0.keys.joined(separator: "  "))" }.joined(separator: "\n")
                + (section.footer.map { "\n  (\($0))" } ?? "")
        }.joined(separator: "\n") + "\n"
    }

    private static func cursor() -> String {
        guard let cls = NSClassFromString("NSCursor") as? NSObject.Type,
              let current = cls.value(forKey: "currentCursor") as? NSObject else { return "no cursor" }
        let named = ["arrowCursor", "pointingHandCursor", "IBeamCursor", "resizeLeftRightCursor", "resizeUpDownCursor",
                     "openHandCursor", "closedHandCursor", "crosshairCursor", "columnResizeCursor", "rowResizeCursor"]
        for name in named where cls.responds(to: NSSelectorFromString(name)) {
            if let cursor = cls.value(forKey: name) as? NSObject, cursor === current || cursor.isEqual(current) { return name }
        }
        return "other \(current)"
    }
}
#endif
