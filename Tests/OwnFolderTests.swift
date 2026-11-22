import Foundation
import Testing
@testable import HermesHQNative

/// [own-folder] New Chat's list: saved projects, the folders Hermes found, and a bot's own working folder left out
/// (SessionStore+OwnFolder.swift; a tester, 2026-11-14).
@Suite struct OwnFolderTests {
    private static func auto(_ path: String, label: String? = nil, paths: [String]? = nil) -> SessionProject {
        SessionProject(id: path, label: label ?? (path as NSString).lastPathComponent, root: path, paths: paths ?? [path], isAuto: true)
    }

    private static func saved(_ id: String, _ label: String, _ path: String) -> SessionProject {
        SessionProject(id: id, label: label, root: path, paths: [path])
    }

    // MARK: The list

    /// The report: two bots, each with only its own working folder (outside Hermes's own folders), no saved project.
    @Test func aBotsOwnWorkingFolderIsNotOffered() {
        let tree = ["otto": [Self.auto("/home/me/otto")], "juno": [Self.auto("/home/me/bookkeeper")]]
        let folders = ["otto": "/home/me/otto", "juno": "/home/me/bookkeeper/"]
        #expect(SessionProjects.newChatEntries(tree, botFolders: folders, order: []).isEmpty)
        // Before the folders are known (the first read is still out) they are folders, never projects.
        let early = SessionProjects.newChatEntries(tree, botFolders: [:], order: [])
        #expect(early.map(\.label) == ["bookkeeper", "otto"] && early.allSatisfy(\.isFolder))
    }

    /// [favorite-in-new-chat] A starred folder is offered even though it is a bot's own.
    @Test func aFavoriteOwnFolderIsOffered() {
        let tree = ["otto": [Self.auto("/home/me/otto")], "juno": [Self.auto("/home/me/bookkeeper")]]
        let folders = ["otto": "/home/me/otto", "juno": "/home/me/bookkeeper/"]
        let entries = SessionProjects.newChatEntries(tree, botFolders: folders, order: [], favorites: ["/home/me/otto"])
        #expect(entries.map(\.key) == ["/home/me/otto"] && entries.allSatisfy(\.isFolder))
    }

    @Test func otherFoldersComeAfterSavedProjects() {
        let tree = ["otto": [Self.auto("/home/me/otto"), Self.auto("/home/me/code/site"), Self.saved("p1", "Books", "/home/me/books")],
                    "juno": [Self.saved("p2", "Atlas", "/home/me/atlas")]]
        let entries = SessionProjects.newChatEntries(tree, botFolders: ["otto": "/home/me/otto"], order: ["otto", "juno"])
        #expect(entries.map(\.label) == ["Atlas", "Books", "site"])
        #expect(entries.map(\.isFolder) == [false, false, true])
        #expect(entries.map(\.key) == ["/home/me/atlas", "/home/me/books", "/home/me/code/site"])
    }

    /// One bot's own folder that another bot saved as a project is that project.
    @Test func aSavedProjectWinsOverABotsOwnFolder() {
        let tree = ["otto": [Self.auto("/home/me/otto")], "juno": [Self.saved("p9", "Otto’s Desk", "/home/me/otto")]]
        let entries = SessionProjects.newChatEntries(tree, botFolders: ["otto": "/home/me/otto"], order: ["juno", "otto"])
        #expect(entries == [SessionProjectEntry(key: "/home/me/otto", label: "Otto’s Desk")])
    }

    /// The bot's folder inside a checkout: the group Hermes made for the checkout is the bot's own.
    @Test func theGroupThatHoldsTheBotsFolderIsItsOwn() {
        let tree = ["otto": [Self.auto("/home/me/otto", paths: ["/home/me/otto", "/home/me/otto/lanes/a"]), Self.auto("/home/me/other")]]
        let entries = SessionProjects.newChatEntries(tree, botFolders: ["otto": "/home/me/otto/work"], order: [])
        #expect(entries.map(\.key) == ["/home/me/other"])
        // Another bot's own folder does not hide a folder of this one that only sits beside it.
        let beside = SessionProjects.newChatEntries(tree, botFolders: ["otto": "/home/me/otto-archive"], order: [])
        #expect(beside.map(\.key) == ["/home/me/other", "/home/me/otto"])
    }

