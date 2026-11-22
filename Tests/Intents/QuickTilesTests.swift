// [quick-actions] The Quick Actions page's pure rules (docs/spec/3x-morepages.md §25, docs/spec/3x-intents.md
// DECISION I22): the stored list, the starter set, missing targets, where each tile goes, and the grid's rows.
import Foundation
import Testing
@testable import HermesHQNative

private func tile(_ kind: QuickTileKind, id: String = UUID().uuidString, bot: String? = nil, wide: Bool = false) -> QuickTile {
    var tile = QuickTile(id: id, kind: kind, wide: wide)
    tile.bot = bot
    tile.botName = bot.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    return tile
}

@Suite struct QuickTileStoreTests {
    // Q7: stored per device, versioned, read back as written.
    @Test func aListIsStoredAndReadBack() {
        let box = IntentsDefaults()
        var list = QuickTileList()
        var chat = tile(.newChat, id: "a", bot: "otto", wide: true)
        chat.project = "/Users/me/site"
        chat.projectName = "Site"
        chat.message = "Morning"
        chat.flag = false
        list.add(chat)
        list.add(tile(.memo, id: "b", bot: "ivy"))
        #expect(QuickTileStore.save(list, box.defaults))
        let back = QuickTileStore.load(box.defaults)
        #expect(back.tiles == list.tiles)
        #expect(back.seeded, "a saved list is never seeded over")
        #expect(!QuickTileStore.save(back, box.defaults), "the same list writes nothing")
        let raw = try? JSONSerialization.jsonObject(with: box.defaults.data(forKey: QuickTileStore.key) ?? Data()) as? [String: Any]
        #expect(raw?["version"] as? Int == QuickTileStore.version)
    }

