import Foundation
import Testing
@testable import HermesHQNative

/// [pinned-only] Owner 2026-11-22: "I'd like to have the ability to pin only certain bots to the sidebar on Mac". The
/// Mac sidebar's Pinned Bots Only (`BotList.pinnedOnly`): the pins, and any other bot or group chat only while it
/// wants the person or is the chat on show.
@Suite struct BotPinnedOnlyTests {
    private func bot(_ id: String, pinned: Bool = false, working: Bool = false, unread: Bool = false, hidden: Bool = false) -> Bot {
        Bot(id: id, name: id.capitalized, role: nil, preview: nil, lastActive: nil, isWorking: working, unread: unread, pinned: pinned,
            pinOrder: nil, sectionName: nil, hidden: hidden, canonicalSessionId: nil, head: nil)
    }

    private func room(_ name: String, pinned: Bool = false, unread: Bool = false, running: Bool = false) -> GroupRowModel {
        GroupRowModel(id: "id:\(name)", name: name, image: nil, faces: [], line: "2 bots", tone: .secondary, time: nil, unread: unread,
                      pinned: pinned, muted: false, memberCount: 2, running: running, sectionId: nil, order: nil, pinnedAt: nil, lastAt: 0,
                      search: name.lowercased(), online: true)
    }

    private func names(_ sections: [BotListSection]) -> [[String]] { sections.map { $0.bots.map(\.id) + $0.rooms.map(\.name) } }

    @Test func onlyThePinsAreLeft() {
        let sections = [
            BotListSection(id: .tiles, title: nil, bots: [bot("ivy", pinned: true), bot("wren", pinned: true)]),
            BotListSection(id: .pinned, title: "Pinned", bots: [bot("seven", pinned: true)], rooms: [room("club", pinned: true)]),
            BotListSection(id: .user("s1"), title: "Work", bots: [bot("a"), bot("b")], rooms: [room("standup")]),
            BotListSection(id: .user("s2"), title: "Empty", bots: []),
            BotListSection(id: .unassigned, title: nil, bots: [bot("c")]),
            BotListSection(id: .groups, title: "Group Chats", bots: [], rooms: [room("family")]),
        ]
        let kept = BotList.pinnedOnly(sections)
        #expect(kept.map(\.id) == [.tiles, .pinned], "a block with no pin is left out, an empty section too")
        #expect(names(kept) == [["ivy", "wren"], ["seven", "club"]])
        #expect(kept[1].title == "Pinned", "a block that stays keeps its heading")
    }

    @Test func aBotThatWantsYouIsStillListed() {
        var waiting = bot("asks")
        waiting.needsInput = .approval
        let sections = [
            BotListSection(id: .tiles, title: nil, bots: [bot("ivy", pinned: true)]),
            BotListSection(id: .user("s1"), title: "Work", bots: [bot("idle"), bot("busy", working: true), bot("said", unread: true), waiting],
                           rooms: [room("quiet"), room("loud", unread: true), room("going", running: true)]),
            BotListSection(id: .unassigned, title: nil, bots: [bot("rest")]),
        ]
        let kept = BotList.pinnedOnly(sections)
        #expect(kept.map(\.id) == [.tiles, .user("s1")])
        #expect(names(kept)[1] == ["busy", "said", "asks", "loud", "going"], "in the block's own order")
        // Read, and done: gone again.
        #expect(BotList.pinnedOnly([sections[0], BotListSection(id: .user("s1"), title: "Work", bots: [bot("idle"), bot("busy"), bot("said")])])
            .map(\.id) == [.tiles])
    }

    @Test func theChatOnShowKeepsItsBot() {
        let sections = [
            BotListSection(id: .tiles, title: nil, bots: [bot("ivy", pinned: true)]),
            BotListSection(id: .unassigned, title: nil, bots: [bot("a"), bot("b")], rooms: [room("club")]),
        ]
        #expect(names(BotList.pinnedOnly(sections, open: ["b"])) == [["ivy"], ["b"]])
        #expect(names(BotList.pinnedOnly(sections, open: ["id:club"])) == [["ivy"], ["club"]])
        #expect(names(BotList.pinnedOnly(sections, open: ["gone"])) == [["ivy"]])
    }

    /// A pin drawn outside the pins' blocks (Group By › None's one list, a pinned room among Group Chats) stays.
    @Test func aPinInAnotherBlockStays() {
        let sections = [BotListSection(id: .everything, title: nil, bots: [bot("a"), bot("ivy", pinned: true)], rooms: [room("club", pinned: true), room("x")])]
        #expect(names(BotList.pinnedOnly(sections)) == [["ivy", "club"]])
    }

    @Test func hiddenIsItsOwnSwitch() {
        let sections = [
            BotListSection(id: .tiles, title: nil, bots: [bot("ivy", pinned: true)]),
            BotListSection(id: .unassigned, title: nil, bots: [bot("a")]),
            BotListSection(id: .hidden, title: "Hidden", bots: [bot("h", hidden: true)]),
        ]
        #expect(BotList.pinnedOnly(sections).map(\.id) == [.tiles, .hidden], "Show Hidden Bots decides whether Hidden is drawn")
    }

    /// With nothing pinned there is nothing to narrow the list to: an empty sidebar would read as no bots at all.
    @Test func nothingPinnedShowsEveryBot() {
        let sections = [
            BotListSection(id: .user("s1"), title: "Work", bots: [bot("a")]),
            BotListSection(id: .unassigned, title: nil, bots: [bot("b")], rooms: [room("club")]),
            BotListSection(id: .hidden, title: "Hidden", bots: [bot("h", pinned: true, hidden: true)]),
        ]
        #expect(BotList.pinnedOnly(sections) == sections, "a hidden pin is not one the sidebar shows")
    }
}
