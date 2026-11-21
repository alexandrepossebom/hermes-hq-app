// [provider-manager] Owner 2026-11-05: "I don't know, you tell me where I can do it. I just need to be able to like add
// and remove providers and then edit their names and then edit the list of models on each provider so that I can like
// control which ones show in the app and the names and everything else."
//
// Settings › Providers is one list of the providers you have (`ProviderList.merge`: your own endpoints, Hermes' built-in
// providers with a key saved, the accounts you're signed in to), each with its name, what it is, and how many of its
// models show. + adds one (Add Provider). Swipe a row (or touch and hold / Control-click it) to remove it, after one
// confirm: an endpoint is deleted, a key removed, an account signed out; where Hermes can't, it says why.
//
// A provider's page: Name (your own endpoints are renamed on the gateway; a built-in's or an account's name is the app's,
// synced to your other devices), Models (every model it offers, a Show switch each, tap a name to rename it, Show All /
// Hide All, Add Model…), Default Model, its key (or connection), Test Connection for your own, and Remove Provider.
// What is hidden or renamed applies to every model menu in the app (`ProviderPrefs`); a pick still sends the real ids.
//
// [provider-off] Owner 2026-11-15: "I keep having the models change to providers that i don't want to use and i want to
// clean out a bunch of providers and there isn't an easy way to do it... i need full management of all of this to be
// very simple". Three things:
//   - every row has a switch. Off, the provider is in no model menu (`ProviderPrefs.isOff`), whatever models it has or
//     adds later; its key stays on the gateway, so what else uses it (voice, a job) still works. The same switch leads
//     the provider's page.
//   - the list holds every provider the model menus show (`ProviderList.merge`'s catalog rows), so none can be in a
//     menu with nothing here to switch.
//   - Select picks several: Turn Off, Turn On, or Remove… them at once, after one confirm.

import Observation
import SwiftUI
import UIKit

// MARK: - The page's data

@MainActor @Observable
final class ProvidersModel {
    let env: EnvKeysModel
    let custom: CustomProvidersModel
    let catalog: ModelCatalogModel
    var accounts: [OAuthProviderRow] = []
    var accountsError: String?
    var accountsLoaded = false
    /// The account's names and short lists (kept up to date when another page or device changes them).
    var prefs: ProviderPrefs
    /// A remove from the list (or the page) that failed.
    var failure: String?
    /// The provider being removed (its row shows it).
    var removing: String?
    @ObservationIgnored let api: GatewaySettingsAPI?
    @ObservationIgnored let readOnly: Bool
    @ObservationIgnored let account: String?
    @ObservationIgnored private var watch: NSObjectProtocol?

