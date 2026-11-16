import Testing
@testable import HermesHQNative

@Suite("Minimal activity composition")
struct ActivityPillTests {
    @Test func everyCombinationKeepsEveryCategoryReachable() {
        for mask in 0..<(1 << ShelfPieceKind.allCases.count) {
            let kinds = ShelfPieceKind.allCases.filter { mask & (1 << $0.rawValue) != 0 }
            let pill = ActivityPill(entries: kinds.map { .init(kind: $0, words: "kind \($0.rawValue)") })
            #expect(Set(pill.ordered.map(\.kind)) == Set(kinds))
            #expect(pill.ordered.count == kinds.count)
            #expect(!pill.isRunning)
            // The approved pill names every current category; "+N more" only when the view runs out of width.
            #expect(!pill.words().contains("more"))
            for kind in kinds { #expect(pill.words().contains("kind \(kind.rawValue)")) }
            if kinds.count > 2 { #expect(pill.words(maxSegments: 2).hasSuffix("+\(kinds.count - 2) more")) }
            for kind in kinds { #expect(pill.accessibilityLabel.contains("kind \(kind.rawValue)")) }
        }
    }

    @Test func backgroundOutlivesTheParentAndAnIdlePlanDoesNotSpin() {
        var pill = ActivityPill(entries: [.init(kind: .tasks, words: "Tasks 2/5")])
        #expect(!pill.isRunning)
        pill.entries.append(.init(kind: .background, words: "1 background", isRunning: true))
        #expect(pill.words() == "Tasks 2/5 · 1 background")
        #expect(pill.isRunning)
        pill.entries.removeFirst()
        #expect(pill.words() == "1 background")
        #expect(pill.isRunning)
    }

    @Test func attentionSurvivesOverflowAndFinishedGroupsAreQuiet() {
        let pill = ActivityPill(entries: [
            .init(kind: .tasks, words: "Tasks 2/5"),
            .init(kind: .subagents, words: "2 helpers", isRunning: true),
            .init(kind: .goal, words: "Goal blocked", needsAttention: true),
            .init(kind: .browser, words: "Browser needs you", needsAttention: true),
            .init(kind: .previousTasks, words: "Previous tasks 5/5")])
        #expect(pill.words() == "Goal blocked · Browser needs you · Tasks 2/5 · Previous tasks 5/5 · 2 helpers")
        #expect(pill.words(maxSegments: 2) == "Goal blocked · Browser needs you · +3 more")
        #expect(pill.words(maxSegments: 1) == "2 need attention · +3 more")
        #expect(pill.singleAttentionKind == nil)
        #expect(pill.needsAttention)
        #expect(pill.accessibilityLabel.contains("Browser needs you"))
        let finished = ActivityPill(entries: [.init(kind: .subagents, words: "Helpers finished"),
                                             .init(kind: .previousTasks, words: "Previous tasks 5/5")])
        #expect(!finished.isRunning)
        #expect(!finished.accessibilityLabel.contains("running"))
    }

    @Test func workerCountsPrecedeAnOrdinaryActiveGoalAndVoiceOverKeepsDetails() {
        let pill = ActivityPill(entries: [
            .init(kind: .goal, words: "Goal active", isRunning: true),
            .init(kind: .tasks, words: "Tasks 2/5"),
            .init(kind: .subagents, words: "1 helper", isRunning: true, accessibilityWords: "1 helper · 3 done"),
            .init(kind: .background, words: "2 background", isRunning: true)])
        #expect(pill.words() == "Tasks 2/5 · 1 helper · 2 background · Goal active")
        #expect(pill.words(maxSegments: 2) == "Tasks 2/5 · 1 helper · +2 more")
        #expect(pill.accessibilityLabel.contains("1 helper · 3 done"))
        #expect(pill.accessibilityLabel.contains("2 background"))
    }

    /// 1043 said "1 helper · +2 more" when the other two were finished history: overflow counts current work only.
    @Test func finishedHistoryIsNeverCountedAsMore() {
        let pill = ActivityPill(entries: [
            .init(kind: .goal, words: "Goal done", isHistorical: true),
            .init(kind: .subagents, words: "1 helper", isRunning: true),
            .init(kind: .previousTasks, words: "Tasks 2/2", isHistorical: true)])
        #expect(pill.words() == "1 helper")
        #expect(pill.words(maxSegments: 1) == "1 helper")
        #expect(pill.current.map(\.kind) == [.subagents])
        #expect(pill.ordered.count == 3, "history is still reachable in the overview")
    }

    @Test func anUnfinishedEarlierPlanReadsAsTasksBeforeHelpers() {
        let pill = ActivityPill(entries: [
            .init(kind: .goal, words: "Goal active"),
            .init(kind: .subagents, words: "1 helper", isRunning: true),
            .init(kind: .previousTasks, words: "Tasks 1/2")])
        #expect(pill.words() == "Tasks 1/2 · 1 helper · Goal active")
    }

    @Test func completedHistoryOnlyStaysWhileItsDetailsAreBeingRead() {
        let pill = ActivityPill(entries: [.init(kind: .goal, words: "Goal done", isHistorical: true),
                                          .init(kind: .previousTasks, words: "Previous tasks 2/2", isHistorical: true)])
        #expect(!pill.shouldShow())
        #expect(pill.shouldShow(keepingDetailsOpen: true))
        #expect(!pill.isRunning)
    }

    /// 1043 put the parent's step in the pill as well as the transcript's "<Bot> is …" line: the same thing twice.
    @Test func parentRunningSpinsThePillButNeverPinsOrNamesItsStep() {
        var pill = ActivityPill(entries: [.init(kind: .tasks, words: "Tasks 0/1")], parentIsRunning: true)
        #expect(pill.isRunning)
        #expect(pill.shouldShow())
        #expect(pill.words() == "Tasks 0/1")
        pill.entries = []
        #expect(!pill.shouldShow(), "a running parent alone is the transcript's line, not a pill")
        pill.parentIsRunning = false
        #expect(!pill.shouldShow())
    }

    @Test func unresolvedFailureIsNotDiscardedWithFinishedHistory() {
        let pill = ActivityPill(entries: [.init(kind: .subagents, words: "1 helper failed", needsAttention: true, isHistorical: true)])
        #expect(pill.shouldShow())
        #expect(pill.needsAttention)
        #expect(!pill.isRunning)
        #expect(pill.words() == "1 helper failed")
        #expect(pill.singleAttentionKind == .subagents)
    }

    @Test func severalUrgentCategoriesAreNeverCalledOrdinaryOverflow() {
        let pill = ActivityPill(entries: [
            .init(kind: .goal, words: "Goal blocked", needsAttention: true),
            .init(kind: .subagents, words: "1 helper failed", needsAttention: true),
            .init(kind: .browser, words: "Browser needs you", needsAttention: true)])
        #expect(pill.words() == "3 need attention")
        #expect(pill.singleAttentionKind == nil)
        #expect(pill.accessibilityLabel.contains("Browser needs you"))
    }
}
