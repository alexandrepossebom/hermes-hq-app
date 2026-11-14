import Foundation
import Testing
@testable import HermesHQNative

/// [macpass-popups] Show Details is offered only when it shows more than the alert's own sentence.
@Suite struct FailureDetailsTests {
    @Test func nothingMoreMeansNoDetails() {
        #expect(FailureAlert.details(reason: "Your gateway didn’t save the change.", detail: nil, whole: false) == nil)
        #expect(FailureAlert.details(reason: "Your gateway didn’t save the change.", detail: "  ", whole: false) == nil)
        #expect(FailureAlert.details(reason: "Your gateway didn’t save the change.", detail: "didn’t save the change", whole: false) == nil)
    }

    @Test func theErrorsOwnTextIsShownUnderTheReason() {
        let details = FailureAlert.details(reason: "It didn’t answer.", detail: "RPC projects.create timed out after 30 s", whole: false)
        #expect(details == "It didn’t answer.\n\nRPC projects.create timed out after 30 s")
    }

    @Test func aReasonCutToTwoLinesKeepsDetailsForItsEnd() {
        let long = String(repeating: "word ", count: 50)
        #expect(FailureAlert.details(reason: long, detail: nil, whole: false) == long)
        #expect(FailureAlert.details(reason: long, detail: nil, whole: true) == nil, "shown whole: nothing more to show")
    }
}
