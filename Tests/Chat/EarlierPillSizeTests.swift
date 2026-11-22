import Testing
import UIKit
@testable import HermesHQNative

/// [transcript] §4.2: "Show earlier messages" alone is one button tall. Build 434 left the hidden words' 40 pt row in
/// the pill, so the button sat under an empty band twice its height (owner screenshot, 2026-10-28).
@MainActor
struct EarlierPillSizeTests {
    private func height(_ state: ChatEarlierPill.State) -> CGFloat {
        let pill = ChatEarlierPill()
        pill.set(state)
        pill.layoutIfNeeded()
        return pill.systemLayoutSizeFitting(CGSize(width: 320, height: 0), withHorizontalFittingPriority: .fittingSizeLevel,
                                            verticalFittingPriority: .fittingSizeLevel).height
    }

    @Test func showEarlierMessagesIsOneButtonTall() {
        #expect(height(.idle) == 48)   // the 44 pt button and 2 pt above and below
    }

    @Test func loadingIsTheSameHeightSoTappingDoesNotJump() {
        #expect(height(.loading) == height(.idle))
    }

    @Test func theFailureStillHasRoomForItsWordsAndTryAgain() {
        #expect(height(.failed) >= 2 + 44 + 44 + 2)
    }
}

/// [desktoplook] Owner screenshot 2026-11-22: in the Desktop Look the pill was a round capsule among the look's 4 pt
/// boxes. It is the look's box in every state; the iOS look keeps its capsule and the failure card's corners.
@MainActor
struct EarlierPillShapeTests {
    @Test func theDesktopLookDrawsTheLooksBoxInEveryState() {
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(ThemeState(skinID: "ios", desktopLook: true))) {
            for state in [ChatEarlierPill.State.idle, .loading, .failed] {
                #expect(ChatEarlierPill.corners(state) == .corners(radius: .fixed(4)), "\(state)")
            }
        }
    }

    @Test func theIOSLookKeepsTheCapsuleAndTheCardsCorners() {
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(ThemeState(skinID: "ios", desktopLook: false))) {
            #expect(ChatEarlierPill.corners(.idle) == .capsule())
            #expect(ChatEarlierPill.corners(.loading) == .capsule())
            #expect(ChatEarlierPill.corners(.failed) == .corners(radius: .fixed(18)))
        }
    }
}
