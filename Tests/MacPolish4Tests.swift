import Foundation
import Testing
import UIKit
@testable import HermesHQNative

/// Mac polish round, batch 4 (the sidebar and the bots, 2026-11-07): the rules behind its fixes that hold without a
/// window. The sidebar's measures are `SidebarRules`, so they run on the iPhone simulator with the rest.
@MainActor
struct MacPolish4Tests {
    // MARK: Icons (#64, #65)

    /// #65 (owner's call): Changes is the chat ⋯ › More's +/− wherever it shows, and the forked branch is Branch in New
    /// Chat's alone.
    @Test func changesHasOneIconAndTheForkIsBranchsAlone() {
        let page = MorePages.pages.first { $0.id == "review" }
        let menu = ChatMenuModel.more(ChatMenuState())
        let changes = menu.first { $0.id == .changes }, branch = menu.first { $0.id == .branch }
        #expect(page?.symbol == "plus.forwardslash.minus")
        #expect(changes?.symbol == page?.symbol)
        #expect(branch?.symbol == "arrow.triangle.branch")
        #expect(branch?.symbol != page?.symbol)
        #expect(TabOrderPage.fallback("review").symbol == "plus.forwardslash.minus")
    }

    /// #64: Star Map is a star where it is a sidebar Tool (the Mac); the iPhone's More tile keeps its sparkles.
    @Test func starMapIsAStarOnTheMac() {
        let symbol = MorePages.pages.first { $0.id == "star-map" }?.symbol
        #if targetEnvironment(macCatalyst)
        #expect(symbol == "star")
        #else
        #expect(symbol == "sparkles")
        #endif
    }

