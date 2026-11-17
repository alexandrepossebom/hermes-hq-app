import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@Suite(.serialized) @MainActor struct SessionTitleOrderingTests {
    @Test func sessionsListRenameWinsOverLiveAutomaticSave() async throws {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        let gate = MenusGate()
        let saved = Mutex("")
        let typed = "My deliberate database investigation"
        f.script.on("session.title") { p, _ in
            await gate.wait()
            saved.withLock { $0 = p["title"]?.string ?? "" }
            return ["title": p["title"] ?? ""]
        }
        f.client.onRest { _, _ in
            saved.withLock { $0 = typed }
            return try JSONSerialization.data(withJSONObject: ["title": typed])
        }
        f.session.receiveAutomaticTitle("Title: Database connection pool troubleshooting guide")
        #expect(await waitUntil { f.params("session.title").count == 1 })
        let store = SessionStore(client: f.client, account: f.session.account,
                                 cacheDirectory: BotsTest.tempDirectory(), autoStart: false)
        let row = SessionSummary(id: f.session.storedSessionId!, profile: f.session.profile, title: "New Chat",
                                 preview: nil, lastActive: nil, source: nil, unread: false, isRunning: true)
        let edit = Task { try await store.rename(row, to: typed) }
        #expect(await waitUntil { f.session.title == typed || saved.withLock { $0 == typed } })
        gate.release()
        #expect(try await edit.value == typed)
        await f.session.automaticTitleSave?.value
        #expect(saved.withLock { $0 } == typed)
        #expect(f.session.title == typed)
        f.session.receiveAutomaticTitle("Other generated title")
        #expect(f.session.title == typed)
    }

    @Test func failedRenameReconsidersAnAutomaticEventReceivedWhileSaving() async {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        let gate = MenusGate()
        f.script.on("session.title") { p, attempt in
            if attempt == 1 {
                await gate.wait()
                throw RPCError(code: 5000, message: "unavailable", data: nil)
            }
            return ["title": p["title"] ?? ""]
        }
        f.client.onRest { _, _ in throw HTTPError(status: 503, body: "unavailable") }
        let edit = Task { try? await f.session.rename(to: "My manual name") }
        #expect(await waitUntil { f.params("session.title").count == 1 })
        f.session.receiveAutomaticTitle("Title: Database connection pool troubleshooting guide")
        gate.release()
        _ = await edit.value
        await f.session.automaticTitleSave?.value
        #expect(f.session.title == "Database connection pool troubleshooting guide")
        #expect(f.params("session.title").last?["title"]?.string == "Database connection pool troubleshooting guide")
    }

    @Test func lateGatewayNameReplacesReopenedLocalFallback() async {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        f.script.on("session.title") { p, _ in ["title": p["title"] ?? ""] }
        f.session.receiveAutomaticTitle("Repair database", alreadyStored: false)
        await f.session.automaticTitleSave?.value
        let reopened = LiveChatSession(client: f.client, account: f.session.account, profile: f.session.profile,
                                       storedSessionId: f.session.storedSessionId, title: "Repair database", head: nil,
                                       cache: makeTempCache(), resolveSessionId: nil, frameMode: .manual)
        reopened.runtimeSessionId = f.rid1
        reopened.receiveAutomaticTitle("Title: Database connection pool troubleshooting guide")
        await reopened.automaticTitleSave?.value
        #expect(reopened.title == "Database connection pool troubleshooting guide")
        #expect(f.params("session.title").last?["title"]?.string == "Database connection pool troubleshooting guide")
    }

    @Test(arguments: [false, true]) func lateSaveEchoDoesNotReplaceBufferedGatewayImprovement(reopened: Bool) async {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        let gate = MenusGate()
        f.script.on("session.title") { p, attempt in
            if attempt == 1 { await gate.wait() }
            if attempt == 2 { throw RPCError(code: 5000, message: "unavailable", data: nil) }
            return ["title": p["title"] ?? ""]
        }
        f.client.onRest { _, _ in throw HTTPError(status: 503, body: "unavailable") }
        f.session.receiveAutomaticTitle("Repair database", alreadyStored: false)
        #expect(await waitUntil { f.params("session.title").count == 1 })
        let receiver = reopened ? LiveChatSession(client: f.client, account: f.session.account, profile: f.session.profile,
                                                 storedSessionId: f.session.storedSessionId, title: "Repair database", head: nil,
                                                 cache: makeTempCache(), resolveSessionId: nil, frameMode: .manual) : f.session
        receiver.runtimeSessionId = f.rid2
        receiver.connection = .ready
        let edit = Task { try? await receiver.rename(to: "My manual name") }
        #expect(await waitUntil { receiver.title == "My manual name" })
        receiver.receiveAutomaticTitle("Title: Database connection pool troubleshooting guide")
        receiver.receiveAutomaticTitle("Repair database") // the older save's late echo, possibly from another screen
        gate.release()
        _ = await edit.value
        await receiver.automaticTitleSave?.value
        #expect(receiver.title == "Database connection pool troubleshooting guide")
        #expect(f.params("session.title").last?["title"]?.string == "Database connection pool troubleshooting guide")
    }

    @Test func failedListRenameKeepsBufferedNameOnBothSurfaces() async {
        let f = MenusFixtureChat()
        f.session.title = "New Chat"
        let store = SessionStore(client: f.client, account: f.session.account,
                                 cacheDirectory: BotsTest.tempDirectory(), autoStart: false)
        let id = f.session.storedSessionId!
        store.recents = [SidebarSessionRow(id: id, profile: f.session.profile, title: "New Chat", lastActive: 1, messageCount: 2)]
        f.session.menus.onTitleApplied = { store.applyTitle(id: id, title: $0) }
        _ = f.session.titleWrites
        let row = SessionSummary(id: id, profile: f.session.profile, title: "New Chat", preview: nil,
                                 lastActive: nil, source: nil, unread: false, isRunning: false)
        let gate = MenusGate()
        f.client.onRest { _, _ in throw HTTPError(status: 503, body: "unavailable") }
        f.script.on("session.title") { p, attempt in
            if attempt == 1 { await gate.wait() }
            return ["title": p["title"] ?? ""]
        }
        f.session.receiveAutomaticTitle("Repair database", alreadyStored: false)
        #expect(await waitUntil { f.params("session.title").count == 1 })
        let edit = Task { try? await store.rename(row, to: "My manual name") }
        #expect(await waitUntil { f.session.title == "My manual name" })
        f.session.receiveAutomaticTitle("Title: Database connection pool troubleshooting guide")
        gate.release()
        _ = await edit.value
        await f.session.automaticTitleSave?.value
        #expect(f.session.title == "Database connection pool troubleshooting guide")
        #expect(store.storedRow(row)?.title == f.session.title)
    }

    @Test(arguments: [false, true]) func listRenameReachesAnIdleOpenChat(resolvedLater: Bool) async throws {
        let f = MenusFixtureChat()
        if resolvedLater { f.session.storedSessionId = "resolved-chat" }
        let typed = "My deliberate custom name"
        f.client.onRest { _, _ in try JSONSerialization.data(withJSONObject: ["title": typed]) }
        let store = SessionStore(client: f.client, account: f.session.account,
                                 cacheDirectory: BotsTest.tempDirectory(), autoStart: false)
        let row = SessionSummary(id: f.session.storedSessionId!, profile: f.session.profile, title: f.session.title,
                                 preview: nil, lastActive: nil, source: nil, unread: false, isRunning: false)
        #expect(try await store.rename(row, to: typed) == typed)
        #expect(f.session.title == typed)
    }
}
