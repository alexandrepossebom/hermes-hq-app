import Foundation
import Testing
@testable import HermesHQNative

/// [viewing] What this device tells the add-on about the chat in front of its person (a tester 2026-11-18: the iPhone
/// alerted for a reply being read on the Mac).
struct ViewingRulesTests {
    private let chat = ViewingRules.Chat(session: "chat-a", profile: "otto")

    @Test func aChatInFrontIsReported() {
        #expect(ViewingRules.shown(active: true, chat: chat, mac: false, idle: nil) == chat)
        #expect(ViewingRules.shown(active: true, chat: chat, mac: true, idle: 5) == chat)
    }

    @Test func notFromBehindAnotherAppNorFromAList() {
        #expect(ViewingRules.shown(active: false, chat: chat, mac: true, idle: 0) == nil)
        #expect(ViewingRules.shown(active: true, chat: nil, mac: false, idle: nil) == nil)
        #expect(ViewingRules.shown(active: true, chat: .init(session: "", profile: "otto"), mac: false, idle: nil) == nil)
    }

    @Test func aMacNobodyIsAtStopsCounting() {
        #expect(ViewingRules.shown(active: true, chat: chat, mac: true, idle: ViewingRules.macIdle + 1) == nil)
        #expect(ViewingRules.shown(active: true, chat: chat, mac: true, idle: nil) == chat, "idle time unknown: the window in front counts")
        #expect(ViewingRules.shown(active: true, chat: chat, mac: false, idle: 9_999) == chat, "a phone in front is in a hand")
    }

    @Test func saidAgainWhileShownAndTakenBackOnce() {
        #expect(ViewingRules.step(shown: chat, reported: nil) == .report(chat))
        #expect(ViewingRules.step(shown: chat, reported: chat) == .report(chat), "each beat renews the 45 s")
        #expect(ViewingRules.step(shown: nil, reported: chat) == .clear)
        #expect(ViewingRules.step(shown: nil, reported: nil) == .nothing)
        #expect(ViewingRules.ttl > ViewingRules.beat * 2, "one lost beat doesn't bring the alerts back")
    }
}
