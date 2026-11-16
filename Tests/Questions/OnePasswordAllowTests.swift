// [1password-allow] Allow in 1Password: the add-on's answers, the page's steps against a stand-in add-on, the unlock
// sheet's button, and the Passwords page's line.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite("1Password: allow in its own app", .serialized)
struct OnePasswordAllowTests {
    typealias Wire = OnePasswordAllowWire

    /// A stand-in add-on: the calls it got, and the answers it gives in turn for each path.
    final class AddOn {
        var calls: [(path: String, method: String, body: [String: Any]?)] = []
        var answers: [String: [(Int, [String: Any]?)]] = [:]
        func call(_ path: String, _ method: String, _ body: [String: Any]?) async -> (status: Int, body: [String: Any]?) {
            calls.append((path, method, body))
            let key = "\(method) \(path)"
            guard var queue = answers[key], !queue.isEmpty else { return (404, nil) }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            answers[key] = queue
            return (next.0, next.1)
        }
    }

    let vaults: [[String: Any]] = [["id": "v-hermes", "name": "Hermes", "items": 6], ["id": "v-work", "name": "Work", "items": 1]]

    func settle(_ model: OnePasswordAllowModel, _ done: (OnePasswordAllowModel.Phase) -> Bool) async {
        for _ in 0..<400 where !done(model.phase) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func theAddOnsAnswersAreRead() {
        #expect(Wire.status(nil) == Wire.Status())
        #expect(Wire.status(["supported": true, "connected": true, "ours": true, "vaults": ["Hermes", "Work"], "bots": 3])
                == Wire.Status(supported: true, connected: true, ours: true, vaults: ["Hermes", "Work"], bots: 3))
        #expect(Wire.job(["job": "j", "state": "waiting"])?.job == .waiting)
        #expect(Wire.job(["job": "j", "state": "choose", "vaults": vaults, "account": "my.1password.example"])?.job
                == .choose([Wire.Vault(id: "v-hermes", name: "Hermes", items: 6), Wire.Vault(id: "v-work", name: "Work", items: 1)],
                           account: "my.1password.example"))
        #expect(Wire.job(["job": "j", "state": "done", "saved": 3, "vaults": [["id": "v-hermes", "name": "Hermes"]]])?.job
                == .done(bots: 3, vaults: ["Hermes"]))
        #expect(Wire.job(["job": "j", "state": "failed", "detail": "1Password wasn’t allowed.", "code": "denied"])?.job
                == .failed("1Password wasn’t allowed.", code: "denied"))
        #expect(Wire.job(["state": "waiting"]) == nil && Wire.job(["job": "j", "state": "odd"]) == nil && Wire.job(nil) == nil)
    }

    @Test func theWords() {
        #expect(Wire.list([]) == "" && Wire.list(["Hermes"]) == "Hermes" && Wire.list(["Hermes", "Work"]) == "Hermes and Work")
        #expect(Wire.list(["Hermes", "Work", "Family"]) == "Hermes, Work and Family")
        #expect(Wire.vaultDetail(Wire.Vault(id: "a", name: "A", items: 1)) == "1 item")
        #expect(Wire.vaultDetail(Wire.Vault(id: "a", name: "A", items: 12)) == "12 items")
        #expect(Wire.vaultDetail(Wire.Vault(id: "a", name: "A", items: nil)) == nil)
        #expect(Wire.doneLine(bots: 3, vaults: ["Hermes"]) == "Your 3 bots can fill logins from the Hermes vault from now on. Nobody is asked again.")
        #expect(Wire.doneLine(bots: 1, vaults: ["Hermes", "Work"]).hasPrefix("This bot can fill logins from Hermes and Work"))
        #expect(Wire.connectedLine(Wire.Status(supported: true, connected: true, ours: true, vaults: ["Hermes"]))
                == "On: bots fill logins from Hermes. Allowed for good.")
    }

    @Test func aVaultNamedHermesIsTickedAndOneVaultIsTheAnswer() {
        let hermes = Wire.Vault(id: "h", name: "hermes", items: 2), work = Wire.Vault(id: "w", name: "Work", items: 9)
        #expect(Wire.firstPick([hermes, work]) == ["h"] && Wire.firstPick([work]) == ["w"])
        #expect(Wire.firstPick([work, Wire.Vault(id: "f", name: "Family", items: nil)]).isEmpty)
        #expect(!Wire.offersNewVault([hermes, work]) && Wire.offersNewVault([work]) && Wire.offersNewVault([]))
    }

    @Test func allowThenPickThenDone() async {
        let addOn = AddOn()
        let route = Wire.route + "/allow"
        addOn.answers["POST \(route)"] = [(200, ["job": "j1", "state": "waiting"])]
        addOn.answers["GET \(route)/j1"] = [(200, ["job": "j1", "state": "waiting"]), (0, nil),
                                             (200, ["job": "j1", "state": "choose", "vaults": vaults, "account": "x"])]
        let model = OnePasswordAllowModel()
        model.call = addOn.call
        model.pause = .milliseconds(1)
        model.start()
        await settle(model) { if case .choose = $0 { true } else { false } }
        #expect(model.phase == .choose([Wire.Vault(id: "v-hermes", name: "Hermes", items: 6), Wire.Vault(id: "v-work", name: "Work", items: 1)]))
        #expect(model.picked == ["v-hermes"] && !model.makeNew && model.canGive)

        model.picked.insert("v-work")
        addOn.answers["POST \(route)/j1"] = [(200, ["job": "j1", "state": "making"])]
        addOn.answers["GET \(route)/j1"] = [(200, ["job": "j1", "state": "making"]),
                                             (200, ["job": "j1", "state": "done", "saved": 3, "vaults": vaults])]
        model.give()
        #expect(model.phase == .making)
        await settle(model) { if case .done = $0 { true } else { false } }
        #expect(model.phase == .done(bots: 3, vaults: ["Hermes", "Work"]))
        let sent = addOn.calls.first { $0.method == "POST" && $0.path == "\(route)/j1" }?.body
        #expect(Set(sent?["vaults"] as? [String] ?? []) == ["v-hermes", "v-work"] && sent?["create"] as? Bool == false)
        #expect(OnePasswordAllowModel.known.connected && OnePasswordAllowModel.known.vaults == ["Hermes", "Work"])
        OnePasswordAllowModel.known = Wire.Status()
    }

    @Test func noVaultsOffersANewOneAndNothingPickedGivesNothing() async {
        let addOn = AddOn()
        let route = Wire.route + "/allow"
        addOn.answers["POST \(route)"] = [(200, ["job": "j2", "state": "waiting"])]
        addOn.answers["GET \(route)/j2"] = [(200, ["job": "j2", "state": "choose", "vaults": [[String: Any]]()])]
        let model = OnePasswordAllowModel()
        model.call = addOn.call
        model.pause = .milliseconds(1)
        model.start()
        await settle(model) { if case .choose = $0 { true } else { false } }
        #expect(model.phase == .choose([]) && model.makeNew && model.canGive)
        model.makeNew = false
        #expect(!model.canGive)
        model.give()
        #expect(model.phase == .choose([]))   // nothing sent
        #expect(!addOn.calls.contains { $0.method == "POST" && $0.path.hasSuffix("/j2") })
    }

    @Test func notAllowedAndARefusedStartSayWhy() async {
        let addOn = AddOn()
        let route = Wire.route + "/allow"
        addOn.answers["POST \(route)"] = [(200, ["job": "j3", "state": "waiting"])]
        addOn.answers["GET \(route)/j3"] = [(200, ["job": "j3", "state": "failed", "detail": "1Password wasn’t allowed. Try again, then click Allow in 1Password.", "code": "denied"])]
        let model = OnePasswordAllowModel()
        model.call = addOn.call
        model.pause = .milliseconds(1)
        model.start()
        await settle(model) { if case .failed = $0 { true } else { false } }
        #expect(model.phase == .failed("1Password wasn’t allowed. Try again, then click Allow in 1Password.", code: "denied"))

        addOn.answers["POST \(route)"] = [(409, ["ok": false, "detail": "1Password’s command-line tool isn’t installed on this computer.", "code": "no-cli"])]
        model.start()
        await settle(model) { if case .failed(_, "no-cli") = $0 { true } else { false } }
        #expect(model.phase == .failed("1Password’s command-line tool isn’t installed on this computer.", code: "no-cli"))

        addOn.answers["POST \(route)"] = [(200, ["job": "j4", "state": "waiting"])]
        addOn.answers["GET \(route)/j4"] = [(404, nil)]   // Hermes restarted under it
        model.start()
        await settle(model) { if case .failed(_, "gone") = $0 { true } else { false } }
        #expect(model.phase == .failed("Hermes restarted before this finished. Try again.", code: "gone"))
    }

    @Test func anAddOnWithoutItIsNotSupported() async {
        let addOn = AddOn()
        #expect(await OnePasswordAllowModel.status(call: addOn.call) == Wire.Status())
        addOn.answers["GET \(Wire.route)?profile=ivy"] = [(200, ["supported": true, "connected": false])]
        #expect(await OnePasswordAllowModel.status(profile: "ivy", call: addOn.call).supported)
        addOn.answers["DELETE \(Wire.route)"] = [(200, ["ok": true, "removed": 2])]
        #expect(await OnePasswordAllowModel.disconnect(call: addOn.call))
        OnePasswordAllowModel.known = Wire.Status()
    }

    @Test func theUnlockSheetLeadsWithAllowOnlyFor1PasswordAndOnlyWhenTheAddOnCan() {
        let asks = ValuePrompt(id: "srq-1", kind: .vaultUnlock, params: ["backend": "onepassword", "display_name": "1Password"])
        #expect(PromptSheetCopy.asksOnePassword(asks))
        #expect(!PromptSheetCopy.asksOnePassword(ValuePrompt(id: "", kind: .vaultUnlock, params: ["backend": "bitwarden"])))
        #expect(!PromptSheetCopy.asksOnePassword(ValuePrompt(id: "", kind: .vaultSaveLogin, params: ["backend": "onepassword"])))

        OnePasswordAllowModel.known = Wire.Status()
        let sheet = PromptSheetController(prompt: asks, botName: "Ivy")
        sheet.loadViewIfNeeded()
        #expect(!sheet.debugAllowShown && sheet.debugWords == sheet.copy.text)   // as it was: the master password
        sheet.debugShowAllow(true)
        #expect(sheet.debugAllowShown)
        #expect(sheet.debugWords.hasPrefix("Ivy wants a login saved in 1Password. Allow it in 1Password"))
        #expect(!sheet.debugWords.contains("Enter your master password"))
        sheet.debugType(["hunter2-master"])
        #expect(sheet.value == "hunter2-master")   // the master password still works

        let other = PromptSheetController(prompt: ValuePrompt(id: "srq-2", kind: .vaultUnlock, params: ["backend": "bitwarden"]))
        other.debugShowAllow(true)
        #expect(!other.debugAllowShown)
        #expect(Wire.allowed.unicodeScalars.first?.value == 0x1D)   // never something a person types
    }

    @Test func thePasswordsPagesLine() throws {
        func source(_ json: String) throws -> VaultSource { try #require(VaultSource(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))) }
        let locked = try source(#"{"name":"onepassword","display_name":"1Password","enabled":true,"needs_unlock":true,"unlocked":false,"installed":true}"#)
        let open = try source(#"{"name":"onepassword","display_name":"1Password","enabled":true,"needs_unlock":true,"unlocked":true,"installed":true}"#)
        let off = try source(#"{"name":"onepassword","display_name":"1Password","enabled":false,"needs_unlock":true,"unlocked":false,"installed":true}"#)
        let can = Wire.Status(supported: true)
        #expect(PasswordsLayout.sourceLine(locked, onePassword: nil) == VaultSource.subtitle(locked))
        #expect(PasswordsLayout.sourceLine(locked, onePassword: can) == "On, but locked: allow it in 1Password so bots can fill logins.")
        #expect(PasswordsLayout.sourceLine(open, onePassword: can) == "On: unlocked for now. Allow it in 1Password and bots aren’t asked again.")
        #expect(PasswordsLayout.sourceLine(off, onePassword: can) == VaultSource.subtitle(off))
        #expect(PasswordsLayout.sourceLine(open, onePassword: Wire.Status(supported: true, connected: true, ours: true, vaults: ["Hermes", "Work"]))
                == "On: bots fill logins from Hermes and Work. Allowed for good.")
    }
}