    // Q13: Short is stored only when set; an entry from before it reads Tall; setShort changes one tile.
    @Test func shortIsStoredAndOlderTilesReadTall() throws {
        let box = IntentsDefaults()
        var list = QuickTileList()
        list.add(tile(.memo, id: "a", bot: "ivy"))
        list.add(tile(.talk, id: "b", bot: "ivy"))
        list.setShort("b", true)
        #expect(QuickTileStore.save(list, box.defaults))
        let back = QuickTileStore.load(box.defaults)
        #expect(back.tiles.map(\.short) == [false, true])
        let raw = try #require(String(data: box.defaults.data(forKey: QuickTileStore.key) ?? Data(), encoding: .utf8))
        #expect(raw.components(separatedBy: "\"short\"").count == 2, "only the Short tile writes the key")
        let old = try JSONDecoder().decode(QuickTile.self, from: Data(#"{"id":"c","kind":"memo","name":"Memo","symbol":"mic.fill","color":"red"}"#.utf8))
        #expect(!old.short)
    }

    // Q7: a kind this build doesn't know, or an entry it can't read, is kept as written and drawn switched off.
    @Test func unknownKindsAndUnreadableEntriesAreKept() throws {
        let box = IntentsDefaults()
        let json = """
        {"version":3,"seeded":true,"tiles":[
          {"id":"a","kind":"memo","name":"Memo","symbol":"mic.fill","color":"red","bot":"ivy"},
          {"id":"b","kind":"teleport","name":"Beam Me","symbol":"sparkles","color":"pink","where":"orbit"},
          {"id":7,"name":"Broken"}
        ]}
        """
        box.defaults.set(Data(json.utf8), forKey: QuickTileStore.key)
        var list = QuickTileStore.load(box.defaults)
        #expect(list.tiles.map(\.name) == ["Memo", "Beam Me", "Broken"])
        #expect(list.tiles[0].known == .memo)
        #expect(list.tiles[1].known == nil && list.tiles[1].kind == "teleport")
        #expect(list.tiles[2].unreadable != nil && list.tiles[2].known == nil)
        #expect(QuickTileRoute.make(list.tiles[1], world: QuickTileWorld()) == .unavailable(QuickTileRules.newerApp))
        #expect(list.tiles[1].subtitle(botName: nil) == "needs a newer app")
        // An edit elsewhere keeps both, the newer build's version and the unreadable entry's own bytes.
        list.setWide("a", true)
        QuickTileStore.save(list, box.defaults)
        let raw = try #require(JSONSerialization.jsonObject(with: box.defaults.data(forKey: QuickTileStore.key) ?? Data()) as? [String: Any])
        #expect(raw["version"] as? Int == 3)
        let tiles = try #require(raw["tiles"] as? [[String: Any]])
        #expect(tiles[2]["id"] as? Int == 7, "written back as it was")
        #expect(tiles[1]["kind"] as? String == "teleport")
        #expect(QuickTileStore.load(box.defaults).tiles.map(\.id).prefix(2) == ["a", "b"])
    }

    // Q7: a list that can't be read at all is never wiped: it is copied aside, and no starter set goes over it.
    @Test func aDecodeErrorNeverWipesTheList() {
        let box = IntentsDefaults()
        let junk = Data("not json".utf8)
        box.defaults.set(junk, forKey: QuickTileStore.key)
        let list = QuickTileStore.load(box.defaults)
        #expect(list.tiles.isEmpty && list.seeded)
        #expect(box.defaults.data(forKey: QuickTileStore.unreadableKey) == junk)
        #expect(!QuickTileStore.listToShow(list, firstBot: ("otto", "Otto")).seeded)
        // Saving later keeps the first copy aside.
        var next = list
        next.add(tile(.search, id: "s"))
        QuickTileStore.save(next, box.defaults)
        #expect(box.defaults.data(forKey: QuickTileStore.unreadableKey) == junk)
        #expect(QuickTileStore.load(box.defaults).tiles.map(\.id) == ["s"])
    }
}

@Suite struct QuickTileSeedingTests {
    // Q8: the starter set, from the roster's first bot.
    @Test func theStarterSetIsMadeForTheFirstBot() {
        let shown = QuickTileStore.listToShow(QuickTileList(), firstBot: ("otto", "Otto"))
        #expect(shown.seeded && shown.list.seeded)
        #expect(shown.list.tiles.map(\.known) == [.memo, .talk, .newChat, .addTask, .search])
        #expect(shown.list.tiles.map(\.name) == ["Memo", "Talk", "New Chat", "Add Task", "Search Chats"])
        #expect(shown.list.tiles.map(\.wide) == [false, false, true, false, false])
        #expect(shown.list.tiles.prefix(3).allSatisfy { $0.bot == "otto" && $0.botName == "Otto" })
        #expect(shown.list.tiles.map { $0.subtitle(botName: nil) } == ["to Otto", "with Otto", "with Otto", "for me", "all chats"])
    }

    // Q8: no bot yet, nothing seeded (and the page shows its empty state); once edited, never seeded again.
    @Test func neverReseededAfterAnEdit() {
        #expect(!QuickTileStore.listToShow(QuickTileList(), firstBot: nil).seeded)
        let box = IntentsDefaults()
        var list = QuickTileStore.listToShow(QuickTileList(), firstBot: ("otto", "Otto")).list
        for id in list.tiles.map(\.id) { list.remove(id) }
        QuickTileStore.save(list, box.defaults)
        let stored = QuickTileStore.load(box.defaults)
        #expect(stored.tiles.isEmpty && stored.seeded)
        #expect(!QuickTileStore.listToShow(stored, firstBot: ("ivy", "Ivy")).seeded)
        #expect(QuickTileStore.listToShow(stored, firstBot: ("ivy", "Ivy")).list.tiles.isEmpty)
    }

    // An older stored list without the flag: tiles mean it was seeded.
    @Test func aListWithoutTheFlagCountsAsSeededWhenItHasTiles() {
        let json = #"{"version":1,"tiles":[{"id":"a","kind":"search","name":"Search Chats","symbol":"magnifyingglass","color":"gray"}]}"#
        #expect(QuickTileStore.decode(Data(json.utf8))?.seeded == true)
        #expect(QuickTileStore.decode(Data(#"{"version":1,"tiles":[]}"#.utf8))?.seeded == false)
    }
}

@Suite struct QuickTileMissingTests {
    private let world = QuickTileWorld(bots: ["otto": "Otto", "herald": "Herald"], jobs: ["otto|brief"], pages: ["files": "Files"])

    // Q9: a bot, job or page not on this gateway: kept, drawn at 40 %, one sentence on a tap.
    @Test func missingTargetsSayOneSentence() {
        #expect(QuickTileRules.missing(tile(.talk, bot: "ivy"), world: world) == "Ivy isn’t on this gateway.")
        var job = tile(.runJob)
        job.job = "wren|nightly"
        job.jobName = "Nightly"
        #expect(QuickTileRules.missing(job, world: world) == "“Nightly” isn’t on this gateway.")
        var page = tile(.page)
        page.page = "terminal"
        page.pageName = "Terminal"
        #expect(QuickTileRules.missing(page, world: world) == "Terminal isn’t on this gateway.")
        #expect(QuickTileRules.missing(tile(.memo), world: world) == "Choose a bot for this action in Edit.")
        #expect(QuickTileRules.missing(tile(.talk, bot: "otto"), world: world) == nil)
        #expect(QuickTileRoute.make(tile(.talk, bot: "ivy"), world: world) == .unavailable("Ivy isn’t on this gateway."))
    }

    // Sign-out clears nothing; bots resolve against the CURRENT roster, and an unknown roster is never "missing".
    @Test func anUnknownRosterIsNeverMissing() {
        #expect(QuickTileRules.missing(tile(.talk, bot: "ivy"), world: QuickTileWorld()) == nil)
        var job = tile(.runJob)
        job.job = "wren|nightly"
        #expect(QuickTileRules.missing(job, world: QuickTileWorld()) == nil)
        // Add Task with no bot needs none; with one, the bot has to be there.
        #expect(QuickTileRules.missing(tile(.addTask), world: world) == nil)
        #expect(QuickTileRules.missing(tile(.addTask, bot: "juno"), world: world) == "Juno isn’t on this gateway.")
    }
}

@Suite struct QuickTileRouteTests {
    private let world = QuickTileWorld(bots: ["otto": "Otto", "ivy": "Ivy"], jobs: ["otto|brief"], pages: ["files": "Files"])

    // Q3, I22: each tile takes its Shortcuts twin's route.
    @Test func eachKindTakesItsShortcutsTwinsRoute() {
        var chat = tile(.newChat, bot: "otto")
        chat.project = "/Users/me/site"
        chat.message = "  Morning  "
        chat.flag = false
        #expect(QuickTileRoute.make(chat, world: world)
            == .newChat(NewChatLink(bot: "otto", project: "/Users/me/site", message: "  Morning  ", send: false)))
        chat.message = "   "
        #expect(QuickTileRoute.make(chat, world: world) == .newChat(NewChatLink(bot: "otto", project: "/Users/me/site", message: nil, send: false)))
        #expect(QuickTileRoute.make(tile(.memo, bot: "ivy"), world: world) == .memo(profile: "ivy"))
        #expect(QuickTileRoute.make(tile(.talk, bot: "ivy"), world: world) == .talk(profile: "ivy"))
        #expect(QuickTileRoute.make(tile(.openChat, bot: "otto"), world: world) == .openChat(profile: "otto"))
        var send = tile(.send, bot: "ivy")
        send.message = "Status?"
        send.flag = false
        #expect(QuickTileRoute.make(send, world: world) == .sendInBackground(profile: "ivy", words: "Status?"))
        send.flag = true
        #expect(QuickTileRoute.make(send, world: world) == .sendInChat(profile: "ivy", words: "Status?"))
        send.message = nil
        #expect(QuickTileRoute.make(send, world: world) == .unavailable("Add the words to send in Edit."))
        #expect(QuickTileRoute.make(tile(.addTask), world: world) == .newTask(bot: nil))
        #expect(QuickTileRoute.make(tile(.addTask, bot: "otto"), world: world) == .newTask(bot: "otto"))
        var job = tile(.runJob)
        job.job = "otto|brief"
        job.jobName = "Brief"
        #expect(QuickTileRoute.make(job, world: world) == .runJob(key: "otto|brief", name: "Brief"))
        var page = tile(.page)
        page.page = "files"
        #expect(QuickTileRoute.make(page, world: world) == .page(id: "files"))
        #expect(QuickTileRoute.make(tile(.search), world: world) == .search)
    }

    // Q3: background tiles keep the page open (and say ✓); the rest close it and go.
    @Test func backgroundTilesStayOnThePage() {
        #expect(QuickTileRoute.runJob(key: "k", name: "n").staysOnPage)
        #expect(QuickTileRoute.sendInBackground(profile: "p", words: "w").staysOnPage)
        #expect(QuickTileRoute.unavailable("x").staysOnPage)
        #expect(!QuickTileRoute.sendInChat(profile: "p", words: "w").staysOnPage)
        #expect(!QuickTileRoute.search.staysOnPage && !QuickTileRoute.page(id: "files").staysOnPage)
        #expect(!QuickTileRoute.newChat(NewChatLink(bot: "otto", project: nil)).staysOnPage)
    }
}

@Suite struct QuickTileListTests {
    private func list(_ ids: [String]) -> QuickTileList { QuickTileList(tiles: ids.map { tile(.search, id: $0) }, seeded: true) }