    @Test func aProfilesHomeIsToldByItsPath() {
        #expect(SessionProjects.isProfileHome("/home/me/.hermes", profile: "default"))
        #expect(SessionProjects.isProfileHome("/home/me/.hermes/profiles/otto/", profile: "otto"))
        #expect(SessionProjects.isProfileHome("/home/me/.hermes/profiles/otto/workspace", profile: "otto"))
        #expect(!SessionProjects.isProfileHome("/home/me/.hermes/profiles/juno/workspace", profile: "otto"))
        #expect(!SessionProjects.isProfileHome("/home/me/.hermes/skills", profile: "otto"))
        #expect(!SessionProjects.isProfileHome("/home/me/otto", profile: "otto"))
        let tree = ["otto": [Self.auto("/home/me/.hermes/profiles/otto/workspace"), Self.auto("/home/me/code/site")]]
        #expect(SessionProjects.newChatEntries(tree, botFolders: [:], order: []).map(\.key) == ["/home/me/code/site"])
    }

    // MARK: Learning the folder

    private func store(_ client: BotsFakeGatewayClient, dir: URL = BotsTest.tempDirectory()) async -> SessionStore {
        let store = SessionStore(client: client, account: .botsTestAccount, cacheDirectory: dir, timing: .fast)
        _ = await BotsTest.waitUntil { store.loadState == .ready }
        return store
    }

    /// `configs`: each bot's `terminal.cwd` as `GET /api/config?profile=` answers it (a bot not named: unset).
    private func client(cwd: JSONValue = "/home/me/otto", tree: JSONValue? = nil, configs: [String: String] = [:],
                        trees: [String: JSONValue] = [:]) -> BotsFakeGatewayClient {
        let client = BotsFakeGatewayClient()
        client.onREST { method, path, query, _ in
            if path == "/api/profiles/sessions/sidebar" { return SessionActionsTests.sidebar([]) }
            if method == "GET", path == "/api/config" {
                let profile = query.first { $0.name == "profile" }?.value ?? "default"
                let cwd: JSONValue = configs[profile].map { .string($0) } ?? "."
                return try (["terminal": ["cwd": cwd, "backend": "local"]] as JSONValue).encoded()
            }
            if method == "GET", path == "/api/sessions/chat-otto" {
                return try (["id": "chat-otto", "title": "Bot Chat", "cwd": cwd] as JSONValue).encoded()
            }
            throw HTTPError(status: 404, body: nil)
        }
        let answer = tree ?? ["projects": [["id": "/home/me/otto", "label": "otto", "path": "/home/me/otto", "isAuto": true, "repos": []],
                                           ["id": "/home/me/code/site", "label": "site", "path": "/home/me/code/site", "isAuto": true, "repos": []],
                                           ["id": "p1", "label": "Books", "path": "/home/me/books", "repos": []]]]
        client.on("projects.tree") { params in
            if let profile = params["profile"]?.string, let own = trees[profile] { return own }
            return answer
        }
        return client
    }

    @Test func theFolderIsReadFromTheBotsOwnChatAndKept() async throws {
        let client = client(), dir = BotsTest.tempDirectory()
        let store = await store(client, dir: dir)
        store.botChatId = { $0 == "otto" ? "chat-otto" : nil }
        _ = try await store.projects(for: "otto")
        #expect(store.botFolders == ["otto": "/home/me/otto"])
        #expect(store.newChatEntries().map(\.label) == ["Books", "site"])
        let reads = client.restCalls.filter { $0.path == "/api/sessions/chat-otto" }
        #expect(reads.count == 1 && reads[0].query.first { $0.name == "profile" }?.value == "otto")
        // Asked once per run, not with every read of the projects.
        _ = try await store.projects(for: "otto")
        #expect(client.restCalls.filter { $0.path == "/api/sessions/chat-otto" }.count == 1)
        // [own-folder-everywhere] Filter › Project and the Sessions groups leave it out too (a tester, 2026-11-21: it
        // was still a project there on build 1166).
        #expect(store.projectEntries().map(\.label) == ["Books", "site", "Home"])
        store.stop()
        RosterDiskWriter.shared.flush()
        // Kept for the next launch: right at the first paint, before anything is read.
        let next = await self.store(self.client(), dir: dir)
        #expect(next.botFolders == ["otto": "/home/me/otto"])
        next.stop()
    }

    @Test func nothingIsAskedWithoutAFoundFolderOrABotChat() async throws {
        let onlySaved = client(tree: ["projects": [["id": "p1", "label": "Books", "path": "/home/me/books", "repos": []]]])
        let first = await store(onlySaved)
        first.botChatId = { _ in "chat-otto" }
        _ = try await first.projects(for: "otto")
        #expect(onlySaved.restCalls.filter { $0.path.hasPrefix("/api/sessions/") }.isEmpty, "only saved projects: nothing to tell apart")
        first.stop()

        let noChat = client()
        let second = await store(noChat)
        second.botChatId = { _ in nil }
        _ = try await second.projects(for: "otto")
        #expect(noChat.restCalls.filter { $0.path.hasPrefix("/api/sessions/") }.isEmpty)
        #expect(second.newChatEntries().map(\.label) == ["Books", "otto", "site"], "no chat of its own yet: its folders stay, as folders")
        #expect(second.newChatEntries().map(\.isFolder) == [false, true, true])
        second.stop()
    }

