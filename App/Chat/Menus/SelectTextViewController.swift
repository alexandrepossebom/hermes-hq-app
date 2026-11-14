import UIKit

/// Select Text (spec 1x §9.2; S:ui-chat/select-text-sheet.tsx): a medium sheet with the message as readable text in a
/// selectable, non-editable text view, Done trailing, and Copy All in the bottom toolbar.
final class SelectTextViewController: UIViewController {
    private let text: String
    private let textView = UITextView()
    private let errorLabel = UILabel()

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func make(text: String) -> UINavigationController {
        let root = SelectTextViewController(text: text)
        root.title = "Select Text"
        root.navigationItem.largeTitleDisplayMode = .never
        // The ✕ leading, as every sheet's bar (ChatSheet.wrap).
        let done = UIBarButtonItem.hqClose(action: UIAction { [weak root] _ in root?.dismiss(animated: true) })
        done.accessibilityIdentifier = "select.done"
        root.navigationItem.hqPlaceClose(done)   // [mac] Stress test 2026-10-28 #55: trailing on the Mac
        let navigation = UINavigationController(rootViewController: root)
        SheetStyle.apply(navigation, from: nil)   // UX study #161: a form sheet in two panes
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.hqPreferLargeAtAccessibilitySizes()   // [a11y]
            sheet.prefersGrabberVisible = false
            // [glass] One block of selectable text across the whole page: it stays on the opaque page, not glass.
            sheet.hqOpaqueGroupedPage()   // solid-ok: one block of selectable text, no cards to hold it
        }
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.groupedPage
        textView.text = text
        textView.font = HQFont.preferred(.body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = ChatPalette.label
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = []
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityIdentifier = "select.text"
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        errorLabel.font = HQFont.preferred(.footnote)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = .systemRed
        errorLabel.textAlignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)
        #if targetEnvironment(macCatalyst)
        // [macpass-popups] The text on the sheet's edges (`MacSheetEdges`), 20 px in as every Mac sheet's content.
        let sides = (view.safeAreaLayoutGuide.leadingAnchor, view.safeAreaLayoutGuide.trailingAnchor)
        #else
        let sides = (view.leadingAnchor, view.trailingAnchor)
        #endif
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: sides.0),
            textView.trailingAnchor.constraint(equalTo: sides.1),
            textView.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -4),
            errorLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            errorLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
        let copyAll = UIBarButtonItem(title: "Copy All", primaryAction: UIAction { [weak self] _ in self?.copyAll() })
        copyAll.accessibilityIdentifier = "select.copy-all"
        toolbarItems = [.flexibleSpace(), copyAll, .flexibleSpace()]
        navigationController?.isToolbarHidden = false
    }

    #if targetEnvironment(macCatalyst)
    /// [macpass-popups] The Mac ignores detents, so the sheet was the tall form size whatever the message: a line or two of
    /// text over a window-tall empty sheet. It is as tall as its text (at least 220 pt, at most the tall size; a longer
    /// message scrolls), measured once the text view has its width.
    private var fittedWidth: CGFloat = 0

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = textView.bounds.width
        guard let navigation = navigationController, navigation.modalPresentationStyle == .formSheet, width > 0,
              abs(width - fittedWidth) > 1, let window = view.window ?? navigation.presentingViewController?.view.window
        else { return }
        fittedWidth = width
        let text = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let wanted = (text + view.safeAreaInsets.top + view.safeAreaInsets.bottom + 8).rounded(.up)
        let height = min(SheetStyle.macTallHeight(window), max(220, wanted))
        guard abs(navigation.preferredContentSize.height - height) > 1 else { return }
        navigation.preferredContentSize = CGSize(width: navigation.preferredContentSize.width, height: height)
    }
    #endif

    private func copyAll() {
        UIPasteboard.general.string = text
        guard UIPasteboard.general.hasStrings else {
            errorLabel.text = "Couldn’t copy this message."
            errorLabel.isHidden = false
            return
        }
        errorLabel.isHidden = true
        Haptics.play(.success)
        MenusHUD.show("Copied", in: view)
    }
}