    init(router: SettingsRouter) {
        let api = router.gatewaySettings?.settingsAPI
        let readOnly = router.gatewaySettings?.isReadOnlyGateway ?? false
        let account = router.services.account?.id
        self.api = api
        self.readOnly = readOnly
        self.account = account
        env = EnvKeysModel(api: api, readOnly: readOnly)
        custom = CustomProvidersModel(api: api, readOnly: readOnly, account: account)
        catalog = ModelCatalogModel(api: api)
        prefs = Self.store(account)?.prefs ?? ProviderPrefs.active
        watch = NotificationCenter.default.addObserver(forName: ProviderPrefsStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadPrefs() }
        }
    }

    isolated deinit { if let watch { NotificationCenter.default.removeObserver(watch) } }

    private static func store(_ account: String?) -> ProviderPrefsStore? {
        if let current = ProviderPrefsStore.current { return current }
        return account.map { ProviderPrefsStore.of(accountId: $0) }
    }

    private func reloadPrefs() { prefs = Self.store(account)?.prefs ?? ProviderPrefs.active }

    /// Changes the names or short lists: saved, synced, and every model menu shows them from its next open.
    func update(_ change: (inout ProviderPrefs) -> Void) {
        guard let store = Self.store(account) else { return }
        store.update(change)
        prefs = store.prefs
        if let account { ModelCatalogCache.shared.markStale(account: account) }
    }

    var rows: [ManagedProvider] {
        ProviderList.merge(custom: custom.providers, vars: env.vars, accounts: accounts, catalog: catalog.raw, prefs: prefs)
    }

    func row(_ id: String) -> ManagedProvider? { rows.first { $0.id == id } }

    var loaded: Bool { env.loaded && custom.loaded && accountsLoaded }

    /// The keys and your own endpoints have loaded, and the sign-ins have loaded or failed: the list can show (a failed
    /// sign-in list says so under it instead of standing in for the whole page).
    var listReady: Bool { env.loaded && custom.loaded && (accountsLoaded || accountsError != nil) }

    /// Everything the list needs, read at once.
    func load() async {
        async let keys: Void = env.load()
        async let mine: Void = custom.load()
        async let models: Void = catalog.load()
        async let signIns: Void = loadAccounts()
        _ = await (keys, mine, models, signIns)
    }

    func loadAccounts() async {
        guard let api else { return }
        do { accounts = try await api.oauthProviders(); accountsError = nil; accountsLoaded = true } catch {
            AppLog.note("settings", "provider accounts load failed: \(type(of: error))")
            accountsError = SettingsErrorText.load(error)
        }
    }

    /// The model catalog's own provider row for a provider (its real slug, models, key and address).
    func catalogRow(_ id: String) -> ModelProviderOption? { catalog.raw.first { ProviderPrefs.providerKey($0.slug) == id } }

    // MARK: [provider-off] On and off

    /// Takes providers out of every model menu, or puts them back. Nothing changes on the gateway.
    func setOff(_ off: Bool, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        update { $0.setOff(off, providers: ids) }
        Haptics.play(.selection)
        AppLog.note("settings", "providers turned \(off ? "off" : "on"): \(ids.count)")
    }

    // MARK: Remove

    /// [provider-off] Several at once, after one confirm that says what goes: keys removed, accounts signed out, your
    /// own providers deleted. One Hermes sets up itself can't be removed here and is turned off instead.
    func askRemove(_ picked: [ManagedProvider], router: SettingsRouter, done: @escaping () -> Void) {
        guard !picked.isEmpty else { return }
        if picked.count == 1 { askRemove(picked[0], router: router, done: done); return }
        let can = ProviderList.removable(picked)
        guard !can.isEmpty else {
            Haptics.play(.warning)
            let alert = UIAlertController(title: "Can’t Remove These",
                                          message: "Hermes sets them up itself on \(HostWord.phrase), so there is nothing here to remove. Turn them off to keep them out of your model menus.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Turn Off", style: .default) { [weak self] _ in
                self?.setOff(true, picked.map(\.id))
                done()
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            FailureAlert.topmost(router.presenter)?.present(alert, animated: true)
            return
        }
        TextPrompt.confirm(title: can.count == 1 ? "Remove 1 Provider?" : "Remove \(can.count) Providers?",
                           message: ProviderList.removeMessage(picked, prefs: prefs), action: "Remove", from: router.presenter) { [weak self] in
            Task { await self?.removeSeveral(picked, done: done) }
        }
    }

    private func removeSeveral(_ picked: [ManagedProvider], done: () -> Void) async {
        failure = nil
        var settled: [String] = []
        var refused: [String] = []
        var why: String?
        var signedOut = false
        for row in picked {
            removing = row.id
            var problem: String?
            switch row.removal {
            case .cannot:
                break   // turned off below
            case .deleteEndpoint:
                guard let endpoint = row.endpoint else { continue }
                do { try await custom.delete(endpoint.id) } catch {
                    AppLog.note("settings", "custom provider delete failed: \(type(of: error))")
                    problem = (error as? CustomProviderFailure)?.text ?? SettingsErrorText.save(error)
                }
            case .removeKeys(let keys):
                problem = await take(row, keys: keys, signOut: false)
            case .removeKeysAndSignOut(let keys):
                signedOut = true
                problem = await take(row, keys: keys, signOut: true)
            case .signOut:
                signedOut = true
                problem = await take(row, keys: [], signOut: true)
            }
            if let problem { refused.append(row.name(prefs)); why = why ?? problem } else { settled.append(row.id) }
        }
        removing = nil
        let kept = picked.filter { if case .cannot = $0.removal { return true } else { return false } }.map(\.id)
        if !kept.isEmpty { update { $0.setOff(true, providers: kept) } }
        await settle(settled.filter { !kept.contains($0) }, accounts: signedOut)
        AppLog.note("settings", "providers removed: \(settled.count - kept.count), turned off: \(kept.count), refused: \(refused.count)")
        if refused.isEmpty {
            Haptics.play(.success)
        } else {
            Haptics.play(.error)
            failure = "Couldn’t remove \(ListFormatter.localizedString(byJoining: refused)). \(why ?? "")"
        }
        done()
    }

    /// Remove, after one confirm (or the reason it can't be). `done` runs once it is gone.
    func askRemove(_ row: ManagedProvider, router: SettingsRouter, done: @escaping () -> Void = {}) {
        let name = row.name(prefs)
        switch row.removal {
        case .cannot(let reason):
            Haptics.play(.warning)
            let alert = UIAlertController(title: "Can’t Remove \(name)", message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            FailureAlert.topmost(router.presenter)?.present(alert, animated: true)
        case .deleteEndpoint:
            guard let endpoint = row.endpoint else { return }
            CustomProviderPages.confirmDelete(endpoint, model: custom, from: router.presenter, started: { [weak self] in
                self?.removing = row.id
            }) { [weak self] failure in
                self?.removing = nil
                self?.failure = failure
                guard failure == nil else { return }
                // [provider-off] The names and switches kept under its catalog id go too (`custom:<key>` went with the
                // delete; Hermes lists some under the bare key).
                Task { await self?.settle([row.id], accounts: false) }
                done()
            }
        case .removeKeys(let keys), .removeKeysAndSignOut(let keys):
            let signOut = row.removal != .removeKeys(keys)
            let message = signOut
                ? "Its key is removed from \(HostWord.phrase) and Hermes signs out of it there. Bots that use \(name) stop working until you add it again."
                : "Its key is removed from \(HostWord.phrase). Bots that use \(name) stop working until you add it again."
            TextPrompt.confirm(title: "Remove \(name)?", message: message, action: "Remove", from: router.presenter) { [weak self] in
                Task { await self?.remove(row, keys: keys, signOut: signOut, done: done) }
            }
        case .signOut:
            TextPrompt.confirm(title: "Sign Out of \(name)?",
                               message: "Hermes on \(HostWord.phrase) forgets this sign-in. Bots that use \(name) stop working until you sign in again there.",
                               action: "Sign Out", from: router.presenter) { [weak self] in
                Task { await self?.remove(row, keys: [], signOut: true, done: done) }
            }
        }
    }

    /// A provider no longer in the list loses the names, hidden models and added models kept for it, so adding it again
    /// later starts fresh. (Your own endpoints' are forgotten by `CustomProvidersModel.delete`.)
    private func forgetGone(_ ids: [String]) {
        let here = Set(rows.map(\.id))
        let gone = ids.filter { !here.contains($0) }
        guard !gone.isEmpty else { return }
        update { prefs in gone.forEach { prefs.forget(provider: $0) } }
        // [ghost-stars] Its starred models leave the Switch Model menus now, not after each chat's next catalog read.
        if let account { gone.forEach { ModelPrefs(accountId: account).removeKnownProvider($0) } }
    }

    /// After a remove: the lists read again, and what is gone is forgotten.
    private func settle(_ ids: [String], accounts: Bool) async {
        if accounts { await loadAccounts() }
        if let account { ModelCatalogCache.shared.markStale(account: account) }
        await catalog.load()
        forgetGone(ids)
    }

    /// Removes a provider's keys and ends its sign-in on the gateway. The reason, when Hermes refused.
    private func take(_ row: ManagedProvider, keys: [String], signOut: Bool) async -> String? {
        for key in keys {
            guard await env.remove(key) else {
                let why = env.failure ?? "Couldn’t remove the key."
                env.dismissFailure()
                return why
            }
        }
        if signOut, let account = row.account, let api {
            do {
                try await api.signOutOAuthProvider(account.id)
                AppLog.note("settings", "provider signed out: \(account.id)")
            } catch {
                AppLog.note("settings", "provider sign out failed: \(type(of: error))")
                return SettingsErrorText.save(error)
            }
        }
        AppLog.note("settings", "provider removed: \(row.id) (\(keys.count) keys\(signOut ? ", signed out" : ""))")
        return nil
    }

    private func remove(_ row: ManagedProvider, keys: [String], signOut: Bool, done: () -> Void) async {
        removing = row.id
        failure = nil
        defer { removing = nil }
        if let problem = await take(row, keys: keys, signOut: signOut) {
            failure = problem
            Haptics.play(.error)
            if signOut { await loadAccounts() }
            return
        }
        Haptics.play(.success)
        await settle([row.id], accounts: signOut)
        done()
    }
}

// MARK: - Settings › Providers

struct ProvidersPageView: View {
    let router: SettingsRouter
    @State private var model: ProvidersModel
    /// [provider-add] Opened from the model list's Add Provider…: the chooser goes over it once it shows.
    private let startAdding: Bool
    @State private var startedAdding = false
    /// [provider-off] Select: rows are picked, not opened, and a bar at the foot acts on the pick.
    @State private var selecting = false
    @State private var picked: Set<String> = []

    init(router: SettingsRouter, startAdding: Bool = false) {
        self.router = router
        self.startAdding = startAdding
        _model = State(initialValue: ProvidersModel(router: router))
    }

    var body: some View {
        let rows = model.rows
        let prefs = model.prefs
        List { Group {
            if let failure = model.failure ?? model.custom.listFailure {
                SaveFailureSection(text: failure, detail: nil, retry: nil, dismiss: { model.failure = nil; model.custom.listFailure = nil })
            }
            if !model.listReady, rows.isEmpty, let error = model.env.loadError ?? model.custom.loadError {
                LoadFailureSection(title: "Couldn’t Load Providers", text: error) { Task { await model.load() } }
            } else if !model.listReady, rows.isEmpty {
                LoadingSection()
            } else {
                Section {
                    if rows.isEmpty {
                        Text("No providers yet. \(DeviceWord.Tap) + to add one.")
                            .foregroundStyle(Color.hqLabel2)
                            .hqRowPadding(4)
                            .accessibilityIdentifier("providers.empty")
                    }
                    ForEach(rows) { row in
                        ProviderListRow(row: row, prefs: prefs, catalog: model.catalog.raw, removing: model.removing == row.id,
                                        readOnly: model.readOnly, picked: selecting ? picked.contains(row.id) : nil) {
                            if selecting { pick(row.id) } else { ProviderPages.open(row.id, model: model, router: router) }
                        } setOn: { on in
                            model.setOff(!on, [row.id])
                        } rename: {
                            ProviderPages.rename(row, model: model, router: router)
                        } remove: {
                            model.askRemove(row, router: router)
                        } select: {
                            picked = [row.id]
                            HQMotion.withAnimation { selecting = true }
                        }
                    }
                    if !model.readOnly, !selecting {
                        Button(action: openAdd) {
                            if DeviceWord.isMac {
                                MacAddRowLabel(title: "Add Provider…")
                            } else {
                                Label("Add Provider…", systemImage: "plus")
                            }
                        }
                        .hqRowPadding(4)
                        .accessibilityIdentifier("custom-providers.add")
                    }
                } footer: { HQSectionFooter {
                    Text(footer(rows)).accessibilityIdentifier("providers.footer")
                } }
                // The accounts Hermes is signed in to are missing from the list above until this reads.
                if let error = model.accountsError {
                    LoadFailureSection(title: "Couldn’t Load Your Sign-Ins", text: error) { Task { await model.loadAccounts() } }
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(model.failure)
        .task { await model.load() }
        .refreshable { await model.load() }
        // [provider-add] Owner 2026-11-04 ("more easily add them"): + opens Add Provider, at the top of the page
        // (iPhone and iPad; the Mac has the list's row only, owner 2026-11-17).
        .onChange(of: rows.map(\.id)) { _, ids in picked.formIntersection(ids) }
        .toolbar {
            if !model.readOnly, selecting {
                ToolbarItem(placement: .primaryAction) {
                    let _ = Theme.touch()
                    Button("Done") { endSelecting() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("providers.select-done")
                }
                .sharedBackgroundVisibility(Theme.isDesktop || DeviceWord.isMac ? .hidden : .automatic)
            } else if !model.readOnly {
                if rows.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        let _ = Theme.touch()
                        Button("Select") {
                            Haptics.play(.selection)
                            picked = []
                            HQMotion.withAnimation { selecting = true }
                        }
                        .accessibilityIdentifier("providers.select")
                    }
                    .sharedBackgroundVisibility(Theme.isDesktop || DeviceWord.isMac ? .hidden : .automatic)
                }
                // [Mac AAA 2026-11-17] Q17, owner: on the Mac the list's own "Add Provider…" row is the one way to add
                // (one go-to); the bar's + goes. The iPhone and iPad keep it.
                if !DeviceWord.isMac {
                    ToolbarItem(placement: .primaryAction) {
                        let _ = Theme.touch()
                        Button(action: openAdd) { Image(systemName: "plus") }
                            .accessibilityLabel(ProviderAdd.title)
                            .accessibilityIdentifier("providers.add")
                    }
                    // The Desktop Look's bar items are plain glyphs (the shared glass circle behind a SwiftUI item showed,
                    // beside a flat Back; StarMapPage's filter had the same).
                    .sharedBackgroundVisibility(Theme.isDesktop ? .hidden : .automatic)
                }
            }
        }
        .onAppear {
            guard startAdding, !startedAdding else { return }
            startedAdding = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))   // after the push that showed this page has settled
                openAdd()
            }
        }
        .accessibilityIdentifier("providers.list")
        // [provider-off] Select's bar stands at the foot of the page, over the list, while several are being picked.
        // (After the list's identifier, which everything inside it without a control of its own would take.)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting { ProviderSelectBar(rows: rows, prefs: prefs, picked: $picked, busy: model.removing != nil, act: act) }
        }
    }

    private func footer(_ rows: [ManagedProvider]) -> String {
        if selecting {
            return "Turn Off keeps a provider’s key on \(HostWord.phrase) and takes it out of every model menu. Remove takes its key off \(HostWord.phrase)."
        }
        let count = ProviderList.onOffLine(rows, prefs: model.prefs).map { "\($0). " } ?? ""
        return "\(count)A provider switched off leaves every model menu; its key stays on \(HostWord.phrase)."
    }

    // MARK: [provider-off] Select

    private func pick(_ id: String) {
        Haptics.play(.selection)
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    private func endSelecting() {
        HQMotion.withAnimation { selecting = false }
        picked = []
    }

    private func act(_ action: ProviderSelectBar.Action) {
        let rows = model.rows.filter { picked.contains($0.id) }
        guard !rows.isEmpty else { return }
        switch action {
        case .off: model.setOff(true, rows.map(\.id)); endSelecting()
        case .on: model.setOff(false, rows.map(\.id)); endSelecting()
        case .remove: model.askRemove(rows, router: router) { endSelecting() }
        }
    }

    private func openAdd() {
        ProviderAdd.openChooser(env: model.env, custom: model.custom, router: router)
    }
}

/// One provider in the list: its name, how many models show and what it is, and its switch.
private struct ProviderListRow: View {
    let row: ManagedProvider
    let prefs: ProviderPrefs
    let catalog: [ModelProviderOption]
    let removing: Bool
    let readOnly: Bool
    /// [provider-off] Select: whether this row is picked (a tick leads it and the switch steps aside); nil outside it.
    let picked: Bool?
    /// Opens its page; picks it in Select.
    let open: () -> Void
    let setOn: (Bool) -> Void
    let rename: () -> Void
    let remove: () -> Void
    let select: () -> Void

    var body: some View {
        // [provider-rows] Owner 2026-11-10 (design pick 4): two lines a row, a dot leading the second: green, or orange
        // when the provider has nothing to pick from. [provider-off] Owner 2026-11-15: the switch has the trailing
        // edge, so how many models show leads the second line; a provider turned off is grey and says "Off".
        let line = ProviderList.rowLine(row, catalog: catalog, prefs: prefs)
        let name = row.name(prefs)
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    if let picked {
                        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                            .font(Font.hq(.title3))
                            .foregroundStyle(picked ? Color.hqTint : Color.hqLabel3)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).foregroundStyle(line.off ? Color.hqLabel2 : Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(line.off ? Color.hqLabel3 : line.none ? Color.hqOrange : Color(uiColor: .systemGreen))
                                .frame(width: 7, height: 7)
                                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                                .accessibilityHidden(true)
                            // Only the count is orange when there is nothing to pick; what the provider is stays grey.
                            (removing ? Text("Removing…")
                                : Text(line.count).foregroundStyle(line.none ? Color.hqOrange : Color.hqLabel2) + Text(" · \(line.source)"))
                                .font(Font.hq(.footnote)).monospacedDigit()
                                .foregroundStyle(Color.hqLabel2)
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            // "Anthropic, Built into Hermes · Key saved, 4 models shown"; "…, Off" for one turned off.
            .accessibilityLabel([name, row.sourceLine, row.endpoint?.isCurrent == true ? "Default" : nil,
                                 removing ? "Removing…" : line.off ? "Off" : ProviderList.shownLine(row, catalog: catalog, prefs: prefs)]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(picked == true ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("provider.\(row.id)")
            if picked == nil {
                Toggle("On", isOn: Binding(get: { !line.off }, set: setOn))
                    .labelsHidden()
                    .disabled(readOnly || removing)
                    .accessibilityLabel("\(name) in model menus")
                    .accessibilityIdentifier("provider.on.\(row.id)")
            }
        }
        .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
        // Red, not the destructive role, which animates the row out before the confirm (GatewayPageView's rows). A row
        // that can't be removed still offers Remove, which says why.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !readOnly, !removing, picked == nil { Button(removeWord) { remove() }.tint(.red) }
        }
        // A mouse has no swipe: the same on a right-click (and a touch and hold).
        .contextMenu {
            if !readOnly, picked == nil {
                Button(line.off ? "Turn On" : "Turn Off", systemImage: line.off ? "eye" : "eye.slash") { setOn(line.off) }
                    .accessibilityIdentifier("provider.menu-onoff")
                Button("Rename…", systemImage: "pencil") { rename() }
                    .accessibilityIdentifier("provider.menu-rename")
                Button("Select", systemImage: "checkmark.circle") { select() }
                    .accessibilityIdentifier("provider.menu-select")
                Button("\(removeWord)…", systemImage: removeIcon, role: .destructive) { remove() }
                    .accessibilityIdentifier("provider.menu-remove")
            }
        }
    }

    private var removeWord: String { row.removal == .signOut ? "Sign Out" : "Remove" }
    private var removeIcon: String { row.removal == .signOut ? "rectangle.portrait.and.arrow.right" : "trash" }
}

/// [provider-off] Select's bar at the foot of the Providers list: how many are picked, Select All, and what to do with
/// them. Turn Off leads (it is the one that can't break anything); Remove asks first.
private struct ProviderSelectBar: View {
    enum Action { case off, on, remove }

    let rows: [ManagedProvider]
    let prefs: ProviderPrefs
    @Binding var picked: Set<String>
    let busy: Bool
    let act: (Action) -> Void

    var body: some View {
        let chosen = rows.filter { picked.contains($0.id) }
        let anyOn = chosen.contains { !prefs.isOff($0.id) }
        let anyOff = chosen.contains { prefs.isOff($0.id) }
        let all = !rows.isEmpty && chosen.count == rows.count
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(chosen.isEmpty ? "Select Providers" : "\(chosen.count) Selected")
                    .font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel).monospacedDigit()
                    .accessibilityIdentifier("providers.select-count")
                Spacer(minLength: 8)
                Button(all ? "Deselect All" : "Select All") {
                    Haptics.play(.selection)
                    picked = all ? [] : Set(rows.map(\.id))
                }
                .font(Font.hq(.subheadline))
                .buttonStyle(.borderless)
                .accessibilityIdentifier("providers.select-all")
            }
            HStack(spacing: 8) {
                Button { act(.off) } label: { label("Turn Off") }
                    .hqProminentButtonStyle()
                    .disabled(!anyOn || busy)
                    .accessibilityIdentifier("providers.select-off")
                Button { act(.on) } label: { label("Turn On") }
                    .buttonStyle(.bordered)
                    .disabled(!anyOff || busy)
                    .accessibilityIdentifier("providers.select-on")
                Button(role: .destructive) { act(.remove) } label: { label(busy ? "Removing…" : "Remove…") }
                    .buttonStyle(.bordered)
                    .disabled(chosen.isEmpty || busy)
                    .accessibilityIdentifier("providers.select-remove")
            }
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 520)
        .hqGlassEffect(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)   // no identifier of the bar's own: its controls would all take it
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Font.hq(.subheadline).weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity).frame(height: HQFont.scaled(30))
    }
}

