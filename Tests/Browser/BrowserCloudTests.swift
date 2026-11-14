// Bot Info › Browser › Browser Use Cloud (hermes-hq-browser 3.9): the add-on says it offers it (`features.cloud`),
// reports a bot in the cloud as `blocked: "cloud"` (it runs no Chrome for it), and tells whether the person's API key
// is saved without ever sending the key back. The page shows the cloud as a choice, not as a problem.

import Foundation
import Testing
@testable import HermesHQNative

private func choice(_ extra: [String: Any]) throws -> BrowserChoice {
    var object: [String: Any] = ["schema": "hermes-hq-browser.choice.v1", "profile": "wren", "mode": "own", "window": "hidden"]
    object.merge(extra) { $1 }
    return try #require(BrowserChoice.parse(try JSONValue.parse(try JSONSerialization.data(withJSONObject: object))))
}

@MainActor
struct BrowserCloudTests {
    @Test func theAddOnSaysWhenItOffersTheCloud() throws {
        let new = try JSONValue.parse(Data(#"{"features": {"choice": false, "cloud": true}}"#.utf8))
        #expect(BrowserHealth.offersCloud(new) && !BrowserHealth.offersChoice(new), "a computer with no Chrome of its own still offers the cloud")
        let older = try JSONValue.parse(Data(#"{"features": {"choice": true}}"#.utf8))
        #expect(!BrowserHealth.offersCloud(older), "3.8 and older: hidden")
    }

    @Test func theKeyNeverComesBackOnlyItsLastCharacters() throws {
        let saved = try #require(BrowserCloud.parse(try JSONValue.parse(Data(
            #"{"schema": "hermes-hq-browser.cloud.v1", "provider": "hq-browser-use", "key_set": true, "key_hint": "…AbCd"}"#.utf8))))
        #expect(saved == BrowserCloud(keySet: true, keyHint: "…AbCd"))
        let none = try #require(BrowserCloud.parse(try JSONValue.parse(Data(
            #"{"schema": "hermes-hq-browser.cloud.v1", "key_set": false, "key_hint": null}"#.utf8))))
        #expect(none == BrowserCloud(keySet: false, keyHint: nil))
        #expect(BrowserCloud.parse(try JSONValue.parse(Data(#"{"schema": "something.else", "key_set": true}"#.utf8))) == nil)
    }

    @Test func aBotInTheCloudIsAChoiceNotAProblem() throws {
        let cloud = try choice(["mode": "cloud", "changeable": false, "blocked": "cloud", "can_take_over": true])
        #expect(cloud.cloud)
        #expect(BrowserChoiceModel.explanation(cloud, name: "Wren") == nil, "no \"Hermes HQ doesn't run its browser\" notice")
        #expect(BrowserChoiceModel.takeOverTitle(cloud, name: "Wren") == nil, "Its Own Profile is the way back, not a take-over button")
        #expect(BrowserChoiceModel.summary(cloud) == "Browser Use Cloud")
        #expect(!(try choice(["changeable": true])).cloud)
        #expect(!(try choice(["changeable": false, "blocked": "released"])).cloud)
    }

    @Test func outcomeLinesNameTheCloudChange() {
        #expect(BrowserChoiceModel.outcome(.cloud, status: nil) == "choice cloud: ok")
        #expect(BrowserChoiceModel.outcome(.cloud, status: 409) == "choice cloud: failed (HTTP 409)")
    }
}
