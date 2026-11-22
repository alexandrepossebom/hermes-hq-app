// [project-mute] A project's Notifications: which kinds each level lets sound, the list the extension reads, and the
// app's side that rewrites it.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ProjectMutesTests {
    private let levels: ProjectMutes.Levels = ["acct": ["s-needs": .needsMe, "s-mute": .mute]]

    @Test func onlyWhenItNeedsMeQuietsFinishedReplies() {
        for kind in ["message.complete", "turnDone", "backgroundDone"] {
            #expect(!ProjectMutes.allows(kind: kind, account: "acct", session: "s-needs", levels: levels), "\(kind) is quieted")
        }
        for kind in ["approval.request", "approval", "input", "turnError", "credits", "plugin", ""] {
            #expect(ProjectMutes.allows(kind: kind, account: "acct", session: "s-needs", levels: levels), "\(kind) still notifies")
        }
    }

    @Test func muteKeepsOnlyApprovalsAndQuestions() {
        for kind in ["message.complete", "turnDone", "backgroundDone", "turnError", "plugin", "task", ""] {
            #expect(!ProjectMutes.allows(kind: kind, account: "acct", session: "s-mute", levels: levels), "\(kind) is quieted")
        }
        for kind in ["approval.request", "approval", "input"] {
            #expect(ProjectMutes.allows(kind: kind, account: "acct", session: "s-mute", levels: levels), "\(kind) still notifies")
        }
    }

    @Test func aChatNotListedIsOnAll() {
        for kind in ["turnDone", "turnError", "approval"] {
            #expect(ProjectMutes.allows(kind: kind, account: "acct", session: "s-new", levels: levels), "a chat this device has not seen")
            #expect(ProjectMutes.allows(kind: kind, account: "other", session: "s-mute", levels: levels), "another gateway's chat")
            #expect(ProjectMutes.allows(kind: kind, account: "acct", session: "", levels: levels), "an alert about no chat")
            #expect(ProjectMutes.allows(kind: kind, account: "", session: "s-mute", levels: levels))
        }
        #expect(ProjectMutes.level(account: "acct", session: "s-mute", levels: levels) == .mute)
    }

    @Test func theListIsStoredAndOneAccountsPartReplaced() {
        #expect(ProjectMutes.decode(ProjectMutes.encode(levels)) == levels)
        #expect(ProjectMutes.encode([:]) == nil && ProjectMutes.decode(nil).isEmpty && ProjectMutes.decode(Data("junk".utf8)).isEmpty)
        let both = ProjectMutes.replacing(levels, account: "other", with: ["x": .mute, "y": .all, "": .mute])
        #expect(both["other"] == ["x": .mute], "All and a chat without an id are not kept")
        #expect(both["acct"] == levels["acct"], "the other gateway's part is left alone")
        #expect(ProjectMutes.replacing(both, account: "acct", with: [:]) == ["other": ["x": .mute]])
        #expect(ProjectNotify.allCases.map(\.title) == ["All", "Only When It Needs Me", "Mute"])
    }
}

@MainActor @Suite(.serialized) struct ProjectMuteCenterTests {
    final class Memory: @unchecked Sendable { var data: Data?; var saves = 0 }

    private func center(_ memory: Memory, account: String? = "acct") -> ProjectMuteCenter {
        let center = ProjectMuteCenter(storage: .init(load: { memory.data }, save: { memory.data = $0; memory.saves += 1 }))
        center.account = { account }
        return center
    }

    @Test func theAppRewritesItsGatewaysPartAndAsksIt() {
        let memory = Memory()
        let a = center(memory)
        #expect(a.allows(kind: "message.complete", session: "s1"))
        a.update(["s1": .needsMe, "s2": .mute])
        #expect(memory.saves == 1 && !a.allows(kind: "message.complete", session: "s1") && a.allows(kind: "approval.request", session: "s1"))
        #expect(!a.allows(kind: "turnError", session: "s2") && a.allows(kind: "input", session: "s2"))
        #expect(a.allows(kind: "message.complete", session: "s3"), "a chat not seen yet")
        a.update(["s1": .needsMe, "s2": .mute])
        #expect(memory.saves == 1, "the same list is not written again")
        // The extension reads what the app saved; another gateway's app leaves this part alone.
        #expect(ProjectMutes.decode(memory.data) == ["acct": ["s1": .needsMe, "s2": .mute]])
        let b = center(memory, account: "acct-b")
        #expect(b.allows(kind: "message.complete", session: "s1"), "the same id on another gateway")
        b.update(["s9": .mute])
        #expect(ProjectMutes.decode(memory.data) == ["acct": ["s1": .needsMe, "s2": .mute], "acct-b": ["s9": .mute]])
        b.update([:])
        #expect(ProjectMutes.decode(memory.data) == ["acct": ["s1": .needsMe, "s2": .mute]])
        let none = center(memory, account: nil)
        none.update(["s1": .mute])
        #expect(none.allows(kind: "message.complete", session: "s1") && memory.saves == 3, "signed out: nothing asked, nothing written")
    }

    /// The store names the chats of the projects that are not on All, by stored id, archived ones too.
    @Test func theStoreListsTheQuietProjectsChats() {
        let store = SessionStore(client: BotsFakeGatewayClient(), account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(),
                                 timing: .fast, autoStart: false)
        #expect(store.projectMuteLevels.isEmpty)
        store.setProjectNotify("/a", .mute)
        store.setProjectNotify("/b", .all)
        #expect(store.projectMuteLevels.isEmpty, "no chat known yet")
        // Two chats in no project: Home's level names them, by stored id; back on All, none.
        store.recents = [SidebarSessionRow(id: "s1", profile: "ivy", title: "One", lastActive: 100, messageCount: 2),
                         SidebarSessionRow(id: "s2", profile: "otto", title: "Two", lastActive: 90, messageCount: 2)]
        store.rebuild()
        #expect(store.projectMuteLevels.isEmpty, "they are in Home, which is on All")
        store.setProjectNotify(SessionProjects.homeKey, .needsMe)
        #expect(store.projectMuteLevels == ["s1": .needsMe, "s2": .needsMe])
        store.setProjectNotify(SessionProjects.homeKey, .all)
        #expect(store.projectMuteLevels.isEmpty)
    }
}
