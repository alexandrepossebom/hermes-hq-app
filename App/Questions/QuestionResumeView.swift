import UIKit

/// A minimized question still owns the dock slot, but leaves the transcript room to read. This is presentation
/// only: the agent keeps waiting, and only Send or Skip resolves the request. Matches the composer's row placement.
final class QuestionResumeView: UIView, ComposerRowDock {
    private let button = UIButton(type: .system)
    private var count = 1
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.accessibilityIdentifier = "question.resume"
        button.accessibilityHint = "Reopens the question with your answers kept."
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        applyLook()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitPreferredContentSizeCategory.self]) {
            (view: QuestionResumeView, _) in view.applyLook()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ dock: QuestionDockView) {
        count = dock.prompt.questions.count
        button.accessibilityValue = count > 1 ? "Question \(dock.page + 1) of \(count)" : nil
        applyLook()
    }

    func announce() { UIAccessibility.post(notification: .layoutChanged, argument: button) }

    private func applyLook() {
        var c = Theme.isDesktop ? UIButton.Configuration.filled() : UIButton.Configuration.hqGlass()
        c.title = count > 1 ? "Answer questions" : "Answer question"
        c.image = UIImage(systemName: "chevron.up", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .small))
        c.imagePlacement = .trailing
        c.imagePadding = 10
        c.baseForegroundColor = ChatPalette.label
        if Theme.isDesktop { c.baseBackgroundColor = ChatPalette.elevated }
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = HQFont.preferred(.body); return a
        }
        button.configuration = c
    }
}
