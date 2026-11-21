// [own-folder] A bot's own folder, and what the New Chat sheet offers (a tester, 2026-11-14).
//
// Hermes groups chats by the folder they ran in and reports each group next to the saved projects, marked automatic
// (`isAuto`). A bot's own chat, and every chat started with no project, runs in the bot's own working folder, so that
// folder came back as a "project" of its own: New Chat offered it under "In a project", though nobody made it and
// picking it is the same as picking no project. The folder can be anywhere (not only under the bot's profile), so it
// is not told by its path: it is the bot's `terminal.cwd` (its config), and the folder the bot's own chat (its Bot Chat)
// runs in, read from that chat's record (`GET /api/sessions/<id>`); both once per bot per run, kept for the next launch.
//
// [own-folder-everywhere] The same tester, 2026-11-21, on build 1166: New Chat still listed the OTHER bots' own folders
// (only a bot whose own chat had said where it runs was known, and chats now start with no folder recorded, so most
// never did), Sessions › Projects still listed them as projects, and one bot's chats were split between its folder's
// group (older chats, cwd = the folder) and Home (newer ones, no cwd). A group Hermes found by itself whose folder is any
// bot's own folder, or any bot's profile home, is now dropped from what the app keeps of every bot's projects
// (`projectsByProfile`), so it is no project or folder anywhere (New Chat, Filter › Project, Group By Project, the
// project pills, Move to Project) and its chats sit under Home with the chats that have no folder. A project someone
// saved on that folder stays. Nothing on the gateway changes: no chat, folder or instruction file is touched.
//
// New Chat then lists saved projects under "In a project", and any other folder Hermes found (a checkout that was never
// made a project) under "In a folder".

import Foundation

extension SessionStore {
    /// How long a bot's own folder, once asked for in this run, is taken as read.
    static let botFolderMaxAge: Duration = .seconds(600)

    /// Each bot's own folder as last learned from its own chat (profile → folder).
    var botFolders: [String: String] { device.botFolders }

    /// [own-folder-everywhere] Each bot's `terminal.cwd` as last read (profile → folder; placeholders left out).
    var botConfigFolders: [String: String] { device.botConfigFolders }

    /// [own-folder-everywhere] Every bot's own folder, whichever way it was learned.
    var ownFolders: Set<String> { Set(device.botFolders.values).union(device.botConfigFolders.values) }

    /// Reads where `profile` works: its `terminal.cwd`, and the folder its own chat runs in. Quiet: a bot with no chat
    /// yet, a read that fails, or an answer that does not say leaves what was known; a read that failed is asked again.
    func learnBotFolder(_ profile: String) async {
        if let at = botFolderAskedAt[profile], ContinuousClock.now - at < Self.botFolderMaxAge { return }
        botFolderAskedAt[profile] = .now
        let query = profile == "default" ? [] : [URLQueryItem(name: "profile", value: profile)]
        var failed = false
        // [own-folder-everywhere] The bot's config says where it works even when no chat records a folder.
        if let data = try? await client.configData(query), let config = try? JSONValue.parse(data) {
            noteConfigFolder(RosterText.trimmed(config["terminal"]?["cwd"]), profile: profile)
        } else {
            failed = true
        }
        if let id = botChatId?(profile), !id.isEmpty {
            if let data = try? await client.rest("GET", Self.path(id), query: query, body: nil), let row = try? JSONValue.parse(data) {
                noteBotFolder(RosterText.trimmed(row["cwd"]), profile: profile)
            } else {
                failed = true
            }
        }
        if failed { botFolderAskedAt[profile] = nil }
    }

    /// The bot's own chat runs in `folder` (its record said so, or the open chat did).
    func noteBotFolder(_ folder: String?, profile: String) {
        guard let folder = folder.map(SessionProjects.folderKey), !folder.isEmpty, device.botFolders[profile] != folder else { return }
        device.botFolders[profile] = folder
        AppLog.trace("sessions", "own folder of \(AppLog.tag(profile)) learned")
        ownFoldersChanged()
    }

    /// [own-folder-everywhere] The bot's `terminal.cwd`. A placeholder (unset, `.`, `auto`, `cwd`: Hermes then works in
    /// its launch folder or the home folder) names no folder, and forgets one known before.
    func noteConfigFolder(_ value: String?, profile: String) {
        let folder = SessionProjects.configFolder(value)
        guard device.botConfigFolders[profile] != folder else { return }
        device.botConfigFolders[profile] = folder
        if folder != nil { AppLog.trace("sessions", "configured folder of \(AppLog.tag(profile)) learned") }
        ownFoldersChanged()
    }

    /// [own-folder-everywhere] A newly known own folder leaves every bot's projects at once (a folder that stopped being
    /// one comes back with that bot's next read of its projects).
    private func ownFoldersChanged() {
        persistState()
        let kept = SessionProjects.droppingOwnFolders(projectsByProfile, ownFolders: ownFolders)
        if kept != projectsByProfile { projectsByProfile = kept }
        onChange?()
    }

    /// What New Chat offers: saved projects, then the folders Hermes found that are no bot's own (Home is not an entry).
    func newChatEntries(order: [String] = []) -> [SessionProjectEntry] {
        SessionProjects.newChatEntries(projectsByProfile, botFolders: device.botFolders, order: order)
    }
}

