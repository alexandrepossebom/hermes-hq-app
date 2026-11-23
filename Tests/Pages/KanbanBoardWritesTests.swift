// [kanban-boards] Owner 2026-11-22: "There are some on there that I’d like to delete or rename and I can’t." Rename and
// Delete Board: the wire each sends, what the list shows while it is on its way and after a refusal, and where the page
// goes when the board on screen is deleted.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@MainActor
struct KanbanBoardWritesTests {
    /// A gateway with `release-2-4` (current), `home` and `default`; PATCH renames, DELETE removes (default refused).
    nonisolated static func gateway(refuse: String? = nil) -> PagesFakeClient {
        let names = Mutex<[(slug: String, name: String)]>([("release-2-4", "Release 2.4"), ("home", "Home"), ("default", "default")])
        let current = Mutex("release-2-4")
        return PagesFakeClient { request in
            let boards = "/api/plugins/kanban/boards"
            switch (request.method, request.path) {
            case ("GET", boards):
                let rows = names.withLock { $0 }.map { row -> JSONValue in
                    ["slug": .string(row.slug), "name": .string(row.name), "total": 2, "is_current": .bool(row.slug == current.withLock { $0 })]
                }
                return ["boards": .array(rows), "current": .string(current.withLock { $0 })]
            case ("GET", "/api/plugins/kanban/board"):
                return KanbanStoreTests.boardJSON([("t_a", "A", "todo")])
            case ("PATCH", _) where request.path.hasPrefix(boards + "/"):
                if let refuse { throw httpError(400, refuse) }
                let slug = String(request.path.dropFirst(boards.count + 1))
                let name = request.body?["name"]?.string ?? ""
                names.withLock { list in
                    if let i = list.firstIndex(where: { $0.slug == slug }) { list[i].name = name }
                }
                return ["board": ["slug": .string(slug), "name": .string(name)]]
            case ("DELETE", _) where request.path.hasPrefix(boards + "/"):
                if let refuse { throw httpError(400, refuse) }
                let slug = String(request.path.dropFirst(boards.count + 1))
                names.withLock { $0.removeAll { $0.slug == slug } }
                if current.withLock({ $0 }) == slug { current.withLock { $0 = "default" } }
                return ["result": ["slug": .string(slug), "action": "archived"], "current": .string(current.withLock { $0 })]
            default:
                return ["ok": true]
            }
        }
    }

    @Test func renameSendsTheTrimmedNameToTheBoardsOwnPathAndTheListShowsIt() async throws {
        let client = Self.gateway()
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil)
        await store.readBoards()
        #expect(await store.renameBoard("home", to: "  House chores ") == nil)
        let patch = try #require(client.log.first { $0.method == "PATCH" })
        #expect(patch.path == "/api/plugins/kanban/boards/home")
        #expect(patch.body == ["name": "House chores"])
        #expect(store.boards?.boards.first { $0.slug == "home" }?.name == "House chores")
    }

    @Test func renamingTheServersCurrentBoardNamesItsSlug() async throws {
        let client = Self.gateway()
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil)
        await store.readBoards()
        #expect(store.boardKey == "release-2-4")
        #expect(await store.renameBoard("", to: "Release 2.5") == nil)
        #expect(client.log.first { $0.method == "PATCH" }?.path == "/api/plugins/kanban/boards/release-2-4")
        #expect(store.boardTitle == "Release 2.5")
    }

    @Test func aRefusedRenamePutsTheOldNameBackAndSaysWhy() async throws {
        let client = Self.gateway(refuse: "The board is busy.")
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil)
        await store.readBoards()
        #expect(await store.renameBoard("home", to: "House") == "The board is busy.")
        #expect(store.boards?.boards.first { $0.slug == "home" }?.name == "Home")
    }

    @Test func deleteRemovesAnotherBoardAndLeavesThePageWhereItIs() async throws {
        let client = Self.gateway()
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil)
        await store.readBoards()
        await store.readBoard()
        #expect(await store.deleteBoard("home") == nil)
        let delete = try #require(client.log.first { $0.method == "DELETE" })
        #expect(delete.path == "/api/plugins/kanban/boards/home")
        #expect(delete.query["delete"] == nil, "archived (recoverable), never the hard delete")
        #expect(store.boards?.boards.map(\.slug) == ["release-2-4", "default"])
        #expect(store.boardKey == "release-2-4")
    }

    @Test func deletingThePickedBoardGoesToTheServersCurrentOne() async throws {
        let client = Self.gateway()
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil)
        UserDefaults.standard.removeObject(forKey: KanbanStore.slugKey(client.account))
        defer { UserDefaults.standard.removeObject(forKey: KanbanStore.slugKey(client.account)) }
        await store.readBoards()
        store.select(board: "home")
        #expect(store.boardKey == "home")
        #expect(await store.deleteBoard("home") == nil)
        #expect(store.slug == "")
        #expect(store.boardKey == "release-2-4")
    }

    @Test func deletingTheServersCurrentBoardFallsBackToDefault() async throws {
        let client = Self.gateway()
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil)
        UserDefaults.standard.removeObject(forKey: KanbanStore.slugKey(client.account))
        defer { UserDefaults.standard.removeObject(forKey: KanbanStore.slugKey(client.account)) }
        await store.readBoards()
        #expect(await store.deleteBoard("") == nil)
        #expect(client.log.first { $0.method == "DELETE" }?.path == "/api/plugins/kanban/boards/release-2-4")
        #expect(store.boardKey == "default")
        #expect(store.board != nil, "the default board is read")
    }

    @Test func theDefaultBoardIsNeverSentADelete() async throws {
        let client = Self.gateway()
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil)
        await store.readBoards()
        #expect(await store.deleteBoard("default") == KanbanModel.defaultBoardKept)
        #expect(!client.log.contains { $0.method == "DELETE" })
        #expect(!KanbanModel.canDelete("default") && !KanbanModel.canDelete("") && KanbanModel.canDelete("home"))
    }

    @Test func aRefusedDeleteBringsTheBoardBack() async throws {
        let client = Self.gateway(refuse: "board 'home' does not exist")
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil)
        await store.readBoards()
        #expect(await store.deleteBoard("home") == "board 'home' does not exist")
        #expect(store.boards?.boards.contains { $0.slug == "home" } == true)
    }

    @Test func aReadOnlyGatewaySendsNoBoardWrites() async throws {
        let client = Self.gateway()
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil)
        store.readOnlyGateway = true
        await store.readBoards()
        #expect(await store.renameBoard("home", to: "House") == JobsStore.readOnlyNotice)
        #expect(await store.deleteBoard("home") == JobsStore.readOnlyNotice)
        #expect(!client.log.contains { $0.method == "PATCH" || $0.method == "DELETE" })
    }

    @Test func theDeleteConfirmationSaysWhatGoesAndThatACopyIsKept() {
        #expect(KanbanModel.deleteBoardMessage(title: "Home", total: 3)
                == "“Home” leaves Kanban on every device. Its 3 tasks go with it. Hermes keeps an archived copy on your gateway computer.")
        #expect(KanbanModel.deleteBoardMessage(title: "Home", total: 1).contains("Its 1 task goes with it."))
        #expect(KanbanModel.deleteBoardMessage(title: "Home", total: 0).contains("It has no tasks."))
    }
}
