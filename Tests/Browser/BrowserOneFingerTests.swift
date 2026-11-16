// What one finger, or the mouse's button, sends to a held browser's page (HermesKit/Browser/BrowserTrackpadMath.swift).
// A tester (2026-11-16): drag and drop did nothing on the iPhone or the Mac; the press was never sent.

import CoreGraphics
import Foundation
import Testing
@testable import HermesHQNative

@Suite struct BrowserOneFingerTests {
    typealias Out = BrowserOneFinger.Out

    // MARK: A finger on glass (the screen is a trackpad)

    @Test func aTapClicks() {
        var finger = BrowserOneFinger(kind: .trackpad)
        #expect(finger.lifted() == [.tap])
    }

    @Test func aFingerThatTravelsOnlyMovesThePointer() {
        var finger = BrowserOneFinger(kind: .trackpad)
        #expect(finger.travelled() == [])
        #expect(finger.held() == [], "a hold after the finger has travelled arms nothing")
        #expect(finger.travelled() == [])
        #expect(finger.lifted() == [], "no click, no button")
        #expect(!finger.buttonDown)
    }

    /// The report: hold, then drag. The page's button goes down at the first travel and comes up at the lift.
    @Test func aHoldThenATravelPressesDragsAndLetsGo() {
        var finger = BrowserOneFinger(kind: .trackpad)
        #expect(finger.held() == [.look(true)])
        #expect(!finger.buttonDown, "the hold only arms: nothing is pressed while the finger is still")
        #expect(finger.travelled() == [.down])
        #expect(finger.buttonDown)
        #expect(finger.travelled() == [], "one press for the whole drag")
        #expect(finger.lifted() == [.up, .look(false)])
        #expect(!finger.buttonDown)
    }

    @Test func aHoldLiftedWithoutTravelIsAClick() {
        var finger = BrowserOneFinger(kind: .trackpad)
        #expect(finger.held() == [.look(true)])
        #expect(finger.held() == [], "arming once")
        #expect(finger.lifted() == [.look(false), .tap])
    }

    @Test func aCancelledTouchLetsTheButtonGoAndNeverClicks() {
        var dragging = BrowserOneFinger(kind: .trackpad)
        _ = dragging.held()
        _ = dragging.travelled()
        #expect(dragging.cancelled() == [.up, .look(false)])
        #expect(dragging.cancelled() == [], "let go once")
        var armed = BrowserOneFinger(kind: .trackpad)
        _ = armed.held()
        #expect(armed.cancelled() == [.look(false)])
        var plain = BrowserOneFinger(kind: .trackpad)
        #expect(plain.cancelled() == [])
    }

    // MARK: A mouse or a trackpad's pointer (the Mac, an iPad's)

    @Test func aMouseClickClicks() {
        var mouse = BrowserOneFinger(kind: .direct)
        #expect(mouse.held() == [], "no hold to wait for")
        #expect(mouse.lifted() == [.tap])
    }

    @Test func aMousePressedAndMovedDragsAtOnce() {
        var mouse = BrowserOneFinger(kind: .direct)
        #expect(mouse.travelled() == [.look(true), .down])
        #expect(mouse.buttonDown)
        #expect(mouse.travelled() == [])
        #expect(mouse.lifted() == [.up, .look(false)])
        var cancelled = BrowserOneFinger(kind: .direct)
        _ = cancelled.travelled()
        #expect(cancelled.cancelled() == [.up, .look(false)])
        var still = BrowserOneFinger(kind: .direct)
        #expect(still.cancelled() == [], "a press taken away before it moved sent nothing")
    }

    // MARK: Where a pointer points

    @Test func aCursorOnThePageIsItsFractionAndBesideItTheNearestEdge() {
        typealias M = BrowserTrackpadMath
        // A 400 x 200 page drawn at (0, 100) in a 400 x 400 stage.
        let view = M.place(stage: CGSize(width: 400, height: 400), page: CGSize(width: 1200, height: 600), zoom: 1, x: 0, y: 0)
        #expect(view.frame == CGRect(x: 0, y: 100, width: 400, height: 200))
        #expect(M.clamped(CGPoint(x: 100, y: 150), in: view) == CGPoint(x: 0.25, y: 0.25))
        #expect(M.clamped(CGPoint(x: 100, y: 20), in: view) == CGPoint(x: 0.25, y: 0), "the margin above the page: its top edge")
        #expect(M.clamped(CGPoint(x: 500, y: 390), in: view) == CGPoint(x: 1, y: 1))
        #expect(M.fraction(CGPoint(x: 100, y: 20), in: view) == nil)
        #expect(M.clamped(CGPoint(x: 1, y: 1), in: M.View()) == nil, "no page yet")
        // Zoomed in twice about the top-left: the same cursor is half as far into the page.
        let zoomed = M.place(stage: CGSize(width: 400, height: 400), page: CGSize(width: 1200, height: 600), zoom: 2, x: 0, y: 0)
        #expect(M.clamped(CGPoint(x: 200, y: 100), in: zoomed) == CGPoint(x: 0.25, y: 0.25))
    }
}