    // Q3: remove, resize, move, step and reorder never lose a tile.
    @Test func editsKeepEveryTile() {
        var tiles = list(["a", "b", "c", "d"])
        tiles.move("a", to: 2)
        #expect(tiles.tiles.map(\.id) == ["b", "c", "a", "d"])
        tiles.move("d", to: -4)
        #expect(tiles.tiles.map(\.id) == ["d", "b", "c", "a"])
        let atTheStart = tiles.step("d", by: -1)
        #expect(!atTheStart)
        let stepped = tiles.step("d", by: 1)
        #expect(stepped)
        #expect(tiles.tiles.map(\.id) == ["b", "d", "c", "a"])
        tiles.reorder(["a", "missing", "c"])
        #expect(tiles.tiles.map(\.id) == ["a", "c", "b", "d"])
        tiles.setWide("c", true)
        #expect(tiles.tiles[1].wide)
        tiles.remove("b")
        #expect(tiles.tiles.map(\.id) == ["a", "c", "d"])
        var renamed = tiles.tiles[0]
        renamed.name = "Find"
        tiles.replace(renamed)
        #expect(tiles.tiles[0].name == "Find" && tiles.tiles.count == 3)
    }

    // Q2: two columns, a Wide tile across both, one column from AX3.
    @Test func theGridsRows() {
        let tiles = [tile(.memo), tile(.talk), tile(.newChat, wide: true), tile(.addTask), tile(.search, wide: true), tile(.page)]
        #expect(QuickTileGrid.rows(tiles, columns: 2) == [[0, 1], [2], [3], [4], [5]])
        #expect(QuickTileGrid.rows(tiles, columns: 1) == [[0], [1], [2], [3], [4], [5]])
        #expect(QuickTileGrid.rows([], columns: 2).isEmpty)
    }
}

@Suite struct QuickActionsPlaceTests {
    // Q10: a More row, a tab of its own, found by its words; the Home Screen's first item.
    @MainActor @Test func quickActionsIsAPageATabAndASearchWord() {
        #expect(TabChoice(key: "page.quick-actions") == .page(QuickTileStore.rowID))
        #expect(TabChoice.pageIDs.last == QuickTileStore.rowID)   // new pages go at the end: the others keep their tags
        #expect(TabOrderPage.fallback(QuickTileStore.rowID).title == "Favorites")
        for word in ["quick actions", "shortcuts", "launcher"] {
            #expect(MoreSearch.pageKeywords[QuickTileStore.rowID]?.contains(word) == true)
        }
        #expect(IntentsText.quickActions == "Favorites")
    }

    // [favorites-name] Owner 2026-11-22: the star, "and we can't reuse a symbol used by something else in the app".
    @MainActor @Test func favoritesHasAStarNoOtherPageUses() {
        let mine = TabOrderPage.fallback(QuickTileStore.rowID).symbol
        #expect(mine == "star.circle")
        #expect(QuickActions.quickActionsSymbol == "star.circle")
        let others = TabChoice.pageIDs.filter { $0 != QuickTileStore.rowID }.map { TabOrderPage.fallback($0).symbol }
        #expect(!others.contains(mine), "another page's tab shows the same symbol")
        #expect(!["star", "star.fill"].contains(mine), "the plain star is Star Map's (Mac) and the favourite toggles'")
    }
}
