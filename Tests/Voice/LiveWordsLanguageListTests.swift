import Foundation
import Testing
@testable import HermesHQNative

/// [language list] Settings › Voice › Language offers every language the device's speech models hear, not only the
/// phone's own (a tester 2026-11-18: Portuguese spoken on a phone set to English was written as English, and the row
/// to change it wasn't there).
struct LiveWordsLanguageListTests {
    private let english = Locale(identifier: "en_US")

    @Test func thePersonsLanguagesLeadThenTheRestByName() {
        let mine = LiveWordsEngine.choices(preferred: ["en-US"], keyboards: ["en-US"])
        let offered = ["pt_BR", "en_US", "de_DE", "pl_PL", "pt_BR"].map(Locale.init(identifier:))
        let all = LiveWordsEngine.allChoices(mine: mine, offered: offered, naming: english)
        #expect(all.map(\.id) == ["en-US", "de-DE", "pl-PL", "pt-BR"])
        #expect(all.last?.name == "Portuguese (Brazil)")
    }

    @Test func aPhoneWithOneLanguageStillGetsTheWholeList() {
        let mine = LiveWordsEngine.choices(preferred: ["en-US"], keyboards: [])
        #expect(mine.count == 1, "this is all the row used to offer, so it was hidden")
        let all = LiveWordsEngine.allChoices(mine: mine, offered: [Locale(identifier: "pt_BR")], naming: english)
        #expect(all.map(\.id) == ["en-US", "pt-BR"])
    }

    @Test func automaticNamesTheLanguageItListensFor() {
        #expect(LiveWordsEngine.automaticName(preferred: ["en-US", "pt-BR"], keyboards: [], current: english, naming: english) == "English")
        #expect(LiveWordsEngine.automaticName(preferred: ["pt-BR"], keyboards: ["en-US"], current: english, naming: english) == "Portuguese")
        #expect(VoiceSettingsCatalog.wordsLanguageAutomatic("English") == "Automatic (English)")
        #expect(VoiceSettingsCatalog.wordsLanguageAutomatic(nil) == "Automatic")
    }
}
