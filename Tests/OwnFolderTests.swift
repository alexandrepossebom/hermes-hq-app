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

    private func client(cwd: JSONValue = "/home/me/otto", tree: JSONValue? = nil) -> BotsFakeGatewayClient {
        let client = BotsFakeGatewayClient()
        client.onREST { method, path, _, _ in
            if path == "/api/profiles/sessions/sidebar" { return SessionActionsTests.sidebar([]) }
            if method == "GET", path == "/api/sessions/chat-otto" {
                return try (["id": "chat-otto", "title": "Bot Chat", "cwd": cwd] as JSONValue).encoded()
            }
            throw HTTPError(status: 404, body: nil)
        }
        let answer = tree ?? ["projects": [["id": "/home/me/otto", "label": "otto", "path": "/home/me/otto", "isAuto": true, "repos": []],
                                           ["id": "/home/me/code/site", "label": "site", "path": "/home/me/code/site", "isAuto": true, "repos": []],
                                           ["id": "p1", "label": "Books", "path": "/home/me/books", "repos": []]]]
        client.on("projects.tree") { _ in answer }
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
        // The list Filter › Project and the Sessions groups use is as it was.
        #expect(store.projectEntries().map(\.label) == ["Books", "otto", "site", "Home"])
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
}
