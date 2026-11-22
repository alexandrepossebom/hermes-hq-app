// [new-project-folder] New Project › Choose Folder…: the words and paths of the folder browser, kept pure so they are
// unit-tested. The browser lists folders on the gateway's computer (`GET /api/fs/list`), so a project's folder is
// picked, not typed.

import Foundation

nonisolated enum ProjectFolderWords {
    /// The folder above `path`; nil at the top ("/").
    static func parent(of path: String) -> String? {
        let clean = normalized(path)
        guard clean != "/" else { return nil }
        let up = (clean as NSString).deletingLastPathComponent
        return up.isEmpty ? "/" : up
    }

    /// No trailing slash (but "/" stays), no surrounding spaces.
    static func normalized(_ path: String) -> String {
        var clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.count > 1, clean.hasSuffix("/") { clean.removeLast() }
        return clean
    }

    /// Where the browser opens, best first: what was already typed, the Projects folder in the gateway user's home,
    /// that home, the gateway's own default folder, then the top. The first that lists is used.
    static func starts(typed: String, home: String?, defaultFolder: String?) -> [String] {
        var out: [String] = []
        func add(_ path: String?) {
            guard let path, case let clean = normalized(path), clean.hasPrefix("/"), !out.contains(clean) else { return }
            out.append(clean)
        }
        let typedClean = normalized(typed)
        if typedClean.hasPrefix("~"), let home {
            add(home + typedClean.dropFirst())
        } else {
            add(typedClean)
        }
        if let home { add(home + "/Projects"); add(home) }
        add(defaultFolder)
        add("/")
        return out
    }

    /// The folders a person picks among: no files, no hidden folders, by name.
    static func folders(_ entries: [WorkspaceEntry]) -> [WorkspaceEntry] {
        entries.filter { $0.isDirectory && !$0.name.hasPrefix(".") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The name New Project offers for a picked folder when none was typed: the folder's own name.
    static func suggestedName(folder: String) -> String {
        let last = (normalized(folder) as NSString).lastPathComponent
        return last == "/" ? "" : last
    }

    /// The gateway's errno words (`not-found`, `permission-denied`, …) as a sentence.
    static func reason(_ code: String) -> String {
        switch code.lowercased() {
        case "not-found", "enoent": return "This folder isn’t there anymore."
        case "permission-denied", "eacces", "eperm": return "Hermes isn’t allowed to open this folder."
        case "not-a-directory", "enotdir": return "This isn’t a folder."
        default: return "This folder couldn’t be opened."
        }
    }
}
