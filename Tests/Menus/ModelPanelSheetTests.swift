// [model-sheet] The model panel as a bottom sheet on the iPhone (owner 2026-11-18, the "quick tiles" design): the same
// pieces as the card in the sheet's order, each inside the page, nothing overlapping, at four phone widths and for the
// hard states. No network.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite struct ModelPanelSheetTests {
    private let widths: [CGFloat] = [320, 375, 402, 440]

    /// Top down: the close disc, name and face on one line; Thinking on its card; the facts; the rows.
    @Test func thePageReadsInTheSheetsOrder() {
        for width in widths {
            let (panel, height) = ModelPanelView.debugSheet(ModelPanelModel.debugSample, width: width)
            let pieces = Dictionary(uniqueKeysWithValues: panel.debugPieces.map { ($0.name, $0.view.frame) })
            let own = panel.debugSheetPieces
            guard let face = pieces["face"], let name = pieces["name"], let facts = pieces["facts"], let settings = pieces["settings"] else {
                Issue.record("a piece is missing at \(width)")
                continue
            }
            #expect(own.close.minX >= 16 && own.close.width >= 44 && own.close.height >= 44, "the close disc is a full tap target")
            #expect(face.maxX <= width - 16 + 0.5)
            #expect(name.minX >= own.close.maxX && name.maxX <= face.minX, "the name sits between the disc and the face at \(width)")
            #expect(abs(own.close.midY - face.midY) < 1, "one line")
            #expect(own.thinkingCard.minY >= max(own.close.maxY, face.maxY), "Thinking's card is under the header")
            #expect(own.thinkingCard.contains(own.thinking), "the bar sits on its card")
            #expect(facts.minY >= own.thinkingCard.maxY && settings.minY >= facts.maxY, "then the facts, then the rows")
            #expect(settings.maxY <= height && height < 620, "the page is the sheet's height (\(height) at \(width))")
            for frame in [own.thinkingCard, facts, settings] {
                #expect(frame.minX >= 16 - 0.5 && frame.maxX <= width - 16 + 0.5, "inside the sheet's margins at \(width)")
            }
            #expect(pieces["tag"] == nil, "the tag follows the name in words; no pill in the header")
        }
    }

    /// Each fact is a tile of its own with a gap between; a tile that opens a page still does.
    @Test func theFactsAreTiles() {
        let (panel, _) = ModelPanelView.debugSheet(ModelPanelModel.debugSample, width: 402) { $0.openContextWindow = {} }
        guard let strip = panel.debugPieces.first(where: { $0.name == "facts" })?.view else { Issue.record("no facts"); return }
        let tiles = strip.subviews.compactMap { $0 as? FactColumn }.sorted { $0.frame.minX < $1.frame.minX }
        #expect(tiles.count == ModelPanelModel.debugSample.facts.count)
        for (a, b) in zip(tiles, tiles.dropFirst()) where abs(a.frame.minY - b.frame.minY) < 1 {
            #expect(b.frame.minX - a.frame.maxX >= 8, "a gap between tiles")
        }
        #expect(tiles.allSatisfy { $0.frame.height >= 60 && $0.backgroundColor != nil && $0.backgroundColor != .clear })
        #expect(strip.backgroundColor == .clear, "no strip behind the tiles")
        #expect(panel.debugFacts.first { $0.title == ModelPanelState.Fact.contextTitle }?.opens == true)
    }

    /// The hard states fit the page too: a long name, offline, a model with no thinking, the largest text.
    @Test func theHardStatesFit() {
        for name in ["long", "bare", "onestop", "offline", "yolo", "bedrock", "custom"] {
            guard let state = ModelPanelModel.debugCase(name) else { continue }
            for width in widths {
                let (panel, height) = ModelPanelView.debugSheet(state, width: width)
                let own = panel.debugSheetPieces
                let pieces = panel.debugPieces
                #expect(height > 0)
                for piece in pieces {
                    #expect(piece.view.frame.minX >= -0.5 && piece.view.frame.maxX <= width + 0.5, "\(piece.name) inside the page (\(name), \(width))")
                    #expect(piece.view.frame.maxY <= height + 0.5, "\(piece.name) above the page's foot (\(name), \(width))")
                }
                if let nameFrame = pieces.first(where: { $0.name == "name" })?.view.frame {
                    #expect(nameFrame.minX >= own.close.maxX - 0.5, "the name clears the close disc (\(name), \(width))")
                }
            }
        }
    }

    /// The close disc closes it once (the actions hear it, not handing off).
    @Test func theCloseDiscCloses() {
        var closed: [Bool] = []
        let (panel, _) = ModelPanelView.debugSheet(ModelPanelModel.debugSample, width: 402) { $0.closed = { closed.append($0) } }
        panel.debugTapClose()
        panel.debugTapClose()
        panel.sheetDismissed()
        #expect(closed == [false])
    }
}
