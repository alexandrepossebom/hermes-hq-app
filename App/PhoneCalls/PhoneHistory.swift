// Phone Calls (Beta): the calls an HQ account made, kept on this device so the call sheet and Settings › Phone Calls ›
// Call history still show them after a relaunch. One file per account, named by a hash of the account id, under
// Application Support/PhoneCalls. Never the samplehost key (that stays in the Keychain, samplehostClient.swift).

import CryptoKit
import Foundation

nonisolated struct PhoneHistoryStore: Sendable {
    /// The newest calls kept, and the lines kept per call.
    static let maxCalls = 50
    static let maxLines = 300

    let directory: URL

    static var app: PhoneHistoryStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return PhoneHistoryStore(directory: support.appending(path: "PhoneCalls", directoryHint: .isDirectory))
    }

    func file(for accountID: String) -> URL {
        let name = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name + ".json")
    }

    private struct Saved: Codable { var version = 1; var calls: [PhoneCallRecord] }

    func load(for accountID: String) -> [PhoneCallRecord] {
        guard let data = try? Data(contentsOf: file(for: accountID)),
              let saved = try? JSONDecoder.phone.decode(Saved.self, from: data) else { return [] }
        return saved.calls
    }

    /// Writes the newest `maxCalls` calls, each with at most `maxLines` lines (the end of the call is kept). The file
    /// is readable once the phone was unlocked after a restart and is left out of backups.
    func save(_ calls: [PhoneCallRecord], for accountID: String) {
        let kept = Array(calls.sorted { $0.placedAt < $1.placedAt }.suffix(Self.maxCalls)).map { call -> PhoneCallRecord in
            var trimmed = call
            if trimmed.lines.count > Self.maxLines { trimmed.lines = Array(trimmed.lines.suffix(Self.maxLines)) }
            return trimmed
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            var url = file(for: accountID)
            let data = try JSONEncoder.phone.encode(Saved(calls: kept))
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try? url.setResourceValues(values)
        } catch {
            AppLog.note("phone", "history not saved")
        }
    }

    func delete(for accountID: String) {
        try? FileManager.default.removeItem(at: file(for: accountID))
    }

    /// Every account's history (DEBUG `-HQDebugResetAccounts`).
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

extension JSONEncoder {
    nonisolated static var phone: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

extension JSONDecoder {
    nonisolated static var phone: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
