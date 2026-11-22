import Foundation
import UIKit
import UniformTypeIdentifiers
import Testing
@testable import HermesHQNative

// [spring-drop] Files dragged over a chat's row in a list: held there the row opens (owner 2026-11-22), let go there
// they go to that chat.

@Suite("Spring drop: the hold on a chat's row")
struct SpringHoldTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    @Test func opensOnlyAfterTheDelay() {
        var hold = SpringHold()
        let moved = hold.over("a", at: start)
        #expect(moved)
        #expect(hold.due(at: start.addingTimeInterval(SpringHold.delay / 2)) == nil)
        #expect(hold.due(at: start.addingTimeInterval(SpringHold.delay)) == "a")
    }

    @Test func movingToAnotherRowStartsTheClockAgain() {
        var hold = SpringHold()
        hold.over("a", at: start)
        let moved = hold.over("b", at: start.addingTimeInterval(0.5))
        #expect(moved)
        #expect(hold.due(at: start.addingTimeInterval(SpringHold.delay)) == nil)
        #expect(hold.due(at: start.addingTimeInterval(0.5 + SpringHold.delay)) == "b")
    }

    @Test func theSameRowIsNotAChange() {
        var hold = SpringHold()
        hold.over("a", at: start)
        let moved = hold.over("a", at: start.addingTimeInterval(0.3))
        #expect(!moved)
        #expect(hold.due(at: start.addingTimeInterval(SpringHold.delay)) == "a")   // the clock kept running
    }

    @Test func anOpenedRowWaitsForTheDragToLeaveIt() {
        var hold = SpringHold()
        hold.over("a", at: start)
        hold.didOpen("a")
        #expect(hold.due(at: start.addingTimeInterval(5)) == nil)
        hold.over(nil, at: start.addingTimeInterval(5))
        hold.over("a", at: start.addingTimeInterval(6))
        #expect(hold.due(at: start.addingTimeInterval(6 + SpringHold.delay)) == "a")
    }

    @Test func offEveryRowNothingOpens() {
        var hold = SpringHold()
        hold.over(nil, at: start)
        #expect(hold.due(at: start.addingTimeInterval(10)) == nil)
        hold.over("a", at: start)
        hold.reset()
        #expect(hold.due(at: start.addingTimeInterval(10)) == nil)
    }
}

/// A drop session from outside the app carrying `types`, at `point` in whatever view asks.
@MainActor private final class FakeDropSession: NSObject, @MainActor UIDropSession {
    var point: CGPoint
    let items: [UIDragItem]
    var local: UIDragSession?

    init(types: [String], at point: CGPoint) {
        self.point = point
        items = [UIDragItem(itemProvider: FakeDropSession.provider(types))]
    }

    static func provider(_ types: [String]) -> NSItemProvider {
        let provider = NSItemProvider()
        for type in types {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { done in
                done(Data("x".utf8), nil)
                return nil
            }
        }
        return provider
    }

    var localDragSession: UIDragSession? { local }
    var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .none
    var progress: Progress { Progress() }
    var allowsMoveOperation: Bool { false }
    var isRestrictedToDraggingApplication: Bool { false }
    func location(in view: UIView) -> CGPoint { point }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool { false }
    func loadObjects(ofClass aClass: any NSItemProviderReading.Type, completion: @escaping ([any NSItemProviderReading]) -> Void) -> Progress {
        Progress()
    }
}

@MainActor
@Suite("Spring drop: a list's rows under a file drag")
struct SessionFileDropTests {
    private func list() -> (UIView, UIView, UIView) {
        let list = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let first = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 50))
        let second = UIView(frame: CGRect(x: 0, y: 50, width: 300, height: 50))
        list.addSubview(first)
        list.addSubview(second)
        return (list, first, second)
    }

    private func drop(_ list: UIView, _ rows: [UIView], opened: @escaping (String) -> Void) -> SessionFileDrop {
        let drop = SessionFileDrop(list: list)
        drop.target = { point in
            guard let index = rows.firstIndex(where: { $0.frame.contains(point) }) else { return nil }
            let key = "row\(index)"
            return SessionFileDrop.Target(key: key, view: rows[index], chat: .session(profile: "p", id: key), open: { opened(key) })
        }
        return drop
    }

    @Test func aFileOverARowLightsItAndHeldThereOpensIt() async throws {
        let (view, first, second) = list()
        var opened: [String] = []
        let drop = drop(view, [first, second]) { opened.append($0) }
        let session = FakeDropSession(types: [UTType.pdf.identifier], at: CGPoint(x: 20, y: 70))
        #expect(drop.update(session) == .copy)
        #expect(second.subviews.contains { $0 is SpringLight })
        #expect(opened.isEmpty)
        try await Task.sleep(for: .seconds(SpringHold.delay + 0.8))   // the hold, then the blink
        #expect(opened == ["row1"])
        // Still resting on the row it opened: it does not open again.
        #expect(drop.update(session) == .copy)
        try await Task.sleep(for: .seconds(SpringHold.delay + 0.8))
        #expect(opened == ["row1"])
        drop.exit()
    }

    @Test func leavingBeforeTheHoldOpensNothing() async throws {
        let (view, first, second) = list()
        var opened: [String] = []
        let drop = drop(view, [first, second]) { opened.append($0) }
        let session = FakeDropSession(types: [UTType.pdf.identifier], at: CGPoint(x: 20, y: 20))
        #expect(drop.update(session) == .copy)
        session.point = CGPoint(x: 20, y: 150)   // below the rows
        #expect(drop.update(session) == .cancel)
        try await Task.sleep(for: .seconds(SpringHold.delay + 0.5))
        #expect(opened.isEmpty)
        #expect(!drop.debugLit)
    }

    @Test func textAndDragsFromInsideTheAppAreLeftAlone() {
        let (view, first, second) = list()
        let drop = drop(view, [first, second]) { _ in }
        let link = FakeDropSession(types: [UTType.url.identifier], at: CGPoint(x: 20, y: 20))
        #expect(!SessionFileDrop.carriesFiles(link))
        #expect(drop.update(link) == .cancel)
        let snippet = FakeDropSession(types: [UTType.utf8PlainText.identifier], at: CGPoint(x: 20, y: 20))
        #expect(drop.update(snippet) == .cancel)
        #expect(!drop.debugLit)
    }

    @Test func lettingGoOnARowHandsTheFilesToItsChatAndOpensIt() {
        let (view, first, second) = list()
        var opened: [String] = []
        let drop = drop(view, [first, second]) { opened.append($0) }
        let session = FakeDropSession(types: [UTType.pdf.identifier], at: CGPoint(x: 20, y: 20))
        _ = drop.update(session)
        #expect(drop.perform(session))
        #expect(opened == ["row0"])
        #expect(DroppedFilesHandOff.debugWaiting == .session(profile: "p", id: "row0"))
        #expect(!drop.debugLit)
    }

    @Test func lettingGoOffTheRowsDoesNothing() {
        let (view, first, second) = list()
        var opened: [String] = []
        let drop = drop(view, [first, second]) { opened.append($0) }
        let session = FakeDropSession(types: [UTType.pdf.identifier], at: CGPoint(x: 20, y: 180))
        #expect(!drop.perform(session))
        #expect(opened.isEmpty)
    }
}
