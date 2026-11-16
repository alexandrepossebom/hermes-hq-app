// Words from Hermes (docs/spec/3x-live-words.md §2.3): the wire's frames, one take's life against a scripted socket
// (partials, the final text, every way it can stop: each leaves the recording to be transcribed after Stop), which source `LiveWords.listen` hands out,
// and that a memo whose words Hermes settled is never transcribed a second time. The same protocol against the
// stand-in gateway's real socket is in `GatewayWordsLiveTests` below (HQ_VOICE_FIXTURE).

import Foundation
import QuartzCore
import Synchronization
import Testing
@testable import HermesHQNative

/// The socket as a script: what the app sent, and what "Hermes" says back (pushed by the test, or by `onSend`).
nonisolated final class ScriptedWordsSocket: GatewayWordsSocket, @unchecked Sendable {
    struct Dropped: Error {}

    private struct State {
        var sent: [GatewayWordsFrame] = []
        var incoming: [Result<GatewayWordsFrame, any Error>] = []
        var waiter: CheckedContinuation<Result<GatewayWordsFrame, any Error>, Never>?
        var closed = false
    }

    private let state = Mutex(State())
    /// Called after each frame the app sends (answer `eos` with a final, drop after some sound).
    let onSend: @Sendable (GatewayWordsFrame, ScriptedWordsSocket) -> Void

    init(onSend: @escaping @Sendable (GatewayWordsFrame, ScriptedWordsSocket) -> Void = { _, _ in }) { self.onSend = onSend }

    var sent: [GatewayWordsFrame] { state.withLock { $0.sent } }
    var closed: Bool { state.withLock { $0.closed } }
    var texts: [String] { sent.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    var audio: Data { sent.reduce(into: Data()) { if case .data(let data) = $1 { $0.append(data) } } }

    func say(_ json: String) { deliver(.success(.text(json))) }
    func drop() { deliver(.failure(Dropped())) }

    private func deliver(_ result: Result<GatewayWordsFrame, any Error>) {
        let waiter = state.withLock { s -> CheckedContinuation<Result<GatewayWordsFrame, any Error>, Never>? in
            guard let waiter = s.waiter else {
                s.incoming.append(result)
                return nil
            }
            s.waiter = nil
            return waiter
        }
        waiter?.resume(returning: result)
    }

    func send(_ frame: GatewayWordsFrame) async throws {
        let closed = state.withLock { s -> Bool in
            if !s.closed { s.sent.append(frame) }
            return s.closed
        }
        if closed { throw Dropped() }
        onSend(frame, self)
    }

    func receive() async throws -> GatewayWordsFrame {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<GatewayWordsFrame, any Error>, Never>) in
            let ready = state.withLock { s -> Result<GatewayWordsFrame, any Error>? in
                if !s.incoming.isEmpty { return s.incoming.removeFirst() }
                if s.closed { return .failure(Dropped()) }
                s.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        return try result.get()
    }

    func close() {
        let waiter = state.withLock { s -> CheckedContinuation<Result<GatewayWordsFrame, any Error>, Never>? in
            s.closed = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(returning: .failure(Dropped()))
    }
}

/// `count` samples of one value, in pieces of a tap's size.
nonisolated func feedWords(_ listener: any LiveWordsListening, samples count: Int, value: Int16 = 7, piece: Int = 400) {
    var left = count
    while left > 0 {
        let n = min(piece, left)
        [Int16](repeating: value, count: n).withUnsafeBufferPointer { listener.feed($0) }
        left -= n
    }
}

@Suite struct GatewayWordsWireTests {
    @Test func theAppsFramesAreTheProtocols() {
        #expect(GatewayWordsWire.path == "/api/audio/transcribe-stream")
        #expect(GatewayWordsWire.startFrame() == #"{"sample_rate":16000}"#)
        #expect(GatewayWordsWire.startFrame(sampleRate: 48_000) == #"{"sample_rate":48000}"#)
        #expect(GatewayWordsWire.endFrame == #"{"eos":true}"#)
        // A tenth of a second of 16 kHz 16-bit mono.
        #expect(GatewayWordsWire.chunkBytes == 3200)
    }

    @Test func hermesFramesAreRead() {
        #expect(GatewayWordsWire.parse(#"{"type":"partial","text":"dzień dobry"}"#) == .partial("dzień dobry"))
        #expect(GatewayWordsWire.parse(#"{"type":"final","transcript":" Dzień dobry. ","provider":"elevenlabs"}"#) == .final("Dzień dobry.", provider: "elevenlabs"))
        #expect(GatewayWordsWire.parse(#"{"type":"final"}"#) == .final("", provider: ""))
        #expect(GatewayWordsWire.parse(#"{"type":"error","message":"no live STT for the configured provider"}"#) == .error("no live STT for the configured provider"))
        #expect(GatewayWordsWire.parse(#"{"type":"partial"}"#) == .unknown)
        #expect(GatewayWordsWire.parse(#"{"type":"session_started"}"#) == .unknown)
        #expect(GatewayWordsWire.parse("not json") == .unknown)
        #expect(GatewayWordsStop.from(message: "no live STT for the configured provider") == .noLiveProvider)
        #expect(GatewayWordsStop.from(message: "provider timed out") == .refused("provider timed out"))
    }

    /// A partial is the whole text so far: the words that stood still are settled, the newest may still change.
    @Test func wordsThatStoodStillAreSettled() {
        #expect(GatewayWordsWire.text(from: "one", after: "") == LiveWordsText(settled: "", pending: "one"))
        #expect(GatewayWordsWire.text(from: "one two three", after: "one two") == LiveWordsText(settled: "one two", pending: "three"))
        #expect(GatewayWordsWire.text(from: "one too three", after: "one two") == LiveWordsText(settled: "one", pending: "too three"))
        #expect(GatewayWordsWire.text(from: "one two", after: "one two") == LiveWordsText(settled: "one", pending: "two"))
        #expect(GatewayWordsWire.text(from: "", after: "one two").isEmpty)
    }

    /// What the gateway's settings say about its live speech to text (off unless `stt.streaming` is turned on).
    @Test func theSettingsSayWhetherHermesCanWriteLive() {
        #expect(GatewayWordsWire.offered(config: nil) == nil)
        #expect(GatewayWordsWire.offered(config: ["voice": [:]]) == nil)
        #expect(GatewayWordsWire.offered(config: ["stt": ["enabled": true, "provider": "elevenlabs"]]) == false)
        #expect(GatewayWordsWire.offered(config: ["stt": ["streaming": true, "provider": "elevenlabs"]]) == true)
        #expect(GatewayWordsWire.offered(config: ["stt": ["streaming": "yes", "provider": "OpenAI"]]) == true)
        #expect(GatewayWordsWire.offered(config: ["stt": ["streaming": true]]) == true, "no stored provider: Hermes picks one")
        #expect(GatewayWordsWire.offered(config: ["stt": ["streaming": true, "provider": "local"]]) == false)
        #expect(GatewayWordsWire.offered(config: ["stt": ["streaming": true, "provider": "local_command"]]) == false)
        #expect(GatewayWordsWire.offered(config: ["stt": ["enabled": false, "streaming": true, "provider": "xai"]]) == false)
        #expect(TalkConfig(config: ["stt": ["streaming": true, "provider": "xai"]]).liveWordsOffered == true)
        #expect(TalkConfig().liveWordsOffered == nil)
    }

    @Test func theSettingsWordsSayWhatHappens() {
        #expect(VoiceSettingsCatalog.wordsFromTitle == "Words From")
        #expect(VoiceSettingsCatalog.wordsFromChoice(.device) == "This \(DeviceWord.name)")
        #expect(VoiceSettingsCatalog.wordsFromChoice(.hermes) == "Hermes")
        let on = VoiceSettingsCatalog.wordsFromHermesNote(offered: true)
        #expect(on.hasPrefix("Hermes writes your words as you record a memo or dictate") && on.hasSuffix(DeviceWord.onlyHere))
        #expect(VoiceSettingsCatalog.wordsFromHermesNote(offered: nil) == on)
        let off = VoiceSettingsCatalog.wordsFromHermesNote(offered: false)
        #expect(on.contains("If it can’t, or in Talk, your speech is transcribed when you stop.") && !on.contains("this \(DeviceWord.name) does"))
        #expect(off.hasPrefix("Live Transcription is off on Hermes") && off.contains("Turn it on in Speech to Text."))
        #expect(VoiceSettingsCatalog.labels["stt.streaming"] == "Live Transcription")
        #expect(VoiceSettingsCatalog.speechToTextKeys.contains("stt.streaming"))
    }
}

@Suite("Words from Hermes: one take", .serialized)
@MainActor
struct GatewayLiveWordsTests {
    final class Shown { var texts: [LiveWordsText] = [] }

    private func link(_ socket: ScriptedWordsSocket?, key: String = "acct|\(UUID().uuidString)") -> GatewayWordsLink {
        GatewayWordsLink(key: key) {
            guard let socket else { throw ScriptedWordsSocket.Dropped() }
            return socket
        }
    }

    /// A socket that answers `eos` with the final text.
    private func finalOnEnd(_ words: String, provider: String = "fixture") -> ScriptedWordsSocket {
        ScriptedWordsSocket { frame, socket in
            if frame == .text(GatewayWordsWire.endFrame) { socket.say(#"{"type":"final","transcript":"\#(words)","provider":"\#(provider)"}"#) }
        }
    }

    @Test func partialsShowAndTheFinalTextSettles() async {
        GatewayWordsMemory.reset()
        let socket = finalOnEnd("Dzień dobry, sprawdź deployment.", provider: "elevenlabs")
        let shown = Shown()
        let listener = GatewayLiveWords(link: link(socket)) { shown.texts.append($0) }
        feedWords(listener, samples: 8_000)   // half a second
        #expect(await waitUntil { socket.audio.count == 16_000 })
        socket.say(#"{"type":"partial","text":"Dzień"}"#)
        socket.say(#"{"type":"partial","text":"Dzień dobry sprawdź"}"#)
        #expect(await waitUntil { shown.texts.count == 2 })
        #expect(shown.texts.last == LiveWordsText(settled: "Dzień", pending: "dobry sprawdź"))
        feedWords(listener, samples: 1_000)   // under a chunk: goes up with Stop
        let words = await listener.finish()
        #expect(words == "Dzień dobry, sprawdź deployment.")
        // The wire, in order: the rate, the sound whole and untouched, then eos.
        #expect(socket.texts == [GatewayWordsWire.startFrame(), GatewayWordsWire.endFrame])
        #expect(socket.sent.first == .text(GatewayWordsWire.startFrame()) && socket.sent.last == .text(GatewayWordsWire.endFrame))
        #expect(socket.audio.count == 18_000 && socket.audio.allSatisfy { $0 == 7 || $0 == 0 })
        #expect(GatewayWordsMemory.last == .hermes(provider: "elevenlabs"))
        #expect(await waitUntil { socket.closed })
        // Asked again, it answers the same words without another wait.
        #expect(await listener.finish() == words)
    }

    /// The gateway has no live speech to text for its provider: it says so at once. The take has no live words and is
    /// transcribed after Stop; this device's words are never the final text when Hermes was chosen.
    @Test func noLiveSpeechToTextLeavesTheTakeToBeTranscribedAfterStop() async {
        GatewayWordsMemory.reset()
        let socket = ScriptedWordsSocket()
        socket.say(#"{"type":"error","message":"no live STT for the configured provider"}"#)
        let key = "acct|ivy-\(UUID().uuidString)"
        let listener = GatewayLiveWords(link: link(socket, key: key)) { _ in }
        feedWords(listener, samples: 4_000)
        #expect(await waitUntil { GatewayWordsMemory.refused(key) }, "that gateway isn't dialled again for a while")
        feedWords(listener, samples: 2_000, value: 9)
        #expect(await listener.finish() == "")
        #expect(GatewayWordsMemory.last == .afterStop(.noLiveProvider))
        #expect(!GatewayWordsMemory.refused(key, now: Date().addingTimeInterval(GatewayWordsWire.refusalLifetime + 1)))
        GatewayWordsMemory.forgetRefusals()
        #expect(!GatewayWordsMemory.refused(key), "its settings changed: it is asked again")
        #expect(!socket.texts.contains(GatewayWordsWire.endFrame))
    }

    /// A drop mid-recording: the words shown so far go (they are not what will be sent), nothing more goes up, and the
    /// take settles on no words, which is what makes the recording be transcribed after Stop.
    @Test func aDropMidRecordingLeavesTheRecordingToBeTranscribed() async {
        GatewayWordsMemory.reset()
        let socket = ScriptedWordsSocket()
        let shown = Shown()
        let listener = GatewayLiveWords(link: link(socket)) { shown.texts.append($0) }
        feedWords(listener, samples: 3_200)
        socket.say(#"{"type":"partial","text":"half a"}"#)
        #expect(await waitUntil { shown.texts.last?.whole == "half a" })
        socket.drop()
        #expect(await waitUntil { shown.texts.last?.isEmpty == true }, "the words row clears: nothing more will come")
        let sent = socket.audio.count
        feedWords(listener, samples: 3_200)
        #expect(await listener.finish() == "")
        #expect(socket.audio.count == sent && !socket.texts.contains(GatewayWordsWire.endFrame))
        #expect(GatewayWordsMemory.last == .afterStop(.dropped))
    }

    @Test func aSocketThatWontOpenLeavesNoWords() async {
        GatewayWordsMemory.reset()
        let listener = GatewayLiveWords(link: link(nil)) { _ in }
        feedWords(listener, samples: 1_600)
        #expect(await listener.finish() == "")
        #expect(GatewayWordsMemory.last == .afterStop(.didNotOpen))
    }

    @Test func aSocketSlowToOpenLeavesNoWordsAndIsClosedWhenItComes() async {
        GatewayWordsMemory.reset()
        let socket = ScriptedWordsSocket()
        let slow = GatewayWordsLink(key: "acct|slow") {
            try? await Task.sleep(for: .milliseconds(400))
            return socket
        }
        let listener = GatewayLiveWords(link: slow, openLimit: 0.1) { _ in }
        feedWords(listener, samples: 1_600)
        #expect(await listener.finish() == "")
        #expect(GatewayWordsMemory.last == .afterStop(.didNotOpen))
        #expect(await waitUntil { socket.closed })
        #expect(socket.sent.isEmpty)
    }

    /// A final that never comes, or an error instead of it, settles on no words within the limit.
    @Test func noFinalInTimeSettlesOnNoWords() async {
        GatewayWordsMemory.reset()
        let socket = ScriptedWordsSocket()
        let listener = GatewayLiveWords(link: link(socket), settleLimit: 0.2) { _ in }
        feedWords(listener, samples: 3_200)
        let started = CACurrentMediaTime()
        #expect(await listener.finish() == "")
        #expect(CACurrentMediaTime() - started < 2)
        #expect(GatewayWordsMemory.last == .afterStop(.slow))
        #expect(socket.closed)
    }

    @Test func anErrorInsteadOfTheFinalSettlesOnNoWords() async {
        GatewayWordsMemory.reset()
        let socket = ScriptedWordsSocket { frame, socket in
            if frame == .text(GatewayWordsWire.endFrame) { socket.say(#"{"type":"error","message":"provider timed out"}"#) }
        }
        let listener = GatewayLiveWords(link: link(socket)) { _ in }
        feedWords(listener, samples: 3_200)
        #expect(await listener.finish() == "")
        #expect(GatewayWordsMemory.last == .afterStop(.refused("provider timed out")))
    }

    /// A disconnect is the wire's cancel: no eos.
    @Test func cancelClosesTheSocketWithoutEos() async {
        let socket = ScriptedWordsSocket()
        let listener = GatewayLiveWords(link: link(socket)) { _ in }
        feedWords(listener, samples: 3_200)
        #expect(await waitUntil { socket.audio.count == 6_400 })
        listener.cancel()
        #expect(await waitUntil { socket.closed })
        #expect(!socket.texts.contains(GatewayWordsWire.endFrame))
        #expect(await listener.finish() == "")
    }
}

@Suite("Words from Hermes: the source", .serialized)
@MainActor
struct LiveWordsSourceTests {
    /// Runs `body` with Words From set to `source`, a scripted device listener, and everything put back after.
    private func with(_ source: LiveWordsSource, script: String? = "heard on this device", _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let was = (defaults.object(forKey: LiveWordsSource.settingKey), defaults.object(forKey: LiveWords.settingKey), LiveWords.debugScript)
        defer {
            defaults.set(was.0, forKey: LiveWordsSource.settingKey)
            defaults.set(was.1, forKey: LiveWords.settingKey)
            LiveWords.debugScript = was.2
            GatewayWordsMemory.reset()
        }
        defaults.set(true, forKey: LiveWords.settingKey)
        LiveWordsSource.chosen = source
        LiveWords.debugScript = script
        GatewayWordsMemory.reset()
        try await body()
    }

    @Test func thisDeviceIsTheSourceUnlessHermesIsChosen() async {
        await with(.device) {
            let socket = ScriptedWordsSocket()
            let listener = LiveWords.listen(hermes: GatewayWordsLink(key: "a|b") { socket }) { _ in }
            #expect(await listener?.finish() == "heard on this device")
            #expect(socket.sent.isEmpty, "nothing of Hermes is asked")
            #expect(GatewayWordsMemory.last == nil)
        }
    }

    @Test func hermesWritesAMemoOrADictationAndLeavesTalkToBeTranscribed() async {
        await with(.hermes) {
            // Talk passes no gateway: its takes are transcribed by Hermes when they end.
            #expect(LiveWords.listen { _ in } == nil)
            let socket = ScriptedWordsSocket { frame, socket in
                if frame == .text(GatewayWordsWire.endFrame) { socket.say(#"{"type":"final","transcript":"I think, um.","provider":"fixture"}"#) }
            }
            let listener = LiveWords.listen(hermes: GatewayWordsLink(key: "a|b") { socket }) { _ in }
            #expect(listener != nil)
            if let listener { feedWords(listener, samples: 3_200) }
            // Tidied like this device's words (no "um").
            #expect(await listener?.finish() == "I think.")
            #expect(LiveWords.diagnosticsLine == "from Hermes (fixture)")
        }
    }

    @Test func liveTranscriptionOffOnHermesUsesThisDeviceWithoutDialling() async {
        await with(.hermes) {
            let socket = ScriptedWordsSocket()
            let listener = LiveWords.listen(hermes: GatewayWordsLink(key: "a|b", offered: false) { socket }) { _ in }
            #expect(await listener?.finish() == "heard on this device")
            try? await Task.sleep(for: .milliseconds(50))
            #expect(socket.sent.isEmpty)
            #expect(GatewayWordsMemory.last == .device(.notOffered))
            #expect(LiveWords.diagnosticsLine.hasPrefix("on this device, not from Hermes: Live Transcription is off on Hermes; "))
        }
    }

    /// A gateway that said its provider has no live transcription isn't dialled again for a while, and this device
    /// doesn't write the words instead: the take is transcribed after Stop.
    @Test func aGatewayThatSaidNoIsNotDialledAgainForAWhile() async {
        await with(.hermes) {
            GatewayWordsMemory.noteRefusal("a|b")
            let socket = ScriptedWordsSocket()
            #expect(LiveWords.listen(hermes: GatewayWordsLink(key: "a|b") { socket }) { _ in } == nil)
            #expect(socket.sent.isEmpty)
            #expect(GatewayWordsMemory.last == .afterStop(.noLiveProvider))
        }
    }

    /// With Hermes chosen and its live transcription on, this device's words are never the take's words, even when
    /// this device could listen.
    @Test func aFailedStreamNeverSettlesOnThisDevicesWords() async {
        await with(.hermes) {
            let socket = ScriptedWordsSocket()
            socket.drop()
            final class Shown { var texts: [LiveWordsText] = [] }
            let shown = Shown()
            let listener = LiveWords.listen(hermes: GatewayWordsLink(key: "a|b") { socket }) { shown.texts.append($0) }
            if let listener { feedWords(listener, samples: 3_200) }
            try? await Task.sleep(for: .milliseconds(700))
            #expect(!shown.texts.contains { !$0.isEmpty }, "none of this device's words show either")
            #expect(await listener?.finish() == "")
            #expect(GatewayWordsMemory.last == .afterStop(.dropped))
        }
    }

    @Test func diagnosticsSayWhoWritesTheWordsAndWhy() async {
        await with(.hermes, script: nil) {
            #expect(LiveWords.diagnosticsLine == "from Hermes (no memo or dictation yet)")
            GatewayWordsMemory.note(.hermes(provider: ""))
            #expect(LiveWords.diagnosticsLine == "from Hermes")
            GatewayWordsMemory.note(.afterStop(.dropped))
            #expect(LiveWords.diagnosticsLine == "from Hermes after Stop, not as you speak: the connection to Hermes dropped")
            GatewayWordsMemory.note(.afterStop(.refused("quota exceeded")))
            #expect(LiveWords.diagnosticsLine == "from Hermes after Stop, not as you speak: Hermes said: quota exceeded")
            // With no device listener and Live Transcription off, nothing listens: transcribed after Stop.
            #expect(LiveWords.listen(hermes: GatewayWordsLink(key: "a|b", offered: false) { ScriptedWordsSocket() }) { _ in } == nil)
            #expect(GatewayWordsMemory.last == .afterStop(.notOffered))
        }
        await with(.device, script: nil) {
            GatewayWordsMemory.note(.hermes(provider: "fixture"))
            #expect(!LiveWords.diagnosticsLine.contains("Hermes"), "this device's line, whatever an earlier take did")
        }
    }

    /// The language this device listens for: the one picked, then the person's own in the phone's order, the
    /// keyboards', and the app's locale last (it used to be first, and is the app's language with the phone's region).
    @Test func thisDevicesLanguageFollowsThePersonNotTheRegion() {
        let wanted = LiveWordsEngine.wanted(chosen: nil, preferred: ["en-US", "pl-PL"], keyboards: ["en-US", "pl-PL", "emoji", "dictation"],
                                            current: Locale(identifier: "en_IE"))
        #expect(wanted.map { $0.identifier(.bcp47) } == ["en-US", "pl-PL", "en-IE"])
        let picked = LiveWordsEngine.wanted(chosen: "pl-PL", preferred: ["en-US", "pl-PL"], keyboards: [], current: Locale(identifier: "en_IE"))
        #expect(picked.map { $0.identifier(.bcp47) } == ["pl-PL", "en-US", "en-IE"])
        // A keyboard's language the phone's list doesn't have is still tried, after the list.
        let keyboard = LiveWordsEngine.wanted(chosen: "", preferred: ["en-GB"], keyboards: ["pl-PL"], current: Locale(identifier: "en_GB"))
        #expect(keyboard.map { $0.identifier(.bcp47) } == ["en-GB", "pl-PL"])
        // Only the first four of a long list, as before.
        let many = LiveWordsEngine.wanted(chosen: nil, preferred: ["en-US", "pl-PL", "de-DE", "fr-FR", "it-IT"], keyboards: [], current: Locale(identifier: "en_US"))
        #expect(many.count == 4)
        let choices = LiveWordsEngine.choices(preferred: ["en-US", "pl-PL"], keyboards: ["pl-PL", "emoji"])
        #expect(choices.map(\.id) == ["en-US", "pl-PL"])
        #expect(choices.allSatisfy { !$0.name.isEmpty })
    }
}

@Suite("Words from Hermes: memos and dictation", .serialized)
@MainActor
struct GatewayWordsTakeTests {
    private func finalOnEnd(_ words: String) -> ScriptedWordsSocket {
        ScriptedWordsSocket { frame, socket in
            if frame == .text(GatewayWordsWire.endFrame) { socket.say(#"{"type":"final","transcript":"\#(words)","provider":"fixture"}"#) }
        }
    }

    private func session(_ client: VoiceFakeClient) async -> LiveChatSession {
        let s = LiveChatSession(client: client, account: client.account, profile: "ivy", storedSessionId: "20260929_120000_aabbcc09",
                                title: "Ivy", head: nil, cache: makeTempCache(), resolveSessionId: nil, frameMode: .manual)
        s.start()
        _ = await waitUntil(timeout: .seconds(5)) { s.openSettled }
        return s
    }

    /// The memo carries Hermes' final text, and sending it never transcribes the same sound again.
    @Test func aMemoCarriesHermesFinalTextAndIsNotTranscribedAgain() async throws {
        let client = VoiceFakeClient()
        VoiceTestStores.activate(client.account.id)
        let capture = FakeCapture(file: try VoiceTestStores.recording(client.account.id, seconds: 3))
        let controller = MemoController(capture: capture)
        controller.tapsMicrophone = false
        let socket = finalOnEnd("Zrób deploy na staging")
        var heard: GatewayLiveWords?
        controller.makeWords = { onText in
            let listener = GatewayLiveWords(link: GatewayWordsLink(key: "a|ivy") { socket }, onText: onText)
            heard = listener
            return listener
        }
        let target = MemoTarget(scope: "acct|ivy|\(UUID().uuidString)", host: nil, session: nil, botName: "Ivy",
                                accountKey: MemoPaths.accountKey(client.account.id))
        controller.memoDown(target, width: 402)
        #expect(await waitUntil { controller.state.phase == .holding })
        let listener = try #require(heard)
        feedWords(listener, samples: 3_200)
        socket.say(#"{"type":"partial","text":"Zrób deploy"}"#)
        #expect(await waitUntil { controller.words.whole == "Zrób deploy" }, "Hermes' partial shows where this device's words show")
        controller.input(.up(at: CACurrentMediaTime() * 1000 + 5000))
        #expect(await waitUntil { controller.state.phase == .idle })
        let draft = try #require(MemoAccountStores.shared.drafts?.draft(for: target.scope))
        #expect(draft.words == "Zrób deploy na staging")

        let s = await session(client)
        s.sendMemo(draft, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 1 })
        #expect(client.entries("POST /api/audio/transcribe").isEmpty, "one transcription: the live one")
        let text = try #require(client.entries("rpc prompt.submit").first?.params?["text"]?.string)
        #expect(text.hasSuffix("Voice memo transcript: Zrób deploy na staging"))
    }

    /// The stream failed: the memo has no words, so the recording is uploaded and
    /// transcribed after Stop as it always was.
    @Test func aMemoWhoseStreamFailedIsTranscribedAfterStop() async throws {
        let client = VoiceFakeClient()
        VoiceTestStores.activate(client.account.id)
        let capture = FakeCapture(file: try VoiceTestStores.recording(client.account.id, seconds: 3))
        let controller = MemoController(capture: capture)
        controller.tapsMicrophone = false
        let socket = ScriptedWordsSocket()
        var heard: GatewayLiveWords?
        controller.makeWords = { onText in
            let listener = GatewayLiveWords(link: GatewayWordsLink(key: "a|ivy") { socket }, onText: onText)
            heard = listener
            return listener
        }
        let target = MemoTarget(scope: "acct|ivy|\(UUID().uuidString)", host: nil, session: nil, botName: "Ivy",
                                accountKey: MemoPaths.accountKey(client.account.id))
        controller.memoDown(target, width: 402)
        #expect(await waitUntil { controller.state.phase == .holding })
        feedWords(try #require(heard), samples: 3_200)
        socket.drop()
        controller.input(.up(at: CACurrentMediaTime() * 1000 + 5000))
        #expect(await waitUntil { controller.state.phase == .idle })
        let draft = try #require(MemoAccountStores.shared.drafts?.draft(for: target.scope))
        #expect(draft.words == nil, "the recording is kept; only its words are missing")
        #expect(FileManager.default.fileExists(atPath: draft.path))

        let s = await session(client)
        s.sendMemo(draft, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 1 })
        #expect(client.entries("POST /api/audio/transcribe").count == 1)
        let text = try #require(client.entries("rpc prompt.submit").first?.params?["text"]?.string)
        #expect(text.hasSuffix("Voice memo transcript: Pick up milk on the way home."))
    }
}

// The same protocol against the stand-in gateway's real socket (scripts/fixtures/voice-gateway.py), with the app's own
// sign-in, ticket and socket. Enabled like `VoiceLiveFixtureTests`:
//   TEST_RUNNER_HQ_VOICE_FIXTURE="http://127.0.0.1:<port>|$PWD/build/fixtures/<credentials>.json" scripts/build.sh test <udid>
@Suite("Words from Hermes (live fixture)", .serialized, .enabled(if: VoiceFixture.available))
@MainActor
struct GatewayWordsLiveTests {
    final class Shown { var texts: [LiveWordsText] = [] }

    private func signIn() async throws -> LiveGatewayClient {
        let config = try #require(VoiceFixture.config)
        let vault = Fixtures.testVault("voice-words")
        vault.removeAll()
        let service = SignInService(store: AccountStore(vault: vault))
        let account = try await service.signInWithPassword(address: config.base.absoluteString, username: config.username,
                                                           password: config.password)
        let client = service.client(for: account)
        try await waitFor(client, .ready)
        return client
    }

    @discardableResult
    private func control(_ path: String, _ json: [String: Any]? = nil, method: String = "POST") async throws -> JSONValue {
        try await Fixtures.control(VoiceFixture.port, path, method: method, json: json)
    }

    /// One second of sound, fed at its own pace so the partials come while it "records".
    private func speak(_ listener: any LiveWordsListening, seconds: Double) async {
        for _ in 0..<Int(seconds * 10) {
            feedWords(listener, samples: 1_600)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aTakeStreamsUpAndSettlesOnHermesFinalText() async throws {
        GatewayWordsMemory.reset()
        try await control("/__fixture/voice", ["reset": true])
        try await control("/__fixture/voice", ["voiceConfig": ["stt": ["streaming": true, "provider": "elevenlabs"]],
                                               "wordsScript": "one two three four five six", "wordsPace": 0.25])
        let client = try await signIn()
        defer { client.shutdown(); Fixtures.testVault("voice-words").removeAll() }
        VoiceGateway.forgetConfig()
        #expect(await VoiceGateway.config(client: client, profile: "ivy").liveWordsOffered == true)
        let link = GatewayWordsLink(client: client, profile: "ivy")
        #expect(link.offered == true)
        let shown = Shown()
        let listener = GatewayLiveWords(link: link) { shown.texts.append($0) }
        await speak(listener, seconds: 1)
        #expect(await waitUntil(timeout: .seconds(5)) { shown.texts.last?.whole == "one two three four" })
        #expect(await listener.finish() == "one two three four five six")
        #expect(GatewayWordsMemory.last == .hermes(provider: "fixture"))
        let state = try await control("/__fixture/voice-state", method: "GET")
        let stream = try #require(state["wordStreams"]?.array?.last)
        #expect(stream["profile"]?.string == "ivy" && stream["sampleRate"]?.int == 16_000 && stream["bytes"]?.int == 32_000)
        #expect(stream["eos"]?.bool == true && stream["closedBy"]?.string == "server final")
        #expect(state["transcribes"]?.array?.isEmpty == true && state["forbidden"]?.array?.isEmpty == true)
    }

    @Test func noLiveSpeechToTextOnTheGatewayLeavesNoWords() async throws {
        GatewayWordsMemory.reset()
        try await control("/__fixture/voice", ["reset": true])
        try await control("/__fixture/voice", ["voiceConfig": ["stt": ["streaming": true, "provider": "elevenlabs"]], "wordsMode": "none"])
        let client = try await signIn()
        defer { client.shutdown(); Fixtures.testVault("voice-words").removeAll() }
        let link = GatewayWordsLink(client: client, profile: "ivy")
        let listener = GatewayLiveWords(link: link) { _ in }
        await speak(listener, seconds: 0.5)
        #expect(await listener.finish() == "")
        #expect(GatewayWordsMemory.last == .afterStop(.noLiveProvider))
        #expect(GatewayWordsMemory.refused(link.key))
    }

    @Test func aDropMidStreamLeavesNoWords() async throws {
        GatewayWordsMemory.reset()
        try await control("/__fixture/voice", ["reset": true])
        try await control("/__fixture/voice", ["voiceConfig": ["stt": ["streaming": true, "provider": "elevenlabs"]],
                                               "wordsMode": "drop", "wordsDropAfterMs": 300])
        let client = try await signIn()
        defer { client.shutdown(); Fixtures.testVault("voice-words").removeAll() }
        let listener = GatewayLiveWords(link: GatewayWordsLink(client: client, profile: "ivy")) { _ in }
        await speak(listener, seconds: 1)
        #expect(await listener.finish() == "")
        #expect(GatewayWordsMemory.last == .afterStop(.dropped))
        let state = try await control("/__fixture/voice-state", method: "GET")
        #expect(state["wordStreams"]?.array?.last?["closedBy"]?.string == "server abort")
    }

    /// An error where the final should be leaves the upload path: the take is transcribed after Stop.
    @Test func anErrorAfterStopLeavesNoWords() async throws {
        GatewayWordsMemory.reset()
        try await control("/__fixture/voice", ["reset": true])
        try await control("/__fixture/voice", ["voiceConfig": ["stt": ["streaming": true, "provider": "elevenlabs"]], "wordsMode": "error"])
        let client = try await signIn()
        defer { client.shutdown(); Fixtures.testVault("voice-words").removeAll() }
        let listener = GatewayLiveWords(link: GatewayWordsLink(client: client, profile: "ivy")) { _ in }
        await speak(listener, seconds: 0.3)
        #expect(await listener.finish() == "")
        #expect(GatewayWordsMemory.last == .afterStop(.refused("Synthetic live transcription failure")))
    }
}
