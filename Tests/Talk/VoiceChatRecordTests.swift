// A live voice chat's words are kept with the chat (`VoiceChatRecord`): the message a finished conversation sends, how
// the chat reads it back, its row, and the controller sending it.

import Foundation
import Testing
@testable import HermesHQNative

struct VoiceChatRecordTests {
    private func fragment(_ user: Bool, _ text: String) -> LiveTranscriptFragment {
        LiveTranscriptFragment(speaker: user ? .user : .assistant, text: text, startMs: 0, endMs: 0)
    }

    private func turns(_ pieces: [(Bool, String)]) -> [VoiceChatRecord.Turn] {
        var out: [VoiceChatRecord.Turn] = []
        for piece in pieces { VoiceChatRecord.add(fragment(piece.0, piece.1), to: &out) }
        return out
    }

    @Test func piecesOfOneSpeakerAreOneTurn() {
        let said = turns([(false, "Hi "), (false, "there."), (true, "What's on "), (true, "my calendar?"), (false, "Two things.")])
        #expect(said.count == 3)
        #expect(VoiceChatRecord.settled(said).map(\.text) == ["Hi there.", "What's on my calendar?", "Two things."])
    }

    @Test func theMessageOpensWithItsMarkAndReadsBack() throws {
        let said = turns([(false, "Hi there."), (true, "What's on my calendar?"), (false, "Two things: lunch at noon and a call at three.")])
        let message = try #require(VoiceChatRecord.message(said, seconds: 252))
        #expect(message.hasPrefix("[Voice chat transcript · 4:12]\n(From the app"))
        #expect(message.contains("reply with exactly NO_REPLY"))
        #expect(message.contains("\nUser: What's on my calendar?\nVoice assistant: Two things"))
        let found = try #require(VoiceChatRecord.parse(message))
        #expect(found.title == "Voice Chat · 4:12")
        #expect(found.words == "Voice: Hi there.\n\nYou: What's on my calendar?\n\nVoice: Two things: lunch at noon and a call at three.")
        #expect(!found.words.contains("From the app"))
        #expect(VoiceChatRecord.isRecord(message))
    }

    @Test func nothingIsSentWhenThePersonSaidNothingOrOnlyStop() {
        #expect(VoiceChatRecord.message([], seconds: 10) == nil)
        #expect(VoiceChatRecord.message(turns([(false, "Hello, I'm here.")]), seconds: 10) == nil)
        #expect(VoiceChatRecord.message(turns([(false, "Hello."), (true, " Stop. ")]), seconds: 10) == nil)
        #expect(VoiceChatRecord.message(turns([(true, "   ")]), seconds: 10) == nil)
    }

    @Test func aLongConversationKeepsItsNewestPart() throws {
        var pieces: [(Bool, String)] = []
        for i in 0..<400 { pieces.append((i % 2 == 0, "Turn number \(i) " + String(repeating: "word ", count: 30))) }
        let message = try #require(VoiceChatRecord.message(turns(pieces), seconds: 3_700))
        #expect(message.count < VoiceChatRecord.maxChars + 1_000)
        #expect(message.contains(VoiceChatRecord.cutNote))
        #expect(message.contains("Turn number 399"))
        #expect(!message.contains("Turn number 0 "))
        #expect(VoiceChatRecord.parse(message)?.title == "Voice Chat · 1:01:40")
    }

    @Test func ordinaryMessagesAreNotRecords() {
        #expect(VoiceChatRecord.parse("What did we say in the voice chat?") == nil)
        #expect(VoiceChatRecord.parse("[Voice chat transcript and more words") == nil)
        #expect(!VoiceChatRecord.isRecord("[Voice chat transcripts are great]"))
    }

    /// The next voice chat is told what was said, not the note written for the bot.
    @Test func theNextVoiceChatHearsTheWordsOnly() throws {
        let message = try #require(VoiceChatRecord.message(turns([(true, "Book the dentist for Friday."), (false, "Done.")]), seconds: 65))
        let record = ChatMessage(id: "m1", role: .user, parts: [.text(message)], timestamp: nil, rowId: nil)
        let typed = ChatMessage(id: "m2", role: .user, parts: [.text("And the vet?")], timestamp: nil, rowId: nil)
        let seed = LiveChatSession.spokenTurns([record, typed])
        #expect(seed.count == 2)
        #expect(seed[0].text == "(Said in an earlier voice chat) You: Book the dentist for Friday.\n\nVoice: Done.")
        #expect(!seed[0].text.contains("NO_REPLY"))
        #expect(seed[1].text == "And the vet?")
    }

