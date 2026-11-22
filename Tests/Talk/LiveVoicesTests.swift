// [voice picker] GPT-Live's and Grok Live's voices: the lists, what is saved where, the bundled samples and the chat
// menu's Voice ▸. [bot voices] A bot's own voice: what counts as one, and the question before a pick for all bots.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Live voices")
@MainActor
struct LiveVoicesTests {
    @Test func everyVoiceHasItsSampleInTheApp() {
        for engine in [TalkEngine.gptLive, .grokLive] {
            #expect(!LiveVoices.voices(engine).isEmpty)
            for voice in LiveVoices.voices(engine) {
                #expect(LiveVoices.sampleURL(engine, voice.id) != nil, "no sample for \(engine.rawValue) \(voice.id)")
                #expect(voice.id == voice.id.lowercased())
            }
        }
        #expect(LiveVoices.voices(.standard).isEmpty)
    }

    @Test func theListsMatchWhatTheVendorsTake() {
        // Hermes's GPT_LIVE_VOICES (tools/voice_live.py) and xAI's five.
        #expect(Set(LiveVoices.voices(.gptLive).map(\.id)) == ["marin", "cedar", "quartz", "ripple", "vesper", "willow", "stone", "gleam",
                                                              "meridian", "bossa", "tempo", "beacon", "delta", "cinder"])
        #expect(Set(LiveVoices.voices(.grokLive).map(\.id)) == ["ara", "eve", "leo", "rex", "sal"])
        #expect(LiveVoices.voices(.gptLive).contains { $0.id == LiveVoices.defaultVoice(.gptLive) })
        #expect(LiveVoices.voices(.grokLive).contains { $0.id == LiveVoices.defaultVoice(.grokLive) })
    }

    @Test func aBotsVoiceIsReadFromItsConfig() {
        let config: JSONValue = ["voice": ["gpt_live": ["voice": " Cedar "], "grok_live": ["model": "grok-voice-latest"]]]
        #expect(LiveVoices.current(.gptLive, config: config) == "cedar")
        // Not set: the engine's default.
        #expect(LiveVoices.current(.grokLive, config: config) == "eve")
        #expect(LiveVoices.current(.gptLive, config: nil) == "marin")
        // A voice written by hand is kept and named as written.
        #expect(LiveVoices.current(.grokLive, config: ["voice": ["grok_live": ["voice": "custom1"]]]) == "custom1")
        #expect(LiveVoices.name("custom1", .grokLive) == "Custom1")
        #expect(LiveVoices.name("rex", .grokLive) == "Rex")
    }

    @Test func aPickChangesOnlyTheOneVoice() {
        #expect(LiveVoices.patch(.gptLive, voice: "quartz") == ["voice": ["gpt_live": ["voice": "quartz"]]])
        #expect(LiveVoices.patch(.grokLive, voice: "rex") == ["voice": ["grok_live": ["voice": "rex"]]])
        #expect(LiveVoices.patch(.standard, voice: "x") == nil)
        #expect(LiveVoices.key(.gptLive) == "voice.gpt_live.voice")
        #expect(LiveVoices.key(.grokLive) == "voice.grok_live.voice")
    }

    // MARK: [bot voices] Each bot's own voice

    @Test func aVoiceNobodyPickedIsNotWritten() {
        let config: JSONValue = ["voice": ["gpt_live": ["voice": " Cedar "], "grok_live": ["model": "grok-voice-latest"]]]
        #expect(LiveVoices.written(.gptLive, config: config) == "cedar")
        // The engine's default by silence is not a voice of the bot's own.
        #expect(LiveVoices.written(.grokLive, config: config) == nil)
        #expect(LiveVoices.written(.gptLive, config: ["voice": ["gpt_live": ["voice": "  "]]]) == nil)
        #expect(LiveVoices.written(.gptLive, config: nil) == nil)
        #expect(LiveVoices.written(.standard, config: config) == nil)
    }

    @Test func theEngineIsThisDevicesChoiceElseTheBotsMode() {
        let live: JSONValue = ["voice": ["voice_chat_mode": "gpt_live"]]
        #expect(LiveVoices.engine(chosen: nil, config: live) == .gptLive)
        #expect(LiveVoices.engine(chosen: nil, config: ["voice": ["voice_chat_mode": "chained"]]) == .standard)
        #expect(LiveVoices.engine(chosen: nil, config: nil) == .standard)
        #expect(LiveVoices.engine(chosen: .grokLive, config: live) == .grokLive)
        #expect(LiveVoices.engine(chosen: .standard, config: live) == .standard)
    }

    @Test func aPickForAllBotsNamesTheVoicesItWouldTakeAway() {
        let bots = [BotVoice(id: "ivy", name: "Ivy", voice: "quartz"),      // its own
                    BotVoice(id: "sam", name: "Sam", voice: "cedar"),       // the shared one
                    BotVoice(id: "ada", name: "Ada", voice: nil),           // none written
                    BotVoice(id: "max", name: "Max", voice: "delta")]       // already the one picked
        #expect(LiveVoices.ownVoices(shared: "cedar", picking: "delta", bots: bots).map(\.id) == ["ivy"])
        // Nothing to lose: no question.
        #expect(LiveVoices.ownVoices(shared: "cedar", picking: "quartz", bots: Array(bots.prefix(3))).isEmpty)
        #expect(LiveVoices.ownVoices(shared: "cedar", picking: "delta", bots: []).isEmpty)
    }

    @Test func theQuestionSaysWhoHasTheirOwnVoice() {
        let ivy = BotVoice(id: "ivy", name: "Ivy", voice: "quartz"), sam = BotVoice(id: "sam", name: "Sam", voice: "stone")
        #expect(LiveVoices.ownVoicesMessage([ivy], .gptLive) == "Ivy (Quartz) has a voice of its own.")
        #expect(LiveVoices.ownVoicesMessage([ivy, sam], .gptLive) == "Ivy (Quartz) and Sam (Stone) have voices of their own.")
        let five = [ivy, sam] + ["Ada", "Max", "Zed"].map { BotVoice(id: $0.lowercased(), name: $0, voice: "delta") }
        #expect(LiveVoices.ownVoicesMessage(five, .gptLive) == "Ivy (Quartz), Sam (Stone), Ada (Delta), and 2 more have voices of their own.")
        #expect(LiveVoices.keepOwnTitle(1) == "Keep Its Own Voice")
        #expect(LiveVoices.keepOwnTitle(2) == "Keep Their Own Voices")
        // The footers say where a bot's own voice is picked, and that it is this bot's alone.
        #expect(LiveVoices.sharedFooter.contains("Bot Info › Settings › Voice"))
        #expect(LiveVoices.botFooter("Ivy") == "Heard the next time you talk with Ivy. Your other bots keep their voices.")
    }

    @Test func theChatMenuShowsVoiceUnderStart() {
        var voice = BotMenuNode(title: "Voice", kind: .submenu([]))
        voice.identifier = "voice.options.voice"
        let nodes = TalkMenus.optionNodes(readsAloud: false, dictation: .on, voice: voice) { _ in }
        #expect(nodes.count == 3)
        guard case .inline(let top) = nodes[0].kind else { Issue.record("first group not inline"); return }
        #expect(top.map(\.identifier) == ["voice.options.start", "voice.options.voice"])
    }
}
