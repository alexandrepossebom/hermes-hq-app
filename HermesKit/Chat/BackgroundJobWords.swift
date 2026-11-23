// [background] What a running background job is FOR, in words (owner 2026-11-22, a row reading "claude -p 'Read
// .goals-bri…" over "No output yet" for 1h 22m: "Is this what you thought would count as success?"). The command alone
// can't say why it runs; the bot that started it usually did, in its own turn. So a row is named, in order, by:
//   1. the command's leading `# comment` (the bot named the job itself);
//   2. the bot's own sentence just before the terminal call that started it, in this chat's transcript;
//   3. a coding agent's prompt ("Claude Code: Fix the four goal set-up issues");
//   4. the program it runs and its folder (BackgroundTaskText.title).
// Under the name: the agent and folder ("Claude Code · goals-2"). Then the newest output line, or an honest quiet line.

import Foundation

nonisolated enum BackgroundJobWords {
    /// A coding agent run headless: its name and the prompt it was given.
    struct Agent: Hashable, Sendable {
        var name: String
        var prompt: String?
    }

    /// The agents that print nothing until they finish (`claude -p`, `codex exec`, …).
    static func agent(_ command: String) -> Agent? {
        let words = shellWords(command)
        let known: [(String, String, Set<String>)] = [
            ("claude", "Claude Code", ["-p", "--print"]),
            ("codex", "Codex", ["exec", "e"]),
            ("gemini", "Gemini CLI", ["-p", "--prompt"]),
            ("opencode", "OpenCode", ["run"]),
            ("cursor-agent", "Cursor Agent", ["-p", "--print"]),
        ]
        for (index, word) in words.enumerated() {
            let program = word.split(separator: "/").last.map(String.init) ?? word
            guard let (_, name, triggers) = known.first(where: { $0.0 == program }) else { continue }
            let rest = Array(words[(index + 1)...])
            guard let at = rest.firstIndex(where: { triggers.contains($0) }) else { continue }
            // The prompt: the first argument after the trigger that isn't a flag (or the flag's own value for `-p "…"`).
            // Flags that take a value (`-m gpt-5`, `--permission-mode acceptEdits`) skip that value too.
            let valued: Set<String> = ["-m", "--model", "-c", "--config", "-C", "--cd", "-s", "--sandbox", "--permission-mode",
                                       "--allowedTools", "--allowed-tools", "--disallowedTools", "--max-turns", "--output-format",
                                       "--profile", "-p", "--prompt", "--append-system-prompt", "--add-dir"]
            var prompt: String?
            var skip = false
            for word in rest[(at + 1)...] {
                if skip { skip = false; continue }
                if word.hasPrefix("-") { skip = valued.contains(word) && !word.contains("="); continue }
                prompt = firstSentence(word, limit: 80); break
            }
            return Agent(name: name, prompt: prompt.flatMap { $0.isEmpty ? nil : $0 })
        }
        return nil
    }

    /// The bot's words about the job: the last sentence of its text just before the terminal call that ran `command`,
    /// in the same turn. `command` may be cut short (`process.list` sends its first 200 characters).
    static func botWords(for command: String, in messages: [ChatMessage]) -> String? {
        let wanted = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        for message in messages.reversed() where message.role == .assistant {
            var before: String?
            for part in message.parts {
                switch part {
                case .text(let text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { before = text }
                case .tool(let call):
                    guard call.name == "terminal", let ran = terminalCommand(call.argsText),
                          ran.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(wanted) else { continue }
                    return before.flatMap { lastSentence($0, limit: 90) }
                case .reasoning:
                    continue
                }
            }
        }
        return nil
    }

    /// The `command` argument of a terminal call's JSON arguments.
    static func terminalCommand(_ argsText: String?) -> String? {
        guard let data = argsText?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["command"] as? String
    }

    /// The row's name (see the file's header for the order).
    static func headline(command: String, botWords: String?) -> String {
        if let comment = BackgroundTaskText.comment(command: command) { return comment }
        if let botWords { return botWords }
        // The agent's name is on the line under it, so the name is just its prompt.
        if let agent = agent(command) { return agent.prompt ?? agent.name }
        let name = BackgroundTaskText.title(command: command)
        return name == "background process" ? "Background command" : name
    }

    /// The line under the name: who runs it and where ("Claude Code · goals-2", "python3 scripts/ship.py · ship-mac").
    /// nil when the name already says all of it.
    static func detail(command: String, cwd: String?, headline: String) -> String? {
        let folder = BackgroundTaskText.folder(command: command) ?? cwd.flatMap(lastComponent)
        var parts: [String] = []
        if let agent = agent(command) {
            parts.append(agent.name)
        } else if let program = BackgroundTaskText.program(command: command), !headline.hasPrefix(program) {
            parts.append(program.count > 48 ? String(program.prefix(47)) + "…" : program)
        }
        if let folder, !headline.contains(folder) { parts.append(folder) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The line while it has printed nothing: where its output goes, what an agent does, or how long it has been quiet.
    static func quietLine(command: String, uptimeSeconds: Int?) -> String {
        let file = BackgroundTaskText.quietLine(command: command)
        if file != "No output yet" { return file }
        if agent(command) != nil { return "Quiet until it's done" }
        if let up = uptimeSeconds, up >= 60 { return "No output for \(BackgroundProcess.duration(up))" }
        return "No output yet"
    }

    // MARK: Words

    static func lastComponent(_ path: String) -> String? {
        let last = path.split(separator: "/").last.map(String.init)
        return last?.isEmpty == false ? last : nil
    }

    /// Plain words: markdown marks gone, spaces collapsed.
    static func plain(_ text: String) -> String {
        var s = text
        for mark in ["**", "__", "`", "~~"] { s = s.replacingOccurrences(of: mark, with: "") }
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func firstSentence(_ text: String, limit: Int) -> String {
        let s = plain(text)
        let cut = sentences(s).first ?? s
        return clip(cut, limit)
    }

    /// The last sentence of the last paragraph: a bot's lead-in to a call ("Now the app's own test gate.").
    static func lastSentence(_ text: String, limit: Int) -> String? {
        let paragraphs = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = paragraphs.last else { return nil }
        var s = plain(last)
        // A list item or heading reads as a sentence without its mark.
        while let first = s.first, "-*#>".contains(first) { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard let sentence = sentences(s).last, sentence.count >= 3 else { return nil }
        return clip(withoutLeadIn(sentence), limit)
    }

    /// "I'm starting a worker on the four fixes" → "The four fixes": the bot's lead-in to a call says only that a job
    /// starts, which the row already shows.
    static func withoutLeadIn(_ sentence: String) -> String {
        let leads = ["i'm starting a worker on ", "i'm starting a worker to ", "starting a worker on ", "starting a worker to ",
                     "i'm kicking off ", "i'm starting ", "i'm running ", "i'm launching ", "i'll run ", "i'll start ",
                     "let me run ", "let me start ", "now running ", "now starting ", "now ", "running ", "starting ", "kicking off ",
                     "launching "]
        let lower = sentence.lowercased()
        guard let lead = leads.first(where: { lower.hasPrefix($0) }) else { return sentence }
        let rest = sentence.dropFirst(lead.count).trimmingCharacters(in: .whitespaces)
        guard rest.count >= 8 else { return sentence }
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    private static func sentences(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            current.append(c)
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            if ".!?".contains(c), next == " " {
                out.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out.map { $0.hasSuffix(":") ? String($0.dropLast()) : $0 }.filter { !$0.isEmpty }
    }

    private static func clip(_ s: String, _ limit: Int) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("."), !t.hasSuffix("..") { t.removeLast() }
        return t.count > limit ? String(t.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : t
    }

    /// Shell words with quotes honoured (`claude -p 'Read the brief' --x` → ["claude", "-p", "Read the brief", "--x"]).
    static func shellWords(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var hasWord = false
        for c in command {
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c; hasWord = true
            } else if c.isWhitespace {
                if hasWord || !current.isEmpty { words.append(current); current = ""; hasWord = false }
            } else {
                current.append(c); hasWord = true
            }
        }
        if hasWord || !current.isEmpty { words.append(current) }
        return words
    }
}
