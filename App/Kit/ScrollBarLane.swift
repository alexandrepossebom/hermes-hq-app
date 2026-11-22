// A sideways scroll bar runs in a lane of its own under what scrolls, never over it. Owner 2026-10-29: "the scrollbar
// (at least on horizontal scrolling) sits over the text in a bunch of places. make sure the scrollbar doesn't get in
// the way of anything."

import CoreGraphics

nonisolated enum ScrollBarLane {
    /// The room a strip that scrolls sideways keeps under its words for the system's bar. Measured in the running app
    /// (2026-10-29): on the iPhone and iPad the bar is 3 pt thick, 3 pt up from the strip's bottom (so 8 leaves 2 pt
    /// over it); [mac] on the Mac it is AppKit's scroller, a 15 pt track on the strip's bottom edge (its knob widens
    /// inside the track under the pointer). Code cards kept 10, the diff 8 and the chips 8: fine on the iPhone, while
    /// on the Mac the scroller sat on their last line.
    static var height: CGFloat { DeviceWord.isMac ? 15 : 8 }

    /// [mac] The room a list that scrolls up and down keeps on its trailing side for the same 15 pt scroller. Owner
    /// 2026-11-22 (a screenshot of a project's page): "The scroll bar looks like it sits on top of the project card
    /// background." A list's cards stand 8–10 pt in from its edge, inside the scroller's track; 8 more puts every card's
    /// edge 16–18 pt in, clear of it. On the iPhone and iPad the bar is 3 pt and floats over the page's margin: none.
    static var listTrailing: CGFloat {
        #if DEBUG
        if debugOff { return 0 }
        #endif
        return DeviceWord.isMac ? 8 : 0
    }

    #if DEBUG
    /// The Mac tour's picture of a list without the lane (as before 2026-11-22).
    nonisolated(unsafe) static var debugOff = false
    #endif
}
