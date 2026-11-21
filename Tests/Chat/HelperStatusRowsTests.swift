import Foundation
import Testing
@testable import HermesHQNative

/// Invented requests, tools and reports. Helper disclosure ownership follows the user's request, including later
/// batches and helper-triggered continuations; another person's delivery or another request is never that request.
@MainActor
@Suite("Helpers · one disclosure per request")
struct HelperStatusRowsTests {
    private let epoch = 1_800_000_000.0
    private let firstGoals = ["Map amber paths", "Check violet labels", "Count copper tiles"]
    private let nextGoals = ["Inspect prism edges", "Trace silver links", "Read cobalt notes", "Check coral names"]

    private func message(_ id: String, _ role: ChatMessage.Role, _ seconds: Double, _ parts: [ChatPart]) -> ChatMessage {
        ChatMessage(id: id, role: role, parts: parts, timestamp: Date(timeIntervalSince1970: epoch + seconds), rowId: nil)
    }

    private func prompt(_ id: String = "request-one", _ seconds: Double = 0) -> ChatMessage {
        message(id, .user, seconds, [.text("Review the invented observatory index.")])
    }

    private func delegate(_ id: String, _ goals: [String], statuses: [String]? = nil,
                          state: ToolCall.State = .running, dispatched: Bool = false) -> ToolCall {
        let tasks = goals.map { ["goal": $0] }
        let args = String(data: try! JSONSerialization.data(withJSONObject: ["tasks": tasks], options: [.sortedKeys]), encoding: .utf8)!
        var call = ToolCall(id: id, name: "delegate_task", title: "Delegate tasks", argsText: args,
                            summary: nil, state: state, durationSeconds: nil)
        if let statuses {
            call.card = .delegate(goals: goals, results: statuses.enumerated().map {
                DelegateResult(status: $0.element, summary: "Invented result \($0.offset): \(goals[$0.offset])")
            }, dispatchedGoals: nil)
        } else if dispatched {
            call.card = .delegate(goals: goals, results: nil, dispatchedGoals: goals)
        }
        return call
    }

    private func note(_ id: String, goal: String, seconds: Double, body: String = "The invented report stays complete.") -> ChatMessage {
        var message = message(id, .system, seconds, [.text("Subagent Task Completed: \(goal)")])
        message.report = body
        return message
    }

    private func child(_ id: String, goal: String, status: SubagentStatus = .running, seconds: Double = 2) -> SubagentProgress {
        SubagentProgress(id: id, goal: goal, sessionId: "session-\(id)", delegationId: "delegation-\(id)", model: "fixture-model",
                         status: status, taskCount: 1, taskIndex: 0, startedAt: epoch + seconds, updatedAt: epoch + seconds + 1,
                         filesRead: ["invented-index.txt"], filesWritten: ["invented-report.txt"],
                         stream: [SubagentStreamEntry(at: epoch + seconds, isError: false, kind: .progress, text: "Checking fixture entry")],
                         summary: "Fixture helper summary")
    }

    private func input(_ messages: [ChatMessage], style: ToolCallStyle = .line, children: [SubagentProgress] = [],
                       running: Bool = false) -> ChatRowBuilder.Input {
        var input = ChatRowBuilder.Input(messages: messages, isRunning: running, botName: "Lumen", expanded: [], scope: "invented-helper-test")
        input.activity.style = style
        input.activity.subagents = children
        input.backgroundResults = Dictionary(uniqueKeysWithValues: messages.compactMap { m in m.report.map { (m.id, $0) } })
        return input
    }

    private var batches: [ChatMessage] {
        [prompt(),
         message("first-batch", .assistant, 1, [.text("Checking the first three sections."),
             .tool(delegate("first-call", firstGoals, statuses: ["completed", "completed", "completed"], state: .done)),
             .text("The first three checks are ready.")]),
         note("first-report", goal: firstGoals[0], seconds: 2, body: "# Amber paths\n\nAll seven invented paths connect.\n\nFull report retained."),
         message("second-batch", .assistant, 3, [.text("Checking four more sections."), .tool(delegate("second-call", nextGoals))])]
    }

    private func helperLines(_ rows: [ChatRow]) -> [BackgroundResultRow] {
        rows.compactMap { if case .backgroundResult(let b) = $0.kind, b.helperRequestID != nil { return b } else { return nil } }
    }

    private func bubbles(_ rows: [ChatRow]) -> [String] {
        rows.compactMap { if case .bubble(let b) = $0.kind { return b.text } else { return nil } }
    }

