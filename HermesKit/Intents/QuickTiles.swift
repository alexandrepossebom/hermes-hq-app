// [quick-actions] The Quick Actions page (docs/spec/3x-morepages.md §25; docs/spec/3x-intents.md DECISION I22). The
// owner, 2026-11-21: "I want everyone to be able to build a custom quick action page so every thing they would need is
// one click away after triggering the shortcut to open the quick action." Its own page, opened by the shortcut, with
// actions and pages as tiles.
//
// Pure: what a tile is, how the page's tiles are stored on this device (`hqn.quickActions`, versioned), the starter set, what a tile says under its name, and which existing route a tap takes
// (`QuickTileRoute`). The app runs the route through the same handler its Shortcuts twin uses (App/QuickActions).

import Foundation

/// What a tile does. Stored by its raw value; a kind this build doesn't know is kept and drawn switched off.
nonisolated enum QuickTileKind: String, CaseIterable, Sendable {
    case newChat = "new-chat"
    case memo
    case talk
    case send
    case openChat = "open-chat"
    case addTask = "add-task"
    case runJob = "run-job"
    case page
    case search
    /// [favorites-live-tiles] A Dashboard tile itself, drawn as the Dashboard draws it (its picture, or its page live).
    case dashboardTile = "dashboard-tile"

    /// Done in the background: the page stays open and says what happened.
    var staysOnPage: Bool { self == .runJob }

    var needsBot: Bool { [.newChat, .memo, .talk, .send, .openChat].contains(self) }

    /// [favorites-live-tiles] A picture, not an icon and words: Set Up has no icon grid, colour or Height, and it is
    /// never Short (3x-morepages Q16).
    var isPicture: Bool { self == .dashboardTile }

    /// The name a new tile of this kind is given (the setup form's Name starts with it).
    func defaultName(bot: String?, job: String?, page: String?) -> String {
        switch self {
        case .newChat: "New Chat"
        case .memo: "Memo"
        case .talk: "Talk"
        case .send: "Message"
        case .openChat: bot.flatMap { $0.isEmpty ? nil : $0 } ?? "Open Chat"
        case .addTask: "Add Task"
        case .runJob: job.flatMap { $0.isEmpty ? nil : $0 } ?? "Run Job"
        case .page: page.flatMap { $0.isEmpty ? nil : $0 } ?? "Page"
        case .search: "Search Chats"
        case .dashboardTile: page.flatMap { $0.isEmpty ? nil : $0 } ?? "Tile"
        }
    }

    /// The icon and colour a new tile of this kind starts with.
    var defaultLook: (symbol: String, color: QuickTileColor) {
        switch self {
        case .newChat: ("square.and.pencil", .accent)
        case .memo: ("mic.fill", .red)
        case .talk: ("waveform", .green)
        case .send: ("paperplane.fill", .indigo)
        case .openChat: ("bubble.left.fill", .green)
        case .addTask: ("checklist", .teal)
        case .runJob: ("bolt.fill", .orange)
        case .page: ("square.grid.2x2.fill", .gray)
        case .search: ("magnifyingglass", .gray)
        case .dashboardTile: ("chart.xyaxis.line", .accent)
        }
    }
}

/// The tile colours (drawn from the theme where it has one: `accent` is the theme's tint).
nonisolated enum QuickTileColor: String, CaseIterable, Sendable {
    case accent, red, orange, yellow, green, teal, indigo, pink, gray
}

