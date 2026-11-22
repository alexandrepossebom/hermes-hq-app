// #351: on the Mac a bot's Screen (and Watch Browser) opens in a window of its own that can be resized, zoomed and made
// full screen. The picture follows the window's size, a zoomed picture keeps its middle, the pointer stays on the same
// pixel, and asking for a viewer while one is up brings it forward or replaces it.

import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor struct ScreenWindowTests {
    private let framebuffer = (1600, 1000)
    private var aspect: CGFloat { CGFloat(framebuffer.0) / CGFloat(framebuffer.1) }

    private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool { abs(a - b) <= tolerance }

    /// The fraction of the desktop at the stage's middle.
    private func middle(_ view: ScreenView, _ stage: CGSize) -> CGPoint {
        let rect = ScreenViewMath.drawn(stage: stage, aspect: aspect, view: view)
        return CGPoint(x: (stage.width / 2 - rect.minX) / rect.width, y: (stage.height / 2 - rect.minY) / rect.height)
    }

    private func context(_ stage: CGSize, control: Bool = true) -> ScreenGesture.Context {
        ScreenGesture.Context(control: control, stage: stage, aspect: aspect, framebuffer: framebuffer)
    }

    @Test func aZoomedPictureKeepsItsMiddleAsTheWindowGrowsAndShrinks() {
        let small = CGSize(width: 600, height: 375)
        let zoomed = ScreenViewMath.clampToDesktop(ScreenViewMath.zoomAbout(.fit, factor: 2, at: CGPoint(x: 450, y: 100),
                                                                            width: small.width, height: small.height),
                                                   width: small.width, height: small.height, aspect: aspect)
        let before = middle(zoomed, small)
        // Bigger, the same shape; wider than the desktop (bands at the sides); taller than it.
        for stage in [CGSize(width: 1200, height: 750), CGSize(width: 1500, height: 700), CGSize(width: 1100, height: 900)] {
            let next = ScreenViewMath.resized(zoomed, from: small, to: stage, aspect: aspect)
            #expect(next.zoom == 2)
            let after = middle(next, stage)
            #expect(close(after.x, before.x) && close(after.y, before.y), "\(stage): \(after) ≠ \(before)")
            // And back: the same part of the desktop as at first.
            let back = ScreenViewMath.resized(next, from: stage, to: small, aspect: aspect)
            #expect(close(back.x, zoomed.x, 0.5) && close(back.y, zoomed.y, 0.5))
        }
        // So tall that the middle would pull the desktop's top edge down into the window: it stops at the edge.
        let tall = CGSize(width: 1100, height: 1300)
        let edge = ScreenViewMath.resized(zoomed, from: small, to: tall, aspect: aspect)
        #expect(close(middle(edge, tall).x, before.x))
        #expect(ScreenViewMath.drawn(stage: tall, aspect: aspect, view: edge).minY == 0)
        // Clamping alone (the old way) kept the top-left offset and slid the middle.
        let clamped = ScreenViewMath.clampToDesktop(zoomed, width: 1200, height: 750, aspect: aspect)
        #expect(!close(middle(clamped, CGSize(width: 1200, height: 750)).x, before.x))
    }

    @Test func aZoomNearAnEdgeStaysInsideTheDesktop() {
        let small = CGSize(width: 600, height: 375)
        let corner = ScreenViewMath.clampToDesktop(ScreenView(zoom: 3, x: -5000, y: -5000), width: small.width, height: small.height, aspect: aspect)
        let stage = CGSize(width: 1400, height: 900)
        let next = ScreenViewMath.resized(corner, from: small, to: stage, aspect: aspect)
        let rect = ScreenViewMath.drawn(stage: stage, aspect: aspect, view: next)
        #expect(rect.maxX >= stage.width - 0.5 && rect.maxY >= stage.height - 0.5)   // no band past the desktop's edge
        #expect(next == ScreenViewMath.clampToDesktop(next, width: stage.width, height: stage.height, aspect: aspect))
    }

    @Test func atFitThePictureFillsTheNewSize() {
        for stage in [CGSize(width: 1200, height: 750), CGSize(width: 1500, height: 700), CGSize(width: 900, height: 1200)] {
            let next = ScreenViewMath.resized(.fit, from: CGSize(width: 600, height: 375), to: stage, aspect: aspect)
            let rect = ScreenViewMath.drawn(stage: stage, aspect: aspect, view: next)
            let fitted = ScreenViewMath.fitted(width: stage.width, height: stage.height, aspect: aspect)
            #expect(close(rect.width, fitted.width) && close(rect.height, fitted.height))
            #expect(close(rect.midX, stage.width / 2) && close(rect.midY, stage.height / 2))
            #expect(close(rect.width, stage.width) || close(rect.height, stage.height))   // touches two edges
        }
        // Nothing to go by yet: only clamped.
        #expect(ScreenViewMath.resized(ScreenView(zoom: 2, x: -10, y: -10), from: .zero, to: CGSize(width: 800, height: 500), aspect: aspect).zoom == 2)
        #expect(ScreenViewMath.resized(.fit, from: CGSize(width: 600, height: 375), to: .zero, aspect: aspect) == ScreenViewMath.clampToDesktop(.fit, width: 0, height: 0, aspect: aspect))
    }

    private func swipe(_ gesture: inout ScreenGesture, _ from: CGPoint, _ to: CGPoint, _ stage: CGSize, at now: TimeInterval) {
        _ = gesture.began([from], now: now, context(stage))
        _ = gesture.moved([to], context(stage))
        _ = gesture.ended(remaining: 0, now: now + 0.1, context(stage))
    }

    @Test func thePointerStaysOnItsPixelAndMovesByTheNewSize() {
        let small = CGSize(width: 600, height: 375), big = CGSize(width: 1500, height: 900)
        var gesture = ScreenGesture()
        swipe(&gesture, CGPoint(x: 100, y: 100), CGPoint(x: 160, y: 130), small, at: 0)
        let pixel = gesture.pointer.pixel(framebuffer)
        #expect(pixel != (800, 500))   // it moved off the centre
        gesture.resized(from: small, context(big))
        gesture.relayout(context(big))
        #expect(gesture.pointer.pixel(framebuffer) == pixel)
        // A swipe in the bigger window moves the pointer by the desktop as now drawn, as in a window opened that big.
        var fresh = ScreenGesture()
        swipe(&fresh, CGPoint(x: 100, y: 100), CGPoint(x: 160, y: 130), small, at: 0)
        fresh.relayout(context(big))
        swipe(&gesture, CGPoint(x: 300, y: 300), CGPoint(x: 600, y: 450), big, at: 1)
        swipe(&fresh, CGPoint(x: 300, y: 300), CGPoint(x: 600, y: 450), big, at: 1)
        #expect(gesture.pointer == fresh.pointer)
        // Drawn 1440 × 900 in a 1500 × 900 window: 300 points across is 300/1440 of the desktop's 1600 pixels.
        #expect(abs(gesture.pointer.pixel(framebuffer).x - pixel.x - Int((300.0 / 1440.0 * 1600).rounded())) <= 1)
        #expect(abs(gesture.pointer.pixel(framebuffer).y - pixel.y - Int((150.0 / 900.0 * 1000).rounded())) <= 1)
    }

    @Test func askingAgainBringsItForwardOrReplacesItOnlyInItsOwnWindow() {
        #expect(ViewerReopen.decide(shown: nil, leaving: false, asked: "otto", ownWindow: false) == .open)
        #expect(ViewerReopen.decide(shown: nil, leaving: false, asked: "otto", ownWindow: true) == .open)
        // iPhone, iPad, or the Mac's pane: one at a time, as before.
        #expect(ViewerReopen.decide(shown: "otto", leaving: false, asked: "otto", ownWindow: false) == .ignore)
        #expect(ViewerReopen.decide(shown: "otto", leaving: false, asked: "ivy", ownWindow: false) == .ignore)
        // The Mac's own window.
        #expect(ViewerReopen.decide(shown: "otto", leaving: false, asked: "otto", ownWindow: true) == .front)
        #expect(ViewerReopen.decide(shown: "otto", leaving: false, asked: "ivy", ownWindow: true) == .replace)
        // One on its way out finishes first.
        #expect(ViewerReopen.decide(shown: "otto", leaving: true, asked: "ivy", ownWindow: true) == .ignore)
    }

    @Test func offTheMacNoViewerGetsAWindow() {
        #if !targetEnvironment(macCatalyst)
        let page = PlainPage()
        #expect(!ViewerWindow.open(page, title: "Otto’s Screen") { Issue.record("no window was asked for") })
        #expect(!ViewerWindow.owns(page))
        #expect(!ViewerWindow.close(page))
        #expect(!ViewerWindow.bringForward(page))
        #expect(ViewerWindow.scene(of: page) == nil)
        #endif
    }
}

private final class PlainPage: UIViewController, MacWindowPage {
    func windowClosed() {}
}
