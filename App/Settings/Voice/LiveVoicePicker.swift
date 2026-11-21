// [voice picker] Settings › Voice › Voice Conversation's voice list (under Voice Model) and the chat's Voice with … ›
// Voice submenu: GPT-Live's and Grok Live's voices, each with its recorded sample. Settings saves the pick for every bot;
// the chat's menu for that bot alone. A conversation reads the voice when it starts, so a change is heard on the next one.
// [bot voices] A bot's own voice is also a row of its Bot Info › Settings (`BotVoicePage`, the same list and samples),
// and a pick in Settings asks before it writes over a voice a bot was given (owner 2026-11-21).

import AVFoundation
import SwiftUI
import UIKit

// MARK: - The samples

@MainActor @Observable final class LiveVoiceSamples: NSObject, AVAudioPlayerDelegate {
    static let shared = LiveVoiceSamples()

    /// `engine/voice` of the sample playing.
    private(set) var playing: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var holds = false

    static func tag(_ engine: TalkEngine, _ id: String) -> String { "\(engine.rawValue)/\(id)" }

    func toggle(_ engine: TalkEngine, _ id: String) {
        if playing == Self.tag(engine, id) { stop() } else { play(engine, id) }
    }

    func play(_ engine: TalkEngine, _ id: String) {
        stop()
        guard let url = LiveVoices.sampleURL(engine, id) else {
            AppLog.note("voice", "voice sample missing: \(LiveVoices.sampleName(engine, id))")
            return
        }
        let tag = Self.tag(engine, id)
        playing = tag
        Task {
            do { try await AudioSessionCoordinator.shared.acquire(.speech) } catch {
                if playing == tag { playing = nil }
                return
            }
            // Another tap while the session was coming up.
            guard playing == tag else { AudioSessionCoordinator.shared.release(.speech); return }
            holds = true
            do {
                let made = try AVAudioPlayer(contentsOf: url)
                made.delegate = self
                player = made
                made.play()
                AppLog.trace("voice", "voice sample playing: \(tag)")
            } catch {
                AppLog.note("voice", "voice sample failed: \(AppLog.scrub(String(describing: error)))")
                stop()
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
        if holds {
            holds = false
            AudioSessionCoordinator.shared.release(.speech)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == finished else { return }
            self.stop()
        }
    }
}

// MARK: - Saving

@MainActor enum LiveVoiceSaver {
    /// Every bot on the gateway: the default one through Settings' shared store (the page shows it at once), the rest on
    /// their own profiles. Answers the names of the bots it could not save for.
    /// [bot voices] `keeping`: bots left with the voice they have (the person chose to keep their own).
    static func saveForEveryBot(_ engine: TalkEngine, voice: String, keeping: Set<String> = [], services: any AppServices) async -> [String] {
        guard let key = LiveVoices.key(engine), let patch = LiveVoices.patch(engine, voice: voice),
              let settings = services as? GatewaySettingsServices, let api = settings.settingsAPI else { return [] }
        if settings.isReadOnlyGateway { return ["your bots"] }
        settings.configStore?.set(key, .string(voice))
        settings.configStore?.flush()
        let others = services.bots.filter { !BotModelPages.isDefault($0.id) && !keeping.contains($0.id) }
        // Side by side: twelve bots, one round trip each.
        let saves = others.map { bot in
            Task { @MainActor () -> String? in
                do { try await GatewaySettingsAPI(client: api.client, profile: bot.id).saveConfig(patch); return nil } catch {
                    AppLog.note("voice", "voice save failed for a bot: \(type(of: error))")
                    return bot.name
                }
            }
        }
        var failed: [String] = []
        for save in saves { if let name = await save.value { failed.append(name) } }
        AppLog.note("voice", "\(engine.rawValue) voice set to \(voice) for \(others.count + 1 - failed.count) of \(others.count + 1) bots, \(keeping.count) kept their own")
        return failed
    }

    /// [bot voices] Every other bot's voice as its own config has it written, read side by side and fresh (another
    /// device, or the bot's own page, may have changed one a moment ago). A bot whose settings could not be read counts
    /// as having no voice of its own: its save would fail the same way, and the footer names it then.
    static func otherBots(_ engine: TalkEngine, services: any AppServices) async -> [BotVoice] {
        guard let settings = services as? GatewaySettingsServices, let api = settings.settingsAPI else { return [] }
        let reads = services.bots.filter { !BotModelPages.isDefault($0.id) }.map { bot in
            Task { @MainActor () -> BotVoice in
                let config = try? await GatewaySettingsAPI(client: api.client, profile: bot.id).config()
                return BotVoice(id: bot.id, name: bot.name, voice: LiveVoices.written(engine, config: config))
            }
        }
        var bots: [BotVoice] = []
        for read in reads { bots.append(await read.value) }
        return bots
    }

    /// One bot (the chat's menu).
    static func save(_ engine: TalkEngine, voice: String, client: any GatewayClient, profile: String?) async throws {
        guard let patch = LiveVoices.patch(engine, voice: voice) else { return }
        let own = profile.map(BotModelPages.isDefault) ?? true
        try await GatewaySettingsAPI(client: client, profile: own ? nil : profile).saveConfig(patch)
        AppLog.note("voice", "\(engine.rawValue) voice set to \(voice) for one bot")
    }
}

// MARK: - One voice's row

/// A voice in a list: its name and feel (a tap picks it and plays its sample), and ▶ to hear it without picking.
/// `prefix` starts its identifiers (`voice.settings.voice`, `bot-voice`).
struct LiveVoiceRow: View {
    let engine: TalkEngine
    let voice: LiveVoice
    let selected: Bool
    let prefix: String
    let pick: () -> Void
    @State private var samples = LiveVoiceSamples.shared

    var body: some View {
        let isPlaying = samples.playing == LiveVoiceSamples.tag(engine, voice.id)
        HStack(alignment: .center, spacing: DeviceWord.isMac ? MacForm.radioGap : 12) {
            Button {
                Haptics.play(.selection)
                samples.play(engine, voice.id)
                pick()
            } label: {
                HStack(alignment: DeviceWord.isMac ? .firstTextBaseline : .center, spacing: DeviceWord.isMac ? MacForm.radioGap : 16) {
                    HQRadioMark(selected: selected)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.name).foregroundStyle(Color.hqLabel)
                        Text(voice.feel).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    }
                    Spacer(minLength: 0)
                    HQCheckMark(selected: selected)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("\(prefix).\(voice.id)")
            Button {
                Haptics.play(.selection)
                samples.toggle(engine, voice.id)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))   // a11y-font-ok: a glyph sized to its fixed 44 pt button
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.hqTint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Stop \(voice.name)" : "Hear \(voice.name)")
            .accessibilityIdentifier("\(prefix).\(voice.id).play")
        }
        .hqRowPadding(0)
        .hqRadioRow()
    }
}

// MARK: - Settings' list

/// The section under Voice Model. Standard speaks with the Text to Speech voice, so it points there instead.
struct LiveVoiceSection: View {
    let engine: TalkEngine
    let router: SettingsRouter
    @State private var chosen: String?
    @State private var failed: [String] = []
    @State private var samples = LiveVoiceSamples.shared
    /// [bot voices] A pick is waiting on its question (bots it would take a voice of their own away from).
    @State private var asking = false

