import Foundation
import Testing
@testable import HermesHQNative

@Suite @MainActor struct ManualChatTitleTests {
    @Test func fallbackProvenanceMatchesTheNameAndIsCleared() {
        let suite = "fallback-title-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ManualChatTitles.awaitModel("Repair database", account: "a", profile: "ivy", id: "s1", defaults: defaults)
        #expect(ManualChatTitles.isAwaitingModel("Repair database", account: "a", profile: "ivy", id: "s1", defaults: defaults))
        #expect(!ManualChatTitles.isAwaitingModel("My manual title", account: "a", profile: "ivy", id: "s1", defaults: defaults))
        ManualChatTitles.set(true, account: "a", profile: "ivy", id: "s1", defaults: defaults)
        #expect(!ManualChatTitles.isAwaitingModel("Repair database", account: "a", profile: "ivy", id: "s1", defaults: defaults))
        ManualChatTitles.awaitModel("Repair database", account: "a", profile: "ivy", id: "s1", defaults: defaults)
        ManualChatTitles.forget(accountId: "a", defaults: defaults)
        #expect(!ManualChatTitles.isAwaitingModel("Repair database", account: "a", profile: "ivy", id: "s1", defaults: defaults))
    }

    @Test func choicesAreScopedAndForgottenWithTheirAccount() {
        let suite = "manual-title-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ManualChatTitles.set(true, account: "a", profile: "ivy", id: "s1", defaults: defaults)
        #expect(ManualChatTitles.contains(account: "a", profile: "ivy", id: "s1", defaults: defaults))
        #expect(!ManualChatTitles.contains(account: "a", profile: "otto", id: "s1", defaults: defaults))
        #expect(!ManualChatTitles.contains(account: "b", profile: "ivy", id: "s1", defaults: defaults))
        ManualChatTitles.set(true, account: "b", profile: "ivy", id: "s1", defaults: defaults)
        ManualChatTitles.forget(accountId: "a", defaults: defaults)
        #expect(!ManualChatTitles.contains(account: "a", profile: "ivy", id: "s1", defaults: defaults))
        #expect(ManualChatTitles.contains(account: "b", profile: "ivy", id: "s1", defaults: defaults))
        ManualChatTitles.set(false, account: "b", profile: "ivy", id: "s1", defaults: defaults)
        #expect(!ManualChatTitles.contains(account: "b", profile: "ivy", id: "s1", defaults: defaults))
        ManualChatTitles.set(true, account: "b", profile: "ivy", id: "s1", defaults: defaults)
        ManualChatTitles.forgetAll(defaults: defaults)
        #expect(!ManualChatTitles.contains(account: "b", profile: "ivy", id: "s1", defaults: defaults))
    }
}
