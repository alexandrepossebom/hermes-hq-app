// [voice picker] The voices GPT-Live and Grok Live speak with, and where each bot keeps its choice (owner 2026-11-04: "It'd
// be nice if I could very easily like change the voices"). Both read the voice from the bot's own config.yaml when a
// conversation starts: `voice.gpt_live.voice` (Hermes, `HA:tools/voice_live.py` GPT_LIVE_VOICES, default marin) and
// `voice.grok_live.voice` (the add-on's grok_live.py, default eve). Every voice has a short recorded sample in the app
// (App/Resources/VoiceSamples, "Hi, I'm <name>. This is how I'll sound when we talk."), so the ▶ costs nothing.

import Foundation

nonisolated struct LiveVoice: Sendable, Equatable, Identifiable {
    /// What config.yaml holds (lower case).
    var id: String
    var name: String
    /// A few words on how it sounds: its pitch from the sample, and xAI's own words for Grok's.
    var feel: String
}

nonisolated enum LiveVoices {
    static func key(_ engine: TalkEngine) -> String? {
        switch engine {
        case .gptLive: "voice.gpt_live.voice"
        case .grokLive: "voice.grok_live.voice"
        case .standard: nil
        }
    }

    static func defaultVoice(_ engine: TalkEngine) -> String {
        switch engine {
        case .gptLive: "marin"
        case .grokLive: "eve"
        case .standard: ""
        }
    }

    /// In the order the list shows them: higher voices first.
    static func voices(_ engine: TalkEngine) -> [LiveVoice] {
        switch engine {
        case .gptLive: gptLive
        case .grokLive: grokLive
        case .standard: []
        }
    }

    private static let gptLive: [LiveVoice] = [
        .init(id: "delta", name: "Delta", feel: "Higher"),
        .init(id: "bossa", name: "Bossa", feel: "Higher"),
        .init(id: "quartz", name: "Quartz", feel: "Higher"),
        .init(id: "marin", name: "Marin", feel: "Higher"),
        .init(id: "willow", name: "Willow", feel: "Middle"),
        .init(id: "gleam", name: "Gleam", feel: "Middle"),
        .init(id: "cedar", name: "Cedar", feel: "Lower"),
        .init(id: "beacon", name: "Beacon", feel: "Lower"),
        .init(id: "cinder", name: "Cinder", feel: "Lower"),
        .init(id: "stone", name: "Stone", feel: "Lower"),
        .init(id: "vesper", name: "Vesper", feel: "Lower"),
        .init(id: "tempo", name: "Tempo", feel: "Lower"),
        .init(id: "ripple", name: "Ripple", feel: "Deep"),
        .init(id: "meridian", name: "Meridian", feel: "Deep"),
    ]

    private static let grokLive: [LiveVoice] = [
        .init(id: "ara", name: "Ara", feel: "Higher · warm, friendly"),
        .init(id: "eve", name: "Eve", feel: "Higher · energetic, upbeat"),
        .init(id: "sal", name: "Sal", feel: "Middle · smooth, balanced"),
        .init(id: "leo", name: "Leo", feel: "Lower"),
        .init(id: "rex", name: "Rex", feel: "Lower · confident, clear"),
    ]

    /// The voice a bot's config names, else the engine's default. A voice the list does not know is kept as written.
    static func current(_ engine: TalkEngine, config: JSONValue?) -> String {
        guard let key = key(engine) else { return "" }
        return normalized(ConfigText.text(config.flatMap { ConfigPath.get($0, key) }), engine)
    }

    static func normalized(_ raw: String?, _ engine: TalkEngine) -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? defaultVoice(engine) : text.lowercased()
    }

    static func name(_ id: String, _ engine: TalkEngine) -> String {
        voices(engine).first { $0.id == id }?.name ?? (id.isEmpty ? "" : id.prefix(1).uppercased() + id.dropFirst())
    }

    /// `PUT /api/config` deep-merges objects, so only the one voice changes.
    static func patch(_ engine: TalkEngine, voice: String) -> JSONValue? {
        switch engine {
        case .gptLive: .object(["voice": .object(["gpt_live": .object(["voice": .string(voice)])])])
        case .grokLive: .object(["voice": .object(["grok_live": .object(["voice": .string(voice)])])])
        case .standard: nil
        }
    }

    /// The bundled sample's resource name (`.m4a`).
    static func sampleName(_ engine: TalkEngine, _ id: String) -> String { "voice-\(engine.rawValue)-\(id)" }

    static func sampleURL(_ engine: TalkEngine, _ id: String, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: sampleName(engine, id), withExtension: "m4a")
    }
}

