// [mac-tasks-row] The Mac's Tasks view pills in one row (owner 2026-11-22): every pill when they fit, else as many as
// fit in order beside "More", the picked view always out.

import CoreGraphics
import Testing
@testable import HermesHQNative

struct TaskViewsFitTests {
    private let keys = ["goals", "today", "upcoming", "inbox", "bots", "list.Home"]
    private let widths: [String: CGFloat] = ["goals": 70, "today": 80, "upcoming": 90, "inbox": 60, "bots": 60,
                                             "list.Home": 80, "+": 30, "more": 70]

    @Test func aWideRowShowsEveryPillAndNoMore() {
        let fit = TaskViewsFit.fit(keys: keys, picked: "today", widths: widths, newList: "+", available: 1000, spacing: 8)
        #expect(fit == .init(shown: Set(keys), more: false))
    }

    @Test func aNarrowRowShowsWhatFitsInOrderThenMore() {
        // 70 + 8 + 80 + 8 + 90 = 256; + 8 + 60 = 324 > 400 - 70 - 8 = 322
        let fit = TaskViewsFit.fit(keys: keys, picked: "today", widths: widths, newList: "+", available: 400, spacing: 8)
        #expect(fit == .init(shown: ["goals", "today", "upcoming"], more: true))
    }

    @Test func thePickedViewStaysOutWhenItWouldNotFit() {
        let fit = TaskViewsFit.fit(keys: keys, picked: "list.Home", widths: widths, newList: "+", available: 400, spacing: 8)
        #expect(fit.more)
        #expect(fit.shown.contains("list.Home"))
        #expect(fit.shown == ["goals", "today", "list.Home"])
    }

    @Test func newListCountsOnlyWhenEverythingElseFits() {
        // The pills alone are 440 + 40 = 480; with "+" 518.
        let without = TaskViewsFit.fit(keys: keys, picked: "today", widths: widths, newList: nil, available: 500, spacing: 8)
        #expect(!without.more)
        let with = TaskViewsFit.fit(keys: keys, picked: "today", widths: widths, newList: "+", available: 500, spacing: 8)
        #expect(with.more)
    }

    @Test func forcedMoreFitsBesideMoreEvenWhenAllWouldFit() {
        // The row overflowed with counts on; the bare widths are fitted beside More, not shown whole without it.
        let fit = TaskViewsFit.fit(keys: keys, picked: "today", widths: widths, newList: nil, available: 1000, spacing: 8,
                                   forceMore: true)
        #expect(fit == .init(shown: Set(keys), more: true))
    }

    @Test func beforeTheyAreMeasuredEveryPillShows() {
        let fit = TaskViewsFit.fit(keys: keys, picked: "today", widths: [:], newList: "+", available: 300, spacing: 8)
        #expect(fit == .init(shown: Set(keys), more: false))
    }
}
