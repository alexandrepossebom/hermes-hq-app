import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A chat's short name when the gateway left only its opening words. Prefer a model's summary; without one, retain
/// a readable opening phrase rather than stitching keywords together. Works without a remote naming service.
nonisolated enum ShortTitle {
    /// Names that mean "no title yet".
    static let genericTitles: Set<String> = ["", "new chat", "untitled", "untitled chat", "new session", "new conversation", "chat"]
    /// Session names have no length budget: a gateway's or a model's name is kept whole, and the screen truncates
    /// it to fit. Only the provisional opening-words excerpt is bounded, so a long first message is never stored as a
    /// name, and an opening used whole past this length still counts as provisional.
    static let excerptCharacters = 40

    /// Whether an opening contains something worth naming. Only suppress complete, standalone social exchanges;
    /// a greeting followed by a request must remain eligible. Unknown wording defaults to a naming request.
    /// What a chat is named from: a voice memo's words (its transcript and anything typed with it), not its
    /// `MEDIA:"<path>"` line; empty when the memo has no transcript yet. Any other message as it is.
    static func namingText(_ message: String) -> String {
        // A picture's or file's ref line (`@image:/…`) is never a name; the words around it are.
        guard let memo = VoiceMemo.parse(message) else { return AttachmentHydration.liftText(message).text }
        let said = memo.hasTranscript && memo.transcriptText != VoiceMemo.noSpeech ? memo.transcriptText : ""
        return [said, memo.rest].filter { !ChatText.trimmed($0).isEmpty }
            .joined(separator: "\n\n")
    }

    static func isNamingRequest(_ text: String) -> Bool {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let tokens = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
        let phrase = words(tokens).joined(separator: " ")
        guard !phrase.isEmpty else { return false }
        let greeting = #"(?:hi|hello|hey|hiya|howdy|good morning|good afternoon|good evening)(?: there)?"#
        let social = #"(?:are you there|are you available|how are you|how are you doing|what s up|(?:can|could|would) you (?:please )?help(?: me)?|i need (?:some )?help|i have a question|quick question)"#
        let courtesy = #"(?:thanks|thank you|thank you very much|bye|goodbye|good night)"#
        let pattern = "^(?:\(greeting)(?: \(social))?|\(social)|\(courtesy))$"
        return phrase.range(of: pattern, options: .regularExpression) == nil
    }

    private static let attachmentLinePrefixes = ["[The user attached", "[Image attached", "[Examine it with", "@image:", "@file:", "@folder:"]

    /// A name that is a file's line and no words at all: a voice memo's `MEDIA:"/Users/…` path, or the gateway's
    /// wrapper around a picture or file. Never shown or stored as a chat's name.
    static func isFileLine(_ title: String) -> Bool {
        let cleaned = cleanName(title)
        return cleaned.hasPrefix("MEDIA:") || attachmentLinePrefixes.contains(where: { cleaned.hasPrefix($0) })
    }

    /// Empty/generic names and visibly cut or overlong opening excerpts are provisional. A fitting, unmarked
    /// phrase can be a real name even when it shares the message's opening words; do not replace it on that guess.
    static func isPlaceholder(_ title: String, firstMessage: String) -> Bool {
        let cleaned = cleanName(title)
        // A voice memo's opening line used as a name (`MEDIA:"/Users/…`): its file path, never a name.
        if cleaned.hasPrefix("MEDIA:") { return true }
        // The gateway's own attachment wrapper (`[The user attached an image: …]`, `[Image attached at: …]`,
        // `@image:`), which it can slice into an instant name when the message opens with a picture.
        if attachmentLinePrefixes.contains(where: { cleaned.hasPrefix($0) }) { return true }
        let shown = normalized(cleaned)
        if genericTitles.contains(shown) { return true }
        let cut = cutMarker(in: cleaned) != nil
        let message = normalized(cleanName(firstMessage))
        // A marked excerpt must stay provisional while the opening page has not loaded yet.
        if message.isEmpty { return cut }
        // A gateway excerpt can stop before its opening quotation is closed.
        guard message.hasPrefix(shown) || normalized(firstMessage).hasPrefix(normalized(title)) else { return false }
        return cut || words(cleaned).joined(separator: " ").count > excerptCharacters
    }

    /// A naming model: the opening message and, when there is one, a longer composed title to restate. Nil when
    /// unavailable. `onDevice` in the app; tests supply their own.
    typealias Model = @Sendable (_ message: String, _ longTitle: String?) async -> String?

    /// Only a usable model name, never the opening fallback: nil when the model is unavailable or its answer isn't
    /// a name. `longTitle` is a composed name too long for the header, given so the model can restate it.
    static func modelName(for message: String, longTitle: String? = nil, using model: Model = onDevice) async -> String? {
        let text = String(ChatText.trimmed(message).prefix(1000))
        guard let made = await model(text, longTitle) else { return nil }
        return accepted(made, message: text).map { restoringCase($0, from: text) }
    }

    /// The on-device model answers in lowercase ("ios app crash"). Give an all-lowercase word the message's spelling
    /// where it has one ("iOS", "CV", ".NET", "Wi-Fi"; a capital that only starts a sentence doesn't count, and a
    /// shouted message lends none: it has no lowercase letters across three or more words, or most of its words over
    /// four letters are all caps, so short acronyms like "AWS IAM" don't count. A shouted message's acronyms are
    /// lost too ("FIX MY CV NOW" gives "Cv fix"); its case says nothing), then start the name with a capital when its
    /// first word is still all lowercase. A word the model already cased is kept. Only for model names: a gateway's
    /// name keeps its own case. Word matching can't tell "us" from "US"; that clash is accepted.
    static func restoringCase(_ name: String, from message: String) -> String {
        var spelled: [String: String] = [:]
        var sentenceStart = true
        let long = words(message).map(bare).filter { $0.filter(\.isLetter).count > 4 }
        let allCaps = words(message).count >= 3 && !message.contains(where: \.isLowercase)
        let shouted = allCaps || !long.isEmpty && long.filter { $0 == $0.uppercased() }.count * 2 > long.count
        for word in shouted ? [] : words(message) {
            let core = bare(word)
            let onlyStartsSentence = sentenceStart && core == core.prefix(1).uppercased() + core.dropFirst().lowercased()
            if !core.isEmpty, core != core.lowercased(), !onlyStartsSentence, spelled[core.lowercased()] == nil {
                spelled[core.lowercased()] = core
            }
            sentenceStart = word.last.map { ".!?".contains($0) } ?? false
        }
        var out = words(name).map { word -> String in
            let core = bare(word)
            guard core == core.lowercased(), let spelling = spelled[core], let range = word.range(of: core) else { return word }
            return word.replacingCharacters(in: range, with: spelling)
        }
        if let first = out.first, first == first.lowercased(), let letter = first.first, letter.isLetter,
           String(letter).uppercased().count == 1 {
            out[0] = String(letter).uppercased() + first.dropFirst()
        }
        return out.joined(separator: " ")
    }

    /// More words than this is an answer, not a name: the gateway's own title generator rejects the same shape.
    static let maxModelWords = 12

    /// A clean, single-line, non-placeholder model name. No character budget; only an answer-shaped reply is refused.
    static func accepted(_ raw: String, message: String) -> String? {
        let cleaned = cleanName(raw)
        guard cutMarker(in: cleaned) == nil, !cleaned.contains(where: \.isNewline) else { return nil }
        let title = words(cleaned).joined(separator: " ")
        guard !title.isEmpty, words(cleaned).count <= maxModelWords,
              !isPlaceholder(raw, firstMessage: message) else { return nil }
        return title
    }

    /// A gateway has already composed this name. Keep its wording whole, at any length; a name the gateway itself
    /// cut keeps one visible ellipsis. This is the stored name.
    static func compact(_ raw: String) -> String {
        let cleaned = cleanName(raw)
        if let marker = cutMarker(in: cleaned) {
            let body = String(cleaned[..<marker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? "New Chat" : words(body).joined(separator: " ") + "…"
        }
        let whole = words(cleaned).joined(separator: " ")
        return whole.isEmpty ? "New Chat" : whole
    }

    private static func cutMarker(in name: String) -> Range<String.Index>? {
        name.range(of: #"(?:…|\.{3})[\s\"'“”‘’`*.。!?:;,]*$"#, options: .regularExpression)
    }

    private static func cleanName(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: [Character: Character] = ["\"": "\"", "'": "'", "“": "”", "‘": "’", "`": "`", "*": "*"]
        // Remove formatting, not spelling: iOS, .NET, Yahoo! and *.swift keep their case and symbols.
        // Paired wrappers can have sentence punctuation outside them, including a period after a quote.
        while true {
            if title.lowercased().hasPrefix("title:") {
                title = String(title.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard let first = title.first, let closing = wrappers[first] else { break }
            var candidate = title
            while let last = candidate.last, ".,。!?:;".contains(last) {
                candidate.removeLast()
                candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard candidate.count > 1, candidate.last == closing else { break }
            title = String(candidate.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
    }

    // MARK: Whole phrases (no model)

    /// A fitting opening remains whole. Without a naming model, use a readable excerpt, visibly marked as an
    /// unfinished name. Keeping the opening intact also lets isPlaceholder recognize it when a better name arrives.
    /// Do not depend on lexical tagging here: some supported environments return only OtherWord tags.
    static func fallback(for message: String) -> String {
        // Flatten the whole opening, not just its first line: otherwise a short first line hides a cut.
        boundedPhrase(message)
    }

    /// Bound at word boundaries, keeping case, internal grammar and punctuation. Only a token
    /// that cannot fit by itself is cut on Character boundaries (also covers writing systems without spaces).
    private static func boundedPhrase(_ text: String) -> String {
        let all = words(cleanName(text))
        let whole = all.joined(separator: " ")
        if whole.count <= excerptCharacters { return whole.isEmpty ? "New Chat" : whole }
        let limit = excerptCharacters - 1
        var picked: [String] = []
        for word in all {
            let next = (picked + [word]).joined(separator: " ")
            if next.count > limit {
                if picked.isEmpty { picked.append(String(word.prefix(limit))) }
                break
            }
            picked.append(word)
        }
        let title = picked.joined(separator: " ")
        return title.isEmpty ? "New Chat" : title + "…"
    }

    // MARK: On-device model

    static let instructions = """
        Create a short, specific chat title naming the user's request or intent, not its answer or outcome. \
        Ignore greetings and conversational filler when the message also contains a request. Describe what the user \
        wants, including the action and subject where useful; do not carry out the request, invent context, or reply to it. \
        Return only one concise, natural phrase in sentence case and in the message's language, not a list of keywords. \
        Preserve names, acronyms, product spelling and numbers. No added quotes or sentence punctuation.
        """

    #if canImport(FoundationModels)
    /// Guided generation: the model fills a title field instead of writing free text, so a chatty answer
    /// ("Sure, I can help!") is not what comes back as the name.
    @Generable nonisolated struct GeneratedTitle {
        @Guide(description: "The chat's title only. Never a reply, greeting or answer to the user.")
        var title: String
    }
    #endif

    static func onDevice(_ message: String, longTitle: String?) async -> String? {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 48)
        var prompt = "Opening message:\n\(message)"
        if let longTitle {
            prompt += "\n\nThis title was cut off. Write a complete title that says the same thing:\n\(longTitle)"
        }
        return try? await session.respond(to: prompt, generating: GeneratedTitle.self, options: options).content.title
        #else
        return nil
        #endif
    }

    // MARK: Text helpers

    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        var s = words(folded).joined(separator: " ")
        while let last = s.last, "….,;:!?-—".contains(last) || last == " " { s.removeLast() }
        return s
    }

    static func words(_ text: String) -> [String] { text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    /// A word without the punctuation around it ("Wi-Fi." → "Wi-Fi", ".NET" → "NET"); inner marks stay.
    static func bare(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "#+")))
    }

}