// MARK: - Pushes and prompts

@MainActor enum ProviderPages {
    static func open(_ id: String, model: ProvidersModel, router: SettingsRouter) {
        guard let row = model.row(id) else { return }
        router.push(row.name(model.prefs), ProviderPageView(id: id, model: model, router: router))
    }

    /// Rename: on the gateway for one of your own (its id kept), else the app's own name, with Reset to Original.
    /// `onPage`: asked from the provider's own page, whose title follows the name (not from the list's row menu).
    static func rename(_ row: ManagedProvider, model: ProvidersModel, router: SettingsRouter, onPage: Bool = false) {
        func retitle(_ name: String) { if onPage { router.navigation?.topViewController?.title = name } }
        let current = row.name(model.prefs)
        let renamed = row.endpoint == nil && model.prefs.providerName(row.id) != nil
        let message = row.endpoint != nil
            ? "Saved on \(HostWord.phrase), so the Hermes desktop app shows it too."
            : "Shown in Hermes HQ on all your devices. Hermes itself keeps calling it \(row.originalName)."
        TextPrompt.present(title: "Rename Provider", message: message, text: current, placeholder: row.originalName, action: "Rename",
                           maxLength: 60, requireChange: true, identifier: "provider.rename-field", selectText: true,
                           secondary: renamed ? ("Reset to Original", {
                               model.update { $0.setProviderName(nil, provider: row.id) }
                               retitle(row.originalName)
                               Haptics.play(.success)
                           }) : nil,
                           from: router.presenter) { name in
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            if let endpoint = row.endpoint {
                Task {
                    do {
                        try await model.custom.rename(endpoint, to: name)
                        Haptics.play(.success)
                        retitle(name)
                    } catch {
                        AppLog.note("settings", "custom provider rename failed: \(type(of: error))")
                        model.failure = (error as? CustomProviderFailure)?.text ?? SettingsErrorText.save(error)
                        Haptics.play(.error)
                    }
                }
            } else {
                model.update { $0.setProviderName(name, provider: row.id, original: row.originalName) }
                retitle(name)
                AppLog.note("settings", "provider renamed in the app: \(row.id)")
                Haptics.play(.success)
            }
        }
    }

