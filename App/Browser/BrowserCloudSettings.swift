import SwiftUI
import UIKit

// Settings › Browser Use Cloud (the owner, 2026-11-14: the choice was per bot only, and one switch for all bots was
// asked for): the person's Browser Use API key, and "Use for All Bots", which puts every bot on the computer in Browser
// Use Cloud, new bots too (browser add-on 3.10+). One bot is still changed on Bot Info › Browser, and a bot put back
// on its own browser there stays on it.

@MainActor @Observable final class BrowserCloudSettingsModel {
    let service: BrowserService?
    weak var router: SettingsRouter?
    var cloud: BrowserCloud?
    var offersAll = false
    var loading = true
    var loadFailure: String?
    var working: String?
    var failure: String?
    /// After "Use for All Bots": the bots the computer left as they were.
    var skipped: [String] = []
    var confirmingForget = false
    var confirmingOff = false

    init(service: BrowserService?, router: SettingsRouter?) {
        self.service = service
        self.router = router
    }

    func load() async {
        loading = true
        loadFailure = nil
        defer { loading = false }
        guard let service else { return }
        do {
            let found = try await service.cloudSettings()
            cloud = found?.cloud
            offersAll = found?.offersAll ?? false
        } catch where BrowserService.isMissing(error) {
            cloud = nil
        } catch {
            AppLog.swallowed("browser", "read Browser Use Cloud", error)
            loadFailure = (error as? LocalizedError)?.errorDescription ?? "Couldn’t read Browser Use Cloud. Try again."
        }
    }

    /// The switch: on asks for a key first when none is saved; off asks before it moves every bot back.
    func setAll(_ on: Bool) {
        guard cloud?.all != on else { return }
        if !on {
            confirmingOff = true
        } else if cloud?.keySet == true {
            applyAll(true)
        } else {
            askKey(thenAll: true)
        }
    }

    func askKey(thenAll: Bool) {
        TextPrompt.present(
            title: cloud?.keySet == true ? "Change the Browser Use API Key" : "Browser Use API Key",
            message: "Paste a key from your Browser Use account (browser-use.com). It’s saved on \(HostWord.phrase) only, and bots there use it to open cloud browsers that Browser Use bills to you.",
            placeholder: "API key", action: "Save", identifier: "browser.cloud.keyField",
            autocapitalization: .none, autocorrection: .no, from: router?.presenter) { [weak self] key in
            self?.saveKey(key, thenAll: thenAll)
        }
    }

    func saveKey(_ typed: String, thenAll: Bool) {
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let service, !key.isEmpty, working == nil else { return }
        working = "Checking the key with Browser Use…"
        Task {
            do {
                let saved = try await service.saveCloudKey(key)
                cloud = saved
                AppLog.note("browser", "cloud key: saved")
                working = nil
                if thenAll { applyAll(true) } else { Haptics.play(.success) }
            } catch {
                working = nil
                let status = (error as? HTTPError)?.status ?? 0
                AppLog.note("browser", status > 0 ? "cloud key: refused (HTTP \(status))" : "cloud key: failed")
                failure = BrowserChoiceModel.detail((error as? HTTPError)?.body) ?? (error as? LocalizedError)?.errorDescription
                    ?? "\(HostWord.sentence) couldn’t check the key. Try again."
                Haptics.play(.warning)
            }
        }
    }

    func forgetKey() {
        guard let service, working == nil else { return }
        working = "Removing the key…"
        Task {
            defer { working = nil }
            do {
                // All bots first: without a key none of them could open a browser.
                if cloud?.all == true { _ = try await service.setCloudForAll(false) }
                cloud = try await service.saveCloudKey("")
                skipped = []
                AppLog.note("browser", "cloud key: removed")
            } catch {
                AppLog.swallowed("browser", "remove the Browser Use key", error)
                failure = "\(HostWord.sentence) couldn’t remove the key. Try again."
            }
        }
    }

    func applyAll(_ on: Bool) {
        guard let service, working == nil else { return }
        working = on ? "Switching every bot to Browser Use Cloud…" : "Giving every bot its own browser back…"
        Task {
            defer { working = nil }
            do {
                let answer = try await service.setCloudForAll(on)
                cloud = answer
                skipped = on ? answer.skipped : []
                AppLog.note("browser", "cloud for all bots: \(on ? "on" : "off"), \(answer.skipped.count) skipped")
                Haptics.play(.success)
            } catch {
                let status = (error as? HTTPError)?.status ?? 0
                AppLog.note("browser", status > 0 ? "cloud for all bots: failed (HTTP \(status))" : "cloud for all bots: failed")
                failure = BrowserChoiceModel.detail((error as? HTTPError)?.body) ?? (error as? LocalizedError)?.errorDescription
                    ?? "\(HostWord.sentence) didn’t make that change. Try again."
                Haptics.play(.warning)
            }
        }
    }