    private var store: GatewayConfigStore? { router.gatewaySettings?.configStore }
    /// The voice as saved (the default bot's): what the other bots share unless they were given their own.
    private var saved: String { LiveVoices.current(engine, config: store?.config) }
    private var current: String { chosen ?? saved }

    var body: some View {
        if engine.isLive {
            Section {
                ForEach(LiveVoices.voices(engine)) { voice in
                    LiveVoiceRow(engine: engine, voice: voice, selected: current == voice.id, prefix: "voice.settings.voice") { pick(voice) }
                }
                if !LiveVoices.voices(engine).contains(where: { $0.id == current }) {
                    // A voice written by hand in config.yaml: shown, kept until another is picked.
                    HQOptionRowLabel(title: LiveVoices.name(current, engine), selected: true)
                        .hqRowPadding(4)
                        .accessibilityIdentifier("voice.settings.voice.custom")
                }
            } header: { HQSectionLabel {
                Text("\(engine.title) Voice")
            } } footer: { HQSectionFooter {
                Text(footer).accessibilityIdentifier("voice.settings.voice.footer")
            } }
            .onChange(of: engine) { _, _ in chosen = nil; failed = []; samples.stop() }
            .onDisappear { samples.stop() }
        } else {
            Section {
                VoiceHintRow(title: "Standard Voice", hint: "Standard speaks with your Text to Speech voice.") {
                    if let page = ConfigCatalog.page("voice.speech") { ConfigScreens.open(page: page, router: router) }
                }
                .accessibilityIdentifier("voice.settings.voice.standard")
            } header: { HQSectionLabel {
                Text("Voice")
            } }
        }
    }

    private var footer: String {
        var text = LiveVoices.sharedFooter
        if !failed.isEmpty { text += " Couldn’t save it for \(ListFormatter.localizedString(byJoining: failed))." }
        return text
    }

    /// The row has played the sample. The tick moves at once; the save waits for the other bots' voices to be read, and
    /// for the answer when one of them has a voice of its own.
    private func pick(_ voice: LiveVoice) {
        guard current != voice.id, !asking else { return }
        let before = saved
        chosen = voice.id
        failed = []
        let engine = engine, services = router.services
        Task {
            let others = await LiveVoiceSaver.otherBots(engine, services: services)
            guard chosen == voice.id, !asking else { return }   // another pick since
            let own = LiveVoices.ownVoices(shared: before, picking: voice.id, bots: others)
            if own.isEmpty { save(voice.id, keeping: []) } else { ask(voice.id, own: own) }
        }
    }

