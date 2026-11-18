import UIKit
import SwiftUI
import UniformTypeIdentifiers

// The composer's ordered context actions (docs/spec/1x-attachments.md §4.1). The sheet renders the same
// menu tree so existing providers keep their ordering, availability, and nested actions.

@MainActor final class ComposerPlusMenu {
    enum Slot: Int, Comparable {
        case pickers = 0, memo = 10, talk = 20, paste = 30, link = 40, folder = 50, snippets = 60, more = 70
        static func < (a: Slot, b: Slot) -> Bool { a.rawValue < b.rawValue }
    }

    /// A slot's elements, made each time the menu opens.
    typealias Provider = () -> [UIMenuElement]
    private var providers: [Slot: [Provider]] = [:]

    /// Adds a slot's items (other streams: Voice Memo, Talk, Link…, Folder…, Prompt Snippets…).
    func register(_ slot: Slot, _ provider: @escaping Provider) {
        providers[slot, default: []].append(provider)
    }

    /// The whole menu, slots in order.
    func makeMenu() -> UIMenu {
        var children: [UIMenuElement] = []
        for slot in providers.keys.sorted() {
            for provider in providers[slot] ?? [] { children += provider() }
        }
        return UIMenu(children: children)
    }

    /// [context-sheet] The sheet's cards: add things (pickers, paste), speak (memo, talk), point at things (link, folder,
    /// snippets), then the rest. A card with nothing in it is left out.
    func makeSections() -> [UIMenu] {
        let cards: [[Slot]] = [[.pickers, .paste], [.memo, .talk], [.link, .folder, .snippets], [.more]]
        return cards.compactMap { slots in
            let children = slots.flatMap { slot in (providers[slot] ?? []).flatMap { $0() } }
            return children.isEmpty ? nil : UIMenu(options: .displayInline, children: children)
        }
    }

    /// The inline row of three pickers (spec §4.1): Camera "Unavailable" without a camera; all "Up to 16 per message" at 16.
    /// [mac] A Mac with no camera (a Mac mini, a Mac Studio, a closed laptop on a display) has no Camera at all: a row
    /// that can never work is left out, not greyed. With a camera (the built-in one, or an iPhone as Continuity Camera
    /// webcam, which macOS lists as a camera) the system's picker takes the photo, as on a phone. "Take Photo" from a
    /// nearby iPhone (AppKit's Import from iPhone) is an NSResponder service with no UIKit form under Catalyst.
    static func pickers(count: Int, camera: @escaping () -> Void, photos: @escaping () -> Void, files: @escaping () -> Void,
                        hasCamera: Bool = UIImagePickerController.isSourceTypeAvailable(.camera)) -> UIMenu {
        let full = count >= AttachmentStaging.maxPerMessage
        let cameraAction = UIAction(title: "Camera", image: UIImage(systemName: "camera")) { _ in camera() }
        cameraAction.accessibilityIdentifier = "composer.plus.camera"
        let photosAction = UIAction(title: "Photos", image: UIImage(systemName: "photo.on.rectangle")) { _ in photos() }
        photosAction.accessibilityIdentifier = "composer.plus.photos"
        let filesAction = UIAction(title: "Files", image: UIImage(systemName: "doc")) { _ in files() }
        filesAction.accessibilityIdentifier = "composer.plus.files"
        if full {
            for a in [cameraAction, photosAction, filesAction] {
                a.attributes = .disabled
                a.subtitle = limitNote
            }
        } else if !hasCamera {
            cameraAction.attributes = .disabled
            cameraAction.subtitle = "Unavailable"
        }
        let shown = DeviceWord.isMac && !hasCamera ? [photosAction, filesAction] : [cameraAction, photosAction, filesAction]
        let row = UIMenu(title: "", options: .displayInline, children: shown)
        row.preferredElementSize = .medium
        return row
    }

    /// Under a source the tray is full for: the limit itself (removing a tile frees a place).
    static var limitNote: String { "Up to \(AttachmentStaging.maxPerMessage) per message" }

