// [project-default-bot] The bot a project's New Chat starts with.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ProjectDefaultBotTests {
    private let bots = ["default", "research", "deploys"]

    @Test func theChosenBotStartsTheChat() {
        #expect(ProjectDefaultBot.resolve(stored: "research", own: ["default"], bots: bots) == "research")
        #expect(ProjectDefaultBot.resolve(stored: "research", own: ["default", "deploys"], bots: bots) == "research")
    }

    @Test func askEveryTimeAsksEvenWithOneBot() {
        #expect(ProjectDefaultBot.resolve(stored: ProjectDefaultBot.ask, own: ["default"], bots: bots) == nil)
    }

    @Test func nothingChosenUsesTheProjectsOnlyBot() {
        #expect(ProjectDefaultBot.resolve(stored: nil, own: ["research"], bots: bots) == "research")
    }

    @Test func nothingChosenAsksWhenSeveralBotsShareTheProjectOrNoneHasIt() {
        #expect(ProjectDefaultBot.resolve(stored: nil, own: ["default", "research"], bots: bots) == nil)
        #expect(ProjectDefaultBot.resolve(stored: nil, own: [], bots: bots) == nil)
    }

    @Test func aChosenBotThatIsGoneFallsBack() {
        #expect(ProjectDefaultBot.resolve(stored: "gone", own: ["default"], bots: bots) == "default")
        #expect(ProjectDefaultBot.resolve(stored: "gone", own: ["default", "research"], bots: bots) == nil)
    }

    @Test @MainActor func projectPRCountsUseVerifiedProjectRowsAndDeduplicate() {
        let projects = ["default": [SessionProject(id: "a", label: "A", root: "/a", paths: ["/a"]),
                                     SessionProject(id: "b", label: "B", root: "/b", paths: ["/b"])]]
        func row(_ id: String, _ cwd: String, _ state: SessionPRStatus.State?) -> SessionSummary {
            var row = SessionSummary(id: id, profile: "default", title: id, preview: nil, lastActive: nil,
                                     source: nil, unread: false, isRunning: false)
            row.cwd = cwd
            row.pullRequest = state.map { SessionPRStatus(state: $0) }
            return row
        }
        var archived = row("merged", "/a", .merged); archived.archived = true
        let rows = [row("none", "/a", SessionPRStatus.State.none), row("open", "/a/sub", .open), archived, archived,
                    row("other", "/b", .open), row("unknown", "/a", .unknown), row("unqueried", "/a", nil),
                    row("draft", "/a", .draft), row("closed", "/a", .closed)]
        let counts = ProjectPageHeader.pullRequestCounts(rows, project: "/a", projects: projects)
        for state in [SessionPRStatus.State.none, .draft, .open, .merged, .closed] { #expect(counts[state] == 1) }
        #expect(counts[.unknown] == nil)
        #expect(ProjectPageHeader.pullRequestCounts(rows, project: "/b", projects: projects)[.open] == 1)
    }

    @Test func codingProjectPreferencesDecodeOlderAndRetainExplicitOff() throws {
        let old = try JSONDecoder().decode(SessionsDeviceState.self, from: Data("{}".utf8))
        #expect(old.codingProjects.isEmpty)
        var state = SessionsDeviceState()
        state.codingProjects = ["/a": true, "/b": false]
        let saved = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(SessionsDeviceState.self, from: saved).codingProjects == state.codingProjects)
    }

    @Test @MainActor func codingPreferenceIsScopedAndSyncsExplicitOff() {
        let dir = BotsTest.tempDirectory()
        func store(_ account: GatewayAccount) -> SessionStore {
            SessionStore(client: BotsFakeGatewayClient(), account: account, cacheDirectory: dir, timing: .fast, autoStart: false)
        }
        let first = store(.botsTestAccount)
        first.setCodingProject("/a", true)
        RosterDiskWriter.shared.flush()
        #expect(first.isCodingProject("/a") && !first.isCodingProject("/b"))
        #expect(store(.botsTestAccount).isCodingProject("/a"))
        var otherAccount = GatewayAccount.botsTestAccount
        otherAccount.id += "-other"
        #expect(!store(otherAccount).isCodingProject("/a"))
        let synced = first.syncValue()
        #expect(synced["codingProjects"]?["/a"]?.bool == true)
        first.setCodingProject("/a", false)
        first.adoptSynced(synced, merge: .rebase, base: nil)
        #expect(!first.isCodingProject("/a"))
        #expect(first.syncValue()["codingProjects"]?["/a"]?.bool == false)
        first.adoptSynced(synced, merge: .replace, base: nil)
        #expect(first.isCodingProject("/a"))
        first.adoptSynced(["sortBy": "updated"], merge: .replace, base: nil)
        #expect(first.isCodingProject("/a"), "old sync documents do not erase the setting")
    }
}
