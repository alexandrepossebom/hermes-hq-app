import Testing
import UIKit
@testable import HermesHQNative

#if DEBUG
@MainActor @Suite("Activity motion phase calibration", .serialized)
struct ActivityMotionPhaseTests {
    private func row(_ y: CGFloat) -> [String: CGRect] {
        ["row": CGRect(x: 0, y: y, width: 100, height: 40)]
    }

    @Test func freshBaselineExposesBounceHiddenByLifetimeMaximum() {
        var lifetime = ActivityMotionPhaseWindow()
        lifetime.reset(rows: row(100))
        lifetime.sample(rows: row(50)) // cold hydration: 50 points
        let before = lifetime.still
        var post = ActivityMotionPhaseWindow()
        post.reset(rows: row(50))
        lifetime.sample(rows: row(53))
        post.sample(rows: row(53))
        lifetime.sample(rows: row(50))
        post.sample(rows: row(50))
        #expect(before == 50)
        #expect(lifetime.still == before, "a lifetime max comparison misses this later bounce")
        #expect(post.still == 3, "a separately baselined phase catches it")
        #expect(post.reversals == 1)
        #expect(post.baselineIDs.count == 1 && post.matchedBaselineIDs.count == 1)
        #expect(post.frames == 2)
    }

    @Test func missingOrUnmatchedBaselineCannotPassNonvacuity() {
        var phase = ActivityMotionPhaseWindow()
        phase.reset(rows: [:])
        phase.sample(rows: row(100))
        #expect(phase.frames == 1 && phase.tracks.count == 1)
        #expect(phase.baselineIDs.isEmpty && phase.matchedBaselineIDs.isEmpty)
        phase.reset(rows: row(100))
        phase.sample(rows: ["other": CGRect(x: 0, y: 100, width: 100, height: 40)])
        #expect(phase.baselineIDs.count == 1 && phase.matchedBaselineIDs.isEmpty)
        phase.sample(rows: row(100))
        #expect(phase.matchedBaselineIDs.count == 1)
    }

    @Test func baselineCoverageIncludesReplacementEmptyAndReturn() {
        var phase = ActivityMotionPhaseWindow()
        phase.reset(rows: row(100))
        phase.sample(rows: row(100))
        #expect(phase.matchedBaselineIDs.count == 1)
        phase.sample(rows: ["replacement": CGRect(x: 0, y: 100, width: 100, height: 40)])
        #expect(phase.matchedBaselineIDs.count == 0)
        phase.sample(rows: [:])
        #expect(phase.matchedBaselineIDs.count == 0)
        phase.sample(rows: row(100))
        #expect(phase.matchedBaselineIDs.count == 1)
        #expect(phase.frames == 4 && phase.coveredFrames == 2 && phase.uncoveredFrames == 2)
    }

