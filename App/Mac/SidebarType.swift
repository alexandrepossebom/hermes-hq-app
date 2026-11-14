// [sidebar-type] Owner 2026-11-14: "the font size and weights that we use in some places, even on the, like, the
// sidebar are wrong and are part of what makes me feel like the app is not polished enough." Every text size, weight
// and row height of the Mac sidebar in one table, so the scheme the owner picks is a one-line change (`shipping`).
// Sizes are in the sidebar's own points before UI Scale (`MacSidebar.font` multiplies by it); the Mac draws this app
// at 77 %, so 19.5 here is 15 pt on the screen, 17 is 13, 14.25 is 11.
// `current`: the look as it shipped through Mac 986 (15 pt rows, semibold when chosen, counts 12.3, times 11.2).
// `native`: Finder's, Mail's and Notes' sidebar (13 pt regular rows whose weight never changes when chosen, the
// selection carries it; 11 pt semibold secondary headings; counts, times and the gateway's name one 11 pt regular
// secondary size; 28 pt rows with smaller faces and icons to match).
// Debug builds draw `native` with `-HQSidebarType native` (the launch arguments, read once a launch, never saved).

import UIKit

#if targetEnvironment(macCatalyst)
struct SidebarType {
    /// A place's, a bot's, New Bot's and the gateway switcher's names (Compact: `rowCompact`).
    var row: CGFloat
    var rowCompact: CGFloat
    /// A chosen row's name (places, bots, the named rail's). An unread bot or chat stays semibold in both: that is
    /// news, not the selection.
    var markedWeight: UIFont.Weight
    /// A chat's title under its bot.
    var chatTitle: CGFloat
    var chatTitleCompact: CGFloat
    /// "Search" in the field at the top, and its ⌘K.
    var search: CGFloat
    var shortcut: CGFloat
    /// A group's heading (Pinned, Work, Tools), semibold in the secondary ink.
    var heading: CGFloat
    /// A place's count, a chat's time, a bot's "Working…", the foot's gateway name, an empty section's hint.
    var count: CGFloat
    var time: CGFloat
    var status: CGFloat
    var gatewayName: CGFloat
    /// The foot's gateway name in the secondary ink (`HQPalette.label2`), as the counts and times; else 74 % label.
    var gatewaySecondary: Bool
    var hint: CGFloat
    /// "N more" under a bot's chats.
    var more: CGFloat
    var moreWeight: UIFont.Weight
    /// The named rail (pulled out a little while folded): a place's name and a bot's name under its icon or face, and
    /// the least either shrinks to (a size here, before UI Scale).
    var railPlace: CGFloat
    var railHead: CGFloat
    var railPlaceLeast: CGFloat
    var railHeadLeast: CGFloat
    /// The places' icons in the open sidebar.
    var icon: CGFloat
    /// A bot's face in its open row.
    var face: CGFloat
    var faceCompact: CGFloat
    /// Row heights (the stack adds 2 between place and bot rows; chats have none).
    var placeRow: CGFloat
    var placeRowCompact: CGFloat
    var botRow: CGFloat
    var botRowCompact: CGFloat

    static let current = SidebarType(
        row: 19.5, rowCompact: 18, markedWeight: .semibold, chatTitle: 17, chatTitleCompact: 15.5,
        search: 17, shortcut: 14.5, heading: 14.5,
        count: 16, time: 14.5, status: 14.5, gatewayName: 14.5, gatewaySecondary: false, hint: 15,
        more: 15.5, moreWeight: .medium,
        railPlace: 13.5, railHead: 14.5, railPlaceLeast: 13.5 * 0.8, railHeadLeast: 14.5 * 0.85,
        icon: 18, face: 34, faceCompact: 28, placeRow: 37, placeRowCompact: 32, botRow: 43.5, botRowCompact: 38)

    /// 13 pt rows are 17 here, 11 pt small words 14.25, the named rail 14 (10.8 pt) and never under 13.65 (10.5 pt).
    /// Rows stay 37 (28.5 pt on the screen; with the 2 pt gap a whole 30 px, `MacSidebar.openRowHeight`), the bots'
    /// too, with a 26 face (20 pt) whose name lands on the places' name column.
    static let native = SidebarType(
        row: 17, rowCompact: 16, markedWeight: .regular, chatTitle: 17, chatTitleCompact: 16,
        search: 17, shortcut: 14.25, heading: 14.25,
        count: 14.25, time: 14.25, status: 14.25, gatewayName: 14.25, gatewaySecondary: true, hint: 14.25,
        more: 14.25, moreWeight: .regular,
        railPlace: 14, railHead: 14, railPlaceLeast: 13.65, railHeadLeast: 13.65,
        icon: 17, face: 26, faceCompact: 24, placeRow: 37, placeRowCompact: 32, botRow: 37, botRowCompact: 32)

    /// What the app ships with. The owner's pick goes here.
    static let shipping = current

    /// The scheme in use: `shipping`, or in a Debug build the one `-HQSidebarType current|native` names.
    static let active: SidebarType = {
        #if DEBUG
        // The launch's own arguments, not the defaults: nothing a run of the app saves can pick the scheme.
        let arguments = ProcessInfo.processInfo.arguments
        let named = arguments.firstIndex(of: "-HQSidebarType").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        switch named {
        case "native": return native
        case "current": return current
        default: break
        }
        #endif
        return shipping
    }()
}
#endif