    /// The chat draws the record as one line that opens on the words, never as your bubble.
    @Test func theChatShowsOneLine() throws {
        let message = try #require(VoiceChatRecord.message(turns([(true, "Book the dentist for Friday."), (false, "Done, Friday at ten.")]), seconds: 65))
        var m = ChatMessage(id: "m1", role: .user, parts: [.text(message)], timestamp: Date(timeIntervalSince1970: 1_791_600_000), rowId: nil)
        m.isPending = false
        let closed = ChatRowBuilder.build(.init(messages: [m], isRunning: false, botName: "Ivy", expanded: []))
        let lines = closed.compactMap { row -> BackgroundResultRow? in
            if case .backgroundResult(let b) = row.kind { return b } else { return nil }
        }
        #expect(lines.count == 1)
        #expect(lines.first?.title == "Voice Chat · 1:05")
        #expect(lines.first?.voice == true && lines.first?.glyph == .voice)
        #expect(lines.first?.result == "You: Book the dentist for Friday.\n\nVoice: Done, Friday at ten.")
        #expect(!closed.contains { $0.isBubble })
        let open = ChatRowBuilder.build(.init(messages: [m], isRunning: false, botName: "Ivy", expanded: ["m1|vc"]))
        #expect(open.contains { if case .backgroundResult(let b) = $0.kind { return b.expanded } else { return false } })
    }
}

@Suite("Voice record controller", .serialized)
@MainActor
struct VoiceChatRecordControllerTests {
    @MainActor final class Box { var transport: FixtureLiveVoice? }

    private func make() -> (TalkController, Box) {
        AudioSessionCoordinator.shared.reset()
        KeepAwake.reset()
        TalkController.chosenEngine = nil
        FixtureLiveVoice.failWith = nil
        FixtureLiveVoice.sent = []
        FixtureLiveVoice.exchanged = []
        FixtureLiveVoice.script = [(0.05, #"{"type":"session.started","session":{"id":"sess_test"}}"#)]
        let talk = TalkController()
        let box = Box()
        var config = TalkConfig()
        config.chatMode = .gptLive
        talk.makeCapture = { FixtureTalkCapture(clock: $0) }
        talk.speaker = FakeSpeaker()
        talk.loadConfig = { _ in config }
        talk.transcribe = { _, _ in .success("") }
        talk.loadLiveStatus = { _ in LiveVoiceStatus(mode: .gptLive, available: true) }
        talk.makeLiveTransport = {
            let transport = FixtureLiveVoice()
            box.transport = transport
            return transport
        }
        talk.exchangeLive = { _, _, _ in "v=0\r\nanswer" }
        talk.holdsLeases = false
        talk.isOnScreen = { true }
        talk.speaksReplies = { true }
        talk.helloPrompt = { nil }
        talk.rememberHello = { _ in }
        return (talk, box)
    }

    /// Ending a live conversation sends everything said, both speakers, once.
    @Test func endingSendsWhatWasSaid() async throws {
        let (talk, box) = make()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        let transport = try #require(box.transport)
        transport.play(#"{"type":"session.output_transcript.delta","delta":"Hi, what can I do?","start_ms":0,"end_ms":800}"#)
        transport.play(#"{"type":"session.input_transcript.delta","delta":"Tell me a joke","start_ms":900,"end_ms":1800}"#)
        transport.play(#"{"type":"session.output_transcript.delta","delta":"Why did the otter cross the river?","start_ms":1900,"end_ms":2900}"#)
        #expect(await waitUntil { talk.live?.record.count == 3 })
        talk.end()
        #expect(await waitUntil { !talk.isLive })
        #expect(chat.records.count == 1)
        let found = try #require(VoiceChatRecord.parse(chat.records[0]))
        #expect(found.words == "Voice: Hi, what can I do?\n\nYou: Tell me a joke\n\nVoice: Why did the otter cross the river?")
        await talk.resetForTests()
    }

    /// A conversation in which the person said nothing leaves nothing in the chat.
    @Test func aSilentConversationSendsNothing() async throws {
        let (talk, box) = make()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        let transport = try #require(box.transport)
        transport.play(#"{"type":"session.output_transcript.delta","delta":"Hello, I'm here.","start_ms":0,"end_ms":800}"#)
        #expect(await waitUntil { talk.live?.record.count == 1 })
        talk.end()
        #expect(await waitUntil { !talk.isLive })
        #expect(chat.records.isEmpty)
        await talk.resetForTests()
    }

    /// A chat that went away is sent nothing.
    @Test func aChatThatWentAwayIsSentNothing() async throws {
        let (talk, box) = make()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        let transport = try #require(box.transport)
        transport.play(#"{"type":"session.input_transcript.delta","delta":"Remind me about the launch","start_ms":0,"end_ms":900}"#)
        #expect(await waitUntil { talk.live?.record.count == 1 })
        talk.chatGone(chat)
        #expect(await waitUntil { !talk.isLive })
        #expect(chat.records.isEmpty)
        await talk.resetForTests()
    }
}
