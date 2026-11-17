import Foundation
import Testing
import UIKit
@testable import HermesHQNative

/// [updates] A group's line opens a sheet (UpdatesSheet.swift): the chat's rows never change for it, and what the
/// sheet shows comes from `UpdateGroups.opened` (its name, how much it holds and when, its members oldest first).
@MainActor
struct UpdatesSheetTests {
    private static let roster = [
        DeliveryMessages.Seat(profile: "default", name: "Hermes", head: ["v": 6, "theme": "shape", "color": "butter", "form": "round"]),
        DeliveryMessages.Seat(profile: "inbox", name: "Inbox", head: FakeChatSession.inboxHead),
    ]
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// Inbox's chat as the screen sees it (as UpdateGroupRowsTests): deliveries, Hermes's replies and notes resolved.
    private func talkInput(expanded: Set<String> = []) -> ChatRowBuilder.Input {
        var messages = DeliveryMessages.resolve(FakeChatSession.botTalkThread(now: now), roster: Self.roster).messages
        messages = BotDMs.resolve(messages, roster: Self.roster).messages
        messages = TimelineNotes.resolve(messages)
        var input = ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Inbox", expanded: expanded, scope: "t")
        input.bots = Self.roster
        input.activity.style = .bottom
        input.now = now
        return input
    }

    private func plainInput(_ messages: [ChatMessage], style: ToolCallStyle = .line) -> ChatRowBuilder.Input {
        var input = ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Hermes", expanded: [], scope: "t")
        input.activity.style = style
        input.now = now
        return input
    }

    /// The chat's lines that hold more than one update, oldest first.
    private func groupLines(_ input: ChatRowBuilder.Input) -> [(row: ChatRow, group: UpdatesGroup)] {
        ChatRowBuilder.build(input).compactMap { row in
            if case .backgroundResult(let b) = row.kind, let group = b.group, group.count > 1 { return (row, group) } else { return nil }
        }
    }

    private func opened(_ input: ChatRowBuilder.Input, line id: String) -> UpdatesOpened? {
        guard let line = ChatRowBuilder.build(input).first(where: { $0.id == id }) else { return nil }
        return UpdateGroups.opened(line: line.id, messageId: line.messageId, input: input)
    }

    /// "<count> · <when>", the when being the run's first and last times.
    private func expectSubtitle(_ opened: UpdatesOpened, _ count: String, now: Date) {
        let times = opened.members.compactMap(\.time)
        guard let first = times.min(), let last = times.max() else { Issue.record("no member has a time"); return }
        #expect(opened.subtitle == count + " · " + UpdateGroups.span(first, last, now: now), "\(opened.subtitle)")
    }

    // MARK: (a) The line is the same row, opened key or not; no member is a row

    @Test func theLineIsTheSameRowWhetherOrNotItsIdIsOpened() throws {
        func ids(_ rows: [ChatRow]) -> [String] { rows.map { "\($0.id)#\($0.fingerprint)#\($0.variant)#\($0.gapAbove)" } }
        let closed = ChatRowBuilder.build(talkInput())
        let lineIds = groupLines(talkInput()).map(\.row.id)
        #expect(lineIds == ["bt-d1|grp", "bt-r2|grp"])
        // Every key the in-chat card used: the lines', and their members'.
        let memberIds = lineIds.flatMap { opened(talkInput(), line: $0)?.members.map(\.id) ?? [] }
        #expect(memberIds.count == 10)
        for keys in [Set(lineIds), Set(lineIds).union(memberIds)] {
            let open = ChatRowBuilder.build(talkInput(expanded: keys))
            #expect(ids(open) == ids(closed))
            for row in open {
                #expect(!row.id.hasSuffix(UpdateGroups.memberSuffix), "\(row.id): a member is not a row of the chat")
                guard case .backgroundResult(let b) = row.kind, (b.group?.count ?? 0) > 1 else { continue }
                #expect(!b.expanded && row.variant == 0, "\(row.id)")
            }
            // What the sheet shows doesn't depend on those keys either.
            for id in lineIds {
                #expect(opened(talkInput(expanded: keys), line: id)?.members.map(\.id) == opened(talkInput(), line: id)?.members.map(\.id))
            }
        }
    }