    private func signatures(_ rows: [ChatRow]) -> [String] {
        rows.map { "\($0.id)#\($0.fingerprint)#\($0.variant)#\($0.gapAbove)" }
    }

    /// Unclaimed reports may share an ordinary Updates disclosure, but remain accessible outside any helper group.
    private func ordinaryReport(_ id: String, input: ChatRowBuilder.Input) -> (raw: String, opened: String)? {
        for row in ChatRowBuilder.build(input) {
            guard case .backgroundResult(let result) = row.kind, result.helperRequestID == nil else { continue }
            if let opened = UpdateGroups.opened(line: row.id, messageId: row.messageId, input: input),
               let member = opened.members.first(where: { $0.messageId == id }), let original = member.result {
                return (original.result, member.full)
            }
            if row.messageId == id, (result.group?.count ?? 1) == 1 {
                return (result.result, BackgroundResults.opened(title: result.title, result: result.result))
            }
        }
        return nil
    }

    @Test func multipleBatchesAndHelperContinuationHaveOneLineInEveryStyle() throws {
        for style in ToolCallStyle.allCases {
            let input = input(batches, style: style, running: true)
            let plan = HelperStatusRows.Plan(input)
            let group = try #require(plan.group(requestID: "request-one"))
            #expect(plan.groups.count == 1)
            #expect(group.helpers.map(\.goal) == firstGoals + nextGoals)
            #expect(group.title == "4 helpers working · 3 done")
            let rows = ChatRowBuilder.build(input)
            #expect(helperLines(rows).count == 1, "\(style)")
            #expect(helperLines(rows).first?.title == group.title)
            #expect(helperLines(rows).first?.helperRequestID == "request-one")
            #expect(!rows.contains { $0.messageId == "first-report" && !$0.id.hasSuffix("|day") })
            #expect(!rows.contains { if case .toolRun(let t) = $0.kind { return t.tools.contains { $0.name == "delegate_task" } } else { return false } })
            #expect(!rows.contains { if case .activity(.delegate) = $0.kind { return true } else { return false } })
            #expect(bubbles(rows) == ["Review the invented observatory index.", "Checking the first three sections.",
                                     "The first three checks are ready.", "Checking four more sections."], "\(style)")
        }
    }

    @Test func openingRetainsEveryCallReportAndNativeHelperDetail() throws {
        let native = child("native-prism", goal: nextGoals[0], seconds: 3)
        let input = input(batches, children: [native], running: true)
        let plan = HelperStatusRows.Plan(input)
        let group = try #require(plan.group(requestID: "request-one"))
        #expect(plan.coveredLiveIDs == [native.id])
        #expect(group.helpers.count == 7)
        #expect(group.helpers.first { $0.id == native.id } == native,
                "Session/delegation IDs, files, model, summary and stream survive for existing detail and control screens")
        #expect(group.members.flatMap(\.steps).map(\.id) == ["first-call", "second-call"])
        #expect(group.opened.members.map(\.id) == group.members.map(\.id))
        let member = try #require(group.members.first { $0.messageId == "first-report" })
        let body = try #require(batches[2].report)
        #expect(member.result?.result == body, "Report actions still have their exact original result")
        #expect(member.full.hasSuffix(body), "The opened report may prepend its goal, but keeps the entire report")
    }

    @Test func repeatedPromptsStaySeparateAndNativeTimeWindowsDisambiguateTheirChildren() throws {
        let goal = "Inspect the repeated bronze marker"
        let messages = [prompt("earlier", 0),
                        message("earlier-work", .assistant, 1, [.tool(delegate("earlier-call", [goal], statuses: ["completed"], state: .done)), .text("Earlier reply.")]),
                        prompt("later", 20),
                        message("later-work", .assistant, 21, [.tool(delegate("later-call", [goal])), .text("Later reply.")]),
                        note("ambiguous-report", goal: goal, seconds: 22)]
        let native = child("ambiguous-native", goal: goal, seconds: 21)
        let plan = HelperStatusRows.Plan(input(messages, children: [native], running: true))
        #expect(plan.groups.map(\.requestID) == ["earlier", "later"])
        #expect(try #require(plan.group(requestID: "earlier")).helpers.map(\.status) == [.completed])
        #expect(try #require(plan.group(requestID: "later")).helpers == [native])
        #expect(plan.coveredLiveIDs == [native.id])
        #expect(!plan.groups.flatMap(\.members).contains { $0.messageId == "ambiguous-report" })
        let rows = ChatRowBuilder.build(input(messages, children: [native], running: true))
        #expect(helperLines(rows).count == 2)
        #expect(rows.contains { $0.messageId == "ambiguous-report" })
        #expect(bubbles(rows).contains("Earlier reply.") && bubbles(rows).contains("Later reply."))
    }

    @Test func labelOnlyLateReportsRemainSeparateAfterAnotherRequest() throws {
        let goal = "Inspect the amber dome"
        let messages = [prompt("old", 0), message("old-work", .assistant, 1, [.tool(delegate("old-call", [goal], state: .done, dispatched: true))]),
                        prompt("new", 10), message("new-work", .assistant, 11, [.tool(delegate("new-call", ["Inspect the blue dome"]))]),
                        note("near-match", goal: goal + " carefully", seconds: 12),
                        note("exact-match", goal: goal, seconds: 13, body: "The old request's complete report.")]
        let plan = HelperStatusRows.Plan(input(messages, running: true))
        let old = try #require(plan.group(requestID: "old"))
        let new = try #require(plan.group(requestID: "new"))
        #expect(old.helpers.map(\.status) == [.dispatched])
        #expect(!old.members.contains { $0.messageId == "exact-match" })
        #expect(!new.members.contains { $0.messageId == "exact-match" })
        #expect(!plan.groups.flatMap(\.members).contains { $0.messageId == "near-match" })
        for report in messages.suffix(2) {
            let accessible = try #require(ordinaryReport(report.id, input: input(messages)))
            let body = try #require(report.report)
            #expect(accessible.raw == body && accessible.opened.hasSuffix(body))
        }
    }

    @Test func explicitDelegationIDRetainsALateReportWithItsOriginalRequest() throws {
        let goal = "Inspect the amber dome"
        let native = child("native-original", goal: goal, seconds: 1)
        var report = note("identified-report", goal: goal, seconds: 13, body: "The original helper's complete report.")
        report.helperReport = HelperReport(delegationID: native.delegationId, tasks: [.init(goal: goal, status: .completed)])
        let messages = [prompt("old", 0), message("old-work", .assistant, 1, [.tool(delegate("old-call", [goal], state: .done, dispatched: true))]),
                        prompt("new", 10), message("new-work", .assistant, 11, [.tool(delegate("new-call", [goal]))]), report]
        let plan = HelperStatusRows.Plan(input(messages, children: [native], running: true))
        let old = try #require(plan.group(requestID: "old"))
        let new = try #require(plan.group(requestID: "new"))
        #expect(old.helpers.map(\.id) == [native.id])
        #expect(old.helpers.map(\.status) == [.completed])
        let member = try #require(old.members.first { $0.messageId == report.id })
        let body = try #require(report.report)
        #expect(member.result?.result == body && member.full.hasSuffix(body))
        #expect(!new.members.contains { $0.messageId == report.id })
        #expect(new.helpers.map(\.status) == [.dispatched])
    }

    @Test func foreignAndAmbiguousReportsCannotAssignTheirContinuationToTheNewestRequest() {
        for evidence in ["delegation", "unique-goal", "repeated-goal", "unknown-goal"] {
            let oldGoal = "Inspect the old amber dome"
            let newGoal = evidence == "repeated-goal" ? oldGoal : "Inspect the new blue dome"
            let native = child("native-original", goal: oldGoal, seconds: 1)
            var report = note("late-report", goal: evidence == "unknown-goal" ? "An unidentified old check" : oldGoal, seconds: 13)
            if evidence == "delegation" {
                report.helperReport = HelperReport(delegationID: native.delegationId,
                                                   tasks: [.init(goal: oldGoal, status: .completed)])
            }
            let followup = delegate("continuation-call", [newGoal])
            let messages = [prompt("old", 0),
                            message("old-work", .assistant, 1, [.tool(delegate("old-call", [oldGoal], state: .done, dispatched: true))]),
                            prompt("new", 10),
                            message("new-work", .assistant, 11, [.tool(delegate("new-call", [newGoal], state: .done, dispatched: true))]),
                            report,
                            message("continuation", .assistant, 14, [.tool(followup), .text("A late helper's follow-up remains accessible.")])]
            let laterNative = child("native-continuation", goal: newGoal, seconds: 14)
            let value = input(messages, children: [native, laterNative], running: true)
            let plan = HelperStatusRows.Plan(value)
            #expect(plan.groups.flatMap(\.members).flatMap(\.steps).map(\.id) == ["old-call", "new-call"], "\(evidence)")
            #expect(!plan.coveredLiveIDs.contains(laterNative.id), "A helper spawned after the uncertain continuation keeps its own status")
            #expect(plan.rows(at: 5, input: value).contains {
                if case .toolRun(let run) = $0.kind { return run.tools.contains { $0.id == followup.id } }
                return false
            }, "\(evidence): original helper step remains accessible")
            #expect(bubbles(ChatRowBuilder.build(value)).contains("A late helper's follow-up remains accessible."))
        }
    }

    private var batchEnvelope: String {
        """
        [ASYNC DELEGATION BATCH COMPLETE — deleg_fixture_batch]
        A background fan-out unit you dispatched earlier — 3 subagents finished.
        --- ✓ TASK 1/3: Map amber paths  (status=completed) ---
        --- RESULT ---
        The amber map has seven invented paths.
        --- ✓ TASK 2/3: Check violet labels  (status=completed) ---
        --- RESULT ---
        The violet labels are consistent.
        --- ✗ TASK 3/3: Count copper tiles  (status=failed) ---
        --- ERROR ---
        The copper fixture intentionally has no tile count.
        """
    }

    @Test func rawBatchReportsKeepOwnershipThroughHydrationAndTimelineResolution() throws {
        let parsed = try #require(HelperReport.parse(batchEnvelope))
        #expect(parsed.delegationID == "deleg_fixture_batch")
        #expect(parsed.tasks.map(\.goal) == firstGoals)
        #expect(parsed.tasks.map(\.status) == [.completed, .completed, .failed])
        let page = Hydration.fold([["role": "user", "content": .string(batchEnvelope), "row_id": 90,
                                   "timestamp": .number(epoch + 4), "display_kind": "async_delegation_complete",
                                   "display_metadata": ["display_text": "3 background agents finished"]]], pageSeq: 1)
        let hydrated = try #require(page.messages.first)
        #expect(hydrated.role == .system)
        #expect(hydrated.helperReport == parsed)
        let resolved = try #require(TimelineNotes.resolve([message("raw-batch", .user, 4, [.text(batchEnvelope)])]).first)
        #expect(resolved.role == .system && resolved.helperReport == parsed)
        let report = try #require(page.meta[hydrated.id]?.asyncResult)
        #expect(report.contains("seven invented paths") && report.contains("intentionally has no tile count"))
        // One report spans two batches of the same request; every unique task keeps its observed outcome.
        let messages = [prompt(), message("batch-a", .assistant, 1, [.tool(delegate("call-a", Array(firstGoals.prefix(2)), state: .done, dispatched: true))]),
                        message("batch-b", .assistant, 2, [.tool(delegate("call-b", [firstGoals[2]], state: .done, dispatched: true))]), hydrated]
        var input = input(messages)
        input.backgroundResults = [hydrated.id: report]
        let group = try #require(HelperStatusRows.Plan(input).group(requestID: "request-one"))
        #expect(group.helpers.map(\.status) == [.completed, .completed, .failed])
        #expect(group.members.filter { $0.messageId == hydrated.id }.count == 1)
        #expect(group.members.first { $0.messageId == hydrated.id }?.full == report)
        #expect(helperLines(ChatRowBuilder.build(input)).map(\.title) == ["2 helpers done · 1 failed"])
    }

    /// The gateway's real batch headers (tools/process_registry_notifications.py) put the call count and duration in
    /// the parentheses after the status. Owner, 2026-11-21: finished helpers still said "dispatched" for hours.
    private func realBatchEnvelope(_ id: String, _ goals: [String], _ statuses: [String]) -> String {
        var lines = ["[ASYNC DELEGATION BATCH COMPLETE — \(id)]",
                     "A background fan-out unit you dispatched earlier — \(goals.count) subagent(s) — has finished; its consolidated results are below.",
                     "", "Dispatched: 2026-11-20 14:51:36 (19m52s ago)", "Role: leaf   Model: fixture-model   Total duration: 1192.63s"]
        for (i, goal) in goals.enumerated() {
            let icon = statuses[i] == "completed" ? "✓" : "✗"
            lines += ["", "--- \(icon) TASK \(i + 1)/\(goals.count): \(goal)  (status=\(statuses[i]), api_calls=34, 1192.42s) ---",
                      "Invented outcome \(i + 1)."]
        }
        return lines.joined(separator: "\n")
    }

    @Test func realBatchHeadersReadTheirStatusNotTheCountAndDuration() throws {
        let parsed = try #require(HelperReport.parse(realBatchEnvelope("deleg_real", firstGoals, ["completed", "completed", "failed"])))
        #expect(parsed.delegationID == "deleg_real")
        #expect(parsed.tasks.map(\.goal) == firstGoals)
        #expect(parsed.tasks.map(\.status) == [.completed, .completed, .failed])
    }

    /// A background batch reported after the owner had moved on (a new request in between) and with a goal longer than
    /// the card keeps: the report still settles its helpers, by the delegation id the dispatch answered with.
    @Test func aBackgroundBatchSettlesByItsDelegationIDAfterTheOwnerMovedOn() throws {
        let long = "Close the remaining invented account-switch test gap " + String(repeating: "with more fixture detail ", count: 20)
        let goals = [long, "Check violet labels"]
        let args = String(data: try JSONSerialization.data(withJSONObject: ["tasks": goals.map { ["goal": $0] }], options: [.sortedKeys]),
                          encoding: .utf8)!
        let result: JSONValue = .object(["status": "dispatched", "mode": "background", "count": 2, "delegation_id": "deleg_0db74985",
                                         "goals": .array(goals.map { .string($0) })])
        var call = ToolCall(id: "bg-call", name: "delegate_task", title: "Delegate tasks", argsText: args, summary: nil,
                            state: .done, durationSeconds: nil)
        call.card = ToolCards.card(name: "delegate_task", args: ToolArgs.parse(args), result: result)
        // The card survives the transcript cache with its delegation id.
        #expect(call.card.flatMap { ToolCard(json: $0.json) } == call.card)
        let page = Hydration.fold([["role": "user", "content": .string(realBatchEnvelope("deleg_0db74985", goals, ["completed", "failed"])),
                                    "row_id": 90, "timestamp": .number(epoch + 30), "display_kind": "async_delegation_complete",
                                    "display_metadata": ["display_text": "2 background agents finished"]]], pageSeq: 1)
        let report = try #require(page.messages.first)
        let messages = [prompt(), message("dispatch", .assistant, 1, [.tool(call), .text("Two helpers are on it in the background.")]),
                        prompt("request-two", 10), message("other-reply", .assistant, 11, [.text("Something else entirely.")]), report]
        var value = input(messages)
        value.backgroundResults = page.meta[report.id]?.asyncResult.map { [report.id: $0] } ?? [:]
        let group = try #require(HelperStatusRows.Plan(value).group(requestID: "request-one"))
        #expect(group.helpers.map(\.status) == [.completed, .failed])
        #expect(!group.title.contains("dispatched"))
    }

    @Test func cacheKeepsStructuredHelperReportsAndStillReadsHQT5() throws {
        var report = note("cached-report", goal: firstGoals[0], seconds: 4)
        report.helperReport = try #require(HelperReport.parse(batchEnvelope))
        let savedAt = Date(timeIntervalSince1970: epoch + 5)
        let data = TranscriptEntry(messages: [report], meta: [:], savedAt: savedAt).encoded()
        #expect(Array(data.prefix(4)) == Array("HQT6".utf8))
        let decoded = try TranscriptEntry.decode(data)
        #expect(decoded.messages.first?.helperReport == report.helperReport)
        #expect(decoded.messages.first?.parts == report.parts)
        #expect(TranscriptEntry.peekSavedAt(data) == savedAt)
        // A message with no report flag has the unchanged HQT5 layout; the prior magic remains readable.
        let plain = prompt("legacy", 0)
        var legacy = TranscriptEntry(messages: [plain], meta: [:], savedAt: savedAt).encoded()
        legacy.replaceSubrange(0..<4, with: Array("HQT5".utf8))
        let older = try TranscriptEntry.decode(legacy)
        #expect(older.messages.first?.parts == plain.parts)
        #expect(older.messages.first?.helperReport == nil)
        #expect(TranscriptEntry.peekSavedAt(legacy) == savedAt)
    }

    @Test func nativeGoalMatchesNeedARequestTimeWindowButExactCallIDsRemainAuthoritative() throws {
        let messages = [prompt("old", 0), message("old-work", .assistant, 1, [.tool(delegate("old-call", ["Old unique goal"]))]),
                        prompt("new", 10), message("new-work", .assistant, 11, [.tool(delegate("new-call", ["New unique goal", "Exact ID goal"]))])]
        let valid = child("native-valid", goal: "New unique goal", seconds: 11)
        let stale = child("native-stale", goal: "Old unique goal", seconds: 10)
        let beforePrompt = child("native-before", goal: "New unique goal", seconds: -1)
        let exact = child("delegate-tool:new-call:1", goal: "Exact ID goal", seconds: -10)
        let plan = HelperStatusRows.Plan(input(messages, children: [valid, stale, beforePrompt, exact], running: true))
        #expect(plan.coveredLiveIDs == [valid.id, exact.id])
        #expect(try #require(plan.group(requestID: "new")).helpers.map(\.id) == [valid.id, exact.id])
        #expect(try #require(plan.group(requestID: "old")).helpers.first?.id != stale.id)
    }

    @Test func queuedDispatchedAndFailedHelpersAreNeverCountedAsDone() throws {
        let goals = ["Running fixture", "Queued fixture", "Failed fixture", "Dispatched fixture", "Completed fixture"]
        let messages = [prompt(), message("status-work", .assistant, 1, [
            .tool(delegate("status-call", goals, statuses: ["running", "queued", "failed", "dispatched", "completed"], state: .done))])]
        let children = [child("delegate-tool:status-call:0", goal: goals[0], status: .running),
                        child("delegate-tool:status-call:1", goal: goals[1], status: .queued),
                        child("delegate-tool:status-call:2", goal: goals[2], status: .failed),
                        child("delegate-tool:status-call:3", goal: goals[3], status: .dispatched),
                        child("delegate-tool:status-call:4", goal: goals[4], status: .completed)]
        let group = try #require(HelperStatusRows.Plan(input(messages, children: children)).groups.first)
        #expect(group.helpers.map(\.status) == [.running, .queued, .failed, .dispatched, .completed])
        #expect(group.title.contains("1 done"))
        #expect(group.title.contains("1 failed"))
        #expect(group.title.contains("1 queued"))
        #expect(group.title.contains("1 dispatched"))
        #expect(!group.title.contains("5 done"))
    }

    @Test func legacyCompletedStandInCannotTurnADispatchAcknowledgementIntoAResult() throws {
        let goal = "Inspect the dispatched jade fixture"
        let messages = [prompt(), message("dispatch-work", .assistant, 1,
            [.tool(delegate("dispatch-call", [goal], state: .done, dispatched: true))])]
        var optimistic = child("delegate-tool:dispatch-call:0", goal: goal, status: .completed)
        optimistic.summary = nil
        optimistic.stream = []
        let group = try #require(HelperStatusRows.Plan(input(messages, children: [optimistic])).groups.first)
        #expect(group.helpers.map(\.status) == [.dispatched])
        #expect(group.title == "1 helper dispatched")
    }

    @Test func anUnownedJobWithTheSameGoalKeepsItsReportSeparate() throws {
        let goal = "Check the shared quartz fixture"
        var job = message("unowned-job", .system, 10, [.text("Nightly quartz inventory")])
        job.job = "Nightly quartz inventory"
        let report = note("ambiguous-job-report", goal: goal, seconds: 12)
        let messages = [prompt(), message("owned-work", .assistant, 1,
                            [.tool(delegate("owned-call", [goal], state: .done, dispatched: true))]),
                        job, message("job-work", .assistant, 11,
                            [.tool(delegate("job-call", [goal], state: .done, dispatched: true))]), report]
        let input = input(messages)
        let plan = HelperStatusRows.Plan(input)
        #expect(plan.groups.count == 1)
        #expect(plan.groups.first?.helpers.map(\.status) == [.dispatched])
        #expect(!plan.groups.flatMap(\.members).contains { $0.messageId == report.id })
        let accessible = try #require(ordinaryReport(report.id, input: input))
        let body = try #require(report.report)
        #expect(accessible.raw == body && accessible.opened.hasSuffix(body))
    }

    @Test func botDeliveriesAndJobsEndOwnershipAndUnrelatedActivityRemainsAccessible() throws {
        let stranger = ChatSender(key: "fixture-bot", name: "Sol", head: nil, profile: "fixture-sol")
        var delivery = message("delivery", .user, 10, [.text("An unrelated invented delivery.")])
        delivery.sender = stranger
        var job = message("job", .user, 10, [.text("An unrelated invented job.")])
        job.job = "Nightly prism inventory"
        var systemDelivery = delivery
        systemDelivery.role = .system
        var systemJob = job
        systemJob.role = .system
        for boundary in [delivery, job, systemDelivery, systemJob] {
            let messages = [prompt(), message("owned", .assistant, 1, [.tool(delegate("owned-call", ["Owned fixture goal"]))]),
                            boundary, message("unrelated", .assistant, 11, [.tool(delegate("unrelated-call", ["Other fixture goal"]))])]
            let plan = HelperStatusRows.Plan(input(messages))
            #expect(plan.groups.count == 1)
            #expect(plan.groups.first?.helpers.map(\.goal) == ["Owned fixture goal"])
        }

        var command = message("command-report", .system, 6, [.text("Background Process Finished: fixture-check")])
        command.report = "The unrelated command printed seven lines."
        var cron = message("cron-report", .system, 8, [.text("Nightly prism inventory")])
        cron.job = "Nightly prism inventory"
        cron.report = "The unrelated scheduled job's full report."
        var terminal = ToolCall(id: "terminal-call", name: "terminal", title: "terminal", argsText: #"{"command":"fixture-check"}"#,
                                summary: nil, state: .done, durationSeconds: 5)
        terminal.note = "Unrelated command finished"
        let messages = [prompt(), message("mixed-work", .assistant, 1, [.reasoning("Keep the invented evidence separate."), .tool(terminal),
                            .tool(delegate("owned-call", ["Owned fixture goal"], statuses: ["completed"], state: .done)), .text("A real reply stays in chat.")]),
                        command, cron, delivery]
        let input = input(messages)
        let rows = ChatRowBuilder.build(input)
        #expect(helperLines(rows).count == 1)
        #expect(bubbles(rows).contains("A real reply stays in chat."))
        var steps: [ToolCall] = []
        var thoughts: [String] = []
        var reports: [String] = []
        for row in rows {
            if case .toolRun(let run) = row.kind { steps += run.tools; thoughts += run.line?.thought.map { [$0] } ?? [] }
            if case .backgroundResult(let result) = row.kind, result.helperRequestID == nil { reports.append(result.result) }
            if let opened = UpdateGroups.opened(line: row.id, messageId: row.messageId, input: input) {
                steps += opened.members.flatMap(\.steps)
                thoughts += opened.members.compactMap(\.thought)
                reports += opened.members.map(\.full)
            }
        }
        #expect(steps.contains { $0.id == terminal.id })
        #expect(thoughts.contains("Keep the invented evidence separate."))
        #expect(reports.contains(command.report!))
        #expect(reports.contains(cron.report!))
        #expect(reports.contains(delivery.plainText))
    }

    @Test func incrementalCompletionAndNewBatchesEqualAFullBuild() {
        let before = Array(batches.prefix(2))
        var model = ChatRowModel()
        model.rebuildAll(input(before), syncMessages: 100, oldestShown: nil)
        model.rebuildNewest(input(batches, running: true), fromMessage: before.count)
        #expect(signatures(Array(model.allRows.reversed())) == signatures(ChatRowBuilder.build(input(batches, running: true))))
        let completed = nextGoals.enumerated().map { child("native-second-\($0.offset)", goal: $0.element, status: .completed, seconds: 3) }
        let done = input(batches, children: completed)
        model.rebuildMessages(done, 3...3)
        #expect(signatures(Array(model.allRows.reversed())) == signatures(ChatRowBuilder.build(done)))
        #expect(helperLines(Array(model.allRows)).first?.title == "7 helpers done")
        var later = batches
        later.append(message("third-batch", .assistant, 5, [.text("One final invented check."), .tool(delegate("third-call", ["Check pearl numbering"]))]))
        let added = input(later, children: completed, running: true)
        model.rebuildNewest(added, fromMessage: 4)
        #expect(signatures(Array(model.allRows.reversed())) == signatures(ChatRowBuilder.build(added)))
        #expect(helperLines(Array(model.allRows)).count == 1)
    }

    @Test func newBatchBuildsAnUnbuiltAnchorBeforeSuppressingItsStatus() {
        var messages = [prompt(), message("first", .assistant, 1,
                          [.tool(delegate("call-first", ["First prism"], statuses: ["completed"], state: .done))])]
        for i in 2...10 { messages.append(message("prose-\(i)", .assistant, Double(i), [.text("Invented update \(i).")])) }
        var model = ChatRowModel()
        model.rebuildAll(input(messages), syncMessages: 1, oldestShown: nil)
        #expect(model.builtFrom == 10)
        let staleRange = model.nextChunk(size: 1)!
        let staleGeneration = model.generation
        let staleRows = ChatRowBuilder.build(input(messages), range: staleRange)
        messages.append(message("second", .assistant, 11, [.tool(delegate("call-second", ["Second prism"]))]))
        let next = input(messages, running: true)
        model.rebuildNewest(next, fromMessage: 11)
        #expect(helperLines(model.allRows).count == 1)
        #expect(model.builtFrom == 1)
        #expect(signatures(Array(model.allRows.reversed())) == signatures(ChatRowBuilder.build(next, range: 1..<messages.count)))
        let appended = model.appendBuilt(staleRows, range: staleRange, generation: staleGeneration, measured: false)
        #expect(!appended)
    }

    @Test func aContradictoryDelegationIDCannotFallBackToGoalMatching() {
        let goal = "Inspect the contrasting prism"
        let native = child("known-native", goal: goal)
        var report = note("foreign-report", goal: goal, seconds: 4)
        report.helperReport = HelperReport(delegationID: "deleg_other", tasks: [.init(goal: goal, status: .completed)])
        let messages = [prompt(), message("work", .assistant, 1, [.tool(delegate("call", [goal]))]), report]
        let plan = HelperStatusRows.Plan(input(messages, children: [native]))
        #expect(plan.groups.first?.helpers.first?.status == .running)
        #expect(!plan.groups.flatMap(\.members).contains { $0.messageId == report.id })
    }

    @Test func silentScheduledRunsKeepTheirOwnershipBoundaryAfterResolution() {
        let messages = [prompt(), message("owned", .assistant, 1, [.tool(delegate("owned-call", ["Owned prism"]))]),
                        message("silent-job", .user, 3, [.text("[Cron delivery: Nightly prism inventory]\n[SILENT]")]),
                        message("scheduled-work", .assistant, 4, [.tool(delegate("scheduled-call", ["Scheduled prism"]))])]
        let own = DeliveryMessages.Seat(profile: "fixture", name: "Ivy", head: nil)
        let resolved = CronDeliveries.resolve(messages, roster: [], own: own).messages
        #expect(resolved[2].role == .system)
        #expect(resolved[2].job == "Nightly prism inventory")
        let plan = HelperStatusRows.Plan(input(resolved))
        #expect(plan.groups.flatMap(\.helpers).map(\.goal) == ["Owned prism"])
        #expect(!ChatRowBuilder.build(input(resolved)).contains { $0.messageId == "silent-job" })
    }

    @Test func loadingOlderRequestOwnershipAndChunkBoundariesMatchesFullBuild() {
        let full = input(batches, running: true)
        let expected = signatures(ChatRowBuilder.build(full))
        for count in 1...batches.count {
            var model = ChatRowModel()
            model.rebuildAll(full, syncMessages: count, oldestShown: nil)
            while let range = model.nextChunk(size: 1) {
                let generation = model.generation
                let appended = model.appendBuilt(ChatRowBuilder.build(full, range: range), range: range, generation: generation, measured: false)
                #expect(appended)
            }
            #expect(signatures(Array(model.allRows.reversed())) == expected, "chunk size \(count)")
        }
        for cut in 1..<batches.count {
            var model = ChatRowModel()
            model.rebuildAll(input(Array(batches.dropFirst(cut)), running: true), syncMessages: 100, oldestShown: nil)
            model.rebuildOldest(full, added: cut)
            while let range = model.nextChunk(size: 1) {
                let generation = model.generation
                let appended = model.appendBuilt(ChatRowBuilder.build(full, range: range), range: range, generation: generation, measured: false)
                #expect(appended)
            }
            #expect(signatures(Array(model.allRows.reversed())) == expected, "older page added \(cut)")
        }
        // The on-screen suffix had only assistant batches and already had unbuilt older rows. Loading the real
        // request changes ownership of the entire built suffix, even before background chunks reach that request.
        var longer = Array(batches.prefix(3))
        // The ordinary update builder deliberately looks back through `reach` messages for folded replies.
        // Keep the first orphan batch beyond that window so this exercises an actually unbuilt suffix.
        for i in 0..<(UpdateGroups.reach + 8) {
            longer.append(message("paging-prose-\(i)", .assistant, 3 + Double(i), [.text("Invented interim note \(i).")]))
        }
        var lastBatch = batches[3]
        lastBatch.timestamp = Date(timeIntervalSince1970: epoch + Double(UpdateGroups.reach + 12))
        longer.append(lastBatch)
        let longerInput = input(longer, running: true)
        let longerExpected = signatures(ChatRowBuilder.build(longerInput))
        let assistantOnly = Array(longer.dropFirst())
        for count in [1, 2] {
            var model = ChatRowModel()
            model.rebuildAll(input(assistantOnly, running: true), syncMessages: count, oldestShown: nil)
            #expect(model.builtFrom > 0)
            model.rebuildOldest(longerInput, added: 1)
            while let range = model.nextChunk(size: 1) {
                let generation = model.generation
                let appended = model.appendBuilt(ChatRowBuilder.build(longerInput, range: range), range: range, generation: generation, measured: false)
                #expect(appended)
            }
            #expect(signatures(Array(model.allRows.reversed())) == longerExpected, "partially built orphan suffix \(count)")
        }
    }
}