// MARK: - [bot voices] Each bot's own voice

// Owner 2026-11-21: "I'd like to be able to choose a voice for each bot so that when you talk to them they can have
// different voices if you want them to." The choice was only in a chat's hold menu (Voice with … › Voice), and a pick in
// Settings › Voice wrote over it for every bot without a word. A bot's voice is now a row of its Bot Info › Settings, and
// Settings asks before it takes a bot's own voice away.

/// One bot's voice as its own config.yaml has it written. `voice` nil: none written, so it speaks the engine's default
/// and has no voice of its own to keep.
nonisolated struct BotVoice: Sendable, Equatable {
    var id: String
    var name: String
    var voice: String?
}

nonisolated extension LiveVoices {
    /// The voice a bot's own config names (lower case); nil when it names none. `GET /api/config` fills in Hermes'
    /// defaults, and those hold no live voice, so a missing key is a voice nobody picked.
    static func written(_ engine: TalkEngine, config: JSONValue?) -> String? {
        guard let key = key(engine) else { return nil }
        let text = ConfigText.text(config.flatMap { ConfigPath.get($0, key) }).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text.lowercased()
    }

    /// The engine Talk would start with for a bot, as far as its settings say: this device's choice, else the bot's own
    /// `voice.voice_chat_mode`. (Whether the gateway can start it is asked when a conversation begins.)
    static func engine(chosen: TalkEngine?, config: JSONValue?) -> TalkEngine {
        chosen ?? TalkEngine(mode: ConfigText.text(config.flatMap { ConfigPath.get($0, "voice.voice_chat_mode") }))
    }

    /// The bots a pick for all bots would take a voice of their own away from: a voice is written in their config, and
    /// it is neither the one Settings showed before the pick (`shared`, the default bot's) nor the one being picked.
    static func ownVoices(shared: String, picking: String, bots: [BotVoice]) -> [BotVoice] {
        bots.filter { bot in
            guard let voice = bot.voice else { return false }
            return voice != shared && voice != picking
        }
    }

    /// The question's second line: who would lose a voice. Three names at most, then a count.
    static func ownVoicesMessage(_ bots: [BotVoice], _ engine: TalkEngine) -> String {
        let named = bots.prefix(3).map { "\($0.name) (\(name($0.voice ?? "", engine)))" }
        let rest = bots.count - named.count
        let list = ListFormatter.localizedString(byJoining: named + (rest > 0 ? ["\(rest) more"] : []))
        return bots.count == 1 ? "\(list) has a voice of its own." : "\(list) have voices of their own."
    }

    static func keepOwnTitle(_ count: Int) -> String { count == 1 ? "Keep Its Own Voice" : "Keep Their Own Voices" }

    /// Settings' footer under the list.
    static let sharedFooter = "Heard the next time you talk. A bot can have a voice of its own: Bot Info › Settings › Voice."

    /// Bot Info's page footer under the list.
    static func botFooter(_ bot: String) -> String { "Heard the next time you talk with \(bot). Your other bots keep their voices." }

    /// Bot Info's row for a bot Talk would use Standard with: its voice is its Text to Speech voice.
    static let standardValue = "Text to Speech"
}
