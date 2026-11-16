// [1password-allow] Owner 2026-11-16: "it pops up in 1Password to authorize it. I don't have to type in my master
// password or anything. I just click allow and then it permanently gives it access. I need the same thing in our app."
//
// hermes-hq-push 0.9.59 (`onePasswordAllow` in its status; onepassword_allow.py) does it on Hermes's computer with
// 1Password's own command-line tool: the 1Password app there asks its person to allow it, they pick the vaults here,
// and a read-only key for those vaults is saved for the bots (1Password calls it a service account). With the key,
// Hermes's 1Password is never locked. The key never comes to the app. These are the answers of
//   GET    …/vault/onepassword                what the Passwords page shows
//   POST   …/vault/onepassword/allow          start: {job, state: waiting}
//   GET    …/vault/onepassword/allow/<job>    waiting → choose (the vaults) → making → done | failed
//   POST   …/vault/onepassword/allow/<job>    {vaults: [id], create: Bool}
//   DELETE …/vault/onepassword                take the key back out

import Foundation

nonisolated enum OnePasswordAllowWire {
    static let route = PushPolicy.route + "/vault/onepassword"
    /// Hermes's name for the 1Password source (`vault.sources`, the unlock card's `backend`).
    static let backend = "onepassword"
    /// What the unlock card is answered with once the key is saved, in place of a master password. The add-on reads
    /// it; an add-on without the feature never gets it (the button isn't shown).
    static let allowed = "\u{1D}hermes-hq:allowed-in-1password"
    /// The vault the add-on makes when asked.
    static let newVault = "Hermes"

    struct Vault: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var items: Int?
    }

    struct Status: Equatable, Sendable {
        /// The add-on has the feature and 1Password's command-line tool is on Hermes's computer.
        var supported = false
        /// This bot has a key (ours or one somebody set by hand).
        var connected = false
        /// The key is the one this feature made: its vaults are known and Disconnect removes it.
        var ours = false
        var vaults: [String] = []
        var bots = 0
    }

    enum Job: Equatable, Sendable {
        case waiting
        case choose([Vault], account: String)
        case making
        case done(bots: Int, vaults: [String])
        case failed(String, code: String)
    }

    static func status(_ body: [String: Any]?) -> Status {
        guard let body else { return Status() }
        func flag(_ key: String) -> Bool { (body[key] as? NSNumber)?.boolValue == true }
        return Status(supported: flag("supported"), connected: flag("connected"), ours: flag("ours"),
                      vaults: (body["vaults"] as? [Any] ?? []).compactMap { $0 as? String },
                      bots: (body["bots"] as? NSNumber)?.intValue ?? 0)
    }

    private static func vaults(_ body: [String: Any]) -> [Vault] {
        (body["vaults"] as? [Any] ?? []).compactMap { row in
            guard let row = row as? [String: Any], let id = row["id"] as? String, !id.isEmpty else { return nil }
            let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Vault(id: id, name: name.isEmpty ? "Vault" : name, items: (row["items"] as? NSNumber)?.intValue)
        }
    }

    /// A job's answer; nil when it isn't one (no answer, another shape).
    static func job(_ body: [String: Any]?) -> (id: String, job: Job)? {
        guard let body, let id = body["job"] as? String, !id.isEmpty, let state = body["state"] as? String else { return nil }
        switch state {
        case "waiting": return (id, .waiting)
        case "choose": return (id, .choose(vaults(body), account: body["account"] as? String ?? ""))
        case "making": return (id, .making)
        case "done": return (id, .done(bots: (body["saved"] as? NSNumber)?.intValue ?? 0, vaults: vaults(body).map(\.name)))
        case "failed": return (id, .failed(failure(body), code: body["code"] as? String ?? "failed"))
        default: return nil
        }
    }

    /// Why it didn't work, from a job or a refused call.
    static func failure(_ body: [String: Any]?) -> String {
        let said = (body?["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return said.isEmpty ? "1Password couldn’t be asked." : said
    }

    // MARK: Words

    /// "Hermes", "Hermes and Work", "Hermes, Work and Family".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    static func vaultDetail(_ vault: Vault) -> String? {
        guard let items = vault.items else { return nil }
        return items == 1 ? "1 item" : "\(items) items"
    }

    /// The Passwords page's line under 1Password once a key is saved.
    static func connectedLine(_ status: Status) -> String {
        guard status.ours, !status.vaults.isEmpty else { return "On: bots fill logins from it. Allowed with a key." }
        return "On: bots fill logins from \(list(status.vaults)). Allowed for good."
    }

    static func doneLine(bots: Int, vaults: [String]) -> String {
        let who = bots == 1 ? "This bot" : "Your \(bots) bots"
        let from = vaults.isEmpty ? "1Password" : (vaults.count == 1 ? "the \(vaults[0]) vault" : "\(list(vaults))")
        return "\(who) can fill logins from \(from) from now on. Nobody is asked again."
    }

    /// The vault rows start with nothing ticked unless there is exactly one, or one already named Hermes.
    static func firstPick(_ vaults: [Vault]) -> Set<String> {
        if vaults.count == 1 { return [vaults[0].id] }
        return Set(vaults.filter { $0.name.caseInsensitiveCompare(newVault) == .orderedSame }.map(\.id))
    }

    /// Offer to make a vault named Hermes only when there isn't one.
    static func offersNewVault(_ vaults: [Vault]) -> Bool {
        !vaults.contains { $0.name.caseInsensitiveCompare(newVault) == .orderedSame }
    }
}