    /// Paste Image, present only when the pasteboard holds an image (checked without a paste prompt). Read as the menu
    /// opens (the + button's menu is itself made on open), never as a deferred element of its own: [Mac full pass
    /// 2026-11-14] one nested inside the button's deferred menu was never filled on the Mac and the menu kept a grey
    /// "Loading…" row between Talk and Link….
    static func paste(enabled: Bool, action: @escaping () -> Void) -> [UIMenuElement] {
        guard UIPasteboard.general.hasImages else { return [] }
        let paste = UIAction(title: "Paste Image", image: UIImage(systemName: "doc.on.clipboard")) { _ in action() }
        paste.accessibilityIdentifier = "composer.plus.paste"
        if !enabled { paste.attributes = .disabled; paste.subtitle = limitNote }
        return [paste]
    }
}

/// [context-sheet] The phone's + opens a sheet (owner 2026-11-18, after Claude's "Add context"): a close disc, the
/// title, Photos (the whole library) on the right; recent photos in one row; then the menu's slots as grouped cards of
/// large rows. It renders the same element tree the old popup did, so providers keep their order, subtitles, disabled
/// states and submenus (a submenu opens as a page inside the sheet). The Mac keeps the system menu.
@MainActor final class ComposerContextSheet: UIHostingController<ComposerContextSheet.Content> {
    init(sections: [UIMenu], canAttach: Bool, onPhoto: @escaping (NSItemProvider) -> Void) {
        let bridge = Bridge()
        super.init(rootView: Content(sections: sections, canAttach: canAttach, bridge: bridge, onPhoto: onPhoto))
        bridge.controller = self
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 32
        }
    }

    @objc required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @MainActor final class Bridge {
        weak var controller: UIViewController?
        /// The sheet sizes to its content (up to the large detent), so nothing sits under its bottom edge.
        func fit(_ height: CGFloat) {
            guard let sheet = controller?.sheetPresentationController, height > 0 else { return }
            let fitted = UISheetPresentationController.Detent.custom(identifier: .init("fit")) { ctx in
                min(height, ctx.maximumDetentValue)
            }
            sheet.animateChanges { sheet.detents = [fitted] }
        }
        func perform(_ action: UIAction) {
            guard !action.attributes.contains(.disabled), let controller else { return }
            // Dismissed first: the action may present its own picker or alert from the chat.
            controller.dismiss(animated: true) {
                let control = UIButton(type: .system)
                control.addAction(action, for: .touchUpInside)
                control.sendActions(for: .touchUpInside)
            }
        }
        func select(_ provider: NSItemProvider, callback: @escaping (NSItemProvider) -> Void) {
            controller?.dismiss(animated: true) { callback(provider) }
        }
        func close() { controller?.dismiss(animated: true) }
    }

    struct Content: View {
        let sections: [UIMenu]
        let canAttach: Bool
        let bridge: Bridge
        let onPhoto: (NSItemProvider) -> Void
        @State private var submenu: UIMenu?

        static let photosID = "composer.plus.photos"

        private var photos: UIAction? {
            func find(_ elements: [UIMenuElement]) -> UIAction? {
                for element in elements {
                    if let action = element as? UIAction, action.accessibilityIdentifier == Self.photosID { return action }
                    if let group = element as? UIMenu, let found = find(group.children) { return found }
                }
                return nil
            }
            return find(sections)
        }

        var body: some View {
            VStack(spacing: 18) {
                header
                if let submenu {
                    card(submenu.children)
                } else {
                    if let photos {
                        if canAttach {
                            ComposerRecentPhotosView { provider in bridge.select(provider, callback: onPhoto) }
                                .frame(height: 116)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .accessibilityIdentifier("composer.plus.recentPhotos")
                        } else if let note = photos.subtitle {
                            Text(note).font(Font(HQFont.style(.footnote))).foregroundStyle(Color.hqMuted)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                        }
                    }
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        let items = visible(section.children)
                        if !items.isEmpty { card(items) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bridge.fit($0) }
            .frame(maxHeight: .infinity, alignment: .top)
            .hqGlassSheetPage()   // [glass-audit] the fitted (half-height) sheet sits on the app's glass
        }

        private var header: some View {
            ZStack {
                Text(submenu.map { $0.title.isEmpty ? "Add context" : $0.title } ?? "Add context")
                    .font(Font(HQFont.style(.headline)))
                HStack {
                    Button {
                        if submenu != nil { withAnimation(HQMotion.reduced ? nil : .snappy) { submenu = nil } } else { bridge.close() }
                    } label: {
                        Image(systemName: submenu == nil ? "xmark" : "chevron.left")
                            .font(Font(HQFont.scaled(17, weight: .semibold, like: .body, cap: 24)))
                            .frame(width: 44, height: 44)
                    }
                    .hqGlassButtonStyle()
                    .buttonBorderShape(.circle)
                    .tint(Color.hqLabel)
                    .accessibilityLabel(submenu == nil ? "Close" : "Back")
                    Spacer()
                    if submenu == nil, let photos {
                        Button("Photos") { bridge.perform(photos) }
                            .font(Font(HQFont.style(.body, weight: .medium)))
                            .foregroundStyle(Color.hqLabel)
                            .disabled(photos.attributes.contains(.disabled))
                            .accessibilityIdentifier(Self.photosID)
                    }
                }
            }
        }

        /// A slot's elements with inline groups opened up, hidden ones and the Photos row (it lives in the header) out.
        private func visible(_ elements: [UIMenuElement]) -> [UIMenuElement] {
            elements.flatMap { element -> [UIMenuElement] in
                if let group = element as? UIMenu, group.options.contains(.displayInline) { return visible(group.children) }
                if let action = element as? UIAction {
                    if action.attributes.contains(.hidden) || action.accessibilityIdentifier == Self.photosID { return [] }
                }
                return [element]
            }
        }

        private func card(_ elements: [UIMenuElement]) -> some View {
            let items = submenu == nil ? elements : visible(elements)
            return VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, element in
                    if index > 0 { Divider().padding(.leading, 62) }
                    rowButton(element)
                }
            }
            .background(Color.hqGroupedCard,
                        in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }

        @ViewBuilder private func rowButton(_ element: UIMenuElement) -> some View {
            if let action = element as? UIAction {
                Button { bridge.perform(action) } label: {
                    row(title: action.title, subtitle: action.subtitle, image: action.image,
                        trailing: action.state == .on ? "checkmark" : nil)
                }
                .buttonStyle(RowStyle())
                .disabled(action.attributes.contains(.disabled))
                .foregroundStyle(action.attributes.contains(.destructive) ? Color.hqRed : Color.hqLabel)
                .accessibilityIdentifier(action.accessibilityIdentifier ?? "")
            } else if let group = element as? UIMenu {
                Button { withAnimation(HQMotion.reduced ? nil : .snappy) { submenu = group } } label: {
                    row(title: group.title, subtitle: group.subtitle, image: group.image, trailing: "chevron.right")
                }
                .buttonStyle(RowStyle())
                .foregroundStyle(Color.hqLabel)
            }
        }

        private func row(title: String, subtitle: String?, image: UIImage?, trailing: String?) -> some View {
            HStack(spacing: 16) {
                if let image {
                    Image(uiImage: image.withRenderingMode(.alwaysTemplate))
                        .font(Font(HQFont.scaled(20, like: .body)))
                        .frame(width: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Font(HQFont.scaled(19, like: .body)))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(Font(HQFont.style(.footnote))).foregroundStyle(Color.hqMuted)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    Image(systemName: trailing).font(Font(HQFont.scaled(15, weight: .semibold, like: .body))).foregroundStyle(Color.hqMuted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }

        private struct RowStyle: ButtonStyle {
            @Environment(\.isEnabled) private var enabled
            func makeBody(configuration: Configuration) -> some View {
                configuration.label
                    .opacity(enabled ? 1 : 0.4)
                    .background(configuration.isPressed ? Color.hqFill3 : .clear)
            }
        }
    }
}

/// The + button opens the context sheet. [composer-bar]
/// The composer takes its glass away (a plain glyph on the bar); a press shows the mic's soft circle behind it.
final class ComposerPlusButton: UIView {
    let button = UIButton(type: .system)
    private let pressedCircle = ComposerGlassButton.makePressedCircle()
    private let glass: UIVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let view = UIVisualEffectView(effect: effect)
        view.cornerConfiguration = .capsule()
        return view
    }()

    /// [context-sheet] The phone: a tap opens the Add context sheet (built as it opens).
    var onTap: (() -> Void)?
    /// [mac] The Mac keeps the system menu, asked each time it opens (the count, the pasteboard). Setting it makes the
    /// menu the button's primary action.
    var menuProvider: (() -> UIMenu)? {
        didSet {
            guard menuProvider != nil, button.menu == nil else { return }
            let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuProvider?().children ?? [])
            }
            button.menu = UIMenu(children: [deferred])
            button.showsMenuAsPrimaryAction = true
        }
    }

    /// [composer-plus] In the iOS look the + stands on a 36 pt disc (owner 2026-10-31: the thin + "looks cheap"), its
    /// glyph 17 pt semibold in label; the Desktop Look keeps the plain glyph. [composer-glass] The disc is Liquid Glass.
    private let disc = ComposerGlassDisc()
    private var usesDisc: Bool { !ComposerView.oneBox }   // [mac] the box's plain glyph on the Mac

    private var glyphImage: UIImage? {
        UIImage(systemName: "plus", withConfiguration: usesDisc ? ComposerGlassButton.discConfiguration : ComposerGlassButton.glyphConfiguration)
    }
    private var glyphColor: UIColor { usesDisc ? ChatPalette.label : ChatPalette.composerGlyph }

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: ChatMetrics.control, height: ChatMetrics.control))
        addSubview(glass)
        glass.contentView.addSubview(pressedCircle)
        glass.contentView.addSubview(disc)
        var config = UIButton.Configuration.plain()
        config.image = glyphImage
        config.baseForegroundColor = glyphColor
        config.contentInsets = .zero
        button.configuration = config
        button.showsMenuAsPrimaryAction = false
        button.addAction(UIAction { [weak self] _ in
            guard let self, self.menuProvider == nil else { return }
            self.onTap?()
        }, for: .touchUpInside)
        button.accessibilityLabel = "Attach"
        button.accessibilityIdentifier = "composer.plus"
        // [a11y] A hold at the accessibility text sizes shows the + large, named (the menu opens on a tap).
        button.showsLargeContentViewer = true
        button.largeContentTitle = "Attach"
        button.largeContentImage = UIImage(systemName: "plus")
        button.scalesLargeContentImage = true
        button.addInteraction(UILargeContentViewerInteraction())
        glass.contentView.addSubview(button)
        button.configurationUpdateHandler = { [weak self] button in
            guard let self else { return }
            if self.usesDisc {
                self.disc.press(button.isHighlighted)
            } else {
                ComposerGlassButton.showPress(self.pressedCircle, button.isHighlighted)
            }
        }
        registerForTraitChanges([ThemeGenerationTrait.self]) { (view: ComposerPlusButton, _) in
            view.pressedCircle.backgroundColor = ChatPalette.fill3
            view.button.configuration?.image = view.glyphImage
            view.button.configuration?.baseForegroundColor = view.glyphColor
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        button.frame = glass.contentView.bounds
        pressedCircle.frame = glass.contentView.bounds.insetBy(dx: 4, dy: 4)
        pressedCircle.layer.cornerRadius = pressedCircle.bounds.width / 2
        disc.isHidden = !usesDisc
        let discSide: CGFloat = 36
        disc.bounds = CGRect(x: 0, y: 0, width: discSide, height: discSide)   // (the press scales it: no frame)
        disc.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// A 48 pt hit box around the 44 pt slot.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -2, dy: -2).contains(point)
    }

    var isEnabledForAttaching: Bool {
        get { button.isEnabled }
        set { button.isEnabled = newValue; alpha = newValue ? 1 : 0.4 }
    }
}