    // MARK: (b) The sheet's name and count

    @Test func aTalkIsNamedForTheBotAndCountsItsMessages() throws {
        let input = talkInput()
        let talk = try #require(opened(input, line: "bt-d1|grp"))
        #expect(talk.title == "With Hermes")
        #expect(talk.members.count == 8, "its work line and the helper's report are members, not messages")
        expectSubtitle(talk, "6 messages", now: now)
        // Every member is from the one bot: its name, and "2 messages".
        let same = try #require(opened(input, line: "bt-r2|grp"))
        #expect(same.title == "From Hermes")
        #expect(same.members.map(\.title) == ["From Hermes", "From Hermes"])
        expectSubtitle(same, "2 messages", now: now)
        // The title and count are the line's own words.
        for (row, group) in groupLines(input) {
            guard case .backgroundResult(let line) = row.kind else { continue }
            let sheet = try #require(opened(input, line: row.id))
            #expect(sheet.title == line.title && sheet.subtitle.hasPrefix(group.tail ?? "?"), "\(row.id)")
            #expect(sheet.members.count == group.count)
        }
    }

    @Test func aMixedRunIsUpdates() throws {
        // A finished process, a helper's report and another bot's message between two of your messages.
        let updates = plainInput(FakeChatSession.updatesThread(now: now))
        let first = try #require(groupLines(updates).first)
        #expect(first.row.id == "up-n1|grp" && first.group.count == 3)
        let mixed = try #require(opened(updates, line: first.row.id))
        #expect(mixed.title == "Updates")
        #expect(mixed.members.map(\.id) == ["up-n1|bg|in", "up-n2|bg|in", "up-d1|dl|in"])
        expectSubtitle(mixed, "3 updates", now: now)
        #expect(mixed.members[0].process && mixed.members[0].full.contains("128 passing"))

        // A long turn of wordless replies between helpers' reports: work lines and reports, one sheet.
        let work = plainInput(FakeChatSession.workFoldThread(now: now))
        let fold = try #require(groupLines(work).first)
        let folded = try #require(opened(work, line: fold.row.id))
        #expect(folded.title == "Updates")
        #expect(folded.members.count == fold.group.count && folded.members.count > 8)
        expectSubtitle(folded, "\(folded.members.count) updates", now: now)
        #expect(folded.members.contains { !$0.steps.isEmpty } && folded.members.contains { $0.title == "Helper finished" })
        // A work line's member has its steps, no words of its own.
        for member in folded.members where !member.steps.isEmpty { #expect(member.full.isEmpty && member.result == nil) }
    }

    @Test func aRunOverDaysNamesItsDays() throws {
        let input = plainInput(FakeChatSession.idleThread(now: now))
        let line = try #require(groupLines(input).first)
        let idle = try #require(opened(input, line: line.row.id))
        #expect(idle.title == "Updates")
        #expect(idle.members.count == 10 && line.group.count == 10)
        let times = idle.members.compactMap(\.time)
        let first = try #require(times.min()), last = try #require(times.max())
        #expect(idle.subtitle == "10 updates · " + ChatRowBuilder.dayRange(first, last, now: now))
        #expect(idle.subtitle.hasSuffix("– Yesterday"))
        // Each member says its day before its time.
        for member in idle.members {
            let time = try #require(member.time)
            let day = try #require(member.day)
            #expect(day == ChatRowBuilder.dayName(time, now: now))
            #expect(UpdateTimes.words(member) == "\(day) \(ChatRowBuilder.clock(time))")
        }
        #expect(Set(idle.members.compactMap(\.day)).count == 10)
    }

    // MARK: (c) When a run happened

    @Test func spanSaysWhenARunHappened() throws {
        let calendar = Calendar.autoupdatingCurrent
        func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second)))
        }
        func plain(_ words: String) -> String {
            words.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        let today = try date(10, 21, 0)
        let a = try date(10, 7, 2), b = try date(10, 7, 15)
        let twelveHour = plain(ChatRowBuilder.clock(b)).hasSuffix("AM")

        // Within one minute: the one time.
        #expect(UpdateGroups.span(a, a.addingTimeInterval(40), now: today) == ChatRowBuilder.clock(a))
        // One day: the first drops an AM/PM it shares with the last.
        let same = UpdateGroups.span(a, b, now: today)
        #expect(same == UpdateTimes.shortClock(ChatRowBuilder.clock(a)) + " – " + ChatRowBuilder.clock(b))
        if twelveHour { #expect(plain(same) == "7:02 – 7:15 AM") }
        // Morning to afternoon: each keeps its own.
        let noon = UpdateGroups.span(try date(10, 11, 50), try date(10, 12, 10), now: today)
        #expect(noon == ChatRowBuilder.clock(try date(10, 11, 50)) + " – " + ChatRowBuilder.clock(try date(10, 12, 10)))
        if twelveHour { #expect(plain(noon) == "11:50 AM – 12:10 PM") }
        // Not today: its day leads.
        let tomorrow = try date(11, 9, 0)
        #expect(UpdateGroups.span(a, b, now: tomorrow) == "Yesterday " + same)
        #expect(UpdateGroups.span(a, a.addingTimeInterval(40), now: tomorrow) == "Yesterday " + ChatRowBuilder.clock(a))
        // Over days: the days alone.
        #expect(UpdateGroups.span(a, try date(11, 8, 30), now: tomorrow) == "Yesterday – Today")
        #expect(UpdateGroups.span(try date(2, 8, 30), a, now: tomorrow) == ChatRowBuilder.dayRange(try date(2, 8, 30), a, now: tomorrow))
        #expect(UpdateGroups.span(try date(2, 8, 30), a, now: tomorrow).hasSuffix(" – Yesterday"))
        // The short clock a shared AM/PM leaves.
        #expect(UpdateTimes.shortClock("7:02 AM") == "7:02" && UpdateTimes.shortClock("7:02\u{202F}PM") == "7:02")
        #expect(UpdateTimes.shortClock("19:02") == "19:02")
    }

    // MARK: (d) A line that isn't a group opens nothing

    @Test func noSheetForALineThatIsNotAGroup() throws {
        let input = talkInput()
        #expect(UpdateGroups.opened(line: "bt-d1|grp", messageId: "bt-d1", input: input) != nil)
        // A row that isn't a line, an id no line has, a message the chat doesn't hold, the right id under another message
        // far from the run.
        #expect(UpdateGroups.opened(line: "bt-a1|b0", messageId: "bt-a1", input: input) == nil)
        #expect(UpdateGroups.opened(line: "nope|grp", messageId: "bt-d1", input: input) == nil)
        #expect(UpdateGroups.opened(line: "bt-d1|grp", messageId: "gone", input: input) == nil)
        #expect(UpdateGroups.opened(line: "bt-d1|grp", messageId: "bt-u1", input: input) == nil)
        // A run of one keeps its own row and opens in place: it has no sheet, by its own id or by a line's.
        let t0 = now.addingTimeInterval(-600)
        var one = ChatRowBuilder.Input(messages: [
            ChatMessage(id: "u1", role: .user, parts: [.text("go")], timestamp: t0, rowId: 1),
            ChatMessage(id: "n1", role: .system, parts: [.text("Background Process Finished: npm test")], timestamp: t0 + 60, rowId: 2),
            ChatMessage(id: "u2", role: .user, parts: [.text("ok")], timestamp: t0 + 90, rowId: 3),
        ], isRunning: false, botName: "Hermes", expanded: [])
        one.backgroundResults = ["n1": "12 passed"]
        #expect(ChatRowBuilder.build(one).contains { $0.id == "n1|bg" })
        #expect(UpdateGroups.opened(line: "n1|bg", messageId: "n1", input: one) == nil)
        #expect(UpdateGroups.opened(line: "n1|grp", messageId: "n1", input: one) == nil)
        #expect(UpdateGroups.opening(rowId: "n1|bg", message: 1, input: one) == nil)
    }

    // MARK: (e) A work line's steps on its card

    private func step(_ n: Int) -> ToolCall {
        ToolCall(id: "s\(n)", name: "terminal", title: "terminal", argsText: #"{"command":"echo \#(n)"}"#, summary: "ok", state: .done,
                 durationSeconds: 1)
    }

    private func member(_ id: String = "m|line|in", title: String = "Worked for 8s", full: String = "", steps: Int = 0,
                        thought: String? = nil) -> UpdateMemberRow {
        UpdateMemberRow(id: id, messageId: "m", mark: .glyph(.terminal), title: title, time: now, preview: "", full: full,
                        steps: (0..<steps).map(step), thought: thought)
    }

    @Test func aLongWorkLineShowsOneStepFewerThanTheLimit() {
        let limit = UpdateCardCell.stepLimit
        #expect(UpdateCardCell.shownSteps(member(steps: 0)).isEmpty)
        #expect(UpdateCardCell.shownSteps(member(steps: 2)).count == 2)
        #expect(UpdateCardCell.shownSteps(member(steps: limit)).count == limit, "at the limit, every step")
        // Over it: one row is kept for "All N Steps", so the card is never longer than the limit.
        for count in [limit + 1, limit + 2, 40] {
            let shown = UpdateCardCell.shownSteps(member(steps: count))
            #expect(shown.count == limit - 1, "\(count) steps")
            #expect(shown.map(\.id) == (0..<(limit - 1)).map { "s\($0)" }, "the first ones, in order")
        }
    }

    @Test func aCardListsItsStepsThenAllSteps() {
        let style = ChatStyle.make(category: .large)
        let limit = UpdateCardCell.stepLimit
        let cell = UpdateCardCell(style: .default, reuseIdentifier: nil)
        cell.configure(member(steps: limit + 3), first: true, last: true, whole: false, width: 390, style: style)
        #expect(cell.debugRows.count == limit && cell.debugRows.last == "All \(limit + 3) Steps")
        #expect(cell.debugWords == nil)
        // The same cell reused for a shorter one: only its own rows show.
        cell.configure(member(steps: 2), first: true, last: true, whole: false, width: 390, style: style)
        #expect(cell.debugRows.count == 2 && !cell.debugRows.contains { $0.hasPrefix("All ") })
        // A note: its title alone.
        cell.configure(member(title: "Model changed to GPT-6"), first: true, last: true, whole: false, width: 390, style: style)
        #expect(cell.debugRows.isEmpty && cell.debugWords == nil && !cell.debugClamped)
        // A work line's thought shows as its words.
        cell.configure(member(steps: 1, thought: "Checking the mail first."), first: true, last: true, whole: false, width: 390, style: style)
        #expect(cell.debugWords == "Checking the mail first." && cell.debugRows.count == 1)
    }

    @Test func aLongMessageIsCutUntilShowMore() {
        let style = ChatStyle.make(category: .large)
        let long = (1...40).map { "Line \($0) of the report." }.joined(separator: "\n\n")
        let cell = UpdateCardCell(style: .default, reuseIdentifier: nil)
        cell.configure(member(title: "From Hermes", full: long), first: true, last: true, whole: false, width: 390, style: style)
        #expect(cell.debugClamped)
        #expect(cell.debugWords?.contains("Line 40 of the report.") == true, "VoiceOver still reads the whole of it")
        cell.configure(member(title: "From Hermes", full: long), first: true, last: true, whole: true, width: 390, style: style)
        #expect(!cell.debugClamped)
        cell.configure(member(title: "From Hermes", full: "Done."), first: true, last: true, whole: false, width: 390, style: style)
        #expect(!cell.debugClamped && cell.debugWords == "Done.")
    }

    // MARK: (f) The sheet in a window

    private func hooks() -> UpdatesSheetViewController.Hooks {
        UpdatesSheetViewController.Hooks(stepPage: { _, _ in nil }, stepsPage: { _, _ in nil }, openFile: { _ in }, reviewChanges: {},
                                         openLink: { _, _ in }, menu: { _, _ in nil })
    }

    @Test func theSheetLaysOutATalksMembers() throws {
        let input = talkInput()
        let talk = try #require(opened(input, line: "bt-d1|grp"))
        let page = UpdatesSheetViewController(opened: talk, focus: nil, hooks: hooks())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = page
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        page.tableView.layoutIfNeeded()

        #expect(page.debugMembers.map(\.id) == talk.members.map(\.id))
        #expect(page.navigationItem.subtitle == talk.subtitle)
        #expect(page.tableView.accessibilityIdentifier == "updates.list")
        #expect(page.tableView.numberOfRows(inSection: 0) == 8)

        // The cards on screen: laid out without ambiguity, inside the list's width, one under the other.
        let shown = page.tableView.visibleCells.compactMap { $0 as? UpdateCardCell }.sorted { $0.frame.minY < $1.frame.minY }
        #expect(shown.count >= 2)
        var bottom = -CGFloat.greatestFiniteMagnitude
        for cell in shown {
            #expect(!cell.contentView.hasAmbiguousLayout)
            for view in cell.contentView.subviews {
                #expect(!view.hasAmbiguousLayout, "\(type(of: view)) in the card at \(cell.frame.minY)")
                #expect(view.frame.minX >= 0 && view.frame.maxX <= cell.contentView.bounds.width + 0.5)
            }
            #expect(cell.frame.height >= 44 && cell.frame.minY >= bottom - 0.5)
            bottom = cell.frame.maxY
        }

        // Every member's card, as the list makes it: a message shows its whole words, a work line its steps.
        let source = try #require(page.tableView.dataSource)
        for (index, member) in talk.members.enumerated() {
            let cell = try #require(source.tableView(page.tableView, cellForRowAt: IndexPath(row: index, section: 0)) as? UpdateCardCell)
            if !member.full.isEmpty {
                let words = try #require(cell.debugWords, "\(member.id)")
                #expect(!words.isEmpty && !words.contains("**"), "\(member.id): formatted, not raw Markdown")
                #expect(cell.debugRows.isEmpty, "\(member.id)")
            } else {
                #expect(cell.debugWords == member.thought, "\(member.id)")
            }
            if !member.steps.isEmpty {
                let extra = member.steps.count > UpdateCardCell.stepLimit ? 1 : 0
                #expect(cell.debugRows.count == UpdateCardCell.shownSteps(member).count + extra, "\(member.id)")
                #expect(cell.debugRows.allSatisfy { !$0.isEmpty })
            }
        }
        let helper = try #require(talk.members.firstIndex { $0.id == "bt-n1|bg|in" })
        let card = try #require(source.tableView(page.tableView, cellForRowAt: IndexPath(row: helper, section: 0)) as? UpdateCardCell)
        #expect(card.debugWords?.contains("Gmail overview") == true)

        // The chat moved on: the sheet shows what its line holds now.
        var fewer = talk
        fewer.members.removeLast()
        fewer.subtitle = "5 messages"
        fewer.fingerprint &+= 1   // as `UpdateGroups.opened` gives a run that changed: the sheet redraws only then
        page.update(fewer)
        #expect(page.tableView.numberOfRows(inSection: 0) == 7 && page.navigationItem.subtitle == "5 messages")
    }
}
