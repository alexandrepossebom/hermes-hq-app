// [own-folder] A bot's own folder, and what the New Chat sheet offers (a tester, 2026-11-14).
//
// Hermes groups chats by the folder they ran in and reports each group next to the saved projects, marked automatic
// (`isAuto`). A bot's own chat, and every chat started with no project, runs in the bot's own working folder, so that
// folder came back as a "project" of its own: New Chat offered it under "In a project", though nobody made it and
// picking it is the same as picking no project. The folder can be anywhere (not only under the bot's profile), so it
// is not told by its path: it is the folder the bot's own chat (its Bot Chat) runs in, read from that chat's record
// (`GET /api/sessions/<id>`), once per bot per run, and kept for the next launch.
//
// New Chat then leaves a bot's own folder out, lists saved projects under "In a project", and any other folder Hermes
// found (a checkout that was never made a project) under "In a folder". Nothing else changes: the Sessions list still
// groups by these folders, and no chat, folder or instruction file is touched.

import Foundation

extension SessionStore {
    /// How long a bot's own folder, once asked for in this run, is taken as read.
    static let botFolderMaxAge: Duration = .seconds(600)

    /// Each bot's own folder as last learned (profile → folder).
    var botFolders: [String: String] { device.botFolders }

    /// Reads the folder `profile`'s own chat runs in. Quiet: a bot with no chat yet, a read that fails, or a gateway
    /// that does not say leaves what was known.
    func learnBotFolder(_ profile: String) async {
        if let at = botFolderAskedAt[profile], ContinuousClock.now - at < Self.botFolderMaxAge { return }
        guard let id = botChatId?(profile), !id.isEmpty else { return }
        botFolderAskedAt[profile] = .now
        var query: [URLQueryItem] = []
        if profile != "default" { query.append(URLQueryItem(name: "profile", value: profile)) }
        guard let data = try? await client.rest("GET", Self.path(id), query: query, body: nil),
              let row = try? JSONValue.parse(data) else {
            botFolderAskedAt[profile] = nil
            return
        }
        noteBotFolder(RosterText.trimmed(row["cwd"]), profile: profile)
    }

    /// The bot's own chat runs in `folder` (its record said so, or the open chat did).
    func noteBotFolder(_ folder: String?, profile: String) {
        guard let folder = folder.map(SessionProjects.folderKey), !folder.isEmpty, device.botFolders[profile] != folder else { return }
        device.botFolders[profile] = folder
        AppLog.trace("sessions", "own folder of \(AppLog.tag(profile)) learned")
        persistState()
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

    /// A bot's own folder by where it is: its profile's home under Hermes's folder, or Hermes's folder itself (the
    /// first bot's home). Told without asking; the folder its own chat runs in (`botFolders`) covers every other place.
    static func isProfileHome(_ folder: String, profile: String) -> Bool {
        let parts = folderKey(folder).split(separator: "/").map(String.init)
        guard let hermes = parts.lastIndex(of: ".hermes") else { return false }
        let rest = Array(parts[(hermes + 1)...])
        if rest.isEmpty { return true }
        return rest.count >= 2 && rest[0] == "profiles" && (rest.count == 2 || rest[1] == profile)
    }

    /// The New Chat sheet's list (a tester, 2026-11-14). One entry per folder, as `entries`:
    /// - a saved project (any bot holds the folder as one): listed as a project;
    /// - a folder Hermes found by itself that is a bot's own (the folder that bot's own chat runs in, or its home):
    ///   left out, because a chat with no project already starts there;
    /// - any other folder Hermes found: listed as a folder (`isFolder`), after the projects.
    static func newChatEntries(_ projectsByProfile: [String: [SessionProject]], botFolders: [String: String],
                               order: [String]) -> [SessionProjectEntry] {
        var saved = Set<String>(), own = Set<String>()
        for (profile, projects) in projectsByProfile {
            for project in projects {
                let key = key(project, profile: profile)
                if project.isAuto != true { saved.insert(key); continue }
                if isProfileHome(project.root, profile: profile) { own.insert(key) }
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
