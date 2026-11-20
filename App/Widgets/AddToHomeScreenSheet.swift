// [tile-widgets] Add to Home Screen…, from a tile's hold menu or the opened tile's (iPhone and iPad; the Mac has no
// Home Screen widgets of ours). The app can't place a widget itself: the sheet says how, in the system's own words, and
// the tile's small, medium and large pictures start drawing at once, so the widget shows it the moment it is chosen
// (`TileWidgetWriter.prepare`). docs/spec/1x-pages.md §5.8 rule 7.

import SwiftUI
import UIKit

@MainActor enum AddToHomeScreenSheet {
    static func present(pin: ArtifactPin, name: String, from host: UIViewController) {
        TileWidgetWriter.shared.prepare(pin)
        let controller = UIHostingController(rootView: HQScaledRoot(AddToHomeScreenView(name: name) { [weak host] in
            host?.presentedViewController?.dismiss(animated: true)
        }))
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.hqPreferLargeAtAccessibilitySizes()   // [a11y]
            sheet.prefersGrabberVisible = false
            sheet.hqGlassPage()   // [glass-audit] below full height on Liquid Glass, its words on cards
        }
        AppLog.note("widgets", "Add to Home Screen shown")
        host.present(controller, animated: true)
    }

    /// The steps, in the system's own words (iOS 26: hold the Home Screen, Edit, Add Widget).
    static func steps(name: String) -> [String] {
        [
            "Touch and hold an empty spot on your Home Screen.",
            "Tap Edit, then Add Widget.",
            "Find Hermes HQ, then tap Tile.",
            "Pick a size and tap Add Widget.",
            "Touch and hold the new widget, tap Edit Widget, and choose “\(name)”.",
        ]
    }
}

struct AddToHomeScreenView: View {
    var name: String
    var close: () -> Void
    @ScaledMetric(relativeTo: .title) private var symbolSize: CGFloat = 36

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "apps.iphone.badge.plus")
                            .font(.system(size: symbolSize))   // a11y-font-ok: a symbol sized with Dynamic Type (@ScaledMetric)
                            .foregroundStyle(Color.hqTint)
                            .frame(height: symbolSize + 4)
                            .accessibilityHidden(true)
                        Text("“\(name)” on Your Home Screen")
                            .font(Font.hq(.title2).weight(.hqBold))
                            .foregroundStyle(Color.hqLabel)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("add-to-home.headline")
                        Text("A Tile widget shows this tile as it last looked in Hermes HQ, and opens it when you tap it.")
                            .font(Font.hq(.subheadline))
                            .foregroundStyle(Color(uiColor: HQPalette.glassInk2))   // [glass-audit] strong ink on the glass
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                .hqDesktopBareRow()
                Section {
                    ForEach(Array(AddToHomeScreenSheet.steps(name: name).enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(index + 1)")
                                .font(Font.hq(.body).weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color.hqTintText)
                                .frame(minWidth: 18, alignment: .leading)
                            Text(step)
                                .font(Font.hq(.body))
                                .foregroundStyle(Color.hqLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("add-to-home.step.\(index + 1)")
                    }
                } footer: {
                    Text("Its pictures for each widget size are being drawn now.")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color(uiColor: HQPalette.glassInk2))
                }
                .hqSheetRows()
            }
            .hqGroupedPage()
            .navigationTitle("Add to Home Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseToolbar(word: "Done", id: "add-to-home.close", action: close) }
        }
        .hqGlassSheetPage()
        .accessibilityIdentifier("add-to-home")
    }
}