/// One tile. Fields a kind doesn't use stay nil.
nonisolated struct QuickTile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// `QuickTileKind`'s raw value (kept as written: a newer build's kind survives an older build's edits).
    var kind: String
    var name: String
    var symbol: String
    /// `QuickTileColor`'s raw value.
    var color: String
    var wide = false
    /// [quick-actions] Owner 2026-11-21: "I also want to be able to change the height to make them shorter." A Short
    /// tile is one line high: its icon beside the name and subtitle (3x-morepages Q13).
    var short = false
    /// The bot's profile, and its name when the tile was set up (said when the bot isn't on this gateway).
    var bot: String? = nil
    var botName: String? = nil
    /// New Chat's project: its key (folder) and name.
    var project: String? = nil
    var projectName: String? = nil
    /// New Chat's first message, or Send a Message's words.
    var message: String? = nil
    /// New Chat: send the first message (on) or leave it in the box. Send a Message: open the chat (on) or send it in
    /// the background.
    var flag: Bool? = nil
    /// Run Job's job (`JobShortcutRecord.key`, `<owner>|<id>`) and its name.
    var job: String? = nil
    var jobName: String? = nil
    /// A page's More row id, and its title.
    var page: String? = nil
    var pageName: String? = nil
    /// [favorites-live-tiles] A Dashboard tile's pin (`ArtifactPin.id`), and its name when it was added (the tile's
    /// name follows the pin's while the two are the same: `shownName`).
    var pin: String? = nil
    var pinName: String? = nil

    /// A stored entry this build could not read at all: kept, as written, and drawn switched off.
    var unreadable: JSONValue? = nil
    /// [favorites-live-tiles] What a newer build stored on a tile that this build has no field for (Q8: a newer kind's
    /// own fields, as `pin` was to the builds before it): written back as it was.
    var extra: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, kind, name, symbol, color, wide, short, bot, botName, project, projectName, message, flag, job, jobName, page, pageName
        case pin, pinName
    }

    /// Any key, for `extra`.
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    var known: QuickTileKind? { unreadable == nil ? QuickTileKind(rawValue: kind) : nil }
    var tint: QuickTileColor { QuickTileColor(rawValue: color) ?? .gray }

    init(id: String = UUID().uuidString, kind: QuickTileKind, name: String? = nil, symbol: String? = nil,
         color: QuickTileColor? = nil, wide: Bool = false) {
        self.id = id
        self.kind = kind.rawValue
        self.name = name ?? kind.defaultName(bot: nil, job: nil, page: nil)
        self.symbol = symbol ?? kind.defaultLook.symbol
        self.color = (color ?? kind.defaultLook.color).rawValue
        self.wide = wide
    }

    init(unreadable raw: JSONValue) {
        id = raw["id"]?.string ?? Self.stableID(raw)
        kind = raw["kind"]?.string ?? "unknown"
        name = raw["name"]?.string ?? "Unknown Action"
        symbol = "questionmark.square.dashed"
        color = QuickTileColor.gray.rawValue
        wide = raw["wide"]?.bool ?? false
        short = raw["short"]?.bool ?? false
        unreadable = raw
    }

    /// The same id for the same stored bytes on every read (FNV-1a over the entry's sorted JSON), so an entry without
    /// a readable id can still be removed or moved.
    private static func stableID(_ raw: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (try? encoder.encode(raw)) ?? Data() {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "unreadable-" + String(hash, radix: 16)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "square.grid.2x2.fill"
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? QuickTileColor.gray.rawValue
        wide = try c.decodeIfPresent(Bool.self, forKey: .wide) ?? false
        short = try c.decodeIfPresent(Bool.self, forKey: .short) ?? false
        bot = try c.decodeIfPresent(String.self, forKey: .bot)
        botName = try c.decodeIfPresent(String.self, forKey: .botName)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        flag = try c.decodeIfPresent(Bool.self, forKey: .flag)
        job = try c.decodeIfPresent(String.self, forKey: .job)
        jobName = try c.decodeIfPresent(String.self, forKey: .jobName)
        page = try c.decodeIfPresent(String.self, forKey: .page)
        pageName = try c.decodeIfPresent(String.self, forKey: .pageName)
        pin = try c.decodeIfPresent(String.self, forKey: .pin)
        pinName = try c.decodeIfPresent(String.self, forKey: .pinName)
        let keys = Set(CodingKeys.allCases.map(\.stringValue))
        if let all = try? JSONValue(from: decoder).object { extra = all.filter { !keys.contains($0.key) } }
    }

    func encode(to encoder: Encoder) throws {
        if let unreadable { return try unreadable.encode(to: encoder) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(color, forKey: .color)
        if wide { try c.encode(wide, forKey: .wide) }
        if short { try c.encode(short, forKey: .short) }
        try c.encodeIfPresent(bot, forKey: .bot)
        try c.encodeIfPresent(botName, forKey: .botName)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encodeIfPresent(projectName, forKey: .projectName)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encodeIfPresent(flag, forKey: .flag)
        try c.encodeIfPresent(job, forKey: .job)
        try c.encodeIfPresent(jobName, forKey: .jobName)
        try c.encodeIfPresent(page, forKey: .page)
        try c.encodeIfPresent(pageName, forKey: .pageName)
        try c.encodeIfPresent(pin, forKey: .pin)
        try c.encodeIfPresent(pinName, forKey: .pinName)
        guard !extra.isEmpty else { return }
        var more = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in extra { try more.encode(value, forKey: AnyKey(stringValue: key)) }
    }

    /// [favorites-live-tiles] A Dashboard tile's name: its own, or the pin's name now while it was never typed over
    /// (it is still the name the pin had when it was added). `current`: the pin's name on the Dashboard (nil: gone).
    func shownName(currentPinName current: String?) -> String {
        guard known == .dashboardTile, let current, !current.isEmpty, name == pinName || name.isEmpty else { return name }
        return current
    }

    /// What the tile does, in a few words under its name ("to otto", "in Site", "run job").
    func subtitle(botName current: String?) -> String {
        let who = current ?? botName ?? bot ?? ""
        switch known {
        case .memo: return "to \(who)"
        case .talk: return "with \(who)"
        case .newChat:
            if let project = projectName ?? project, !project.isEmpty { return "in \(project)" }
            return "with \(who)"
        case .send: return flag == true ? "with \(who)" : "asks \(who)"
        case .openChat: return "chat with \(who)"
        case .addTask: return bot == nil ? "for me" : "for \(who)"
        case .runJob: return "run job"
        case .page: return "page"
        case .search: return "all chats"
        case .dashboardTile: return "tile"
        case nil: return "needs a newer app"
        }
    }
}

/// What is around when a tile is drawn or tapped: the CURRENT gateway's roster, jobs and pages. nil: not known yet
/// (the roster hasn't answered), which is never "missing".
nonisolated struct QuickTileWorld: Sendable {
    /// profile → shown name.
    var bots: [String: String]?
    var jobs: Set<String>?
    var pages: [String: String]?
    /// [favorites-live-tiles] The pins on this account's Dashboard: id → name.
    var pins: [String: String]?

    init(bots: [String: String]? = nil, jobs: Set<String>? = nil, pages: [String: String]? = nil, pins: [String: String]? = nil) {
        self.bots = bots
        self.jobs = jobs
        self.pages = pages
        self.pins = pins
    }
}

/// Where a tap goes: each case is the route its Shortcuts twin takes (spec I22).
nonisolated enum QuickTileRoute: Equatable, Sendable {
    /// `NewChatRouter.open` with the link `NewChatIntent` builds.
    case newChat(NewChatLink)
    /// `NewChatRouter.talk` (Talk to Bot).
    case talk(profile: String)
    /// `RecordVoiceNoteIntent`'s request (VoiceNoteRequestStore → IntentsRuntime).
    case memo(profile: String)
    /// `OpenBotChatIntent`'s route (`QuickActions.openBot`).
    case openChat(profile: String)
    /// The bot's own chat, then the words sent as typed words are.
    case sendInChat(profile: String, words: String)
    /// `AskBotIntent`'s background send (`ShareSender`), no wait.
    case sendInBackground(profile: String, words: String)
    /// The New Task sheet, the bot chosen when there is one.
    case newTask(bot: String?)
    /// `RunJobIntent`'s calls, no wait.
    case runJob(key: String, name: String)
    /// A More page, opened on the page's own stack (or its tab).
    case page(id: String)
    /// The Home Screen item's Search Chats (DECISION I6).
    case search
    /// [favorites-live-tiles] A Dashboard tile, opened by the Dashboard's own open (as its Home Screen widget is).
    case dashboardTile(id: String)
    /// Not on this gateway (or not this build's): one sentence, nothing runs.
    case unavailable(String)

    var staysOnPage: Bool {
        switch self {
        case .sendInBackground, .runJob, .unavailable: true
        default: false
        }
    }

    /// The route for `tile` against what the current gateway has.
    static func make(_ tile: QuickTile, world: QuickTileWorld) -> QuickTileRoute {
        if let missing = QuickTileRules.missing(tile, world: world) { return .unavailable(missing) }
        guard let kind = tile.known else { return .unavailable(QuickTileRules.newerApp) }
        let bot = tile.bot ?? ""
        let words = tile.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? tile.message : nil
        switch kind {
        case .newChat:
            return .newChat(NewChatLink(bot: bot, project: tile.project?.nilIfEmpty, message: words, send: tile.flag ?? true))
        case .memo: return .memo(profile: bot)
        case .talk: return .talk(profile: bot)
        case .openChat: return .openChat(profile: bot)
        case .send:
            guard let words else { return .unavailable("Add the words to send in Edit.") }
            return tile.flag == true ? .sendInChat(profile: bot, words: words) : .sendInBackground(profile: bot, words: words)
        case .addTask: return .newTask(bot: tile.bot?.nilIfEmpty)
        case .runJob: return .runJob(key: tile.job ?? "", name: tile.jobName ?? tile.name)
        case .page: return .page(id: tile.page ?? "")
        case .search: return .search
        case .dashboardTile: return .dashboardTile(id: tile.pin ?? "")
        }
    }
}

nonisolated enum QuickTileRules {
    static let newerApp = "This action needs a newer version of Hermes HQ."

    /// One sentence when the tile's bot, job or page isn't on this gateway (nil: it is, or that isn't known yet).
    static func missing(_ tile: QuickTile, world: QuickTileWorld) -> String? {
        guard let kind = tile.known else { return newerApp }
        if kind.needsBot || (kind == .addTask && tile.bot != nil), let bot = tile.bot, let bots = world.bots {
            if bots[bot] == nil { return "\(tile.botName ?? bot) isn’t on this gateway." }
        }
        if kind.needsBot, (tile.bot ?? "").isEmpty { return "Choose a bot for this action in Edit." }
        if kind == .runJob {
            guard let job = tile.job, !job.isEmpty else { return "Choose a job for this action in Edit." }
            if let jobs = world.jobs, !jobs.contains(job) { return "“\(tile.jobName ?? tile.name)” isn’t on this gateway." }
        }
        if kind == .page {
            guard let page = tile.page, !page.isEmpty else { return "Choose a page for this action in Edit." }
            if let pages = world.pages, pages[page] == nil { return "\(tile.pageName ?? tile.name) isn’t on this gateway." }
        }
        if kind == .dashboardTile {
            // [favorites-live-tiles] Unpinned (or another account's): kept, at 40 %, until it is pinned again or removed.
            guard let pin = tile.pin, !pin.isEmpty else { return notOnDashboard(tile) }
            if let pins = world.pins, pins[pin] == nil { return notOnDashboard(tile) }
        }
        return nil
    }

    /// [favorites-live-tiles] A Dashboard tile whose pin isn't on this account's Dashboard now.
    static func notOnDashboard(_ tile: QuickTile) -> String { "“\(tile.pinName ?? tile.name)” isn’t on your Dashboard any more." }
}

/// The page's tiles on this device.
nonisolated struct QuickTileList: Equatable, Sendable {
    var tiles: [QuickTile] = []
    /// The starter set was offered once (or the person changed the list): never seeded again.
    var seeded = false

    mutating func add(_ tile: QuickTile) { tiles.append(tile) }

    mutating func replace(_ tile: QuickTile) {
        if let index = tiles.firstIndex(where: { $0.id == tile.id }) { tiles[index] = tile } else { tiles.append(tile) }
    }

    mutating func remove(_ id: String) { tiles.removeAll { $0.id == id } }

    mutating func setWide(_ id: String, _ wide: Bool) {
        if let index = tiles.firstIndex(where: { $0.id == id }) { tiles[index].wide = wide }
    }

    /// A Dashboard tile is never Short (a picture has no one-line form): it stays as it is.
    mutating func setShort(_ id: String, _ short: Bool) {
        if let index = tiles.firstIndex(where: { $0.id == id }), tiles[index].known?.isPicture != true { tiles[index].short = short }
    }

    /// [favorites-live-tiles] The pins already on the page (Add Action leaves them out).
    var pins: Set<String> { Set(tiles.compactMap { $0.known == .dashboardTile ? $0.pin : nil }) }

    /// Moves the tile to `index` (clamped).
    mutating func move(_ id: String, to index: Int) {
        guard let from = tiles.firstIndex(where: { $0.id == id }) else { return }
        let tile = tiles.remove(at: from)
        tiles.insert(tile, at: max(0, min(index, tiles.count)))
    }

    /// One step earlier (-1) or later (+1); false at an end.
    @discardableResult mutating func step(_ id: String, by delta: Int) -> Bool {
        guard let from = tiles.firstIndex(where: { $0.id == id }), tiles.indices.contains(from + delta) else { return false }
        tiles.swapAt(from, from + delta)
        return true
    }

    /// The tiles in `order` (ids); any not named keep their place after them (none is ever dropped).
    mutating func reorder(_ order: [String]) {
        var byID = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next = order.compactMap { byID.removeValue(forKey: $0) }
        next += tiles.filter { byID[$0.id] != nil }
        tiles = next
    }

    /// [favorites-retired] The pages chosen on the retired Favorites page (`FavoritePages.ids`) become page tiles at the
    /// end, in Favorites' order: those on this gateway (`pages`: id → title and icon), and not already a tile. A tile
    /// that opened Favorites itself goes (this page is what replaced it). Answers whether the list changed.
    @discardableResult
    mutating func absorbFavorites(_ ids: [String], pages: [String: (title: String, symbol: String)]) -> Bool {
        let before = tiles
        tiles.removeAll { $0.known == .page && $0.page == FavoritePages.rowID }
        var have = Set(tiles.compactMap { $0.known == .page ? $0.page : nil })
        for id in ids where id != FavoritePages.rowID && id != QuickTileStore.rowID && !have.contains(id) {
            guard let page = pages[id] else { continue }
            var tile = QuickTile(id: "favorite-" + id, kind: .page, name: page.title, symbol: page.symbol)
            tile.page = id
            tile.pageName = page.title
            tiles.append(tile)
            have.insert(id)
        }
        return tiles != before
    }
}

nonisolated enum QuickTileStore {
    static let key = "hqn.quickActions"
    /// A stored list this build could not read is copied here once, before anything is written over it.
    static let unreadableKey = "hqn.quickActions.unreadable"
    static let didChange = Notification.Name("hqn.quickActions.changed")
    static let version = 1
    /// The page's own More row id (and its `TabChoice` page id): never a tile of itself.
    static let rowID = "quick-actions"

    private struct Envelope: Codable {
        var version: Int
        var seeded: Bool?
        var tiles: [Entry]
    }

    /// One stored tile, or what was stored when it can't be read as one.
    private struct Entry: Codable {
        var tile: QuickTile
        init(_ tile: QuickTile) { self.tile = tile }
        init(from decoder: Decoder) throws {
            if let tile = try? QuickTile(from: decoder) { self.tile = tile; return }
            tile = QuickTile(unreadable: try JSONValue(from: decoder))
        }
        func encode(to encoder: Encoder) throws { try tile.encode(to: encoder) }
    }

    static func decode(_ data: Data) -> QuickTileList? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        return QuickTileList(tiles: envelope.tiles.map(\.tile), seeded: envelope.seeded ?? !envelope.tiles.isEmpty)
    }

    static func encode(_ list: QuickTileList, version: Int = QuickTileStore.version) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Envelope(version: version, seeded: list.seeded, tiles: list.tiles.map(Entry.init)))
    }

    static func load(_ defaults: UserDefaults = .standard) -> QuickTileList {
        guard let data = defaults.data(forKey: key) else { return QuickTileList() }
        if let list = decode(data) { return list }
        // Unreadable as a whole: kept aside (never wiped), and the starter set is not offered over it.
        if defaults.data(forKey: unreadableKey) == nil { defaults.set(data, forKey: unreadableKey) }
        return QuickTileList(tiles: [], seeded: true)
    }

    /// Stores `list` (marking it seeded: the person has a list now). Returns whether it changed.
    @discardableResult static func save(_ list: QuickTileList, _ defaults: UserDefaults = .standard) -> Bool {
        var list = list
        list.seeded = true
        if let data = defaults.data(forKey: key), decode(data) == nil, defaults.data(forKey: unreadableKey) == nil {
            defaults.set(data, forKey: unreadableKey)
        }
        let stored = defaults.data(forKey: key).flatMap(decode)
        // A newer build's version number stays (its entries were kept as written).
        let version = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(VersionOnly.self, from: $0) }?.version ?? Self.version
        guard let data = encode(list, version: max(version, Self.version)) else { return false }
        if stored == list { return false }
        defaults.set(data, forKey: key)
        if defaults === UserDefaults.standard { NotificationCenter.default.post(name: didChange, object: nil) }
        return true
    }

    private struct VersionOnly: Decodable { var version: Int }

    /// The list to show: the stored one, or the starter set the first time there's a bot to make it for.
    /// Returns the list and whether it was just seeded (the caller saves it).
    static func listToShow(_ stored: QuickTileList, firstBot: (profile: String, name: String)?) -> (list: QuickTileList, seeded: Bool) {
        guard stored.tiles.isEmpty, !stored.seeded, let bot = firstBot else { return (stored, false) }
        return (QuickTileList(tiles: starter(bot: bot.profile, name: bot.name), seeded: true), true)
    }

    /// Voice Memo, Talk, New Chat (wide), Add Task and Search Chats, for the roster's first bot.
    static func starter(bot: String, name: String) -> [QuickTile] {
        func forBot(_ tile: QuickTile) -> QuickTile {
            var tile = tile
            tile.bot = bot
            tile.botName = name
            return tile
        }
        var chat = forBot(QuickTile(id: "starter-new-chat", kind: .newChat, wide: true))
        chat.flag = true
        return [forBot(QuickTile(id: "starter-memo", kind: .memo)), forBot(QuickTile(id: "starter-talk", kind: .talk)), chat,
                QuickTile(id: "starter-add-task", kind: .addTask), QuickTile(id: "starter-search", kind: .search)]
    }
}

/// The grid: two columns, a Wide tile across both; one full-width column from AX3 (`QuickActionsViewController.stacked`).
nonisolated enum QuickTileGrid {
    /// Rows of tile indices. A small tile left alone before a wide one keeps its own row (the order never changes).
    static func rows(_ tiles: [QuickTile], columns: Int) -> [[Int]] {
        guard columns > 1 else { return tiles.indices.map { [$0] } }
        var rows: [[Int]] = []
        var open: [Int] = []
        for (index, tile) in tiles.enumerated() {
            if tile.wide {
                if !open.isEmpty { rows.append(open); open = [] }
                rows.append([index])
            } else {
                open.append(index)
                if open.count == columns { rows.append(open); open = [] }
            }
        }
        if !open.isEmpty { rows.append(open) }
        return rows
    }
}
