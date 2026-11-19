// [m9/composer] The model list's load rules and failure words (docs/spec/3x-composer.md §12; web r1-33
// `modelLoadError`, r2-60 `retry: 1`). Pure, unit tested in Tests/Composer.

import Foundation

nonisolated enum ModelLoad {
    /// The read is tried this many times before the failure shows.
    static let tries = 2
    static let messageLimit = 120

    /// Whether asking again at once can do better. Not after a cancel, not when the gateway refused the call's shape
    /// (4000) or does not know the method (-32601), and not when there is no connection to ask over.
    static func secondTryHelps(_ error: any Error) -> Bool {
        if QueryRetry.cancelled(error) { return false }
        if let menus = error as? MenusError { return menus != .offline && menus != .loading }
        if let rpc = error as? RPCError {
            if rpc.code == 4000 || rpc.code == -32601 || rpc.isNotConnected || needsRestart(rpc) { return false }
        }
        return true
    }

    /// Hermes was updated on disk and is still running the old code (`5098`: "This gateway is running code from … but
    /// the checkout on disk is now …"): it refuses the model list until it restarts, so asking again can't help.
    static func needsRestart(_ error: any Error) -> Bool {
        guard let rpc = error as? RPCError else { return false }
        return rpc.code == 5098 || rpc.message.contains("checkout on disk is now")
    }

    static var restartWords: String { "\(HostWord.sentence) was updated and needs a restart before it can list models." }

    /// The line under "Couldn’t Load Models": nil = the title alone.
    static func words(for error: any Error, offline: Bool) -> String? {
        if offline || (error as? MenusError) == .offline || (error as? RPCError)?.isNotConnected == true { return "You’re offline." }
        // [log review 2026-11-18] The gateway's own words here were a cut-off line about code and checkouts.
        if needsRestart(error) { return restartWords }
        if QueryRetry.timedOut(error) || (error as? RPCError)?.isConnectionLost == true || error is URLError {
            return "\(HostWord.sentence) didn’t answer in time."
        }
        return cut(MenusError.text(error))
    }

    /// A gateway's own message, trimmed and cut at 120 characters with "…"; nil when it says nothing.
    static func cut(_ message: String) -> String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.count > messageLimit else { return text }
        return String(text.prefix(messageLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static let failureTitle = "Couldn’t Load Models"
    static let loadingWords = "Loading models…"
    static let menuFailure = "Couldn’t load models"
}

/// The line under "Couldn’t Load Commands" (the ☰ sheet with no saved list): offline says so, as the Models sheet does,
/// and the computer is named as everywhere else (`HostWord`), never blamed for a phone with no connection.
nonisolated enum CommandsLoad {
    static func words(for error: any Error) -> String {
        if (error as? MenusError) == .offline || (error as? RPCError)?.isNotConnected == true { return "You’re offline." }
        if QueryRetry.timedOut(error) || (error as? RPCError)?.isConnectionLost == true || error is URLError {
            return "\(HostWord.sentence) didn’t answer in time."
        }
        return "\(HostWord.sentence) didn’t send its list of commands. Show Details has the reason."
    }
}
