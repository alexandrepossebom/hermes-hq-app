// Bot Info › Browser › Browser Use Cloud (hermes-hq-browser 3.9): the add-on says it offers it (`features.cloud`),
// reports a bot in the cloud as `blocked: "cloud"` (it runs no Chrome for it), and tells whether the person's API key
// is saved without ever sending the key back. The page shows the cloud as a choice, not as a problem.

import Foundation
import Synchronization
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

    /// Settings › Browser Use Cloud › Use for All Bots (add-on 3.10).
    @Test func useForAllBotsIsReadFromTheAddOn() throws {
        let new = try JSONValue.parse(Data(#"{"features": {"cloud": true, "cloud_all": true}}"#.utf8))
        #expect(BrowserHealth.offersCloudForAll(new))
        #expect(!BrowserHealth.offersCloudForAll(try JSONValue.parse(Data(#"{"features": {"cloud": true}}"#.utf8))), "3.9: the key, no switch")
        let on = try #require(BrowserCloud.parse(try JSONValue.parse(Data(
            #"{"schema": "hermes-hq-browser.cloud.v1", "key_set": true, "key_hint": "…AbCd", "all": true, "skipped": ["ivy", 3, "juno"]}"#.utf8))))
        #expect(on.all && on.skipped == ["ivy", "juno"])
        let older = try #require(BrowserCloud.parse(try JSONValue.parse(Data(#"{"schema": "hermes-hq-browser.cloud.v1", "key_set": true}"#.utf8))))
        #expect(!older.all && older.skipped.isEmpty)
    }

    @Test func botsLeftAsTheyWereAreNamed() {
        #expect(BrowserCloudSettingsModel.skippedLine([]) == nil)
        #expect(BrowserCloudSettingsModel.skippedLine(["ivy"])?.hasPrefix("ivy was left as it was: its browser tools") == true)
        #expect(BrowserCloudSettingsModel.skippedLine(["ivy", "juno"])?.hasPrefix("ivy and juno were left as they were: their") == true)
        #expect(BrowserCloudSettingsModel.skippedLine(["ivy", "juno", "otto", "wren"])?.hasPrefix("ivy, juno and 2 more were left") == true)
    }

    @Test func settingsFindsBrowserUseCloud() {
        #expect(SettingsSearch.results("browser use", in: SettingsSearch.rootPages).first?.label == "Browser Use Cloud")
        #expect(SettingsNavigator.category(of: "browser-use-cloud") == .gateway)
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

    // MARK: A hosted Hermes (Hermes Cloud, add-on 3.11): the owner asked for Browser Use Cloud on a hosted gateway

    @Test func aHostedBotHasTwoBrowsersAndNothingIsWrong() throws {
        let hosted = try choice(["changeable": false, "blocked": "hosted", "hosted": true])
        #expect(hosted.hosted && !hosted.cloud)
        #expect(BrowserChoiceModel.explanation(hosted, name: "Wren") == nil, "no notice: the page offers its two browsers")
        #expect(BrowserChoiceModel.takeOverTitle(hosted, name: "Wren") == nil, "there is no Chrome to run for it there")
        #expect(BrowserChoiceModel.summary(hosted) == "Hermes Cloud")
        let cloud = try choice(["mode": "cloud", "changeable": false, "blocked": "cloud", "can_take_over": true, "hosted": true])
        #expect(cloud.hosted && cloud.cloud && BrowserChoiceModel.summary(cloud) == "Browser Use Cloud")
        #expect(!(try choice(["changeable": true])).hosted, "3.10 and older, and a computer of your own")
    }

    /// The add-on can't always see the address it is reached under, so the app says when the gateway is one Nous hosts.
    @Test func theAddOnIsToldItIsHostedOnceAndOnlyOnAHostedGateway() async throws {
        func service(hostedGateway: Bool, knows: Bool = true) -> (BrowserService, BotsFakeGatewayClient) {
            let client = BotsFakeGatewayClient()
            let told = Mutex(false)
            client.onREST { method, path, _, _ in
                if method == "POST", path.hasSuffix("/cloud") {
                    told.withLock { $0 = true }
                    return Data(#"{"schema": "hermes-hq-browser.cloud.v1", "key_set": false}"#.utf8)
                }
                guard path.hasSuffix("/health") else { throw HTTPError(status: 404, body: nil) }
                let health: JSONValue = ["installed": true, "protocol": 3, "hosted": .bool(told.withLock { $0 }),
                                         "features": ["control": true, "watch": true, "cloud": true, "hosted": .bool(knows)]]
                return try health.encoded()
            }
            let service = BrowserService(rest: client, sockets: NoPluginSockets())
            service.hostedGateway = hostedGateway
            return (service, client)
        }
        func posts(_ client: BotsFakeGatewayClient) -> Int { client.restCalls.filter { $0.method == "POST" && $0.path.hasSuffix("/cloud") }.count }

        let (nous, nousClient) = service(hostedGateway: true)
        #expect(BrowserHealth.hosted(try await nous.plugin().health), "told, and the answer kept is the one after")
        _ = try await nous.plugin(fresh: true)
        #expect(posts(nousClient) == 1, "not told again once it says so itself")

        let (own, ownClient) = service(hostedGateway: false)
        #expect(!BrowserHealth.hosted(try await own.plugin().health) && posts(ownClient) == 0)

        let (older, olderClient) = service(hostedGateway: true, knows: false)
        _ = try await older.plugin()
        #expect(posts(olderClient) == 0, "3.10 and older have no such word")
    }

    @Test func aMissingBrowserAddOnIsSetUpNotUpdated() {
        #expect(AddOnUpdate.installTitle(setUp: true, both: false, addOns: .browser) == "Install the browser add\u{2011}on")
        #expect(AddOnUpdate.installTitle(setUp: false, both: false, addOns: .browser) == "Install the browser update")
    }
}