    /// A model's name, with Reset to Original once renamed.
    static func renameModel(_ id: String, provider: ManagedProvider, model: ProvidersModel, router: SettingsRouter) {
        let original = ModelNames.builtInModelName(id)
        let own = model.prefs.modelName(provider: provider.id, model: id)
        TextPrompt.present(title: "Rename Model", message: "The model’s ID stays \(id). Only Hermes HQ shows the new name.",
                           text: own ?? original, placeholder: original, action: "Rename", maxLength: 80, requireChange: true,
                           identifier: "provider-model.rename-field", selectText: true,
                           secondary: own != nil ? ("Reset to Original", {
                               model.update { $0.setModelName(nil, provider: provider.id, model: id) }
                               Haptics.play(.success)
                           }) : nil,
                           from: router.presenter) { name in
            model.update { $0.setModelName(name, provider: provider.id, model: id, original: original) }
            AppLog.note("settings", "model renamed in the app (\(provider.id))")
            Haptics.play(.success)
        }
    }
}

// MARK: - A provider's page

struct ProviderPageView: View {
    let id: String
    let model: ProvidersModel
    let router: SettingsRouter
    /// What Test Connection found (your own endpoints).
    @State private var found: [String] = []
    @State private var test: CustomProviderTest?
    @State private var testing = false
    @State private var busy = false
    @State private var query = ""
    @State private var failure: String?
    /// The last row seen: the page keeps it while the list reads again after a change (it never goes blank).
    @State private var last: ManagedProvider?