    /// [bot voices] The question before a bot's own voice is written over. A UIKit alert from the page, not a SwiftUI
    /// one on a row or the footer: the list builds those only as they scroll into view, and the footer is fourteen
    /// voices down. Without a page to ask from, nothing is saved and the tick goes back.
    private func ask(_ voice: String, own: [BotVoice]) {
        guard var top = router.presenter else { chosen = nil; return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        asking = true
        let alert = UIAlertController(title: "Change Every Bot’s Voice?", message: LiveVoices.ownVoicesMessage(own, engine), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Change All Bots", style: .default) { _ in save(voice, keeping: []) })
        alert.addAction(UIAlertAction(title: LiveVoices.keepOwnTitle(own.count), style: .default) { _ in
            save(voice, keeping: Set(own.map(\.id)))
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            asking = false
            chosen = nil   // the tick goes back to the saved voice
        })
        top.present(alert, animated: true)
    }

    private func save(_ voice: String, keeping: Set<String>) {
        asking = false
        chosen = voice
        let engine = engine, services = router.services
        Task {
            let missed = await LiveVoiceSaver.saveForEveryBot(engine, voice: voice, keeping: keeping, services: services)
            if chosen == voice {
                failed = missed
                if !missed.isEmpty { Haptics.play(.error) }   // the footer names the bots it didn't reach
            }
        }
    }
}

// MARK: - [bot voices] One bot's own voice (Bot Info › Settings › Voice)

/// The same list and samples as Settings', on this bot's own config (`store` reads its `?profile=`; the default bot's
/// is Settings' shared store, so both show a change). A pick is saved for this bot alone.
struct BotVoicePage: View {
    let botName: String
    let engine: TalkEngine
    let store: GatewayConfigStore
    @State private var samples = LiveVoiceSamples.shared

    private var current: String { LiveVoices.current(engine, config: store.config) }

    var body: some View {
        List { Group {
            ConfigFailureSection(store: store)
            if store.config == nil {
                LoadingSection(text: "Loading settings…")
            } else {
                Section {
                    ForEach(LiveVoices.voices(engine)) { voice in
                        LiveVoiceRow(engine: engine, voice: voice, selected: current == voice.id, prefix: "bot-voice") { pick(voice) }
                    }
                    if !LiveVoices.voices(engine).contains(where: { $0.id == current }) {
                        // A voice written by hand in config.yaml: shown, kept until another is picked.
                        HQOptionRowLabel(title: LiveVoices.name(current, engine), selected: true)
                            .hqRowPadding(4)
                            .accessibilityIdentifier("bot-voice.custom")
                    }
                } header: { HQSectionLabel {
                    Text("\(engine.title) Voice")
                } } footer: { HQSectionFooter {
                    Text(LiveVoices.botFooter(botName)).accessibilityIdentifier("bot-voice.footer")
                } }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(store.failure?.text)
        .task { await store.load() }
        .onDisappear { samples.stop() }
        .accessibilityIdentifier("bot-voice.list")
    }

    private func pick(_ voice: LiveVoice) {
        guard current != voice.id, let key = LiveVoices.key(engine) else { return }
        store.set(key, .string(voice.id))
        store.flush()   // now, not after the autosave's wait: the next conversation may start at once
        AppLog.note("voice", "\(engine.rawValue) voice set to \(voice.id) for one bot (bot info)")
    }
}

extension BotModelPages {
    /// Bot Info › Settings › Voice, pushed inside the sheet: the live engine's voices for this bot, or, for a bot Talk
    /// uses Standard with, its own Text to Speech page (Standard speaks with that voice). On `store` when the row
    /// already read it.
    static func openVoice(_ bot: Bot, services: any AppServices, store: GatewayConfigStore? = nil, on navigation: UINavigationController?) {
        guard let navigation, let store = store ?? contextWindowStore(for: bot, services: services) else { return }
        Haptics.play(.selection)
        let router = SettingsRouter(services: services, navigation: navigation)
        let engine = LiveVoices.engine(chosen: TalkController.chosenEngine, config: store.config)
        let own = isDefault(bot.id)
        if engine.isLive {
            let page = SettingsPageController(title: "Voice", BotVoicePage(botName: bot.name, engine: engine, store: store)
                                                .hqMacFormSide(in: navigation))
            page.onDisappear = { store.flush() }
            router.push(page)
        } else if let speech = ConfigCatalog.page("voice.speech") {
            let page = SettingsPageController(title: speech.title,
                                              VoiceFieldsPage(page: speech, store: store, router: router, readsReplies: true, botName: own ? nil : bot.name)
                                                .hqMacFormSide(in: navigation))
            page.onDisappear = { store.flush() }
            router.push(page)
        }
    }
}