extension SessionProjects {
    /// A folder as a key: no blanks around it, no trailing slash (never expanded: it is the gateway computer's).
    static func folderKey(_ folder: String) -> String {
        var root = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        return root
    }

    /// [own-folder-everywhere] `terminal.cwd` as a folder: nil for Hermes's placeholders (`.`, `auto`, `cwd`, unset) and
    /// for anything that is not a whole path (absolute, or from the home folder: `~/…`).
    static func configFolder(_ value: String?) -> String? {
        guard let value else { return nil }
        let folder = folderKey(value)
        guard folder.count > 1, folder.hasPrefix("/") || folder.hasPrefix("~/") else { return nil }
        return folder
    }

    /// [own-folder-everywhere] `root` is `folder`. A `~/…` folder (as a config may give it; Hermes expands it on its own
    /// computer) is the same folder under any home folder there: `/home/<name>/…`, `/Users/<name>/…` or `/root/…`.
    static func isFolder(_ root: String, _ folder: String) -> Bool {
        let root = folderKey(root), folder = folderKey(folder)
        guard folder.hasPrefix("~/") else { return root == folder }
        let tail = String(folder.dropFirst())      // "/rest"
        guard tail.count > 1, root.hasSuffix(tail) else { return false }
        let home = root.dropLast(tail.count).split(separator: "/", omittingEmptySubsequences: false)
        return home == ["", "root"] || (home.count == 3 && home[0].isEmpty && ["home", "Users"].contains(home[1]) && !home[2].isEmpty)
    }

    /// A bot's own folder by where it is: its profile's home under Hermes's folder, or Hermes's folder itself (the
    /// first bot's home). Told without asking; the folder its own chat runs in (`botFolders`) covers every other place.
    static func isProfileHome(_ folder: String, profile: String) -> Bool {
        let parts = folderKey(folder).split(separator: "/").map(String.init)
        guard let hermes = parts.lastIndex(of: ".hermes") else { return false }
        let rest = Array(parts[(hermes + 1)...])
        if rest.isEmpty { return true }
        return rest.count >= 2 && rest[0] == "profiles" && (rest.count == 2 || rest[1] == profile)
    }

    /// [own-folder-everywhere] Some bot's home: Hermes's folder itself, or `profiles/<name>` in it (exactly; a folder
    /// inside one may be a workspace someone made).
    static func isAnyProfileHome(_ folder: String) -> Bool {
        let parts = folderKey(folder).split(separator: "/").map(String.init)
        guard let hermes = parts.lastIndex(of: ".hermes") else { return false }
        let rest = Array(parts[(hermes + 1)...])
        return rest.isEmpty || (rest.count == 2 && rest[0] == "profiles")
    }

    /// [own-folder-everywhere] A group Hermes found by itself on a bot's own folder (`ownFolders`, any bot's) or on a
    /// bot's home. Never a saved project.
    static func isOwnFolderGroup(_ project: SessionProject, ownFolders: Set<String>) -> Bool {
        guard project.isAuto == true else { return false }
        return isAnyProfileHome(project.root) || ownFolders.contains { isFolder(project.root, $0) }
    }

    /// [own-folder-everywhere] Every bot's projects without the groups that are a bot's own folder (`isOwnFolderGroup`).
    static func droppingOwnFolders(_ projectsByProfile: [String: [SessionProject]], ownFolders: Set<String>) -> [String: [SessionProject]] {
        projectsByProfile.mapValues { projects in projects.filter { !isOwnFolderGroup($0, ownFolders: ownFolders) } }
    }

    /// The New Chat sheet's list (a tester, 2026-11-14). One entry per folder, as `entries`:
    /// - a saved project (any bot holds the folder as one): listed as a project;
    /// - a folder Hermes found by itself that is a bot's own (the folder that bot's own chat runs in, or its home):
    ///   left out, because a chat with no project already starts there;
    /// - any other folder Hermes found: listed as a folder (`isFolder`), after the projects.
    /// [own-folder-everywhere] Any bot's own folder is left out whichever bot is picked. The store's projects come
    /// without them already (`droppingOwnFolders`); this also leaves out, for New Chat only, the found group that holds a
    /// bot's own folder (a checkout it works inside) and folders inside its own profile home.
    static func newChatEntries(_ projectsByProfile: [String: [SessionProject]], botFolders: [String: String],
                               order: [String]) -> [SessionProjectEntry] {
        var saved = Set<String>(), own = Set<String>()
        let everyOwn = Set(botFolders.values)
        for (profile, projects) in projectsByProfile {
            for project in projects {
                let key = key(project, profile: profile)
                if project.isAuto != true { saved.insert(key); continue }
                if isProfileHome(project.root, profile: profile) || isOwnFolderGroup(project, ownFolders: everyOwn) { own.insert(key) }
            }
            // The group that holds the bot's own folder most closely (the folder itself, or the checkout it is in).
            if let mine = botFolders[profile], let id = SessionProject.owner(of: mine, in: projects),
               let holder = projects.first(where: { $0.id == id }), holder.isAuto == true {
                own.insert(key(holder, profile: profile))
            }
        }
        let all = entries(projectsByProfile, order: order)
        let projects = all.filter { saved.contains($0.key) }
        let folders = all.filter { !saved.contains($0.key) && !own.contains($0.key) }.map { entry in
            var folder = entry
            folder.isFolder = true
            return folder
        }
        return projects + folders
    }
}