    @Test func aFailedOrEmptyReadKeepsWhatWasKnownAndAsksAgain() async throws {
        let client = client(cwd: .null)
        let store = await store(client)
        store.botChatId = { _ in "chat-missing" }
        store.noteBotFolder("/home/me/otto", profile: "otto")
        _ = try await store.projects(for: "otto")
        _ = try await store.projects(for: "otto")
        #expect(client.restCalls.filter { $0.path == "/api/sessions/chat-missing" }.count == 2, "a read that failed is asked again")
        #expect(store.botFolders == ["otto": "/home/me/otto"])
        store.botChatId = { _ in "chat-otto" }
        _ = try await store.projects(for: "otto")
        #expect(store.botFolders == ["otto": "/home/me/otto"], "a record with no folder changes nothing")
        store.stop()
    }

    // MARK: Every bot's own folder, everywhere (a tester, 2026-11-21, build 1166)

    nonisolated private static func tree(_ paths: [String], saved: [(String, String, String)] = []) -> JSONValue {
        let found: [JSONValue] = paths.map { path in
            ["id": .string(path), "label": .string((path as NSString).lastPathComponent), "path": .string(path), "isAuto": true, "repos": []]
        }
        let made: [JSONValue] = saved.map { id, label, path in ["id": .string(id), "label": .string(label), "path": .string(path), "repos": []] }
        return ["projects": .array(made + found)]
    }

    /// The report: Iris has no folder of her own; Dario, Ksiegowy and Zygi each work in a folder outside Hermes's own
    /// (their `terminal.cwd`), and their cron and subagent runs made a found group of it. None of them is a project or
    /// a folder anywhere, whichever bot New Chat has picked, and a checkout one of them found stays a folder.
    @Test func noBotsOwnFolderIsAProjectOrAFolderAnywhere() async throws {
        let client = client(configs: ["dario": "/home/me/dario", "ksiegowy": "/home/me/ksiegowy/", "zygi": "~/zygi"],
                            trees: ["iris": ["projects": []],
                                    "dario": Self.tree(["/home/me/dario", "/home/me/hermes-agent"]),
                                    "ksiegowy": Self.tree(["/home/me/ksiegowy"]),
                                    "zygi": Self.tree(["/home/me/zygi"])])
        let store = await store(client)
        store.botChatId = { _ in nil }      // their own chats record no folder (cwd NULL)
        for bot in ["iris", "dario", "ksiegowy", "zygi"] { _ = try await store.projects(for: bot) }
        #expect(store.botConfigFolders == ["dario": "/home/me/dario", "ksiegowy": "/home/me/ksiegowy", "zygi": "~/zygi"])
        #expect(store.newChatEntries().map(\.label) == ["hermes-agent"])
        #expect(store.newChatEntries().allSatisfy { $0.isFolder })
        // Sessions › Projects (Filter › Project, Group By Project): no bot's folder.
        #expect(store.projectEntries().map(\.label) == ["hermes-agent", "Home"])
        #expect(store.projectEntries(bot: "dario").map(\.label) == ["hermes-agent", "Home"])
        #expect(store.projectEntries(bot: "ksiegowy").isEmpty, "only Home left: no Project submenu")
        // One bot's chats in one place: in its folder (older chats) or with no folder (newer ones), both under Home.
        let byProfile = store.projectsByProfile
        for cwd in ["/home/me/dario", "/home/me/dario/", nil] as [String?] {
            #expect(SessionProjects.key(cwd: cwd, profile: "dario", projectsByProfile: byProfile) == SessionProjects.homeKey)
        }
        #expect(SessionProjects.key(cwd: "/home/me/zygi", profile: "zygi", projectsByProfile: byProfile) == SessionProjects.homeKey)
        #expect(SessionProjects.key(cwd: "/home/me/hermes-agent", profile: "dario", projectsByProfile: byProfile) == "/home/me/hermes-agent")
        // Each bot's config is read once (Iris has no found group: nothing to tell apart); no bot's chat was asked for.
        #expect(client.restCalls.filter { $0.path == "/api/config" && $0.query.first?.value == "dario" }.count == 1)
        #expect(client.restCalls.filter { $0.path.hasPrefix("/api/sessions/") }.isEmpty)
        store.stop()
    }

