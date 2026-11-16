// Words from Hermes (docs/spec/3x-live-words.md §2.3; a tester's request, 2026-11): a second source of the words as
// you speak. The microphone's sound goes up the gateway's live speech-to-text socket while a memo or a dictation
// records, Hermes' partial text shows where this device's own words show, and the text Hermes settles on after Stop is
// what gets typed or sent. It uses the chat profile's Speech to Text provider and language, so a language this device
// hears badly is heard well.
//
//   app    → {"sample_rate": 16000}, then binary s16le mono PCM, then {"eos": true}   (a disconnect cancels)
//   Hermes → {"type":"partial","text"}   the whole text so far
//            {"type":"final","transcript","provider"}
//            {"type":"error","message"}  also at once when the provider has no live speech to text
//
// Nothing is ever lost, and the final words never come from this device: the person chose Hermes because it hears
// them better. A socket that won't open, an error, a drop or a slow answer leaves the take with no live words, which
// is what makes the recording be transcribed by Hermes after Stop, as it always was. Never logs the words.
//
// This is the only file that names the socket's route (`scripts/check-talk-guards.sh`). The app still never reads the
// gateway's client voice config: that answer carries provider keys (3x-talk T3).

import Foundation
import Synchronization

/// Where the words as you speak come from (Settings › Voice › Words From).
nonisolated enum LiveWordsSource: String, CaseIterable, Sendable {
    case device, hermes

    static let settingKey = "hq.voice.liveWordsSource"
    static var chosen: LiveWordsSource {
        get { UserDefaults.standard.string(forKey: settingKey).flatMap(LiveWordsSource.init(rawValue:)) ?? .device }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: settingKey) }
    }
}

