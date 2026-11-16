import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A chat's short name when the gateway left only its opening words (owner 2026-11-07: "I just added another…" on the
/// iPhone bar). Hermes names a chat twice: the first words of the opening message at once, then a model's 3–7 word title.
/// That second step can fail (no usable key for the title model, an older gateway, a gateway without it), so the app
/// makes its own after the first reply: Apple's on-device model where the device has one, else a word rule. Works with
/// any gateway.
nonisolated enum ShortTitle {
    /// Names that mean "no title yet".
    static let genericTitles: Set<String> = ["", "new chat", "untitled", "untitled chat", "new session", "new conversation", "chat"]
    /// Longest name the app writes: about what the iPhone bar shows beside its back and ⋯ buttons.
    static let maxWords = 3
    static let maxCharacters = 20

    /// True when `title` is no real name: empty or generic, or the opening message's own first words (the gateway's
    /// instant title, cut with "…", or a long message used whole).
    static func isPlaceholder(_ title: String, firstMessage: String) -> Bool {
        let shown = normalized(title)
        if genericTitles.contains(shown) { return true }
        let message = normalized(firstMessage)
        guard !message.isEmpty, message.hasPrefix(shown) else { return false }
        let cut = title.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("…") || title.hasSuffix("...")
        return cut || message.count > shown.count || words(shown).count > maxWords || shown.count > maxCharacters
    }

    /// A short title for `message`: the on-device model's when it gives a usable one, else `fallback(for:)`.
    static func make(from message: String) async -> String {
        let text = String(ChatText.trimmed(message).prefix(1000))
        if let made = await onDevice(text), let usable = accepted(made, message: text) { return usable }
        return fallback(for: text)
    }

    /// The model's answer when it reads as a name: a few words, not the message's own opening, not a reply.
    static func accepted(_ raw: String, message: String) -> String? {
        let cleaned = cleanName(raw)
        guard !cleaned.contains(where: \.isNewline) else { return nil }
        let title = capitalizedFirst(words(cleaned).joined(separator: " "))
        guard !title.isEmpty, words(title).count <= maxWords, title.count <= maxCharacters,
              !isPlaceholder(title, firstMessage: message) else { return nil }
        return title
    }

    /// Gateway names use the same budget as local ones. Keep an already-short name intact; otherwise drop filler
    /// and keep whole topic words. This is the stored name, not a display-only ellipsis.
    static func compact(_ raw: String) -> String {
        accepted(raw, message: "") ?? fallback(for: cleanName(raw))
    }

    private static func cleanName(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)) }
        return title.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’`*.。!?:;\n"))
    }

    // MARK: Word rule (no model)

    /// Words that carry no topic: pronouns, helpers, politeness, articles, prepositions.
    static let filler: Set<String> = [
        "i", "i'm", "im", "i've", "ive", "i'd", "id", "i'll", "me", "my", "mine", "we", "we're", "our", "us", "you", "your",
        "it", "its", "it's", "this", "that", "these", "those", "there", "here", "they", "them", "he", "she", "his", "her",
        "a", "an", "the", "some", "any", "another", "other", "just", "also", "really", "actually", "basically", "now",
        "please", "pls", "plz", "thanks", "thank", "hey", "hi", "hello", "ok", "okay", "so", "well", "um", "uh",
        "can", "could", "would", "will", "should", "shall", "may", "might", "must", "do", "does", "did", "is", "are",
        "was", "were", "be", "been", "am", "have", "has", "had", "want", "wanted", "need", "needed", "like", "help",
        "let's", "lets", "let", "go", "ahead", "try", "to", "of", "in", "on", "at", "for", "with", "from", "by", "into",
        "about", "and", "or", "but", "if", "then", "than", "as", "up", "out", "what", "how", "why", "when", "where",
        "which", "who", "whether", "get", "got", "make", "sure", "know", "think", "one", "new",
    ]

    /// The message's topic words, filler dropped, at most `maxWords` and `maxCharacters`.
    static func fallback(for message: String) -> String {
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        let all = words(firstLine).map(bare).filter { !$0.isEmpty }
        let topic = all.filter { !filler.contains($0.lowercased()) }
        var picked: [String] = []
        // All filler ("Hi there!"): the first words as typed, under the very same limits.
        for word in (topic.isEmpty ? all : topic).prefix(maxWords) {
            let clean = picked.isEmpty ? capitalizedFirst(word) : word
            let next = (picked + [clean]).joined(separator: " ")
            if next.count > maxCharacters {
                // A single long token (including languages without spaces) still needs a bounded name. String's
                // Character prefix keeps composed characters whole, and capitalization happens before the bound.
                if picked.isEmpty { picked.append(String(clean.prefix(maxCharacters))) }
                break
            }
            picked.append(clean)
        }
        let title = picked.joined(separator: " ")
        return title.isEmpty ? "New Chat" : title
    }

    // MARK: On-device model

    static let instructions = """
        You name chat sessions so they can be found again in a short list on a phone. Given the user's opening message, \
        reply with only a title of 1 to \(maxWords) words, at most \(maxCharacters) characters including spaces, in sentence case, in the message's language. Name \
        what the user wants done. Keep names, product names and numbers exact. No quotes, no ending punctuation. Never \
        answer the message.
        """

    private static func onDevice(_ message: String) async -> String? {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 24)
        return try? await session.respond(to: "Opening message:\n\(message)", options: options).content
        #else
        return nil
        #endif
    }

    // MARK: Text helpers

    static func normalized(_ text: String) -> String {
        var s = words(text.lowercased()).joined(separator: " ")
        while let last = s.last, "….,;:!?-—".contains(last) || last == " " { s.removeLast() }
        return s
    }

    static func words(_ text: String) -> [String] { text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    /// A word without the punctuation around it ("room." → "room", "(bonus" → "bonus"); inner marks stay ("bonus/play").
    static func bare(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "#+")))
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