    /// A project someone saved on a bot's folder stays a project.
    @Test func aSavedProjectOnABotsFolderStays() async throws {
        let client = client(configs: ["dario": "/home/me/dario"],
                            trees: ["dario": Self.tree(["/home/me/dario"], saved: [("p1", "Dario’s Desk", "/home/me/dario")])])
        let store = await store(client)
        store.botChatId = { _ in nil }
        _ = try await store.projects(for: "dario")
        #expect(store.projectEntries().map(\.label) == ["Dario’s Desk", "Home"])
        #expect(store.newChatEntries() == [SessionProjectEntry(key: "/home/me/dario", label: "Dario’s Desk")])
        store.stop()
    }

    /// A folder learned after the projects were kept takes them out at once, from every bot; it is kept for the next
    /// launch, which starts without them before anything is read.
    @Test func aFolderLearnedLaterLeavesEveryBotsProjectsAndIsKept() async throws {
        let dir = BotsTest.tempDirectory()
        let client = client(trees: ["dario": Self.tree(["/home/me/dario", "/home/me/site"]), "iris": Self.tree(["/home/me/dario"])])
        let store = await store(client, dir: dir)
        store.botChatId = { _ in nil }
        _ = try await store.projects(for: "dario")
        _ = try await store.projects(for: "iris")
        #expect(store.projectEntries().map(\.label) == ["dario", "site", "Home"], "unset terminal.cwd: nothing known yet")
        store.noteConfigFolder("/home/me/dario", profile: "dario")
        #expect(store.projectEntries().map(\.label) == ["site", "Home"])
        #expect(store.projectsByProfile["iris"] == [], "another bot's run in Dario's folder is not a project of Iris's either")
        store.stop()
        RosterDiskWriter.shared.flush()
        let next = await self.store(self.client(), dir: dir)
        #expect(next.botConfigFolders == ["dario": "/home/me/dario"])
        #expect(next.projectEntries().map(\.label) == ["site", "Home"])
        next.stop()
    }

    @Test func aConfigsPlaceholderIsNoFolder() {
        for value in [nil, "", ".", "auto", "cwd", "~", "~/", "/", "work", "./dario"] as [String?] {
            #expect(SessionProjects.configFolder(value) == nil, "\(value ?? "nil")")
        }
        #expect(SessionProjects.configFolder(" /home/me/dario/ ") == "/home/me/dario")
        #expect(SessionProjects.configFolder("~/dario") == "~/dario")
    }

    @Test func aHomeFolderPathMatchesUnderAnyHome() {
        #expect(SessionProjects.isFolder("/home/me/dario", "~/dario"))
        #expect(SessionProjects.isFolder("/Users/me/dario/", "~/dario"))
        #expect(SessionProjects.isFolder("/root/dario", "~/dario"))
        #expect(!SessionProjects.isFolder("/home/me/work/dario", "~/dario"))
        #expect(!SessionProjects.isFolder("/home/me/xdario", "~/dario"))
        #expect(!SessionProjects.isFolder("/srv/dario", "~/dario"))
        #expect(SessionProjects.isFolder("/home/me/dario", "/home/me/dario/"))
        #expect(!SessionProjects.isFolder("/home/me/dario/sub", "/home/me/dario"))
    }

    /// Any bot's home is no project; a folder made inside one, and a saved project there, are.
    @Test func everyBotsHomeLeavesAndOnlyFoundGroups() {
        let tree: [String: [SessionProject]] = [
            "iris": [Self.auto("/home/me/.hermes/profiles/otto"), Self.auto("/home/me/.hermes"), Self.auto("/home/me/.hermes/profiles/otto/notes"),
                     Self.saved("p1", "Otto Home", "/home/me/.hermes/profiles/juno"), Self.auto("/home/me/code/site")],
        ]
        let kept = SessionProjects.droppingOwnFolders(tree, ownFolders: [])
        #expect(kept["iris"]?.map(\.root) == ["/home/me/.hermes/profiles/otto/notes", "/home/me/.hermes/profiles/juno", "/home/me/code/site"])
    }

    /// A config read that fails is asked again with the next read of the projects; one that answers is not, for a while.
    @Test func aFailedConfigReadIsAskedAgain() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, path, _, _ in
            if path == "/api/profiles/sessions/sidebar" { return SessionActionsTests.sidebar([]) }
            throw HTTPError(status: 503, body: nil)
        }
        client.on("projects.tree") { _ in Self.tree(["/home/me/dario"]) }
        let store = await store(client)
        store.botChatId = { _ in nil }
        _ = try await store.projects(for: "dario")
        _ = try await store.projects(for: "dario")
        #expect(client.restCalls.filter { $0.path == "/api/config" }.count == 2)
        #expect(store.projectEntries().map(\.label) == ["dario", "Home"], "nothing known: the group stays")
        store.stop()
    }
}