    /// #64, #65: the two new icons have a tap motion of their own, as every tab icon must (`TabMotionTests`), and the
    /// +/− moves enough to be seen.
    @Test(arguments: [false, true])
    func theNewIconsMoveWhenTapped(bold: Bool) throws {
        let changes = try #require(TabIcons.barSymbol("plus.forwardslash.minus"))
        let star = try #require(TabIcons.barSymbol("star"))
        #expect(TabMotion.kind(of: changes) == .changes)
        #expect(TabMotion.kind(of: star) == .star)
        for (name, bar) in [("changes", changes), ("star", star)] {
            let drawn = TabIcons.redrawn(bar, pointSize: 21) ?? bar
            let motion = try #require(TabMotionTests.motion(of: drawn, bold: bold), "\(name): no tap motion")
            #expect(motion.frames.count > 20)
            let first = motion.frames.first?.dataProvider?.data as Data?
            #expect(motion.frames.contains { $0.dataProvider?.data as Data? != first }, "\(name): every frame the same")
            if name == "changes" { #expect(TabMotionTests.movement(motion) >= TabMotionTests.leastMovement) }
        }
    }

    // MARK: Tools (#33)

    /// #33: every page Settings › Tabs can place keeps its own tag as a place (plugin pages get theirs past them, on
    /// the Mac only).
    @Test func placeTagsKeepThePagesOwn() {
        for id in TabChoice.pageIDs { #expect(PagesTabs.placeTag(id) == TabChoice.page(id).tag) }
    }

    // MARK: The sidebar (#51, #54, #56: `SidebarRules`)

    /// #51: a list's edges fade only while rows lie past them, the fade growing with them to its full height and never
    /// past half the list.
    @Test func listEdgesFadeOnlyWhereRowsLiePast() {
        #expect(SidebarRules.fadeStops(above: 0, below: 0, height: 400) == nil)
        let foot = SidebarRules.fadeStops(above: 0, below: 300, height: 400)
        #expect(foot?.top == 0)
        #expect(foot?.bottom == 1 - SidebarRules.fadeHeight / 400)
        let both = SidebarRules.fadeStops(above: 11, below: 300, height: 400)
        #expect(both?.top == 11.0 / 400)
        let short = SidebarRules.fadeStops(above: 100, below: 100, height: 30)
        #expect(short?.top == 0.5 && short?.bottom == 0.5)
    }

    /// After #33: the bots' list fades out across a group's heading when it would stop on it (the heading cut, or its
    /// first row cut or out of sight); a list that ends on a cut bot, or shows whole, keeps its usual fade.
    @Test func botsListNeverStopsOnALoneHeading() {
        let rows = [SidebarRules.ListRow(top: 100, bottom: 130, heading: true),
                    SidebarRules.ListRow(top: 130, bottom: 170, heading: false),
                    SidebarRules.ListRow(top: 170, bottom: 200, heading: true),
                    SidebarRules.ListRow(top: 200, bottom: 240, heading: false),
                    SidebarRules.ListRow(top: 240, bottom: 280, heading: false)]
        let lead = SidebarRules.headingLead
        // Unassigned (170–200) whole, Notes (200–240) under the fade: the fade runs across the heading instead.
        let lone = SidebarRules.headingFade(rows: rows, top: 0, height: 230, below: 50)
        #expect(lone?.start == 170 - lead && lone?.end == 200 - lead)
        // Notes almost out of sight under the heading: the same.
        #expect(SidebarRules.headingFade(rows: rows, top: 0, height: 224, below: 56)?.start == 170 - lead)
        // Scrolled: measured in the list's visible height.
        #expect(SidebarRules.headingFade(rows: rows, top: 50, height: 180, below: 50)?.start == 120 - lead)
        // Notes clear of the fade, the next bot cut: it reads as more below.
        #expect(SidebarRules.headingFade(rows: rows, top: 0, height: 265, below: 15) == nil)
        // The heading itself cut by the fade, its bot out of sight: the fade runs across the whole heading.
        #expect(SidebarRules.headingFade(rows: rows, top: 0, height: 205, below: 75)?.start == 170 - lead)
        // All in view.
        #expect(SidebarRules.headingFade(rows: rows, top: 0, height: 300, below: 0) == nil)
    }

    /// Mac AAA 2026-11-16: the foot fade always leaves a faded row where more lies below. A cut row that shows enough
    /// of itself keeps the usual fade; one cut near its top (or the list ending in the room between two rows) has the
    /// fade reach up over the last whole row.
    @Test func footFadeAlwaysShowsMoreBelow() {
        let rows = [SidebarRules.ListRow(top: 0, bottom: 40, heading: false),
                    SidebarRules.ListRow(top: 42, bottom: 82, heading: false),
                    SidebarRules.ListRow(top: 84, bottom: 124, heading: false)]
        let fade = SidebarRules.fadeHeight
        // Half of the third row in view: its name reads faded.
        #expect(SidebarRules.peekFade(rows: rows, height: 104, below: 20) == fade)
        // A few points of it: the fade covers the second row.
        #expect(SidebarRules.peekFade(rows: rows, height: 90, below: 34) == 90 - (42 + 40 * SidebarRules.peekStart))
        // Ending in the room between two rows: the same.
        #expect(SidebarRules.peekFade(rows: rows, height: 83, below: 41) == 83 - (42 + 40 * SidebarRules.peekStart))
        // Nothing below: the usual fade (none is drawn).
        #expect(SidebarRules.peekFade(rows: rows, height: 124, below: 0) == fade)
        // Never past half the list.
        #expect(SidebarRules.peekFade(rows: rows, height: 44, below: 80) == 22)
    }

    /// [Mac AAA 2026-11-16] sidebar S3: the top fade reaches over the first whole row when only a sliver of the row
    /// above it shows, and never past half the list.
    @Test func headFadeCoversASliverAtTheTop() {
        let rows = [SidebarRules.ListRow(top: -36, bottom: 4, heading: false),
                    SidebarRules.ListRow(top: 6, bottom: 46, heading: false),
                    SidebarRules.ListRow(top: 48, bottom: 88, heading: false)]
        // 4 pt of the first row in view: the fade runs to 80 % down the second (6 + 40 × 0.8).
        let head = SidebarRules.peekHeadFade(rows: rows, height: 120, above: 36)
        #expect(abs(head - (6 + 40 * (1 - SidebarRules.peekStart))) < 0.001)
        // Half a row in view: still let go into the fade (its words would be cut through their tops).
        let half = [SidebarRules.ListRow(top: -20, bottom: 20, heading: false),
                    SidebarRules.ListRow(top: 22, bottom: 62, heading: false)]
        #expect(abs(SidebarRules.peekHeadFade(rows: half, height: 120, above: 20) - (22 + 40 * (1 - SidebarRules.peekStart))) < 0.001)
        // Nearly all of it in view: the usual fade.
        let most = [SidebarRules.ListRow(top: -2, bottom: 38, heading: false)] + rows.dropFirst()
        #expect(SidebarRules.peekHeadFade(rows: Array(most), height: 120, above: 2) == SidebarRules.fadeHeight)
        // Taken whole by fadeStops, though fewer points lie above than it is tall.
        let stops = SidebarRules.fadeStops(above: 36, below: 0, height: 120, headFade: head)
        #expect(abs((stops?.top ?? 0) - head / 120) < 0.001)
    }

    /// #54: a name shrinks to fit only down to the Mac's smallest text.
    @Test func namesShrinkNoSmallerThanTheMacsSmallestText() {
        #expect(SidebarRules.shrink(pointSize: 17, least: 0.85, smallest: 13) == 0.85)
        #expect(abs(SidebarRules.shrink(pointSize: 14.5, least: 0.85, smallest: 13) - 13 / 14.5) < 0.001)
        #expect(SidebarRules.shrink(pointSize: 13, least: 0.8, smallest: 13) == 1)
    }

    /// #56: a colour read past the strip is the window not drawn yet when it is black beside a page that isn't, or in
    /// light mode anything near black; a dimmed App Background or a dark theme's page is a page.
    @Test func aNearBlackReadInLightModeIsNotAPage() {
        #expect(SidebarRules.undrawn(red: 0, green: 0, blue: 0, light: true, pageIsBlack: false))
        #expect(SidebarRules.undrawn(red: 0, green: 0, blue: 0, light: false, pageIsBlack: false))
        #expect(!SidebarRules.undrawn(red: 0, green: 0, blue: 0, light: false, pageIsBlack: true))
        #expect(SidebarRules.undrawn(red: 18, green: 20, blue: 22, light: true, pageIsBlack: false))
        #expect(!SidebarRules.undrawn(red: 18, green: 20, blue: 22, light: false, pageIsBlack: false))
        #expect(!SidebarRules.undrawn(red: 242, green: 242, blue: 247, light: true, pageIsBlack: false))
        #expect(!SidebarRules.undrawn(red: 115, green: 110, blue: 120, light: true, pageIsBlack: false))
        // Beside a very dark App Background picture, near black is the picture; pure black still means not drawn.
        #expect(!SidebarRules.undrawn(red: 18, green: 20, blue: 22, light: true, pageIsBlack: false, picture: true))
        #expect(SidebarRules.undrawn(red: 0, green: 0, blue: 0, light: true, pageIsBlack: false, picture: true))
    }
}