    @Test func openingCoverageRetainsADisappearanceAfterTheRowReturns() {
        var opening = ActivityMotionPhaseWindow()
        opening.reset(rows: row(100))
        opening.sample(rows: row(100))
        opening.sample(rows: [:])
        opening.sample(rows: row(100))
        #expect(opening.frames == 3 && opening.matchedBaselineIDs.count == 1)
        #expect(opening.uncoveredFrames == 1 && opening.coveredFrames != opening.frames,
                "a final match cannot erase an unobserved interval during the push")
    }

    @Test func zeroModelHeightStillSamplesAnOutgoingPresentation() {
        let model = CALayer(), presented = CALayer(), header = CALayer()
        model.frame = CGRect(x: 20, y: 500, width: 300, height: 0)
        presented.frame = CGRect(x: 20, y: 500, width: 300, height: 20)
        header.frame = CGRect(x: 0, y: 0, width: 200, height: 44)
        #expect(!ActivityShelfPresentationCheck.needsSampling(model: model, presentation: nil, headerPresentation: nil))
        #expect(ActivityShelfPresentationCheck.needsSampling(model: model, presentation: presented, headerPresentation: nil))
        presented.frame = model.frame
        #expect(ActivityShelfPresentationCheck.needsSampling(model: model, presentation: presented, headerPresentation: header))
        header.isHidden = true
        #expect(!ActivityShelfPresentationCheck.needsSampling(model: model, presentation: presented, headerPresentation: header))
        model.frame = CGRect(x: 20, y: 500, width: 300, height: 44)
        #expect(ActivityShelfPresentationCheck.needsSampling(model: model, presentation: nil, headerPresentation: nil),
                "a present model with no presentation must be counted as missing, not skipped")
    }

    @Test func shelfPresentationCalibrationRejectsFadeSlideResize() {
        let rect = CGRect(x: 20, y: 500, width: 300, height: 44)
        let stable = ActivityShelfPresentationCheck(model: rect, presentation: rect, modelOpacity: 1, presentationOpacity: 1)
        #expect(stable.geometryError == 0 && stable.opacityError == 0)
        let fade = ActivityShelfPresentationCheck(model: rect, presentation: rect, modelOpacity: 1, presentationOpacity: 0.5)
        #expect(fade.opacityError == 0.5)
        let slide = ActivityShelfPresentationCheck(model: rect, presentation: rect.offsetBy(dx: 8, dy: 0), modelOpacity: 1, presentationOpacity: 1)
        #expect(slide.geometryError == 8)
        let resized = ActivityShelfPresentationCheck(model: rect, presentation: CGRect(x: 20, y: 500, width: 290, height: 44), modelOpacity: 1, presentationOpacity: 1)
        #expect(resized.geometryError == 10)
        let rotation = ActivityShelfPresentationCheck(model: rect, presentation: rect, modelOpacity: 1, presentationOpacity: 1,
                                                       presentationTransform: CATransform3DMakeRotation(.pi, 0, 0, 1))
        #expect(rotation.transformError > 1)
    }

    @Test func layerCaptureIgnoresNavigationButDetectsShelfAnimation() {
        let modelChat = CALayer(), presentedChat = CALayer()
        modelChat.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        presentedChat.frame = CGRect(x: 170, y: 0, width: 400, height: 800)
        let model = CALayer(), presented = CALayer()
        model.frame = CGRect(x: 20, y: 500, width: 300, height: 44)
        presented.frame = model.frame
        modelChat.addSublayer(model); presentedChat.addSublayer(presented)
        func capture() -> ActivityShelfPresentationCheck {
            ActivityShelfPresentationCheck.capture(model: model, chat: modelChat, presentation: presented, presentationChat: presentedChat)
        }
        #expect(capture().geometryError == 0 && capture().opacityError == 0)
        presented.opacity = 0.5
        #expect(capture().opacityError == 0.5)
        presented.opacity = 1
        presented.position.x += 8
        #expect(capture().geometryError == 8)
        presented.frame = CGRect(x: 20, y: 500, width: 290, height: 44)
        #expect(capture().geometryError == 10)
    }

    @Test func warmVisibilityCalibrationDoesNotWaitForActualShelf() {
        let chat = CGRect(x: 0, y: 0, width: 400, height: 800)
        let expected = CGRect(x: 100, y: 600, width: 200, height: 44)
        func check(_ actual: CGRect, _ clip: CGRect, attached: Bool = true, opacity: CGFloat = 1) -> ActivityShelfVisibilityCheck {
            ActivityShelfVisibilityCheck(expected: expected, actual: actual, chat: chat, viewportInChat: clip, attached: attached, opacity: opacity)
        }
        let outsideViewport = CGRect(x: 0, y: 0, width: 90, height: 800)
        #expect(check(expected, outsideViewport).withinChat && !check(expected, outsideViewport).eligible)
        let viewport = CGRect(x: 0, y: 0, width: 150, height: 800)
        #expect(check(expected, viewport).eligible && check(expected, viewport).visibleWhenEligible)
        #expect(!check(expected, viewport, attached: false).withinChat, "hidden, detached or clipped ancestry is ineligible")
        #expect(!check(expected, viewport, opacity: 0).withinChat)
        let clippedHeader = CGRect(x: expected.minX, y: expected.minY, width: expected.width, height: 1)
        #expect(!check(clippedHeader, viewport).withinChat, "a one-point header cannot redefine the 44-point contract")
        #expect(!check(expected, viewport, opacity: 1 * 0).withinChat,
                "include a transparent chat root in the inherited opacity, not just the visible header")
        #expect(!check(expected.offsetBy(dx: 20, dy: 0), viewport).withinChat, "an in-chat offset still violates dock placement")
        #expect(!check(expected.offsetBy(dx: 500, dy: 0), viewport).withinChat)
        #expect(!check(expected.offsetBy(dx: 500, dy: 0), viewport).visibleWhenEligible)
        #expect(!check(expected, viewport, opacity: 0).visibleWhenEligible)
        let late = [check(expected, outsideViewport), check(expected, viewport, opacity: 0), check(expected, viewport)]
        #expect(late.first(where: { $0.eligible })?.visibleWhenEligible == false,
                "later visibility must not erase the first eligible failure")
    }

    @Test func openingPolicyMeasuresDockAnchorAndDiscreteMotion() {
        var opening = ActivityMotionPhaseWindow()
        opening.reset(rows: row(100), inset: 100, shelfExtent: 0)
        opening.sample(rows: row(50), inset: 150, shelfExtent: 50)
        #expect(opening.moves == 1 && opening.reversals == 0)
        #expect(opening.anchorError == 0 && opening.insetShelfError == 0)

        var arbitrary = ActivityMotionPhaseWindow()
        arbitrary.reset(rows: row(100), inset: 100, shelfExtent: 0)
        arbitrary.sample(rows: row(50), inset: 100, shelfExtent: 0)
        #expect(arbitrary.anchorError == 50)
        var unrelatedInset = ActivityMotionPhaseWindow()
        unrelatedInset.reset(rows: row(100), inset: 100, shelfExtent: 0)
        unrelatedInset.sample(rows: row(50), inset: 150, shelfExtent: 0)
        #expect(unrelatedInset.anchorError == 0 && unrelatedInset.insetShelfError == 50)

        var glide = ActivityMotionPhaseWindow()
        glide.reset(rows: row(100), inset: 100, shelfExtent: 0)
        glide.sample(rows: row(75), inset: 125, shelfExtent: 25)
        glide.sample(rows: row(50), inset: 150, shelfExtent: 50)
        #expect(glide.anchorError == 0 && glide.insetShelfError == 0)
        #expect(glide.moves == 2, "even an anchored change must not glide")
        #expect(glide.excessMotion == 25)

        var slow = ActivityMotionPhaseWindow()
        slow.reset(rows: row(100), inset: 100, shelfExtent: 0)
        for i in 1...20 {
            let distance = CGFloat(i) * 0.2
            slow.sample(rows: row(100 - distance), inset: 100 + distance, shelfExtent: distance)
        }
        #expect(slow.moves == 0, "every individual step is below the direction threshold")
        #expect(slow.excessMotion > 1, "small steps cannot hide an accumulated glide")
    }

    @Test func insetObservationUsesTheRenderedScrollBounds() {
        #expect(ActivityMotionPhaseWindow.renderedInset(modelInset: 185, modelOffset: -185, presentationOffset: -135) == 135,
                "a model inset already changed while the prior frame is still presented")
        #expect(ActivityMotionPhaseWindow.renderedInset(modelInset: 185, modelOffset: -185, presentationOffset: -185) == 185)
    }

    @Test func discreteCommitMayPresentThePreviousModelForOneSample() {
        let oldRect = CGRect(x: 10, y: 741, width: 382, height: 0)
        let newRect = CGRect(x: 10, y: 691, width: 382, height: 44)
        let previous = ActivityShelfPresentationCheck(model: oldRect, presentation: oldRect, modelOpacity: 1, presentationOpacity: 1)
        let pending = ActivityShelfPresentationCheck(model: newRect, presentation: oldRect, modelOpacity: 1, presentationOpacity: 1)
        #expect(pending.geometryError == 50, "raw model/presentation comparison rejects a normal pending commit")
        #expect(pending.alignedWithPreviousModel(previous).geometryError == 0)
        #expect(pending.alignedWithPreviousModel(pending).geometryError == 50,
                "the old rendered model cannot remain accepted for another sample")
    }

    @Test func previousModelDoesNotExcuseAnInterpolatedSurface() {
        let oldRect = CGRect(x: 10, y: 741, width: 382, height: 0)
        let newRect = CGRect(x: 10, y: 691, width: 382, height: 44)
        let previous = ActivityShelfPresentationCheck(model: oldRect, presentation: oldRect, modelOpacity: 1, presentationOpacity: 1)
        let middle = ActivityShelfPresentationCheck(model: newRect, presentation: CGRect(x: 10, y: 716, width: 382, height: 22),
                                                    modelOpacity: 1, presentationOpacity: 1)
        #expect(middle.alignedWithPreviousModel(previous).geometryError > 1)
        let fade = ActivityShelfPresentationCheck(model: newRect, presentation: oldRect, modelOpacity: 1, presentationOpacity: 0.5)
        #expect(fade.alignedWithPreviousModel(previous).opacityError > 0.01)
    }

    @Test func stationaryGeometryIncludesHorizontalMotionAndSize() {
        var phase = ActivityMotionPhaseWindow()
        phase.reset(rows: row(100))
        phase.sample(rows: ["row": CGRect(x: 3, y: 100, width: 108, height: 46)])
        phase.sample(rows: row(100))
        #expect(phase.horizontal == 3 && phase.width == 8 && phase.height == 6)
    }

    @Test func oneRemainingBaselineCannotHideAnotherMissingRow() {
        var phase = ActivityMotionPhaseWindow()
        let two = ["row": CGRect(x: 0, y: 100, width: 100, height: 40),
                   "second": CGRect(x: 0, y: 150, width: 100, height: 40)]
        phase.reset(rows: two)
        phase.sample(rows: two)
        phase.sample(rows: row(100))
        phase.sample(rows: two)
        #expect(phase.coveredFrames == 3 && phase.uncoveredFrames == 0 && phase.matchedBaselineIDs.count == 2)
        #expect(phase.incompleteCoverageFrames == 1, "a surviving row must not conceal another row's missing sample")
    }
}
#endif
