// [question-dictate] #438: the question card's answer field has the composer's dictation. The words go in at the caret
// and count as the page's answer; the card's take ends with Send, Skip, Minimize, a page turn or its field going; the
// composer's row never takes the card's take for its own; and only one dictation runs at a time.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite("Question card dictation", .serialized)
@MainActor
struct QuestionDictationTests {
    private let branch = ClarifyQuestion(qid: "q0", question: "Branch?", choices: ["main (Recommended)", "staging"], multiSelect: false)
    private let name = ClarifyQuestion(qid: "q1", question: "Name?", choices: nil, multiSelect: false)

    private final class Rig {
        let controller: DictationController
        let recorder: FakeDictationRecorder
        let chat: FakeTalkChat
        let dictation: QuestionDictation
        let dock: QuestionDockView
        let window: UIWindow
        var notices: [MemoNotice] = []

        @MainActor init(questions: [ClarifyQuestion], draft: ClarifyDraft, words: String) {
            KeepAwake.reset()
            AudioSessionCoordinator.shared.reset()
            let recorder = FakeDictationRecorder()
            let controller = DictationController()
            controller.makeRecorder = { recorder }
            controller.loadConfig = { _ in TalkConfig() }
            controller.transcribe = { _, _ in
                try? await Task.sleep(for: .milliseconds(20))
                return .success(words)
            }
            controller.makeWords = { _ in nil }
            controller.holdsLeases = false
            controller.haptics = false
            controller.isOnScreen = { true }
            self.controller = controller
            self.recorder = recorder
            let chat = FakeTalkChat()
            self.chat = chat
            dictation = QuestionDictation(chat: { chat }, controller: controller)
            dock = QuestionDockView(prompt: ClarifyPrompt(id: "srq-d", questions: questions), draft: draft)
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let host = UIViewController()
            window.rootViewController = host
            window.isHidden = false
            dock.frame = CGRect(x: 8, y: 300, width: 374, height: 420)
            host.view.addSubview(dock)
            dock.dictation = dictation
            dock.layoutIfNeeded()
            controller.onNotice = { [weak self] _, notice in self?.notices.append(notice) }
        }

        func close() {
            controller.resetForTests()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func find<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if view.accessibilityIdentifier == id, let hit = view as? T { return hit }
        for sub in view.subviews { if let hit: T = find(id, in: sub) { return hit } }
        return nil
    }

    private func field(_ rig: Rig, page: Int) throws -> DockTextField {
        let view = try #require(find("question.page.\(page)", in: rig.dock, as: QuestionPageView.self))
        return try #require(view.answerField)
    }

    @Test func anOpenQuestionsFieldHasTheMicAndTheWordsBecomeItsAnswer() async throws {
        let rig = Rig(questions: [name], draft: ClarifyDraft(page: 0, stages: ["q1": ClarifyStage(draft: "Call it")]), words: "  otto  ")
        defer { rig.close() }
        let field = try field(rig, page: 0)
        #expect(field.showsMic)
        #expect(field.micEnabled)
        let mic: UIButton = try #require(find("question.dictate", in: field))
        mic.sendActions(for: .primaryActionTriggered)
        #expect(rig.dictation.isActive)
        #expect(!rig.controller.isActive(in: rig.chat, for: nil), "the composer's row does not take the card's take")
        #expect(await waitUntil { rig.controller.phase == .recording })
        // The row takes the field's place, and Send waits for the words.
        #expect(field.dictationContent != nil)
        #expect(!field.showsMic)
        #expect(field.textView.alpha == 0)
        #expect(rig.dock.isDictating)
        let send: UIButton = try #require(find("question.primary", in: rig.dock))
        #expect(!send.isEnabled)
        let done: UIButton = try #require(find("dictation.done", in: field))
        done.sendActions(for: .touchUpInside)
        #expect(await waitUntil { !rig.controller.isActive })
        // Trimmed, after a space, and the page's answer as typed words are.
        #expect(field.text == "Call it otto")
        #expect(rig.dock.draft.stages["q1"]?.draft == "Call it otto")
        #expect(field.dictationContent == nil)
        #expect(field.textView.alpha == 1)
        #expect(field.showsMic)
        #expect(!rig.dock.isDictating)
        #expect(send.isEnabled)
        #expect(rig.chat.sent.isEmpty, "nothing goes to the bot until Send")
        #expect(!KeepAwake.isHeld(.dictation))
    }

    @Test func somethingElseOpensForDictationAndAChoiceThrowsTheTakeAway() async throws {
        let rig = Rig(questions: [branch, name], draft: ClarifyDraft(page: 0, stages: [:]), words: "a branch of its own")
        defer { rig.close() }
        let page = try #require(find("question.page.0", in: rig.dock, as: QuestionPageView.self))
        #expect(page.answerField == nil, "Something else… is closed")
        let field = try #require(rig.dock.fieldForDictation())
        #expect(field.showsMic)
        #expect(rig.dock.draft.stages["q0"]?.other == true)
        rig.dictation.begin(into: field)
        #expect(await waitUntil { rig.controller.phase == .recording })
        // A pick closes "Something else…": its field goes, and the take with it (nothing typed, no card).
        let choice: UIControl = try #require(find("question.choice.1", in: page))
        choice.sendActions(for: .touchUpInside)
        #expect(!rig.controller.isActive)
        #expect(rig.recorder.cancelled == 1)
        #expect(rig.notices.isEmpty)
        #expect(rig.dock.draft.stages["q0"]?.choices == ["staging"])
    }

