// [question-dictate] Dictation into a bot's question card (#438, docs/spec/1x-questions.md §4.3, 3x-talk.md §8): a
// tester could only type a free-text answer ("Something else…", or an open question's field), though voice is how they
// answer in the chat. The card's answer field gets the composer's mic. It is the composer's dictation, not a recorder of
// its own: `DictationController` records under the `.dictation` audio owner, so the audio session, Words From,
// Language, Live Words, the limit, the lease and the failure cards are the same; only the field the words go into
// differs. The take's owner is this screen's `QuestionDictation`, so the composer's row never shows for it (the
// composer is hidden behind the card anyway, and its own take was thrown away when the card came).
//
//     │ ●  ( ✕ )  ● Dictating  0:07  ▂▅█▅▂   [ Done ] │      the row in the field's place, the words heard above it
//
// It ends as the composer's does (Done, ✕, the limit, a call, the app leaving), and also when the card is sent or
// skipped, minimized, turns its page, or the field goes (a choice picked closes "Something else…", another device
// answered). One dictation runs app-wide: while another records (the composer in another window), the card's mic is
// dimmed.

import UIKit

/// The dictation row in an answer field's place, the words heard so far above it.
final class QuestionDictationView: UIView {
    let row = DictationRow()
    let heardView = LiveWordsView()
    /// Its height may have changed (the words took a line more or less, or came or went).
    var onResize: (() -> Void)?
    private(set) var heardShown = false
    /// Inside the field: where typed words start, and above the words.
    static let inset = UIEdgeInsets(top: 8, left: 8, bottom: 0, right: 8)
    static let gap: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "question.dictation"
        heardView.isHidden = true
        heardView.baseFont = HQFont.preferred(.body)
        heardView.onResize = { [weak self] in self?.onResize?() }
        addSubview(heardView)
        addSubview(row)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The words row: nil hides it.
    func show(heard: (words: LiveWordsText, listening: Bool)?) {
        let before = heardShown ? heardView.height(for: wordsWidth) : 0
        if let heard { heardView.update(heard.words, listening: heard.listening) }
        heardShown = heard != nil
        heardView.isHidden = !heardShown
        let after = heardShown ? heardView.height(for: wordsWidth) : 0
        if before != after { onResize?() }
        setNeedsLayout()
    }

    private var wordsWidth: CGFloat {
        max(60, (bounds.width > 0 ? bounds.width : 280) - Self.inset.left - Self.inset.right)
    }

    /// The row's 44 pt, and the words above it when they show.
    func height(for width: CGFloat) -> CGFloat {
        guard heardShown else { return 44 }
        let words = heardView.height(for: max(60, width - Self.inset.left - Self.inset.right))
        return 44 + Self.inset.top + words + Self.gap
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        row.frame = CGRect(x: 0, y: bounds.height - 44, width: bounds.width, height: 44)
        if heardShown {
            heardView.frame = CGRect(x: Self.inset.left, y: Self.inset.top, width: wordsWidth, height: heardView.height(for: wordsWidth))
        }
        accessibilityElements = heardShown ? [heardView, row] : [row]
    }
}

/// One chat screen's dictation into its question card. Owned by the screen's `ChatPromptsController`; the card's
/// answer fields call `begin(into:)` from their mic.
@MainActor final class QuestionDictation: NSObject {
    private weak var screen: ChatViewController?
    /// The field the take types into, and the last one that dictated (a failure card's Try Again goes back to it).
    private weak var field: DockTextField?
    private weak var lastField: DockTextField?
    /// The card's answer fields that show a mic (dimmed while another dictation records).
    private let fields = NSHashTable<DockTextField>.weakObjects()
    private lazy var content: QuestionDictationView = {
        let view = QuestionDictationView()
        view.row.onCancel = { [weak self] in
            Haptics.play(.rigid)   // the recording thrown away, as the composer's ✕
            self?.cancel(why: "cancelled")
        }
        view.row.onDone = { [weak self] in
            guard let self, self.controller.isActive(for: self) else { return }
            self.controller.done()
        }
        view.onResize = { [weak self] in self?.field?.textChanged() }
        return view
    }()
    private var shown = false

    /// Tests swap these.
    var controller: DictationController = .shared
    var chat: () -> (any ChatVoiceTurns)?
    /// Voice is offered in this chat (a live chat of the signed-in account), as for the composer's mic.
    var isAvailable: () -> Bool
    var isOnScreen: () -> Bool
    /// The take began or ended (Read Replies Aloud waits behind it; Talk's circle comes back).
    var onChange: (_ active: Bool) -> Void

