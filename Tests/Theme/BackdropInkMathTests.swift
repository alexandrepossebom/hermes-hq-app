// [backdrop-ink] Which ink words standing straight on the app's picture take, and how the picture's tone is read where
// they stand (App/Theme/BackdropInk.swift). Owner 2026-11-15: "When you select a darker background, the text on the
// top … It's not automatically adjusting to the background type. So we need to make sure that happens every time."

import CoreGraphics
import Testing
import UIKit
@testable import HermesHQNative

@Suite struct BackdropInkMathTests {
    /// Light's label (near black) and Dark's (near white), linear.
    private let lightLabel = 0.01, darkLabel = 0.9

    @Test func aNightSkyInLightTakesTheLightInk() {
        // The owner's screenshot: Light, a near-black sky, Dim at nothing.
        let ground = BackdropInkMath.ground(picture: 0.005, dim: 0, page: 0.98)
        #expect(BackdropInkMath.pick(ground: ground, own: lightLabel, other: darkLabel) == .other)
    }

    @Test func aPalePictureInDarkTakesTheDarkInk() {
        let ground = BackdropInkMath.ground(picture: 0.85, dim: 0, page: 0.004)
        #expect(BackdropInkMath.pick(ground: ground, own: darkLabel, other: lightLabel) == .other)
    }

    @Test func aPictureOfTheModesOwnToneKeepsItsInk() {
        #expect(BackdropInkMath.pick(ground: BackdropInkMath.ground(picture: 0.85, dim: 0, page: 0.98), own: lightLabel, other: darkLabel) == .own)
        #expect(BackdropInkMath.pick(ground: BackdropInkMath.ground(picture: 0.01, dim: 0, page: 0.004), own: darkLabel, other: lightLabel) == .own)
    }

    @Test func dimBringsTheModesOwnInkBack() {
        // The same night sky under enough of Light's page colour reads in Light's own ink again.
        let bare = BackdropInkMath.ground(picture: 0.005, dim: 0, page: 0.98)
        let dimmed = BackdropInkMath.ground(picture: 0.005, dim: 0.8, page: 0.98)
        #expect(BackdropInkMath.pick(ground: bare, own: lightLabel, other: darkLabel) == .other)
        #expect(BackdropInkMath.pick(ground: dimmed, own: lightLabel, other: darkLabel) == .own)
    }

    @Test func everyPictureAndDimGetsTheInkThatMeasuresMost() {
        // Whatever the picture and Dim, in both modes: the ink picked reads at 4.5:1, or nothing would have read better.
        for (page, own, other) in [(0.98, lightLabel, darkLabel), (0.004, darkLabel, lightLabel)] {
            for picture in stride(from: 0.0, through: 1.0, by: 0.02) {
                for dim in stride(from: 0.0, through: 0.8, by: 0.1) {
                    let ground = BackdropInkMath.ground(picture: picture, dim: dim, page: page)
                    let tones: [BackdropInkMath.Pick: Double] = [.own: own, .other: other, .white: 1, .black: 0]
                    let pick = BackdropInkMath.pick(ground: ground, own: own, other: other)
                    let measured = BackdropInkMath.ratio(tones[pick]!, ground)
                    let best = tones.values.map { BackdropInkMath.ratio($0, ground) }.max()!
                    #expect(measured >= BackdropInkMath.contrast || measured >= best - 0.002, "picture \(picture), dim \(dim), page \(page): \(pick) at \(measured)")
                }
            }
        }
    }

    @Test func anInkThatIsPartlyClearIsMeasuredAsItLands() {
        // A second label at 60 % over a dark ground is not as light as the ink itself.
        let landed = BackdropInkMath.landed(ink: 0.9, alpha: 0.6, on: 0.01)
        #expect(landed < 0.9 && landed > 0.01)
        #expect(BackdropInkMath.landed(ink: 0.9, alpha: 1, on: 0.01) == SoftCard.decoded(SoftCard.encoded(0.9)))
    }

    // MARK: Where the words stand

    @Test func aPictureOfThePagesShapeIsShownWhole() {
        let region = BackdropInkMath.region(image: CGSize(width: 600, height: 1300), view: CGSize(width: 300, height: 650), band: nil)
        #expect(abs(region.minX) < 0.001 && abs(region.minY) < 0.001 && abs(region.width - 1) < 0.001 && abs(region.height - 1) < 0.001)
    }

    @Test func aWidePhotoOnAPhoneShowsItsMiddle() {
        // A landscape photo fills a portrait page from its centre: all of its height, the middle of its width.
        let region = BackdropInkMath.region(image: CGSize(width: 2000, height: 1000), view: CGSize(width: 400, height: 800), band: nil)
        #expect(abs(region.height - 1) < 0.001)
        #expect(abs(region.width - 0.25) < 0.001)
        #expect(abs(region.midX - 0.5) < 0.001)
    }

    @Test func theBarsBandIsTheTopOfWhatShows() {
        // A tall photo on a wide page (an iPad on its side): the band starts where the shown part does, not at the photo's top.
        let region = BackdropInkMath.region(image: CGSize(width: 1000, height: 2000), view: CGSize(width: 1000, height: 500), band: 100)
        #expect(abs(region.minY - 0.375) < 0.001)
        #expect(abs(region.height - 0.25 * 0.2) < 0.001)
    }

    // MARK: Reading a picture

    /// A picture dark over its top `split` and light under it.
    private func picture(split: Double, top: CGFloat = 0.02, bottom: CGFloat = 0.95) -> CGImage {
        let width = 160, height = 320
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // (A bitmap context's origin is its bottom left.)
        context.setFillColor(CGColor(gray: bottom, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: top, alpha: 1))
        context.fill(CGRect(x: 0, y: Double(height) * (1 - split), width: Double(width), height: Double(height) * split))
        return context.makeImage()!
    }

    @Test func theTonesAreReadFromTheTopDown() throws {
        let tones = try #require(BackdropTones.measure(picture(split: 0.25)))
        let top = tones.tone(in: CGRect(x: 0, y: 0, width: 1, height: 0.2))
        let bottom = tones.tone(in: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        #expect(top < 0.01)
        #expect(bottom > 0.8)
    }

    @Test func aDarkTopUnderALightPagePicksTheBarsInkAlone() throws {
        // A night sky over a pale foreground, in Light with Dim down: the bar's words go light, the page's stay dark.
        let tones = try #require(BackdropTones.measure(picture(split: 0.25)))
        let size = CGSize(width: 160, height: 320)
        let bar = tones.tone(in: BackdropInkMath.region(image: size, view: size, band: 320 * 0.16))
        let page = tones.tone(in: BackdropInkMath.region(image: size, view: size, band: nil))
        #expect(BackdropInkMath.pick(ground: BackdropInkMath.ground(picture: bar, dim: 0, page: 0.98), own: lightLabel, other: darkLabel) == .other)
        #expect(BackdropInkMath.pick(ground: BackdropInkMath.ground(picture: page, dim: 0, page: 0.98), own: lightLabel, other: darkLabel) == .own)
    }
}
