// [tile-widgets] Where the Home Screen widgets' data lives: generic-password items in the app's own default Keychain
// access group, as the bot faces for pushed alerts (Shared/PushFaces.swift). The widget extension lists that group in
// keychain-access-groups (TalkActivityWidget/HermesHQTalkActivity.entitlements), which every team profile allows, so
// this needs no App Group and no change at Apple. Readable after the first unlock, never synced, never backed up.
//
// The app writes the index, the pictures and the tasks; the extension only reads them, and writes one thing: what each
// placed widget is (its family, its size, its tile), so the app draws exactly the sizes that are on the Home Screen. The
// extension never reaches the gateway: a Sign in with Nous account's refresh token rotates on every use, and a second
// process renewing it unattended could sign the person out.
//
// Built into the app and the extension (project.yml), Foundation and Security only.

import Foundation
import Security

nonisolated enum WidgetVault {
    /// Every widget item's service starts with this; a sign-out takes them all (`removeAll`).
    static let prefix = "ai.hermes.hq.widget."

    /// A test run's own services (`WidgetVault.testPrefix` set by the unit tests), so a test never touches what the app
    /// on the same simulator wrote.
    nonisolated(unsafe) static var testPrefix: String? = nil

    static func service(_ name: String) -> String { (testPrefix ?? prefix) + name }

    private static func query(_ service: String, _ account: String?) -> [String: Any] {
        var item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { item[kSecAttrAccount as String] = account }
        return item
    }

    /// Writes `data` (an update when the item is there). False when Keychain refused it.
    @discardableResult
    static func write(_ data: Data, service: String, account: String) -> Bool {
        let item = query(service, account)
        let status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func read(service: String, account: String) -> Data? {
        var item = query(service, account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// The accounts (item names) kept under `service`.
    static func accounts(service: String) -> [String] {
        var all = query(service, nil)
        all[kSecReturnAttributes as String] = true
        all[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(all as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    static func delete(service: String, account: String) {
        SecItemDelete(query(service, account) as CFDictionary)
    }

    static func deleteAll(service: String) {
        SecItemDelete(query(service, nil) as CFDictionary)
    }

    // MARK: Codable items

    static func save<T: Encodable>(_ value: T, service: String, account: String, maxBytes: Int) -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(value), data.count <= maxBytes else { return false }
        if read(service: service, account: account) == data { return true }
        return write(data, service: service, account: account)
    }

    static func load<T: Decodable>(_ type: T.Type, service: String, account: String, maxBytes: Int) -> T? {
        guard let data = read(service: service, account: account), data.count <= maxBytes else { return nil }
        return try? PropertyListDecoder().decode(type, from: data)
    }
}