nonisolated enum GatewayWordsWire {
    static let path = "/api/audio/transcribe-stream"
    /// The longest the socket may take to open; past it the take has no live words.
    static let openLimit: Double = 5
    /// The longest Stop waits for Hermes to settle the text; past it the recording is transcribed the old way.
    static let settleLimit: Double = 5
    /// Sound goes up in pieces of about this long (16-bit mono: two bytes a sample).
    static let chunkBytes = Int(LiveWords.sampleRate * 0.1) * 2
    /// A gateway that said it has no live speech to text isn't asked again for this long (or until its settings change).
    static let refusalLifetime: TimeInterval = 600

    static func startFrame(sampleRate: Int = Int(LiveWords.sampleRate)) -> String { "{\"sample_rate\":\(sampleRate)}" }
    static let endFrame = "{\"eos\":true}"

    enum ServerFrame: Equatable, Sendable {
        case partial(String)
        case final(String, provider: String)
        case error(String)
        case unknown
    }

    static func parse(_ text: String) -> ServerFrame {
        guard let value = try? JSONValue.parse(Data(text.utf8)), let type = value["type"]?.string else { return .unknown }
        switch type {
        case "partial":
            guard let words = value["text"]?.string else { return .unknown }
            return .partial(words)
        case "final":
            return .final((value["transcript"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                          provider: value["provider"]?.string ?? "")
        case "error": return .error(value["message"]?.string ?? "")
        default: return .unknown
        }
    }

    /// Hermes' partial is the whole text so far. The words that stood still since the last one are settled; the rest
    /// may still change.
    static func text(from partial: String, after last: String) -> LiveWordsText {
        let now = partial.split(whereSeparator: \.isWhitespace), before = last.split(whereSeparator: \.isWhitespace)
        var same = 0
        while same < now.count, same < before.count, now[same] == before[same] { same += 1 }
        // The newest word is never settled: it is the one still being said.
        same = min(same, max(0, now.count - 1))
        return LiveWordsText(settled: now[..<same].joined(separator: " "), pending: now[same...].joined(separator: " "))
    }

    /// Whether the gateway's settings say live speech to text can run (`GET /api/config`): nil when they don't say.
    /// `stt.streaming` is off unless turned on; a provider that only runs on the computer has no live wire.
    static func offered(config: JSONValue?) -> Bool? {
        guard let stt = config?["stt"], stt.object != nil else { return nil }
        if case .bool(false)? = stt["enabled"] { return false }
        let on: Bool
        switch stt["streaming"] {
        case .bool(let value)?: on = value
        case .string(let value)?: on = ["true", "1", "yes", "on"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
        case .number(let value)?: on = value != 0
        default: on = false
        }
        guard on else { return false }
        let provider = (stt["provider"]?.string ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return !["none", "local", "local_command"].contains(provider)
    }
}

/// Why a take's words did not come from Hermes, in words Voice Diagnostics shows.
nonisolated enum GatewayWordsStop: Equatable, Sendable {
    /// `stt.streaming` is off, or the provider runs on the computer only (known from the settings, nothing was dialled).
    case notOffered
    /// The socket said it has no live speech to text for the provider.
    case noLiveProvider
    case didNotOpen
    case dropped
    case slow
    /// Hermes' own error, word for word.
    case refused(String)

    var words: String {
        switch self {
        case .notOffered: "Live Transcription is off on Hermes"
        case .noLiveProvider: "Hermes’ speech to text provider has no live transcription"
        case .didNotOpen: "the connection to Hermes didn’t open"
        case .dropped: "the connection to Hermes dropped"
        case .slow: "Hermes took too long to settle the words"
        case .refused(let said): said.isEmpty ? "Hermes couldn’t transcribe live" : "Hermes said: \(VoiceReport.scrub(String(said.prefix(160))))"
        }
    }

    /// Hermes' error message → the stop. Its "no live STT" answer is remembered (`GatewayWordsMemory`).
    static func from(message: String) -> GatewayWordsStop {
        message.lowercased().contains("no live stt") ? .noLiveProvider : .refused(message)
    }
}

/// How the last take that asked Hermes for its words went (Voice Diagnostics reads it).
nonisolated enum GatewayWordsOutcome: Equatable, Sendable {
    /// Hermes settled the text (`provider` as it named itself, possibly "").
    case hermes(provider: String)
    /// This device's words were used instead (only when Live Transcription is off on Hermes, as Settings says).
    case device(GatewayWordsStop)
    /// Neither gave words: the recording was transcribed after Stop.
    case afterStop(GatewayWordsStop)
}

/// What is remembered between takes: gateways that have no live speech to text, and the last outcome.
nonisolated enum GatewayWordsMemory {
    private struct State: Sendable {
        var refusals: [String: Date] = [:]
        var last: GatewayWordsOutcome?
    }
    private static let state = Locked(State())

    static func refused(_ key: String, now: Date = Date()) -> Bool {
        guard let at = state.value.refusals[key] else { return false }
        return now.timeIntervalSince(at) < GatewayWordsWire.refusalLifetime
    }

    static func noteRefusal(_ key: String, now: Date = Date()) { state.mutate { $0.refusals[key] = now } }
    static var last: GatewayWordsOutcome? { state.value.last }
    static func note(_ outcome: GatewayWordsOutcome) { state.mutate { $0.last = outcome } }
    /// The gateway's settings changed (the provider or Live Transcription may have): it is asked again.
    static func forgetRefusals() { state.mutate { $0.refusals.removeAll() } }
    static func reset() { state.set(State()) }
}

nonisolated enum GatewayWordsFrame: Equatable, Sendable {
    case text(String)
    case data(Data)
}

/// The live speech-to-text socket, open (`URLSessionWebSocketTask` in the app, a script in tests).
nonisolated protocol GatewayWordsSocket: Sendable {
    func send(_ frame: GatewayWordsFrame) async throws
    func receive() async throws -> GatewayWordsFrame
    func close()
}

nonisolated struct GatewayWordsTask: GatewayWordsSocket {
    let task: URLSessionWebSocketTask

    func send(_ frame: GatewayWordsFrame) async throws {
        switch frame {
        case .text(let text): try await task.send(.string(text))
        case .data(let data): try await task.send(.data(data))
        }
    }

    func receive() async throws -> GatewayWordsFrame {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .data(data)
        @unknown default: return .data(Data())
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

/// The chat's gateway, for one take: how its live speech-to-text socket is opened and what is known about it.
nonisolated struct GatewayWordsLink: Sendable {
    /// "<account id>|<profile>": what a "no live speech to text" answer is remembered under.
    var key: String
    /// What the gateway's settings say (`GatewayWordsWire.offered`); nil when they were not read yet: it is tried.
    var offered: Bool?
    var open: @Sendable () async throws -> any GatewayWordsSocket

    /// The chat's own gateway and profile. The socket opens with a fresh single-use ticket, as the speech socket does.
    init(client: any GatewayClient, profile: String?) {
        key = "\(client.account.id)|\(profile ?? "")"
        offered = VoiceGateway.knownConfig(client: client, profile: profile)?.liveWordsOffered
        open = {
            guard let sockets = client as? any GatewayVoiceSockets else { throw VoiceFailure(reason: "This gateway can’t stream speech.", detail: nil) }
            let task = try await sockets.voiceSocket(path: GatewayWordsWire.path, query: VoiceWire.profileQuery(profile))
            task.resume()
            return GatewayWordsTask(task: task)
        }
    }

    /// The link for a take in a chat, or nil when Words From is this device (nothing of Hermes is asked then). The
    /// gateway's settings are read again behind it (kept a minute), so a switch flipped there is known by the next take.
    @MainActor static func forTake(client: any GatewayClient, profile: String) -> GatewayWordsLink? {
        guard LiveWords.isOn, LiveWords.source == .hermes else { return nil }
        let profile = profile.isEmpty ? nil : profile
        Task.detached(priority: .utility) { _ = await VoiceGateway.config(client: client, profile: profile) }
        return GatewayWordsLink(client: client, profile: profile)
    }

    init(key: String, offered: Bool? = true, open: @escaping @Sendable () async throws -> any GatewayWordsSocket) {
        self.key = key
        self.offered = offered
        self.open = open
    }
}

/// One take heard by Hermes. Fed 16 kHz mono samples from any thread; the words out on the main actor.
nonisolated final class GatewayLiveWords: LiveWordsListening, @unchecked Sendable {
    private enum Outgoing: Sendable { case audio(Data), end }

    private struct State {
        /// Sound not yet handed to the sender (under `chunkBytes`).
        var pending = Data()
        var lastPartial = ""
        var stop: GatewayWordsStop?
        var ended = false
        var cancelled = false
        var final: String?
        var provider = ""
        var waiter: CheckedContinuation<Void, Never>?
        var socket: (any GatewayWordsSocket)?
    }

    private let state = Mutex(State())
    private let link: GatewayWordsLink
    private let onText: @MainActor (LiveWordsText) -> Void
    private let outgoing: AsyncStream<Outgoing>.Continuation
    private let settleLimit: Double
    private var running: Task<Void, Never>?

    /// `openLimit` and `settleLimit` are shortened by tests.
    init(link: GatewayWordsLink, openLimit: Double = GatewayWordsWire.openLimit,
         settleLimit: Double = GatewayWordsWire.settleLimit, onText: @escaping @MainActor (LiveWordsText) -> Void) {
        self.link = link
        self.onText = onText
        self.settleLimit = settleLimit
        let (stream, continuation) = AsyncStream<Outgoing>.makeStream()
        outgoing = continuation
        running = Task.detached(priority: .userInitiated) { [weak self] in
            // A socket that opens after the limit is closed, not left open.
            let late = Locked(false)
            let opened: (any GatewayWordsSocket)? = await LiveWordsWait.first(within: openLimit, otherwise: { late.set(true); return nil }) {
                let socket = try? await link.open()
                guard !late.value else { socket?.close(); return nil }
                return socket
            }
            guard let self else { opened?.close(); return }
            guard let socket = opened else { return self.stopped(.didNotOpen) }
            let live = self.state.withLock { s -> Bool in
                guard !s.cancelled, s.stop == nil else { return false }
                s.socket = socket
                return true
            }
            guard live else { return socket.close() }
            await self.run(socket, stream)
        }
    }

    /// The sender and the reader, until the text is final or something stops them.
    private func run(_ socket: any GatewayWordsSocket, _ stream: AsyncStream<Outgoing>) async {
        let sending = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await socket.send(.text(GatewayWordsWire.startFrame()))
                for await piece in stream {
                    switch piece {
                    case .audio(let data): try await socket.send(.data(data))
                    case .end: try await socket.send(.text(GatewayWordsWire.endFrame))
                    }
                }
            } catch {
                // The reader says why: Hermes' error frame is often still on its way when a send fails (it answers
                // "no live STT" and closes at once). Only a socket that then says nothing is called dropped here.
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { self?.stopped(.dropped) }
            }
        }
        do {
            reading: while true {
                guard case .text(let text) = try await socket.receive() else { continue }
                switch GatewayWordsWire.parse(text) {
                case .partial(let words): heard(words)
                case .final(let words, let provider):
                    settled(words, provider: provider)
                    break reading
                case .error(let message):
                    stopped(.from(message: message))
                    break reading
                case .unknown: continue
                }
            }
        } catch {
            stopped(.dropped)
        }
        sending.cancel()
        socket.close()
    }

    private func heard(_ partial: String) {
        let text = state.withLock { s -> LiveWordsText? in
            guard s.stop == nil, !s.cancelled, s.final == nil else { return nil }
            let text = GatewayWordsWire.text(from: partial, after: s.lastPartial)
            s.lastPartial = partial
            return text
        }
        guard let text else { return }
        let onText = self.onText
        Task { @MainActor in onText(text) }
    }

    private func settled(_ words: String, provider: String) {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            guard s.stop == nil, !s.cancelled else { return nil }
            s.final = words
            s.provider = provider
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume()
    }

    /// Hermes stopped giving words: the take has none (the recording is transcribed after Stop), and the words shown
    /// so far go, since they are not what will be typed or sent.
    private func stopped(_ why: GatewayWordsStop) {
        let (first, ended, waiter, socket) = state.withLock { s -> (Bool, Bool, CheckedContinuation<Void, Never>?, (any GatewayWordsSocket)?) in
            guard s.stop == nil, !s.cancelled, s.final == nil else { return (false, false, nil, nil) }
            s.stop = why
            s.pending.removeAll()
            defer { s.waiter = nil }
            return (true, s.ended, s.waiter, s.socket)
        }
        guard first else { return }
        outgoing.finish()
        socket?.close()
        if why == .noLiveProvider { GatewayWordsMemory.noteRefusal(link.key) }
        VoiceEvents.noteLater("words from Hermes stopped: \(why.words)")
        AppLog.note("voice", "words from Hermes stopped: \(AppLog.scrub(why.words))")
        waiter?.resume()
        if !ended {
            let onText = self.onText
            Task { @MainActor in onText(LiveWordsText()) }
        }
    }

    // MARK: LiveWordsListening

    func feed(_ samples: UnsafeBufferPointer<Int16>) {
        guard !samples.isEmpty else { return }
        let chunk = state.withLock { s -> Data? in
            guard !s.ended, !s.cancelled, s.stop == nil else { return nil }
            s.pending.append(Data(buffer: samples))
            guard s.pending.count >= GatewayWordsWire.chunkBytes else { return nil }
            defer { s.pending = Data() }
            return s.pending
        }
        if let chunk { outgoing.yield(.audio(chunk)) }
    }

    func finish() async -> String {
        let (already, rest) = state.withLock { s -> (Bool, Data?) in
            defer { s.ended = true }
            guard !s.ended, !s.cancelled else { return (true, nil) }
            let rest = s.stop == nil && !s.pending.isEmpty ? s.pending : nil
            s.pending = Data()
            return (false, rest)
        }
        guard !already else { return state.withLock { $0.final ?? "" } }
        if let rest { outgoing.yield(.audio(rest)) }
        outgoing.yield(.end)
        outgoing.finish()
        // Hermes' final text, a stop, or the limit.
        let limit = Task.detached { [weak self, settleLimit] in
            try? await Task.sleep(for: .seconds(settleLimit))
            if !Task.isCancelled { self?.stopped(.slow) }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = state.withLock { s -> Bool in
                if s.final != nil || s.stop != nil || s.cancelled { return true }
                s.waiter = continuation
                return false
            }
            if resume { continuation.resume() }
        }
        limit.cancel()
        let (final, provider, stop) = state.withLock { ($0.final, $0.provider, $0.stop) }
        if let final {
            GatewayWordsMemory.note(.hermes(provider: provider))
            VoiceEvents.noteLater("words from Hermes settled")
            return final
        }
        // No words: the recording is transcribed after Stop.
        GatewayWordsMemory.note(.afterStop(stop ?? .dropped))
        return ""
    }

    func cancel() {
        let (waiter, socket) = state.withLock { s -> (CheckedContinuation<Void, Never>?, (any GatewayWordsSocket)?) in
            guard !s.cancelled else { return (nil, nil) }
            s.cancelled = true
            s.ended = true
            defer { s.waiter = nil }
            return (s.waiter, s.socket)
        }
        outgoing.finish()
        // A disconnect is the wire's cancel: Hermes throws the take away.
        socket?.close()
        waiter?.resume()
    }
}
