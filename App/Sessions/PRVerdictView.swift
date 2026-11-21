// [pr-verdict] Owner 2026-11-21 (option B of artifacts/coding-pr-review/mock1.html, "rows carry the verdict"): what a
// coding row says at its subtitle's trailing end about its lead pull request (`PRVerdict`,
// HermesKit/Model/PullRequestFacts.swift). Quiet: the subtitle's own ink, caption size, regular weight, monospaced
// digits; the theme's red only when checks fail. Never cut: it takes its own width and the subtitle's words give way.

import SwiftUI

/// The verdict's mark: a check, a cross (red), or the quarter ring the header's Working chip draws.
struct PRVerdictMark: View {
    let verdict: PRVerdict
    var ink: Color

    var body: some View {
        switch verdict {
        case .passed:
            Image(systemName: "checkmark")
                .font(Font.hq(.caption2).weight(.semibold))
                .foregroundStyle(ink)
        case .failing:
            Image(systemName: "xmark")
                .font(Font.hq(.caption2).weight(.semibold))
                .foregroundStyle(Color.hqRed)
        case .running:
            ZStack {
                Circle().stroke(ink.opacity(0.3), lineWidth: 1.5)
                Circle().trim(from: 0, to: 0.25).stroke(ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            .frame(width: HQFont.scaled(8), height: HQFont.scaled(8))
            .padding(.trailing, 2)   // a symbol brings its own side bearing; the ring has none and sat against the words
        case .size:
            EmptyView()
        }
    }
}

/// The mark, then its words ("+128 −12", "2 checks failing", "checks running"); the row's spoken label says it.
struct PRVerdictView: View {
    let verdict: PRVerdict
    var ink: Color

    var body: some View {
        HStack(spacing: 3) {
            PRVerdictMark(verdict: verdict, ink: ink)
            if let words = verdict.words {
                Text(verbatim: words)
                    .font(Font.hq(.caption))
                    .monospacedDigit()
                    .foregroundStyle(isFailing ? Color.hqRed : ink)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .layoutPriority(2)
        .accessibilityHidden(true)
    }

    private var isFailing: Bool {
        if case .failing = verdict { return true }
        return false
    }
}
