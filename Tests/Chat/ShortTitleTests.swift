import Testing
@testable import HermesHQNative

@Suite struct ShortTitleTests {
    let hue = "I just added another Philips hue ceiling light in the bonus/play room. Set it up."

    @Test func namingRequestsExcludeOnlyStandaloneGreetingsAndCourtesies() {
        for text in ["", "  \n", "!!!", "Hi", "HELLO there!!!", "Hey, are you there?",
                     "Hi, how are you?", "Can you help?", "Hey, could you help me?", "Good morning!", "Thanks!", "Thank you."] {
            #expect(!ShortTitle.isNamingRequest(text), "Unexpected request: \(text)")
        }
        for text in ["Hi, can you help me debug my iOS app?", "Hello! Plan a trip to Tokyo",
                     "Hey\nWhat is 2+2?", "How are you handling errors in Swift?",
                     "Hi there, what is the weather?", "Summarize this", "你好，请帮我写代码", "2+2?"] {
            #expect(ShortTitle.isNamingRequest(text), "Missed request: \(text)")
        }
    }

    @Test func openingWordsArePlaceholders() {
        #expect(ShortTitle.isPlaceholder("I just added another…", firstMessage: hue))
        #expect(ShortTitle.isPlaceholder("I just added another Philips hue ceiling light in", firstMessage: hue))
        #expect(ShortTitle.isPlaceholder(hue, firstMessage: hue))                       // a long message used whole
        #expect(ShortTitle.isPlaceholder("New Chat", firstMessage: hue))
        #expect(ShortTitle.isPlaceholder("", firstMessage: ""))
    }

    @Test func realNamesAreKept() {
        #expect(!ShortTitle.isPlaceholder("Set up bonus room Hue light", firstMessage: hue))
        #expect(!ShortTitle.isPlaceholder("Weather in Austin", firstMessage: "Weather in Austin"))   // short, used whole
        #expect(!ShortTitle.isPlaceholder("Bot Chat", firstMessage: hue))
    }

    @Test func offlineExcerptKeepsWordOrder() {
        #expect(ShortTitle.fallback(for: hue) == "I just added another Philips hue…")
        #expect(ShortTitle.fallback(for: "Can you please check why the Postgres pool keeps running out?")
                == "Can you please check why the Postgres…")
        #expect(ShortTitle.fallback(for: "hi there!") == "hi there!")
        let long = ShortTitle.fallback(for: "Refactor HermesKit/Chat/LiveChatSession+Events.swift onComplete settlement")
        #expect(long.count <= ShortTitle.excerptCharacters)
    }

    @Test func modelAnswersMustLookLikeNames() {
        #expect(ShortTitle.accepted("\"Hue light setup\".", message: hue) == "Hue light setup")
        #expect(ShortTitle.accepted("Title: hue ceiling light", message: hue) == "hue ceiling light")
        #expect(ShortTitle.accepted("Sure! I'll set up the new Philips Hue ceiling light in your bonus room right away for you.",
                                    message: hue) == nil)                                                    // a reply
        #expect(ShortTitle.accepted("I just added…", message: hue) == nil)                                 // marked excerpt
        #expect(ShortTitle.accepted("", message: hue) == nil)
    }

    @Test func aVoiceMemoIsNamedFromItsWordsNotItsPath() {
        let memo = MemoText.reference(path: "/Users/me/.hermes/attachments/voice-memo-72.m4a", said: .text("Plan the Lisbon trip with the kids in March"))
        #expect(ShortTitle.namingText(memo) == "Plan the Lisbon trip with the kids in March")
        #expect(ShortTitle.isNamingRequest(ShortTitle.namingText(memo)))
        #expect(ShortTitle.fallback(for: ShortTitle.namingText(memo)) == "Plan the Lisbon trip with the kids in…")
        #expect(ShortTitle.namingText(MemoText.reference(path: "/tmp/voice-memo.m4a", said: .empty)).isEmpty)
        #expect(ShortTitle.namingText(MemoText.reference(path: "/tmp/voice-memo.m4a", said: .off)).isEmpty)
        #expect(ShortTitle.namingText("Just a typed message") == "Just a typed message")
        // A name that is the memo's path line is a placeholder, even against the transcript.
        #expect(ShortTitle.isPlaceholder("MEDIA:\"/Users/studi…", firstMessage: "Plan the Lisbon trip"))
        #expect(ShortTitle.isPlaceholder("MEDIA:\"/Users/me/.hermes/profiles/…", firstMessage: ""))
    }

    /// The gateway sliced its model-only image wrapper into the instant name (hermes-hq 20261118_085950,
    /// "[The user attached…" for "Fix this top bar…"); that name is provisional, so the app's own replaces it.
    @Test func anAttachmentWrapperNameIsAPlaceholder() {
        let first = "Fix this top bar. It shouldn’t take on ALL of the color like that."
        #expect(ShortTitle.isPlaceholder("[The user attached…", firstMessage: first))
        #expect(ShortTitle.isPlaceholder("[The user attached an image: clipboard.jpg]", firstMessage: first))
        #expect(ShortTitle.isPlaceholder("[Image attached at: /tmp/a.png]", firstMessage: first))
        #expect(ShortTitle.isPlaceholder("@image:/Users/me/a.jpg", firstMessage: ""))
        #expect(!ShortTitle.isPlaceholder("Top bar color fix", firstMessage: first))
        // The stored row: words, then the picture's ref line; only the words name the chat.
        let stored = first + "\n@image:/Users/me/.dispatch-attachments/63982030/clipboard.jpg"
        #expect(ChatText.trimmed(ShortTitle.namingText(stored)) == first)
    }
}
