// [settings] The words of a finished background process's alert (docs/spec/3x-settings.md §15b; the web's
// `composer-status.ts`: first line of the command, " (exit N)" for any exit code, then the last lines of its output).
// The head is the job's name, not its raw first line: a leading `# comment` names it outright, and otherwise the
// setup a bot puts in front (`cd …`, `export …`, `FOO=bar`) gives way to the program it ran and the folder it ran in.

import Foundation

nonisolated enum BackgroundTaskText {
    static func failed(exitCode: Int?) -> Bool { (exitCode ?? 0) != 0 }

    static func line(command: String?, status: String?, exitCode: Int?, tail: String?) -> String {
        var head = title(command: command)
        if let exitCode { head += " (exit \(exitCode))" }
        let lines = (tail ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(3)
        let title = failed(exitCode: exitCode) ? "Background task failed" : "Background task finished"
        return String(([title + ": " + head] + lines).joined(separator: "\n").prefix(240))
    }

    /// A readable name for a background command: "Archiving Mac build 42" for `# Archiving Mac build 42\n…`,
    /// "python3 scripts/ship.py archive · ship-42-mac" for `cd …/ship-42-mac && BUILD=42 python3 scripts/ship.py archive > log`.
    static func title(command: String?) -> String {
        let lines = (command ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // A comment before the first command is the bot's own name for the job.
        if let first = lines.first, first.hasPrefix("#"), !first.hasPrefix("#!") {
            let words = first.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !words.isEmpty { return words }
        }
        var folder: String?
        for line in lines where !line.hasPrefix("#") {
            for segment in segments(line) {
                if let dir = changedDirectory(segment) { folder = dir; continue }
                guard let run = program(segment) else { continue }
                return folder.map { "\(run) · \($0)" } ?? run
            }
        }
        if let folder { return "cd \(folder)" }
        return "background process"
    }

    /// The command's steps, split on `&&`, `||` and `;`.
    private static func segments(_ line: String) -> [String] {
        var parts = [line]
        for separator in ["&&", "||", ";"] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The folder a `cd`/`pushd` step moves into, as its last path component.
    private static func changedDirectory(_ segment: String) -> String? {
        let words = segment.split(separator: " ", omittingEmptySubsequences: true)
        guard let verb = words.first, verb == "cd" || verb == "pushd" else { return nil }
        let path = words.dropFirst().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return last.isEmpty || last == "~" ? "home" : last
    }

    /// The step's program and arguments, without setup steps, leading `VAR=value`s or what follows a redirect or pipe.
    private static func program(_ segment: String) -> String? {
        var words = segment.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let setup: Set<String> = ["export", "source", ".", "set", "unset", "true", "echo", "sleep", "popd", "umask", "ulimit"]
        guard let verb = words.first, !setup.contains(verb) else { return nil }
        while let word = words.first, isAssignment(word) { words.removeFirst() }
        if words.first == "env" { words.removeFirst(); while let word = words.first, isAssignment(word) { words.removeFirst() } }
        var kept: [String] = []
        for word in words {
            if word == "|" || word == "&" || word.hasPrefix(">") || word.hasPrefix("2>") || word.hasPrefix("&>") || word.hasPrefix("<") { break }
            kept.append(word)
        }
        let run = kept.joined(separator: " ")
        return run.isEmpty ? nil : run
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
