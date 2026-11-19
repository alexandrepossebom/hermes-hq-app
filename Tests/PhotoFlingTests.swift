import CoreGraphics
import Testing
@testable import HermesHQNative

/// Owner 2026-11-19: flinging a photo away closes the viewer (`PhotoFling`).
@MainActor struct PhotoFlingTests {
    private let both: PhotoFling.Directions = [.up, .down]

    @Test func aQuickFlickClosesWithLittleTravel() {
        #expect(PhotoFling.closes(translation: CGPoint(x: 0, y: -30), velocity: CGPoint(x: 0, y: -900), directions: .up))
        #expect(PhotoFling.closes(translation: CGPoint(x: 0, y: 30), velocity: CGPoint(x: 0, y: 900), directions: both))
    }

    @Test func aSlowDragClosesPastTheDistance() {
        #expect(PhotoFling.closes(translation: CGPoint(x: 0, y: -150), velocity: .zero, directions: .up))
        #expect(!PhotoFling.closes(translation: CGPoint(x: 0, y: -60), velocity: .zero, directions: .up))
    }

    @Test func aDragFlickedBackSettles() {
        #expect(!PhotoFling.closes(translation: CGPoint(x: 0, y: -150), velocity: CGPoint(x: 0, y: 1200), directions: both))
        #expect(!PhotoFling.closes(translation: CGPoint(x: 0, y: 150), velocity: CGPoint(x: 0, y: -1200), directions: both))
    }

    @Test func onlyTheDirectionsItHandles() {
        // The chat viewer's fling is up only: the system zoom transition owns the drag down.
        #expect(!PhotoFling.closes(translation: CGPoint(x: 0, y: 200), velocity: CGPoint(x: 0, y: 1500), directions: .up))
        #expect(!PhotoFling.begins(velocity: CGPoint(x: 0, y: 500), directions: .up))
        #expect(PhotoFling.begins(velocity: CGPoint(x: 0, y: -500), directions: .up))
        #expect(PhotoFling.begins(velocity: CGPoint(x: 0, y: 500), directions: both))
    }

    @Test func sidewaysNeverBegins() {
        #expect(!PhotoFling.begins(velocity: CGPoint(x: 800, y: -300), directions: both))
        #expect(!PhotoFling.begins(velocity: CGPoint(x: -800, y: 300), directions: both))
        #expect(PhotoFling.begins(velocity: CGPoint(x: 300, y: -800), directions: both), "a diagonal, mostly up, begins")
    }
}
