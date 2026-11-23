import Foundation
import Testing
@testable import HermesHQNative

/// [sessions-motion] Owner 2026-11-22: opening a project "feels jerky". The list faded out before the page faded in,
/// so neither was on screen for a few frames. These pin the replacement: both views fully drawn the whole way and
/// never standing over each other.
struct SessionsSlideTests {
    private let width: CGFloat = 402
    private let all: [SessionsSlide] = [.toProjects, .toBots, .intoProject, .outOfProject, .toNextProject, .toPreviousProject]

    /// Where each view's leading edge is at progress `p` (every piece rides the same spring, so progress is shared).
    private func edges(_ path: SessionsSlide.Path, _ p: CGFloat) -> (new: CGFloat, old: CGFloat) {
        (path.newFrom * (1 - p), path.oldTo * p)
    }

    @Test func everyMoveEndsWithTheNewViewInPlaceAndTheOldOneAside() {
        for motion in all {
            let path = motion.path(width: width)
            #expect(path.newFrom != 0, "\(motion): the new view starts off its place")
            #expect(path.oldTo != 0, "\(motion): the old view moves")
            #expect((path.newFrom > 0) != (path.oldTo > 0), "\(motion): the two go the same way")
        }
    }

    @Test func sideBySideMovesKeepTheViewsAWidthApartTheWholeWay() {
        for motion in all where motion.path(width: width).layering == .sideBySide {
            let path = motion.path(width: width)
            for step in 0...20 {
                let (new, old) = edges(path, CGFloat(step) / 20)
                #expect(abs(abs(new - old) - width) < 0.001, "\(motion) at \(step): gap \(new - old)")
            }
        }
    }

    /// The view beneath is cut exactly at the leading edge of the one on top, at the start, the end and in between
    /// (the cut's width is animated on the same spring, so linear in progress).
    @Test func theViewBeneathIsCutAtTheEdgeOfTheOneOnTop() {
        for motion in [SessionsSlide.intoProject, .outOfProject] {
            let path = motion.path(width: width)
            let start = path.underShown(atStart: true), end = path.underShown(atStart: false)
            for step in 0...20 {
                let p = CGFloat(step) / 20
                let (new, old) = edges(path, p)
                let shown = start + (end - start) * p
                let (top, beneath) = path.layering == .newOnTop ? (new, old) : (old, new)
                #expect(abs(beneath + shown - top) < 0.001, "\(motion) at \(step)")
                #expect(shown >= 0 && shown <= width)
            }
        }
    }

    @Test func intoAPageItComesOverTheListAndOutOfItItLeavesOverIt() {
        #expect(SessionsSlide.intoProject.path(width: width).layering == .newOnTop)
        #expect(SessionsSlide.intoProject.path(width: width).newFrom == width)
        #expect(SessionsSlide.outOfProject.path(width: width).layering == .oldOnTop)
        #expect(SessionsSlide.outOfProject.path(width: width).oldTo == width)
        #expect(SessionsSlide.toProjects.path(width: width).newFrom > 0)   // Projects is the switch's right side
        #expect(SessionsSlide.toBots.path(width: width).newFrom < 0)
    }

    @Test func oneProjectToAnotherGoesTheWayThePillsGo() {
        let pills = ["home", "site", "app", "reading"]
        #expect(SessionsViewController.pageToPage(from: "site", to: "reading", pills: pills) == .toNextProject)
        #expect(SessionsViewController.pageToPage(from: "reading", to: "home", pills: pills) == .toPreviousProject)
        #expect(SessionsViewController.pageToPage(from: "site", to: "site", pills: pills) == nil)
        #expect(SessionsViewController.pageToPage(from: nil, to: "site", pills: pills) == nil)
        #expect(SessionsViewController.pageToPage(from: "gone", to: "site", pills: pills) == nil)
    }
}
