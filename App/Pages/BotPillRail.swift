// [bot-pills] Owner 2026-11-05: the bot pills at the top of Sessions: All, then each bot as a slim pill with its small
// face (`SessionPill`). Tasks had the same rail under its bar until 2026-11-12, when its views (Today, Upcoming, Inbox,
// your lists) took that row ([tasks-first], `TaskViewsHeader`) and its bots moved into the bar's Filter. Tiles was
// tried and dropped (owner: its own pages sort it better).

import SwiftUI
import UIKit

/// The pills in one row that scrolls sideways: All, then `extra` (Sessions' New and Working), then the bots. A tap on
/// the lit bot goes back to All. The picked pill is scrolled to the middle.
/// `identifier`: the pills are "<identifier>.all" and "<identifier>.<bot>", the rail "<identifier>s".
struct BotPillRail<Extra: View>: View {
    var bots: [SessionChipBot]
    var picked: String?
    var allPicked: Bool
    var identifier: String
    /// [project-pills] VoiceOver's name for the row: "Projects" when its pills are projects.
    var label = "Bots"
    /// [projects-switch] Drawn before All (Sessions' Bots | Projects switch).
    var leading: AnyView? = nil
    /// [projects-switch] No All when it would stand alone beside the switch (one bot, nothing New or Working).
    var showsAll = true
    var onPick: (String?) -> Void
    var onPickAll: () -> Void
    @ViewBuilder var extra: () -> Extra
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var allId: String { "\(identifier).all" }

    var body: some View {
        // [sessions-ux] The switch stays put at the rail's start and the pills scroll beside it: scrolled along with
        // them it left the screen (nothing then said which view was drawn, or switched it), and a picked pill,
        // centred, pushed half of it off the edge.
        HStack(spacing: 0) {
            if let leading {
                leading
                    .padding(.leading, side)
                    .padding(.top, DesktopRows.underBar)
                    .padding(.bottom, Theme.isDesktop ? 2 : 4)
            }
            scroller.padding(.leading, leading == nil ? 0 : 2)
        }
    }

    private var side: CGFloat { Theme.isDesktop ? DesktopRows.gutter : 16 }
    /// The scrolling pills' first place (with the switch outside them there is no All pill to scroll back to).
    private var startId: String { "\(identifier).start" }

    private var scroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if leading != nil { Color.clear.frame(width: 0, height: 1).padding(.trailing, -8).id(startId) }
                    if showsAll {
                        SessionPill(caption: "All", name: "All Bots", picked: allPicked, identifier: allId) {
                            onPickAll()
                        } face: {
                            EmptyView()
                        }
                        .id(allId)
                    }
                    extra()
                    ForEach(bots) { bot in
                        // [photoheads] Reading `version` redraws the pill when a photo arrives or goes.
                        let _ = BotFaces.shared.version
                        SessionPill(caption: bot.name, name: bot.name, picked: picked == bot.id,
                                    identifier: "\(identifier).\(bot.id)", hasFace: true) {
                            // The lit pill goes back to every bot.
                            onPick(picked == bot.id ? nil : bot.id)
                        } face: {
                            HeadImage(head: bot.head, profile: bot.id, size: SessionPill<EmptyView>.faceSize,
                                      working: bot.isWorking, phase: HeadView.phase(for: bot.id))
                        }
                        .id(bot.id)
                    }
                }
                .padding(.leading, leading == nil ? side : 6)
                .padding(.trailing, side)
                // The pills' 44 pt touch frames hold 5 pt above and below them already.
                // [top-bar-gap] Owner 2026-11-09: in the Desktop Look the bar is a frosted band with an edge, and the
                // pills sat 8 pt under it ("the top bar is so close to the contents"). They get the room the Mac's
                // rail already has (`DesktopRows.underBar`).
                .padding(.top, DesktopRows.underBar)
                .padding(.bottom, Theme.isDesktop ? 2 : 4)
                .hqPickGlassRow()
            }
            .scrollIndicators(.hidden)
            .hqScrollEdgeFade(width: 20)
            .onAppear { show(picked, proxy) }
            .onChange(of: picked) { _, picked in
                if reduceMotion { show(picked, proxy) } else { withAnimation(.easeInOut(duration: 0.25)) { show(picked, proxy) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("\(identifier)s")
    }

    /// The picked pill in the middle; with nothing picked, the pills from their start.
    private func show(_ picked: String?, _ proxy: ScrollViewProxy) {
        if let picked { proxy.scrollTo(picked, anchor: .center) }
        else if leading != nil { proxy.scrollTo(startId, anchor: .leading) }
        else { proxy.scrollTo(allId, anchor: .center) }
    }
}