    init(screen: ChatViewController) {
        self.screen = screen
        chat = { [weak screen] in screen?.session as? ChatVoiceTurns }
        isAvailable = { [weak screen] in screen.map { $0.voice.isAvailable && TalkMenus.dictate != nil } ?? false }
        isOnScreen = { [weak screen] in screen?.voice.isOnScreen ?? false }
        onChange = { [weak screen] active in
            screen?.voice.cardDictationChanged(active)
        }
        super.init()
        observe()
    }

    /// Tests: no screen.
    init(chat: @escaping () -> (any ChatVoiceTurns)?, controller: DictationController) {
        self.chat = chat
        self.controller = controller
        isAvailable = { true }
        isOnScreen = { true }
        onChange = { _ in }
        super.init()
        observe()
    }

    private func observe() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(changed(_:)), name: DictationController.didChange, object: nil)
        center.addObserver(self, selector: #selector(levelChanged(_:)), name: DictationController.levelChanged, object: nil)
        center.addObserver(self, selector: #selector(wordsChanged(_:)), name: DictationController.wordsChanged, object: nil)
    }

    // MARK: Reading

    /// A take records or transcribes for the card.
    var isActive: Bool { controller.isActive(for: self) }
    /// The field it types into.
    var activeField: DockTextField? { isActive ? field : nil }
    /// The card's mic can start one now: voice is offered here, and no other dictation runs (one app-wide).
    var canBegin: Bool { isAvailable() && isOnScreen() && !controller.isActive && chat() != nil }

    // MARK: Fields

    /// The field gets the mic when voice is offered in this chat.
    func adopt(_ field: DockTextField) {
        guard isAvailable() else { return }
        fields.add(field)
        field.onDictate = { [weak self, weak field] in
            guard let self, let field else { return }
            self.begin(into: field)
        }
        field.onLeftWindow = { [weak self, weak field] in
            guard let self, let field, self.field === field else { return }
            self.cancel(why: "its answer field went")
        }
        field.dictateEnabled = !controller.isActive
    }

    /// The mic: the composer's dictation, its words typed into `field` at the caret.
    func begin(into field: DockTextField) {
        guard canBegin, let chat = chat(), field.window != nil, field.textView.isEditable else { return }
        self.field = field
        lastField = field
        AppLog.trace("questions", "dictating into the question card")
        controller.start(in: chat, for: self) { [weak self, weak field] words in
            guard let self, let field, field.window != nil, self.isOnScreen() else { return }
            field.insertDictation(words)
        }
    }

    /// A failure card's Try Again (or Dictate with Hermes) while the card covers the composer: the field that last
    /// dictated, if it still shows, else `fallback`.
    func retry(fallback: () -> DockTextField?) {
        if let last = lastField, last.isShowing {
            begin(into: last)
        } else if let field = fallback() {
            begin(into: field)
        }
    }

    /// The card was sent, skipped, minimized, turned its page or left: its take ends with nothing typed.
    func cancel(why: String) {
        controller.cancel(for: self, why: why)
    }

    // MARK: Showing it

    @objc private func changed(_ note: Notification) {
        guard note.object as AnyObject? === controller else { return }
        refresh()
    }

    @objc private func levelChanged(_ note: Notification) {
        guard note.object as AnyObject? === controller, shown else { return }
        content.row.show(phase: controller.phase, elapsed: controller.elapsed, level: controller.level, limit: controller.limit)
    }

    @objc private func wordsChanged(_ note: Notification) {
        guard note.object as AnyObject? === controller, shown else { return }
        content.show(heard: controller.heardRow)
    }

    private func refresh() {
        let others = controller.isActive && !isActive
        for each in fields.allObjects { each.dictateEnabled = !others && !isActive }
        // As the composer's row: once the microphone records, or as "Starting…" when the start takes a while.
        let mine = isActive && (controller.phase != .starting || controller.startingShown)
        if mine, let field {
            content.row.show(phase: controller.phase, elapsed: controller.elapsed, level: controller.level, limit: controller.limit)
            content.show(heard: controller.heardRow)
            if field.dictationContent !== content { field.dictationContent = content }
            if !shown {
                shown = true
                onChange(true)
                HQAnnounce.layoutChanged(content.row)
            }
        } else {
            if shown {
                shown = false
                content.show(heard: nil)
                if field?.dictationContent === content { field?.dictationContent = nil }
                onChange(false)
            }
            // Over: the words (if any) go to the field the take captured, not to this one.
            if !isActive { field = nil }
        }
    }
}
