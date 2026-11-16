import UIKit

/// [mac-pages] Owner 2026-11-16: "If you click an HTML file, you can't enlarge it because it's too small to actually be
/// able to fully utilize and see." The Mac draws this app at 77 %, so a page's 16 px words came out at 12 pt on the
/// screen, smaller than in any browser, with no way to enlarge them. 100 % is the page's real size (a browser's), and
/// − / + in the bar (⌘− / ⌘+ / ⌘0 while the page has the keys) step through a browser's zoom levels. One level for
/// every page, kept between launches.
///
/// The page lays out in its room over the zoom and is drawn grown by it, as a live tile is (`LiveTileBox`): the web
/// view's own `pageZoom` magnifies without laying out again on the Mac, and CSS zoom breaks 100vh pages. Off the Mac
/// the zoom is 1 and the page fills its room.
@MainActor enum PageZoom {
    static let steps = [50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300]
    static let changed = Notification.Name("PageZoom.changed")
    private static let key = "hq.mac.page-zoom"

    static var percent: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: key)
            return steps.contains(stored) ? stored : 100
        }
        set {
            guard steps.contains(newValue), newValue != percent else { return }
            if newValue == 100 { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(newValue, forKey: key) }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// The level one step in (`by` 1) or out (-1); nil at the end of the range.
    static func step(by: Int) -> Int? {
        guard let at = steps.firstIndex(of: percent), steps.indices.contains(at + by) else { return nil }
        return steps[at + by]
    }

    /// Steps in or out, or back to 100 % (`by` 0).
    static func change(by: Int) {
        if by == 0 { percent = 100 } else if let next = step(by: by) { percent = next }
    }

    static func canChange(by: Int) -> Bool { by == 0 ? percent != 100 : step(by: by) != nil }

    /// What the page is drawn grown by: the level over the Mac's 77 %; 1 elsewhere.
    static var scale: CGFloat {
        #if targetEnvironment(macCatalyst)
        CGFloat(percent) / 100 / MacTypeSteps.catalyst
        #else
        1
        #endif
    }

    /// `web` filling `room` (in its superview's coordinates): laid out in the room's size over the zoom, drawn grown
    /// by it.
    static func place(_ web: UIView, in room: CGRect) {
        let zoom = scale
        let size = CGSize(width: (room.width / zoom).rounded(), height: (room.height / zoom).rounded())
        let transform = zoom == 1 ? CGAffineTransform.identity : CGAffineTransform(scaleX: zoom, y: zoom)
        let center = CGPoint(x: room.midX, y: room.midY)
        guard web.bounds.size != size || web.transform != transform || web.center != center else { return }
        web.transform = .identity
        web.frame = CGRect(origin: .zero, size: size)
        web.transform = transform
        web.center = center
    }

    #if targetEnvironment(macCatalyst)
    /// − 100 % + for a page's bar. `items` are in a bar's trailing order (right to left), so they read − 100 % +.
    /// The level's menu lists every step and Actual Size. `onChange` runs when the level changes (lay the page out).
    /// `compact` (a narrow pane's bar, where three items cut the file's name short): the level alone, with Zoom In
    /// and Zoom Out in its menu.
    final class Controls {
        let items: [UIBarButtonItem]
        private let out: UIBarButtonItem, level: UIBarButtonItem, into: UIBarButtonItem
        private var watch: NSObjectProtocol?

        private let compact: Bool

        init(compact: Bool = false, onChange: @escaping @MainActor () -> Void) {
            self.compact = compact
            out = UIBarButtonItem(image: UIImage(systemName: "minus.magnifyingglass"), primaryAction: UIAction { _ in PageZoom.change(by: -1) })
            out.accessibilityLabel = "Zoom Out"
            out.accessibilityIdentifier = "page.zoom.out"
            into = UIBarButtonItem(image: UIImage(systemName: "plus.magnifyingglass"), primaryAction: UIAction { _ in PageZoom.change(by: 1) })
            into.accessibilityLabel = "Zoom In"
            into.accessibilityIdentifier = "page.zoom.in"
            level = UIBarButtonItem(title: "100%", image: nil, primaryAction: nil, menu: nil)
            level.accessibilityIdentifier = "page.zoom.level"
            items = compact ? [level] : [into, level, out]
            refresh()
            watch = NotificationCenter.default.addObserver(forName: PageZoom.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    onChange()
                }
            }
        }

        isolated deinit {
            if let watch { NotificationCenter.default.removeObserver(watch) }
        }

        private func refresh() {
            let now = PageZoom.percent
            level.title = "\(now)%"
            level.accessibilityLabel = "Zoom, \(now) percent"
            let steps = compact ? [
                UIAction(title: "Zoom In", image: UIImage(systemName: "plus.magnifyingglass"), attributes: PageZoom.canChange(by: 1) ? [] : .disabled) { _ in PageZoom.change(by: 1) },
                UIAction(title: "Zoom Out", image: UIImage(systemName: "minus.magnifyingglass"), attributes: PageZoom.canChange(by: -1) ? [] : .disabled) { _ in PageZoom.change(by: -1) },
            ] : []
            level.menu = UIMenu(children: steps + [
                UIAction(title: "Actual Size", attributes: now == 100 ? .disabled : []) { _ in PageZoom.percent = 100 },
                UIMenu(options: [.displayInline, .singleSelection], children: PageZoom.steps.map { step in
                    UIAction(title: "\(step)%", state: step == now ? .on : .off) { _ in PageZoom.percent = step }
                }),
            ])
            out.isEnabled = PageZoom.canChange(by: -1)
            into.isEnabled = PageZoom.canChange(by: 1)
        }
    }

    /// View › Make Text Bigger / Smaller / Actual Size, answered by a page that has the keys: the item's state.
    static func validate(_ command: UICommand) {
        switch command.action {
        case KeyCommands.textBigger: command.attributes = canChange(by: 1) ? [] : .disabled
        case KeyCommands.textSmaller: command.attributes = canChange(by: -1) ? [] : .disabled
        case KeyCommands.textNormal: command.attributes = canChange(by: 0) ? [] : .disabled
        default: break
        }
    }
    #endif
}
