// Presentation only: a plan is not evidence of live work. All categories stay available in the overview.
nonisolated enum ShelfPieceKind: Int, CaseIterable, Hashable, Sendable {
    case goal, tasks, subagents, background, previousTasks, browser
}

nonisolated struct ActivityPill: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var kind: ShelfPieceKind
        var words: String
        var isRunning = false
        var needsAttention = false
        var accessibilityWords: String? = nil
        var isHistorical = false
    }

    var entries: [Entry]
    var parentIsRunning = false
    var currentStep: String? = nil

    /// Attention first, then task progress and independently running work. Ties retain category order.
    var ordered: [Entry] {
        entries.sorted { lhs, rhs in
            func rank(_ entry: Entry) -> Int {
                if entry.needsAttention { return 0 }
                if entry.kind == .tasks { return 1 }
                if entry.isRunning, entry.kind == .subagents || entry.kind == .background { return 2 }
                if entry.isRunning { return 3 }
                return 4
            }
            let l = rank(lhs), r = rank(rhs)
            return l == r ? lhs.kind.rawValue < rhs.kind.rawValue : l < r
        }
    }

    var isRunning: Bool { parentIsRunning || entries.contains { $0.isRunning } }
    var needsAttention: Bool { entries.contains { $0.needsAttention } }
    var singleAttentionKind: ShelfPieceKind? {
        let urgent = entries.filter(\.needsAttention)
        return urgent.count == 1 ? urgent[0].kind : nil
    }
    var accessibilityLabel: String {
        let parts = ordered.map { $0.accessibilityWords ?? $0.words }
        return (parts.isEmpty ? currentStep ?? "Working" : parts.joined(separator: ", ")) + (isRunning ? ", running" : "")
    }

    /// Finished history is reachable alongside current work, but never pins an otherwise empty live surface.
    func shouldShow(keepingDetailsOpen: Bool = false) -> Bool {
        parentIsRunning || entries.contains { !$0.isHistorical || $0.isRunning || $0.needsAttention }
            || (keepingDetailsOpen && !entries.isEmpty)
    }

    /// Overflow counts categories, never adds checklist items to workers. Width is measured by UIKit.
    func words(maxSegments: Int = 2) -> String {
        let current = ordered.filter { !$0.isHistorical || $0.needsAttention || $0.isRunning }
        let urgent = current.filter(\.needsAttention)
        if urgent.count > max(1, maxSegments) {
            let other = entries.count - urgent.count
            return "\(urgent.count) need attention" + (other > 0 ? " · +\(other) more" : "")
        }
        if current.isEmpty, parentIsRunning {
            return (currentStep ?? "Working") + (entries.isEmpty ? "" : " · +\(entries.count) more")
        }
        let shown = Array((current.isEmpty ? ordered : current).prefix(max(1, maxSegments)))
        let overflow = entries.count - shown.count
        return (shown.map(\.words) + (overflow > 0 ? ["+\(overflow) more"] : [])).joined(separator: " · ")
    }
}