    /// "otto" · "otto and ivy" · "otto, ivy and 2 more": the bots left as they were.
    static func skippedLine(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        let who: String = switch names.count {
        case 1: first
        case 2: "\(first) and \(names[1])"
        default: "\(first), \(names[1]) and \(names.count - 2) more"
        }
        return "\(who) \(names.count == 1 ? "was" : "were") left as \(names.count == 1 ? "it was" : "they were"): "
            + "\(names.count == 1 ? "its" : "their") browser tools or the browser add\u{2011}on are turned off."
    }
}

struct BrowserCloudSettingsView: View {
    @Bindable var model: BrowserCloudSettingsModel

    var body: some View {
        List {
            if model.loading && model.cloud == nil {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if model.cloud == nil, let reason = model.loadFailure {
                Section {
                    ContentUnavailableView {
                        UnavailableTitle("Couldn’t Load Browser Use Cloud", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(reason).hqMacFont(MacType.emptyBodyFont)
                    } actions: {
                        Button("Try Again") { Task { await model.load() } }
                            .hqProminentButtonStyle()
                            .buttonBorderShape(.capsule)
                            .accessibilityIdentifier("settings.cloud.retry")
                    }
                }
            } else if let cloud = model.cloud {
                keySection(cloud)
                allSection(cloud)
            } else {
                Section {
                    Text("The browser add\u{2011}on on \(HostWord.phrase) doesn’t offer this yet. Once it’s updated you can add your Browser Use API key here and have your bots browse in the cloud.")
                        .foregroundStyle(Color.hqLabel2)
                        .accessibilityIdentifier("settings.cloud.unavailable")
                }
            }
        }
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .disabled(model.working != nil)
        .overlay(alignment: .bottom) {
            if let working = model.working {
                HStack(spacing: 10) { ProgressView(); Text(working).font(Font.hq(.subheadline)) }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .hqGlassEffect(in: .capsule)
                    .padding(.bottom, 24)
                    .accessibilityIdentifier("settings.cloud.working")
            }
        }
        .alert("Couldn’t Change Browser Use Cloud", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.failure ?? "") }
        .alert("Remove the Browser Use API Key?", isPresented: $model.confirmingForget) {
            Button("Remove", role: .destructive) { model.forgetKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.cloud?.all == true
                 ? "Use for All Bots turns off and every bot goes back to its own browser on \(HostWord.phrase)."
                 : "Bots set to Browser Use Cloud can’t open a browser until you add a key again or switch them back to their own.")
        }
        .alert("Turn Off Browser Use Cloud for All Bots?", isPresented: $model.confirmingOff) {
            Button("Turn Off") { model.applyAll(false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every bot goes back to its own browser on \(HostWord.phrase), with the sign-ins it had there. You can still choose Browser Use Cloud for one bot in Bot Info › Browser.")
        }
        .task { await model.load() }
    }

    @ViewBuilder private func keySection(_ cloud: BrowserCloud) -> some View {
        Section {
            Button {
                model.askKey(thenAll: false)
            } label: {
                HStack {
                    Text("API Key").foregroundStyle(Color.hqLabel)
                    Spacer()
                    Text(cloud.keySet ? (cloud.keyHint ?? "Saved") : "Add").foregroundStyle(Color.hqLabel2)
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("settings.cloud.key")
            if cloud.keySet {
                Button("Remove API Key", role: .destructive) { model.confirmingForget = true }
                    .accessibilityIdentifier("settings.cloud.forget")
            }
        } footer: { HQSectionFooter {
            Text("Your key from browser-use.com, saved on \(HostWord.phrase) only. Browser Use bills your account by the minute while a bot’s cloud browser is open.")
        } }
    }

    @ViewBuilder private func allSection(_ cloud: BrowserCloud) -> some View {
        if model.offersAll {
            Section {
                Toggle("Use for All Bots", isOn: Binding(get: { cloud.all }, set: { model.setAll($0) }))
                    .accessibilityIdentifier("settings.cloud.all")
            } footer: { HQSectionFooter {
                VStack(alignment: .leading, spacing: 6) {
                    if let line = BrowserCloudSettingsModel.skippedLine(model.skipped) {
                        Text(line).foregroundStyle(Color.hqLabel).accessibilityIdentifier("settings.cloud.skipped")
                    }
                    Text(cloud.all
                         ? "Every bot on \(HostWord.phrase) browses in Browser Use Cloud, and so does any bot you add. To keep one bot on its own browser, choose Its Own Profile in its Bot Info › Browser."
                         : "Puts every bot on \(HostWord.phrase) in a Browser Use Cloud browser, and any bot you add later. You can watch and take over as before. To switch just one bot, use its Bot Info › Browser.")
                }
            } }
        } else {
            Section {
                Text("Update the browser add\u{2011}on on \(HostWord.phrase) to switch every bot at once. Until then, choose Browser Use Cloud for each bot in its Bot Info › Browser.")
                    .foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("settings.cloud.all.unavailable")
            }
        }
    }
}