    /// Your own endpoint, deleted since the page showed it (its Address, Key and Connection page's Delete Provider): the
    /// page says so instead of keeping the last copy.
    private var endpointDeleted: Bool {
        guard let endpoint = last?.endpoint, model.custom.loaded else { return false }
        return model.custom.provider(endpoint.id) == nil
    }

    var body: some View {
        let row = model.row(id) ?? (endpointDeleted ? nil : last)
        List { Group {
            if let failure = failure ?? model.failure {
                SaveFailureSection(text: failure, detail: nil, retry: nil, dismiss: { self.failure = nil; model.failure = nil })
            }
            if let row {
                onSection(row)
                nameSection(row)
                modelsSection(row)
                defaultSection(row)
                keySection(row)
                removeSection(row)
            } else {
                Section { Text("This provider was removed.").foregroundStyle(Color.hqLabel2) }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(failure)
        .onChange(of: model.row(id)) { _, now in if let now { last = now } }
        // [macpass-settings r3] A rename from another device reached the Name row but left the page title on the old
        // name: the page carrying the old name takes the new one.
        .onChange(of: row?.name(prefs)) { old, new in
            guard let old, let new, old != new else { return }
            router.navigation?.viewControllers.last(where: { $0.title == old })?.title = new
        }
        .onAppear { if last == nil { last = model.row(id) } }
        .refreshable { await model.load() }
        .accessibilityIdentifier("provider-page")
    }

    private var prefs: ProviderPrefs { model.prefs }
    private var locked: Bool { model.readOnly || busy }

    // MARK: [provider-off] On or off

    private func onSection(_ row: ManagedProvider) -> some View {
        let off = prefs.isOff(row.id)
        return Section {
            SwitchRow(title: "Show in Model Menus", isOn: Binding(get: { !off }, set: { on in model.setOff(!on, [row.id]) }),
                      disabled: model.readOnly)
                .hqRowPadding(4)
                .accessibilityIdentifier("provider-page.on")
        } footer: { HQSectionFooter {
            Text(off
                ? "Its models are out of every model menu. A chat already on one keeps it, and its key stays on \(HostWord.phrase)."
                : "Off takes its models out of every model menu. Its key stays on \(HostWord.phrase).")
        } }
    }

    // MARK: Name

    private func nameSection(_ row: ManagedProvider) -> some View {
        Section {
            ValueRow(title: "Name", value: row.name(prefs), opensPrompt: true) { ProviderPages.rename(row, model: model, router: router, onPage: true) }
                .disabled(model.readOnly)
                .accessibilityIdentifier("provider-page.name")
        } footer: {
            if row.endpoint == nil, prefs.providerName(row.id) != nil {
                HQSectionFooter { Text("Hermes calls it \(row.originalName).") }
            }
        }
    }

    // MARK: Models

    private func modelsSection(_ row: ManagedProvider) -> some View {
        let all = ProviderList.allModels(row, catalog: model.catalog.raw, found: found, prefs: prefs)
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = words.isEmpty ? all : all.filter { id in
            id.lowercased().contains(words) || name(id, row).lowercased().contains(words)
        }
        let anyHidden = all.contains { prefs.isHidden(provider: row.id, model: $0) }
        let anyShown = all.contains { !prefs.isHidden(provider: row.id, model: $0) }
        let off = prefs.isOff(row.id)   // [provider-off] none shows while it is off: the switches wait, greyed
        return Section {
            if all.count > 12 {
                TextField("Search Models", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .hqRowPadding(4)
                    .accessibilityIdentifier("provider-models.search")
            }
            // [provider-models] Owner 2026-11-10 (design pick 20): on the iPhone and iPad, Show All and Hide All sit on
            // the Models heading's line (as the list's first row they read as a model); the Mac keeps the row.
            if all.count > 1, DeviceWord.isMac, !off {
                HStack(spacing: 20) {
                    Button("Show All") { setAll(all, hide: false, row) }
                        .disabled(!anyHidden || model.readOnly)
                        .accessibilityIdentifier("provider-models.show-all")
                    Button("Hide All") { setAll(all, hide: true, row) }
                        .disabled(!anyShown || model.readOnly)
                        .accessibilityIdentifier("provider-models.hide-all")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .hqRowPadding(4)
            }
            if all.isEmpty {
                Text(row.endpoint != nil ? "No models saved yet. Use Test Connection below, or Add Model…" : "Hermes lists no models for this provider yet.")
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .hqRowPadding(4)
            }
            ForEach(shown, id: \.self) { id in modelRow(id, row).disabled(off).opacity(off ? 0.5 : 1) }
            if !model.readOnly, !off {
                Button { addModel(row) } label: {
                    if DeviceWord.isMac { MacAddRowLabel(title: "Add Model…") } else { Label("Add Model…", systemImage: "plus") }
                }
                .disabled(locked)
                .hqRowPadding(4)
                .accessibilityIdentifier("provider-models.add")
            }
        } header: { HQSectionLabel {
            if all.count > 1, !DeviceWord.isMac, !off {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Models")
                    Spacer(minLength: 8)
                    Button("Show All") { setAll(all, hide: false, row) }
                        .disabled(!anyHidden || model.readOnly)
                        .accessibilityIdentifier("provider-models.show-all")
                    Button("Hide All") { setAll(all, hide: true, row) }
                        .disabled(!anyShown || model.readOnly)
                        .accessibilityIdentifier("provider-models.hide-all")
                }
                .buttonStyle(.borderless)
                .font(Font.hq(.subheadline))
                .textCase(nil)
            } else {
                Text("Models")
            }
        } } footer: { HQSectionFooter {
            if !words.isEmpty, shown.isEmpty {
                Text("No model matches “\(query)”.")
            } else if off {
                Text("None of these show while the provider is off. Switch it on above to choose which do.")
            } else {
                Text("A model a bot is using still shows in model menus.")
            }
        } }
    }

    private func name(_ id: String, _ row: ManagedProvider) -> String {
        prefs.modelName(provider: row.id, model: id) ?? ModelNames.builtInModelName(id)
    }

    private func modelRow(_ id: String, _ row: ManagedProvider) -> some View {
        let hidden = prefs.isHidden(provider: row.id, model: id)
        let added = prefs.extraModels(row.id).contains(id)
        return HStack(spacing: 12) {
            Button {
                ProviderPages.renameModel(id, provider: row, model: model, router: router)
            } label: {
                let note = [name(id, row) != id ? id : nil, added ? "Added by you" : nil].compactMap { $0 }.joined(separator: " · ")
                // [provider-models] One line a model: its own id beside its name, in small type, when both fit; else
                // the id under the name as before.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(name(id, row)).foregroundStyle(hidden ? Color.hqLabel2 : Color.hqLabel).lineLimit(1).fixedSize()
                        if !note.isEmpty {
                            Text(note).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).lineLimit(1).fixedSize()
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name(id, row)).foregroundStyle(hidden ? Color.hqLabel2 : Color.hqLabel)
                            .fixedSize(horizontal: false, vertical: true)
                        if !note.isEmpty {
                            Text(note).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.readOnly)
            .accessibilityLabel(name(id, row))
            .accessibilityHint("Renames it")
            .accessibilityIdentifier("provider-model.\(id)")
            Toggle("Show", isOn: Binding(get: { !hidden }, set: { on in
                Haptics.play(.selection)
                model.update { $0.setHidden(!on, provider: row.id, model: id) }
                AppLog.note("settings", "model \(on ? "shown" : "hidden") (\(row.id))")
            }))
            .labelsHidden()
            .disabled(model.readOnly)
            .accessibilityLabel("Show \(name(id, row))")
            .accessibilityIdentifier("provider-model.show.\(id)")
        }
        .hqRowPadding(4)
        .contextMenu {
            if !model.readOnly {
                Button("Rename…", systemImage: "pencil") { ProviderPages.renameModel(id, provider: row, model: model, router: router) }
                if added {
                    Button("Remove Model", systemImage: "trash", role: .destructive) {
                        model.update { $0.removeExtra(id, provider: row.id) }
                    }
                }
            }
        }
    }

    private func setAll(_ models: [String], hide: Bool, _ row: ManagedProvider) {
        Haptics.play(.selection)
        model.update { $0.setHidden(hide, provider: row.id, models: models) }
        AppLog.note("settings", "\(hide ? "hid" : "showed") all \(models.count) models (\(row.id))")
    }

    /// Add Model…: your own endpoint keeps it on the gateway; a built-in's is the app's, offered in the menus.
    private func addModel(_ row: ManagedProvider) {
        let message = row.endpoint != nil
            ? "Type the model’s ID as the service spells it. It’s saved with this provider on \(HostWord.phrase)."
            : "Type the model’s ID as \(row.name(prefs)) spells it. Hermes HQ offers it in the model menus."
        TextPrompt.present(title: "Add Model", message: message, placeholder: "Model ID", action: "Add", maxLength: 200,
                           identifier: "provider-models.add-field", autocapitalization: .none, autocorrection: .no,
                           from: router.presenter) { typed in
            let id = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }
            if let endpoint = row.endpoint {
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        try await model.custom.addModel(id, to: endpoint)
                        model.update { $0.setHidden(false, provider: row.id, model: id) }
                        await model.catalog.load()
                        Haptics.play(.success)
                        AppLog.note("settings", "model added to an endpoint")
                    } catch {
                        AppLog.note("settings", "endpoint add model failed: \(type(of: error))")
                        failure = (error as? CustomProviderFailure)?.text ?? SettingsErrorText.save(error)
                        Haptics.play(.error)
                    }
                }
            } else {
                model.update { $0.addExtra(id, provider: row.id) }
                AppLog.note("settings", "model added in the app (\(row.id))")
                Haptics.play(.success)
            }
        }
    }

    // MARK: Default Model

    @ViewBuilder private func defaultSection(_ row: ManagedProvider) -> some View {
        if let endpoint = row.endpoint {
            Section {
                ChooserRow(title: "Default Model", value: endpoint.model.isEmpty ? nil : name(endpoint.model, row), alone: true) {
                    let choices = ProviderList.allModels(row, catalog: model.catalog.raw, found: found, prefs: prefs)
                    router.push("Default Model", CustomProviderModelChooser(choices: choices, current: endpoint.model) { picked in
                        router.navigation?.popViewController(animated: true)
                        saveEndpointModel(endpoint, picked)
                    })
                }
                .disabled(locked)
                .accessibilityIdentifier("provider-page.default-model")
            } footer: { HQSectionFooter {
                Text("The model this provider starts with when a bot switches to it.")
            } }
        } else if let catalogRow = model.catalogRow(row.id), !catalogRow.models.isEmpty {
            let mine = ProviderPrefs.providerKey(model.catalog.mainProvider) == row.id
            Section {
                ChooserRow(title: "Default Model", value: mine ? name(model.catalog.mainModel, row) : "Another Provider", alone: true) {
                    let view = ModelChooserView(catalog: model.catalog, title: "Default Model", currentProvider: catalogRow.slug,
                                                currentModel: mine ? model.catalog.mainModel : "",
                                                note: SettingsWords.mainModelFooter(defaultBot: router.defaultBotName, otherBots: router.hasOtherBots)) { provider, picked in
                        router.closeChooser()
                        setMainModel(provider: provider, model: picked, confirm: false)
                    }
                    router.openChooser("Default Model", view)
                }
                .disabled(locked)
                .accessibilityIdentifier("provider-page.default-model")
            } footer: { HQSectionFooter {
                Text(SettingsWords.mainModelFooter(defaultBot: router.defaultBotName, otherBots: router.hasOtherBots))
            } }
        }
    }

    private func saveEndpointModel(_ endpoint: CustomProvider, _ picked: String) {
        var draft = CustomProviderDraft(endpoint)
        draft.choose(picked)
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.custom.save(draft)
                Haptics.play(.success)
            } catch {
                failure = (error as? CustomProviderFailure)?.text ?? SettingsErrorText.save(error)
                Haptics.play(.error)
            }
        }
    }

    private func setMainModel(provider: String, model picked: String, confirm: Bool) {
        guard !model.readOnly, let api = model.api else { failure = BotWriteError.readOnlyReason; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await api.setModel(scope: "main", provider: provider, model: picked,
                                           baseURL: model.catalog.provider(provider)?.apiURL, confirm: confirm)
                Haptics.play(.success)
                AppLog.note("settings", "main model changed (provider page)")
                router.services.refreshBots()
                await model.catalog.load()
            } catch ModelSetError.confirm(let message) {
                TextPrompt.confirmPlain(title: "Use \(ModelNames.displayModelName(picked, provider: provider))?", message: message,
                                        action: "Use It", from: router.presenter) {
                    setMainModel(provider: provider, model: picked, confirm: true)
                }
            } catch {
                AppLog.note("settings", "main model change failed: \(type(of: error))")
                failure = SettingsErrorText.save(error)
                Haptics.play(.error)
            }
        }
    }

    // MARK: Key, connection, account

    @ViewBuilder private func keySection(_ row: ManagedProvider) -> some View {
        if let endpoint = row.endpoint {
            Section {
                ValueRow(title: "Address, Key and Connection", value: endpoint.hasKey ? "Key saved" : "No key") {
                    CustomProviderPages.open(endpoint, model: model.custom, router: router)
                }
                .accessibilityIdentifier("provider-page.connection")
                Button(testing ? "Testing…" : "Test Connection") { runTest(endpoint, row) }
                    .disabled(testing)
                    .hqMacPushButton(leading: true)
                    .accessibilityIdentifier("provider-page.test")
                if let test {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: test.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(test.ok ? Color.green : Color.hqRed)
                        Text(test.summary).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                    }
                    .hqRowPadding(4)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("provider-page.test-result")
                }
            } header: { HQSectionLabel {
                Text("Connection")
            } }
        }
        if !row.keys.isEmpty {
            Section {
                ForEach(row.keys, id: \.key) { info in
                    EnvKeyRow(info: info, model: model.env, router: router)
                }
            } header: { HQSectionLabel {
                Text(row.keys.count == 1 ? "Key" : "Keys")
            } } footer: { HQSectionFooter {
                Text("Saved on \(HostWord.phrase), never in Hermes HQ.")
            } }
        }
        if let account = row.account {
            Section {
                LabeledContent("Account", value: account.connected ? (account.detail ?? "Signed In") : "Not Signed In")
                    .hqRowPadding(4)
                    .accessibilityIdentifier("provider-page.account")
            } footer: { HQSectionFooter {
                Text("You sign in to \(row.originalName) on \(HostWord.phrase).")
            } }
        }
    }

    private func runTest(_ endpoint: CustomProvider, _ row: ManagedProvider) {
        guard !testing else { return }
        testing = true
        test = nil
        Task {
            defer { testing = false }
            do {
                let answer = try await model.custom.test(CustomProviderDraft(endpoint))
                test = answer
                if answer.ok { found = answer.models }
                Haptics.play(answer.ok ? .success : .error)
            } catch {
                AppLog.note("settings", "provider page test failed: \(type(of: error))")
                test = CustomProviderTest(ok: false, reachable: false, message: SettingsErrorText.save(error))
                Haptics.play(.error)
            }
        }
    }

    // MARK: Remove

    @ViewBuilder private func removeSection(_ row: ManagedProvider) -> some View {
        if !model.readOnly {
            Section {
                if case .cannot = row.removal {
                    Button("Remove Provider", role: .destructive) {}
                        .disabled(true)
                        .hqMacFormButton(destructive: true)
                        .accessibilityIdentifier("provider-page.remove")
                } else {
                    Button(model.removing == row.id ? "Removing…" : row.removal == .signOut ? "Sign Out" : "Remove Provider", role: .destructive) {
                        model.askRemove(row, router: router) { router.navigation?.popViewController(animated: true) }
                    }
                    .disabled(model.removing != nil)
                    .hqMacFormButton(destructive: true)
                    .accessibilityIdentifier("provider-page.remove")
                }
            } footer: { HQSectionFooter {
                Text(removeFooter(row)).accessibilityIdentifier("provider-page.remove-footer")
            } }
        }
    }

    private func removeFooter(_ row: ManagedProvider) -> String {
        switch row.removal {
        case .cannot(let reason): return reason
        case .deleteEndpoint: return "Removes it and its saved key from \(HostWord.phrase)."
        case .removeKeys: return "Removes its key from \(HostWord.phrase). You can add it again under +."
        case .removeKeysAndSignOut: return "Removes its key and signs out of it on \(HostWord.phrase)."
        case .signOut: return "Signs out of it on \(HostWord.phrase)."
        }
    }
}
