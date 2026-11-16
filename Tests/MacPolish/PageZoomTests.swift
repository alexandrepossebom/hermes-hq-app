// [mac-pages] The zoom of a bot's HTML page on the Mac (App/Chat/Viewer/PageZoom.swift). Owner 2026-11-16: "If you
// click an HTML file, you can't enlarge it because it's too small to actually be able to fully utilize and see."

import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct PageZoomTests {
    init() { PageZoom.percent = 100 }

    @Test func itStartsAtActualSizeAndStepsThroughABrowsersLevels() {
        #expect(PageZoom.percent == 100)
        #expect(!PageZoom.canChange(by: 0))
        PageZoom.change(by: 1)
        #expect(PageZoom.percent == 110)
        PageZoom.change(by: 1)
        #expect(PageZoom.percent == 125)
        PageZoom.change(by: -1)
        PageZoom.change(by: -1)
        PageZoom.change(by: -1)
        #expect(PageZoom.percent == 90)
        PageZoom.change(by: 0)
        #expect(PageZoom.percent == 100)
    }

    @Test func theEndsOfTheRangeStop() {
        PageZoom.percent = 300
        #expect(!PageZoom.canChange(by: 1))
        PageZoom.change(by: 1)
        #expect(PageZoom.percent == 300)
        PageZoom.percent = 50
        #expect(!PageZoom.canChange(by: -1))
        PageZoom.percent = 100
    }

    @Test func aLevelThatIsNotAStepIsRefused() {
        PageZoom.percent = 137
        #expect(PageZoom.percent == 100)
    }

    @Test func thePageLaysOutInItsRoomOverTheZoomAndFillsIt() {
        PageZoom.percent = 100
        let web = UIView()
        let room = CGRect(x: 0, y: 40, width: 1000, height: 600)
        PageZoom.place(web, in: room)
        // Drawn grown by the zoom, the page covers its room whatever the level (1 off the Mac).
        #expect(abs(web.frame.width - room.width) <= PageZoom.scale)
        #expect(abs(web.frame.height - room.height) <= PageZoom.scale)
        #expect(abs(web.frame.midX - room.midX) < 0.5 && abs(web.frame.midY - room.midY) < 0.5)
        #expect(abs(web.bounds.width * PageZoom.scale - room.width) <= PageZoom.scale)
    }
}