    @Test func skipSendMinimizeAndAPageTurnEachEndTheTake() async throws {
        let questions = [name, ClarifyQuestion(qid: "q2", question: "Why?", choices: nil, multiSelect: false)]
        for end in ["skip", "send", "minimize", "back", "escape"] {
            let rig = Rig(questions: questions, draft: ClarifyDraft(page: 1, stages: ["q2": ClarifyStage(draft: "ivy")]), words: "never typed")
            let field = try field(rig, page: 1)
            rig.dictation.begin(into: field)
            #expect(await waitUntil { rig.controller.phase == .recording }, "\(end)")
            switch end {
            case "skip": rig.dock.sending = .skip
            case "send": rig.dock.sending = .send
            case "minimize": rig.dock.setMinimized(true)
            case "back":   // Send waits while dictating; Back turns the page, out of the field's sight
                let back: UIButton = try #require(find("question.back", in: rig.dock))
                back.sendActions(for: .primaryActionTriggered)
                #expect(rig.dock.page == 0)
            default:
                #if targetEnvironment(macCatalyst)
                rig.dock.escapePressed()
                #else
                rig.dictation.cancel(why: "cancelled")
                #endif
            }
            #expect(!rig.controller.isActive, "\(end)")
            try? await Task.sleep(for: .milliseconds(80))
            #expect(field.text == "ivy", "\(end): nothing typed")
            #expect(field.dictationContent == nil, "\(end)")
            #expect(!KeepAwake.isHeld(.dictation), "\(end)")
            rig.close()
        }
    }

    @Test func theCardsMicWaitsWhileTheComposerDictatesElsewhere() async throws {
        let rig = Rig(questions: [name], draft: ClarifyDraft(page: 0, stages: [:]), words: "x")
        defer { rig.close() }
        let field = try field(rig, page: 0)
        let elsewhere = FakeTalkChat(profile: "wren")
        rig.controller.start(in: elsewhere) { _ in }
        #expect(!field.micEnabled, "one dictation app-wide")
        #expect(!rig.dictation.canBegin)
        rig.dictation.begin(into: field)
        #expect(!rig.dictation.isActive, "the card's mic starts nothing while another records")
        #expect(rig.controller.isActive(in: elsewhere, for: nil))
        // The card's own cancel leaves the other take alone.
        rig.dictation.cancel(why: "test")
        #expect(rig.controller.isActive(in: elsewhere))
        rig.controller.cancel()
        #expect(field.micEnabled)
    }

    @Test func aLockedCardsMicIsDimmed() throws {
        let rig = Rig(questions: [name], draft: ClarifyDraft(page: 0, stages: ["q1": ClarifyStage(draft: "juno")]), words: "x")
        defer { rig.close() }
        let field = try field(rig, page: 0)
        rig.dock.sending = .send
        #expect(!field.micEnabled)
        rig.dictation.begin(into: field)
        #expect(!rig.dictation.isActive)
        rig.dock.sending = .none
        #expect(field.micEnabled)
    }

    @Test func noVoiceNoMic() throws {
        let rig = Rig(questions: [name], draft: ClarifyDraft(page: 0, stages: [:]), words: "x")
        defer { rig.close() }
        let plain = QuestionDockView(prompt: ClarifyPrompt(id: "srq-n", questions: [name]), draft: ClarifyDraft(page: 0, stages: [:]))
        let page = try #require(find("question.page.0", in: plain, as: QuestionPageView.self))
        #expect(page.answerField?.showsMic == false)
        rig.dictation.isAvailable = { false }
        let other = QuestionDockView(prompt: ClarifyPrompt(id: "srq-o", questions: [name]), draft: ClarifyDraft(page: 0, stages: [:]))
        other.dictation = rig.dictation
        let otherPage = try #require(find("question.page.0", in: other, as: QuestionPageView.self))
        #expect(otherPage.answerField?.showsMic == false)
    }

    @Test func theComposersTakeAndTheCardsAreTold() async {
        let rig = Rig(questions: [name], draft: ClarifyDraft(page: 0, stages: [:]), words: "x")
        defer { rig.close() }
        let owner = NSObject()
        rig.controller.start(in: rig.chat, for: owner) { _ in }
        #expect(rig.controller.isActive(in: rig.chat))
        #expect(rig.controller.isActive(for: owner))
        #expect(!rig.controller.isActive(in: rig.chat, for: nil))
        rig.controller.cancel(for: NSObject(), why: "not its own")
        #expect(rig.controller.isActive)
        // The chat leaving (or a question taking the composer's place) throws away a take whatever it types into.
        rig.controller.cancel(in: rig.chat)
        #expect(!rig.controller.isActive)
    }
}
