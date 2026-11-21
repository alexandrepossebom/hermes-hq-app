// Phone Calls (Beta) round 2: the pure pieces (no requests). Outcomes, the item-12 note, voicemail wording, the
// transcript reader, instructions and greeting, event rows, history, the result message, the call note, the
// proposal link and Check my setup. Numbers are 212 555 01xx stand-ins; the owner is "Alex".
import Foundation
import Testing
@testable import HermesHQNative

struct PhoneOutcomeTests {
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_000_000)
    nonisolated static func event(_ name: String, _ at: Double, result: String? = nil, cause: String? = nil) -> PhoneCallEvent {
        PhoneCallEvent(name: name, occurredAt: t0.addingTimeInterval(at), result: result, hangupCause: cause)
    }
    nonisolated static func answered(ring: Double = 4, talk: Double = 92, machine: Bool = false, cause: String = "normal_clearing") -> [PhoneCallEvent] {
        [event("call.initiated", 0), event("call.answered", ring),
         event("call.machine.premium.detection.ended", ring + 1, result: machine ? "machine" : "human"),
         event("call.hangup", ring + talk, cause: cause)]
    }
    nonisolated static func unanswered(_ cause: String) -> [PhoneCallEvent] { [event("call.initiated", 0), event("call.hangup", 30, cause: cause)] }

    @Test(arguments: [
        ("finished", answered(), [String](), PhoneOutcome.finished, "Finished · 1m 32s"),
        ("machine", answered(ring: 1, talk: 23, machine: true), [], .voicemail, "Went to voicemail · 23s"),
        ("wording", answered(ring: 6, talk: 23), ["Please leave a message after the tone."], .voicemail, "Went to voicemail · 23s"),
        ("no answer", unanswered("no_answer"), [], .noAnswer, "No answer"),
        ("timeout", unanswered("timeout"), [], .noAnswer, "No answer"),
        ("cancel", unanswered("originator_cancel"), [], .noAnswer, "No answer"),
        ("ring ran out", unanswered("normal_clearing"), [], .noAnswer, "No answer"),
        ("busy", unanswered("user_busy"), [], .busy, "Busy"),
        ("declined", unanswered("call_rejected"), [], .declined, "Declined"),
        ("unallocated", unanswered("unallocated_number"), [], .noSuchNumber, "Couldn't connect: that number doesn't exist"),
        ("format", unanswered("invalid_number_format"), [], .noSuchNumber, "Couldn't connect: that number doesn't exist"),
        ("out of order", unanswered("destination_out_of_order"), [], .couldNotConnect("the other phone is out of service"),
         "Couldn't connect: the other phone is out of service"),
        ("odd cause", unanswered("bearer_capability_not_available"), [], .couldNotConnect("bearer capability not available"),
         "Couldn't connect: bearer capability not available"),
    ] as [(String, [PhoneCallEvent], [String], PhoneOutcome, String)])
    func everyOutcomeFromTheLog(name: String, events: [PhoneCallEvent], said: [String], outcome: PhoneOutcome, title: String) {
        let verdict = PhoneVerdict.derive(events: events, status: nil, theirLines: said, ended: true, localEnd: nil, gaveUp: false)
        #expect(verdict.settled, "\(name)")
        #expect(verdict.outcome == outcome, "\(name)")
        #expect(phoneOutcomeTitle(outcome, duration: verdict.duration) == title, "\(name)")
    }

    @Test func notSettledUntilTheLogShowsTheHangup() {
        let early = [Self.event("call.initiated", 0), Self.event("call.answered", 3)]
        let live = PhoneVerdict.derive(events: early, status: nil, theirLines: [], ended: false, localEnd: nil, gaveUp: false)
        #expect(!live.settled && live.outcome == nil)
        #expect(live.answeredAt == Self.t0.addingTimeInterval(3))
        let over = PhoneVerdict.derive(events: early, status: nil, theirLines: [], ended: true, localEnd: .youHungUp, gaveUp: false)
        #expect(!over.settled, "\"Ended\" while the log catches up")
        let late = PhoneVerdict.derive(events: early, status: samplehostCallStatus(call_duration: 40), theirLines: [], ended: true,
                                       localEnd: .youHungUp, gaveUp: true)
        #expect(late.settled && late.outcome == .finished && late.duration == 40, "read long enough: what is known")
        let nothing = PhoneVerdict.derive(events: [], status: nil, theirLines: [], ended: true, localEnd: .youHungUp, gaveUp: true)
        #expect(nothing.outcome == .noAnswer, "you hung up before anyone picked up")
        let unknown = PhoneVerdict.derive(events: [], status: nil, theirLines: [], ended: true, localEnd: nil, gaveUp: true)
        #expect(unknown.outcome == .unknown)
        #expect(phoneOutcomeTitle(.unknown, duration: nil) == "Ended")
    }

    @Test func ringTimeIsAnsweredMinusInitiated() {
        let verdict = PhoneVerdict.derive(events: Self.answered(ring: 2.5).shuffled(), status: nil, theirLines: [], ended: true,
                                          localEnd: nil, gaveUp: false)
        #expect(verdict.ringSeconds == 2.5)
        #expect(verdict.duration == 92, "answered to hangup")
        let fromStatus = PhoneVerdict.derive(events: Self.answered(), status: samplehostCallStatus(call_duration: 95), theirLines: [],
                                             ended: true, localEnd: nil, gaveUp: false)
        #expect(fromStatus.duration == 95, "call_duration wins")
    }

    @Test func straightToVoicemailNote() {
        #expect(phoneStraightToVoicemailNote(voicemail: true, ringSeconds: 0.8)
                == "Voicemail picked up in 1 second, so the phone probably never rang. That is the other phone or its carrier (Do Not Disturb or a Focus, Silence Unknown Callers, a spam filter), not your samplehost setup.")
        #expect(phoneStraightToVoicemailNote(voicemail: true, ringSeconds: 2.4)?.hasPrefix("Voicemail picked up in 2 seconds,") == true)
        #expect(phoneStraightToVoicemailNote(voicemail: true, ringSeconds: 3) == nil, "under 3 seconds only")
        #expect(phoneStraightToVoicemailNote(voicemail: false, ringSeconds: 1) == nil)
        #expect(phoneStraightToVoicemailNote(voicemail: true, ringSeconds: nil) == nil)
    }

    @Test(arguments: ["Please record your message at the tone.", "You have reached the voicemail of 212 555 0142",
                      "Leave a message after the beep", "The person you are calling is not available", "I can’t take your call",
                      "The mailbox is full"])
    func voicemailWording(_ said: String) { #expect(phoneSoundsLikeVoicemail(said)) }

    @Test(arguments: ["Hello, dental office, how can I help?", "Sure, Tuesday works.", "Can you call back later?"])
    func notVoicemail(_ said: String) { #expect(!phoneSoundsLikeVoicemail(said)) }

    @Test func durationsAndStatusWords() {
        #expect(phoneDuration(23) == "23s")
        #expect(phoneDuration(92) == "1m 32s")
        #expect(phoneDuration(3720) == "1h 2m")
        #expect(phoneShown("+12125550142") == "+1 212 555 0142")
        #expect(phoneShown("+442079460958") == "+442079460958")
        var call = PhoneCallRecord(id: "c", sessionID: "s", to: "+12125550142", purpose: "p", placedAt: Self.t0, hangupCommandID: "h")
        #expect(call.statusText == "Ringing…")
        call.state = .live
        #expect(call.statusText == "On the call")
        call.voicemail = true
        #expect(call.statusText == "Voicemail answered")
        call.state = .ended
        #expect(call.statusText == "Ended")
        call.outcome = .voicemail; call.duration = 23
        #expect(call.statusText == "Went to voicemail · 23s")
    }

    @Test func eventRowsDecodeTheRealShape() throws {
        let json = """
        {"data":[{"record_type":"call_event","call_leg_id":"leg-1","call_session_id":"s-1","name":"call.hangup","type":"webhook",
          "occurred_at":"2026-11-21 12:36:49.554602","metadata":{},
          "payload":{"event_type":"call.hangup","payload":{"hangup_cause":"normal_clearing","hangup_source":"callee","sip_hangup_cause":"unspecified"}}},
         {"record_type":"call_event","name":"call.machine.premium.detection.ended","type":"webhook","occurred_at":"2026-11-21T12:36:41Z",
          "payload":{"event_type":"call.machine.premium.detection.ended","payload":{"result":"machine"}}},
         {"payload":{"event_type":"call.answered","payload":{}},"occurred_at":"2026-11-21 12:36:40"}]}
        """
        struct Rows: Decodable { let data: [PhoneCallEvent] }
        let rows = try JSONDecoder().decode(Rows.self, from: Data(json.utf8)).data
        #expect(rows.map(\.name) == ["call.hangup", "call.machine.premium.detection.ended", "call.answered"], "name, else event_type")
        #expect(rows[0].hangupCause == "normal_clearing" && rows[0].hangupSource == "callee")
        #expect(rows[1].result == "machine")
        let base = try #require(PhoneCallEvent.date("2026-11-21 12:36:40"))
        #expect(abs(try #require(rows[0].occurredAt).timeIntervalSince(base) - 9.554602) < 0.0001, "space, microseconds, UTC")
        #expect(rows[1].occurredAt == base.addingTimeInterval(1))
        #expect(PhoneCallEvent.date("2026-11-21 12:36:40.5+02:00") == base.addingTimeInterval(0.5 - 7200))
        #expect(PhoneCallEvent.date("yesterday") == nil)
        // The app's own saved copy reads back the same.
        let again = try JSONDecoder.phone.decode([PhoneCallEvent].self, from: JSONEncoder.phone.encode(rows))
        #expect(again.map(\.name) == rows.map(\.name))
        #expect(again.map(\.result) == rows.map(\.result) && again.map(\.hangupCause) == rows.map(\.hangupCause))
        for (a, b) in zip(again, rows) {   // seconds as a JSON number: exact to well under a millisecond
            #expect(abs((a.occurredAt ?? .distantPast).timeIntervalSince(b.occurredAt ?? .distantFuture)) < 0.001)
        }
    }
}

struct PhoneTranscriptReaderTests {
    static func ask(_ id: String, _ q: String) -> samplehostMessage {
        samplehostMessage(role: "assistant", text: nil, tool_calls: [.init(id: id, type: "function", function: .init(name: "ask_owner", arguments: #"{"question":"\#(q)"}"#))])
    }

    @Test func hidesReceiptsSilenceAndEmotionTagsAndShowsYouLines() {
        let read = PhoneTranscript.read([
            samplehostMessage(role: "assistant", text: #"<emotion value="happy"/> Hi there!"#),
            samplehostMessage(role: "user", text: "Hello? <emotion name=\"calm\">Who is this?</emotion>"),
            samplehostMessage(role: "user", text: "   "),
            Self.ask("a", "Which day?"),
            samplehostMessage(role: "tool", text: #"{"http_status":422,"error":"unreachable"}"#),
            samplehostMessage(role: "tool", text: #"{"data":{"result":"ok"}}"#),
            samplehostMessage(role: "system", text: "[long silence]"),
            samplehostMessage(role: "tool", text: PhoneAskOwner.toolAnswer("Friday", toolCallID: "a")),
            samplehostMessage(role: "system", text: "The owner answered your question \"Which day?\": Friday. Tell the person now, then continue."),
            samplehostMessage(role: "system", text: PhoneAskOwner.ownerMessagePrefix + "Ask for a window seat."),
        ], answered: [])
        #expect(read.lines.map(\.text) == ["Hi there!", "Hello? Who is this?", "Friday", "Ask for a window seat."])
        #expect(read.lines.map(\.speaker) == [.assistant, .them, .you, .you])
        #expect(read.question == nil)
        #expect(read.answers == ["a": "Friday"])
        #expect(read.asked.map(\.text) == ["Which day?"])
    }

    @Test func duplicatesShowOnceWithEveryOpenID() {
        let read = PhoneTranscript.read([Self.ask("a", "Is 3 OK?"), Self.ask("b", "Other?"), Self.ask("c", " is 3 ok? ")], answered: [])
        #expect(read.question?.id == "c")
        #expect(read.question?.ids == ["c", "a"], "the same words, any case")
        let oneAnswered = PhoneTranscript.read([Self.ask("a", "Is 3 OK?"), Self.ask("c", "Is 3 OK?")], answered: ["a"])
        #expect(oneAnswered.question?.ids == ["c"])
        // Our two tool messages for one answer read back as one You line.
        let back = PhoneTranscript.read([Self.ask("a", "Is 3 OK?"), Self.ask("c", "Is 3 OK?"),
                                         samplehostMessage(role: "tool", text: PhoneAskOwner.toolAnswer("Yes", toolCallID: "c")),
                                         samplehostMessage(role: "tool", text: PhoneAskOwner.toolAnswer("Yes", toolCallID: "a"))], answered: [])
        #expect(back.lines.map(\.text) == ["Yes"])
        #expect(back.question == nil)
    }
}

struct PhoneWordsTests {
    @Test func greeting() {
        #expect(PhoneAskOwner.greeting(ownerName: "Alex", recorded: false) == "Hi, this is an AI assistant calling on behalf of Alex.")
        #expect(PhoneAskOwner.greeting(ownerName: " Alex ", recorded: true) == "Hi, this is an AI assistant calling on behalf of Alex. This call is recorded.")
        #expect(PhoneAskOwner.greeting(ownerName: "", recorded: false) == "Hi, this is an AI assistant calling with a quick request.")
        #expect(PhoneAskOwner.greeting(ownerName: "  ", recorded: true) == "Hi, this is an AI assistant calling with a quick request. This call is recorded.")
    }

    @Test func instructionsPieces() {
        let text = PhoneAskOwner.instructions(purpose: "Move the cleaning to next week", ownerName: "Alex", recorded: true, voicemail: .hangUp)
        for piece in ["on behalf of Alex", "Alex is not on the call", "Why you are calling, in Alex's words: Move the cleaning to next week",
                      "Stay on the call until the goal is done", "Do not end the call just because it is taking long",
                      "call the ask_owner tool once", "its result is a receipt, never the answer",
                      "never call it twice for the same question", "starts with \"The owner answered\"",
                      "\"Message from the owner\"", "This call is recorded; say so if asked.",
                      "hang up right away without saying anything"] {
            #expect(text.contains(piece), "\(piece)")
        }
        #expect(!text.contains("60"), "no time allotment")
        #expect(!text.contains("—"), "no em dashes")
        let plain = PhoneAskOwner.instructions(purpose: "p", ownerName: "", recorded: false, voicemail: .leaveMessage)
        #expect(plain.contains("on behalf of the owner") && plain.contains("The owner is not on the call"))
        #expect(!plain.contains("recorded"))
        #expect(plain.contains("leave one short message saying who you are calling for and why, then hang up"))
        #expect(PhoneLimits.stayCopy == "The assistant stays on until the job is done. Safety stop at 30 minutes.")
        #expect(PhoneLocalEnd.safetyStop.note == "30-minute safety stop")
    }
}

struct PhoneHistoryTests {
    static func call(_ n: Int, lines: Int = 1) -> PhoneCallRecord {
        var c = PhoneCallRecord(id: "call-\(n)", sessionID: "s", to: "+12125550142", purpose: "p",
                                placedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + n)), hangupCommandID: "h")
        c.lines = (0..<lines).map { PhoneTranscript.Line(id: "\($0)", speaker: .them, text: "line \($0)") }
        c.events = [PhoneCallEvent(name: "call.hangup", occurredAt: Date(timeIntervalSince1970: 5), hangupCause: "user_busy")]
        c.outcome = .couldNotConnect("a reason"); c.settled = true; c.result = .sent; c.state = .ended
        c.answerCommandIDs = ["q": "transient"]
        return c
    }

    @Test func roundTripCapAndDelete() throws {
        let store = PhoneHistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "phone-pure-\(UUID().uuidString)"))
        defer { store.removeAll() }
        store.save([Self.call(1, lines: 2)], for: "acct-a")
        let back = store.load(for: "acct-a")
        var expected = Self.call(1, lines: 2)
        expected.answerCommandIDs = [:]   // in-flight state isn't saved
        #expect(back == [expected])
        #expect(store.load(for: "acct-b").isEmpty, "per account")
        store.save((1...60).map { Self.call($0, lines: $0 == 60 ? 320 : 1) }, for: "acct-a")
        let capped = store.load(for: "acct-a")
        #expect(capped.count == 50)
        #expect(capped.first?.id == "call-11", "the newest 50")
        #expect(capped.last?.lines.count == 300)
        #expect(capped.last?.lines.first?.text == "line 20", "the end of a long call is kept")
        #expect(store.file(for: "acct-a").lastPathComponent.count == 64 + 5, "sha256 hex + .json")
        store.delete(for: "acct-a")
        #expect(store.load(for: "acct-a").isEmpty)
    }
}

struct PhoneChatTextTests {
    static func ended(_ lines: [PhoneTranscript.Line]) -> PhoneCallRecord {
        var c = PhoneCallRecord(id: "c", sessionID: "s", to: "+12125550142", purpose: "Move my appointment",
                                placedAt: Date(timeIntervalSince1970: 0), hangupCommandID: "h")
        c.state = .ended; c.outcome = .finished; c.duration = 92; c.settled = true
        c.lines = lines
        c.asked = [PhoneQA(question: "Is Tuesday OK?", answer: "Yes"), PhoneQA(question: "Morning?", answer: nil)]
        return c
    }

    @Test func resultMessage() {
        let message = PhoneResultMessage(Self.ended([.init(id: "1", speaker: .assistant, text: "Hello"), .init(id: "2", speaker: .them, text: "Hi"),
                                                     .init(id: "3", speaker: .you, text: "Yes")]))
        #expect(message.display == "Call to +1 212 555 0142: finished, 1m 32s")
        #expect(message.text == """
        Phone call result (sent by Hermes HQ, not typed by the person)
        To: +12125550142
        Goal: Move my appointment
        Outcome: finished, 1m 32s
        Questions the assistant asked and the answers: \nIs Tuesday OK? → Yes
        Morning? → (not answered)
        Transcript:
        Assistant: Hello
        Them: Hi
        You: Yes
        """)
        #expect(PhoneResultMessage.bubble(forStored: message.text) == message.display, "after a relaunch too")
        #expect(PhoneResultMessage.bubble(forStored: "To: +1") == nil)
    }

    @Test func longTranscriptKeepsTheEndAndSaysItWasCut() {
        let lines = (0..<400).map { PhoneTranscript.Line(id: "\($0)", speaker: .them, text: "Line number \($0) of a long call.") }
        let text = PhoneResultMessage(Self.ended(lines)).text
        let transcript = String(text[text.range(of: "Transcript:\n")!.upperBound...])
        #expect(transcript.hasPrefix(PhoneResultMessage.cutMark + "\nThem: Line number"), "starts at a whole line")
        #expect(transcript.hasSuffix("Them: Line number 399 of a long call."))
        #expect(transcript.count <= PhoneResultMessage.transcriptLimit + PhoneResultMessage.cutMark.count + 1)
        #expect(!transcript.contains("Line number 0 of"))
    }

    @Test(arguments: [("Can you call the dentist?", true), ("CALLING them now", true), ("phone my mum", true), ("ring the shop", true),
                      ("dial it", true), ("check my voicemail", true), ("calls today", true), ("recall the plan", false),
                      ("the callback url", false), ("a phoneme", false), ("ringtone", false), ("hello", false)])
    func callNoteTrigger(typed: String, mentions: Bool) {
        #expect(PhoneChatNote.mentionsCalling(typed) == mentions, "\(typed)")
        #expect((PhoneChatNote.note(for: typed, ready: true, scheme: "hermeshq") != nil) == mentions, "\(typed)")
        #expect(PhoneChatNote.note(for: typed, ready: false, scheme: "hermeshq") == nil, "only when Phone Calls is ready")
    }

    @Test func callNoteTextAndStripping() throws {
        let note = PhoneChatNote.text(scheme: "hermeshq")
        #expect(note.hasPrefix("(Hermes HQ: this person can place AI phone calls from the app."))
        #expect(note.contains("[Call +12125550142](hermeshq://phone-call?to=%2B12125550142&goal=<URL-encoded goal in plain words>)"))
        #expect(note.hasSuffix("If you don't have the number, ask for it or look it up first.)"))
        let sent = "Call the dentist and move my appointment" + "\n\n" + note
        #expect(PhoneChatNote.stripped(sent, scheme: "hermeshq") == "Call the dentist and move my appointment")
        #expect(PhoneChatNote.stripped("Call the dentist", scheme: "hermeshq") == nil)
        #expect(PhoneChatNote.note(for: sent, ready: true, scheme: "hermeshq") == nil, "never twice")
        // The chat's stored rows: the bubble shows the words as typed, also inside a task's wrapped text.
        let scheme = AppIdentity.current.urlScheme
        let titles = SentTitles()
        #expect(titles.title(forStored: "Call the dentist\n\n" + PhoneChatNote.text(scheme: scheme)) == "Call the dentist")
        let messages = [ChatMessage(id: "u1", role: .user, parts: [.text("Phone the shop\n\n" + PhoneChatNote.text(scheme: scheme))], timestamp: Date(), rowId: nil),
                        ChatMessage(id: "u2", role: .user, parts: [.text("hello")], timestamp: Date(), rowId: nil)]
        #expect(titles.applied(to: messages).map(\.plainText) == ["Phone the shop", "hello"])
        let result = PhoneResultMessage(Self.ended([]))
        #expect(titles.title(forStored: result.text) == result.display)
    }
}

struct PhoneProposalTests {
    static let scheme = "hermeshq"
    static func url(_ s: String) -> URL { URL(string: s)! }

    @Test func parsesAValidProposal() throws {
        let p = try #require(PhoneProposal.parse(Self.url("hermeshq://phone-call?to=%2B12125550142&goal=Move%20my%20cleaning%20to%20Tuesday&utm=x"),
                                                 from: "+12125550100", scheme: Self.scheme))
        #expect(p == PhoneProposal(to: "+12125550142", goal: "Move my cleaning to Tuesday", voicemail: .hangUp), "unknown items ignored")
        let leave = PhoneProposal.parse(Self.url("hermes://phone-call?to=212%20555%200142&goal=Ask&voicemail=leave"), from: "+12125550100",
                                        scheme: Self.scheme)
        #expect(leave?.to == "+12125550142", "after phoneDestination")
        #expect(leave?.voicemail == .leaveMessage)
    }

    @Test(arguments: ["hermeshq://phone-call?goal=Ask", "hermeshq://phone-call?to=12345&goal=Ask", "hermeshq://phone-call?to=%2B12125550142",
                      "hermeshq://phone-call?to=%2B12125550142&goal=%20%20", "hermeshq://phone-call/extra?to=%2B12125550142&goal=Ask",
                      "hermeshq://user@phone-call?to=%2B12125550142&goal=Ask", "https://phone-call?to=%2B12125550142&goal=Ask",
                      "hermeshq://phone-calls?to=%2B12125550142&goal=Ask", "otherapp://phone-call?to=%2B12125550142&goal=Ask"])
    func refusesInvalid(_ link: String) {
        #expect(PhoneProposal.parse(Self.url(link), from: "+12125550100", scheme: Self.scheme) == nil, "\(link)")
    }

    @Test func voiceOverReadsTheDrawnWords() {
        let reply = "I can call them. [Call +12125550142](hermes://phone-call?to=%2B12125550142&goal=Ask%20for%20a%20table) or [bad](hermes://phone-call?to=1)"
        #expect(PhoneProposal.spoken(reply, scheme: Self.scheme)
                == "I can call them. Call +1 212 555 0142. Ask for a table or [bad](hermes://phone-call?to=1)", "invalid links stay")
        #expect(PhoneProposal.spoken("No links here.", scheme: Self.scheme) == "No links here.")
        #expect(SpokenMarkdown.plain(PhoneProposal.spoken(reply, scheme: Self.scheme)).hasSuffix("or bad"))
    }

    @Test func goalLength() {
        let long = String(repeating: "a", count: 500)
        #expect(PhoneProposal.parse(Self.url("hermeshq://phone-call?to=%2B12125550142&goal=" + long), scheme: Self.scheme)?.goal.count == 500)
        #expect(PhoneProposal.parse(Self.url("hermeshq://phone-call?to=%2B12125550142&goal=" + long + "a"), scheme: Self.scheme) == nil)
    }

    @Test func outsideTheAppIsAlwaysRefused() {
        #expect(PhoneProposal.refusesOutside(Self.url("hermeshq://phone-call?to=%2B12125550142&goal=Ask"), scheme: Self.scheme))
        #expect(PhoneProposal.refusesOutside(Self.url("HERMES://PHONE-CALL?to=x"), scheme: Self.scheme), "valid or not, any case")
        #expect(!PhoneProposal.refusesOutside(Self.url("hermeshq://new-chat?bot=otto"), scheme: Self.scheme), "other links untouched")
        #expect(!PhoneProposal.refusesOutside(Self.url("https://example.com/phone-call"), scheme: Self.scheme))
        // The app's own scheme, as AppDelegate.open checks it.
        #expect(PhoneProposal.refusesOutside(Self.url(AppIdentity.current.urlScheme + "://phone-call?to=%2B12125550142&goal=Ask")))
    }
}

struct PhoneSetupCheckTests {
    static let setup = PhoneSetup(apiKey: "KEYTEST", fromNumber: "+12125550100", connectionID: "conn-1", assistantID: "assistant-1")
    static let number = try! JSONDecoder().decode(samplehostNumber.self, from: Data(#"{"id":"1","phone_number":"+12125550100","status":"active","connection_id":"conn-1"}"#.utf8))
    static func good() -> PhoneSetupCheck.Reads {
        PhoneSetupCheck.Reads(
            numbers: .success([number]),
            app: .success(samplehostCallControlApp(active: true, application_name: "Calls", outbound: .init(outbound_voice_profile_id: "ovp-1"))),
            profile: .success(samplehostVoiceProfile(enabled: true, whitelisted_destinations: ["US", "CA"])),
            assistant: .success(samplehostAssistantDetail(json: ["id": "assistant-1", "name": "Otto", "model": "openai/gpt-4o",
                                                             "enabled_features": ["telephony"],
                                                             "telephony_settings": ["recording_settings": ["enabled": false]]])),
            balance: .success(samplehostBalance(balance: "12.50", currency: "USD")))
    }
    static func state(_ rows: [PhoneSetupCheck.Row], _ id: String) -> PhoneSetupCheck.State? { rows.first { $0.id == id }?.state }

    @Test func allGood() {
        let rows = PhoneSetupCheck.rows(setup: Self.setup, reads: Self.good())
        #expect(rows.map(\.id) == ["key", "number", "connection", "profile", "country", "assistant", "model", "recording", "balance"])
        #expect(rows.allSatisfy { $0.state == .pass }, "\(rows.filter { $0.state != .pass })")
        #expect(rows.first { $0.id == "balance" }?.sentence == "Your balance is $12.50.")
    }

    @Test func crossesSayWhatToDo() {
        var reads = Self.good()
        reads.app = .success(samplehostCallControlApp(active: false, outbound: .init(outbound_voice_profile_id: "ovp-1")))
        reads.profile = .success(samplehostVoiceProfile(enabled: false, whitelisted_destinations: ["GB"]))
        reads.assistant = .success(samplehostAssistantDetail(json: ["id": "assistant-1", "model": "openai/gpt-live-1", "enabled_features": [],
                                                                "telephony_settings": [:]]))
        reads.balance = .success(samplehostBalance(balance: "0.40", currency: "USD"))
        let rows = PhoneSetupCheck.rows(setup: Self.setup, reads: reads)
        for id in ["connection", "profile", "country", "assistant", "recording", "balance"] {
            #expect(Self.state(rows, id) == .fail, "\(id)")
            #expect(rows.first { $0.id == id }?.fix?.isEmpty == false, "\(id)")
        }
        #expect(Self.state(rows, "model") == .warn, "GPT Live warns")
        #expect(rows.first { $0.id == "recording" }?.sentence == "Recording is on on the assistant but off here.", "absent reads as samplehost's default: on")
        var other = Self.setup
        other.connectionID = "conn-2"
        #expect(Self.state(PhoneSetupCheck.rows(setup: other, reads: Self.good()), "number") == .fail, "not on the chosen connection")
        var noProfile = Self.good()
        noProfile.app = .success(samplehostCallControlApp(active: true, outbound: nil))
        noProfile.profile = nil
        #expect(Self.state(PhoneSetupCheck.rows(setup: Self.setup, reads: noProfile), "profile") == .fail)
    }

    @Test func aFailedReadIsCouldntCheckNotACross() {
        let reads = PhoneSetupCheck.Reads(numbers: .failure(.network), app: .failure(.unexpected(500)), profile: nil,
                                          assistant: .failure(.provider("busy")), balance: .failure(.network))
        let rows = PhoneSetupCheck.rows(setup: Self.setup, reads: reads)
        #expect(!rows.contains { $0.state == .fail }, "\(rows.filter { $0.state == .fail })")
        #expect(rows.filter { $0.state == .unknown }.count == rows.count)
        #expect(rows.allSatisfy { $0.sentence.hasSuffix(PhoneSetupCheck.couldNotCheck) })
        let bad = PhoneSetupCheck.rows(setup: Self.setup, reads: .init(numbers: .failure(.badKey)))
        #expect(Self.state(bad, "key") == .fail, "a refused key is a real answer")
        let missing = PhoneSetupCheck.rows(setup: Self.setup, reads: .init(numbers: .success([Self.number]), app: .failure(.unexpected(404)),
                                                                           assistant: .failure(.unexpected(404))))
        #expect(Self.state(missing, "connection") == .fail && Self.state(missing, "assistant") == .fail, "a 404 is an answer")
    }
}
