// [custom-providers] Settings › Providers › Your Providers end to end against the settings fixture's
// `/api/providers/custom-endpoints` stand-in: rename one (its id kept, no key sent), add one after Test Connection
// (the address that answered and the first model found), and delete one. Run with
// HQN_E2E_ONLY="testCP1_YourProvidersRenameAddDelete" scripts/e2e-settings.sh.
// [provider-manager] Settings › Providers is one list of the providers you have (rows `provider.<catalog id>`); each
// opens a provider page. CP1 and CP2 now go through it; CP3 renames a built-in, renames and hides its models, adds one
// and checks the model chooser; CP4 renames one of your own on the gateway, adds a model to it, and removes from the
// row's menu.
// [provider-add] testCP2: the Providers page's + and its Add Provider chooser (a preset fills in a new entry; a service
// Hermes has built in opens its key), then removing from the list: swipe Delete on one of Your Providers, swipe Remove on
// an API key, and Sign Out of an account (only where Hermes can sign it out).
// [provider-off] testCP5: a row's switch takes the provider out of the model chooser; a provider Hermes sets up itself
// (the fixture's Mixture of Agents) is listed; Select turns several off, removes several after one confirm (the one that
// can't be removed is turned off), and turns them back on; the provider page's own switch.
// [moa-setup] testCP6: Mixture of Agents' row opens the Mixture of Agents page (its models, New Preset…, Make Default,
// Delete Preset, and the row's own switch), not the page every provider gets.

import XCTest

extension SettingsEndToEndTests {
    @MainActor private func openProviders(_ app: XCUIApplication) {
        openSettings(app)
        let providers = app.buttons["settings.providers"]
        scrollTo(providers, app)
        XCTAssertTrue(providers.waitForExistence(timeout: 5))
        providers.tap()
    }

    /// The launch for these tests: no provider or model renamed, hidden or added from an earlier run.
    @MainActor private func launchClean() -> XCUIApplication { launchSignedIn(["-HQDebugResetProviderPrefs", "YES"]) }

    /// Types into the open prompt's field and taps its action.
    @MainActor private func answerPrompt(_ app: XCUIApplication, _ field: String, _ text: String, _ action: String, _ shotName: String? = nil) {
        let input = app.textFields[field]
        XCTAssertTrue(appears(input, app, "prompt-\(field)"), "the prompt opens")
        input.clearAndType(text)
        if let shotName { shot(app, shotName) }
        // The prompt's button can come late while the keyboard settles (once in a Desktop Look run): wait, then tap.
        XCTAssertTrue(appears(app.alerts.buttons[action], app, "prompt-\(field)-\(action)", timeout: 8), "the prompt's \(action)")
        confirmAlert(app, action)
    }

    @MainActor func testCP1_YourProvidersRenameAddDelete() throws {
        let app = launchClean()
        openProviders(app)
        let together = app.buttons["provider.custom:together"]
        XCTAssertTrue(appears(together, app, "providers-list", timeout: 10), "the gateway's own providers are listed")
        XCTAssertTrue(together.label.contains("Together AI") && together.label.contains("api.together.ai"), together.label)
        XCTAssertTrue(together.label.contains("models shown"), together.label)
        XCTAssertTrue(app.buttons["provider.custom:home-server"].exists)
        // [provider-manager] Only what you have: keys saved (Anthropic, OpenRouter) and accounts signed in (Nous, Claude
        // Code); OpenAI has no key and Codex isn't signed in, so they're only under +.
        XCTAssertTrue(app.buttons["provider.anthropic"].exists && app.buttons["provider.openrouter"].exists)
        XCTAssertTrue(app.buttons["provider.anthropic"].label.contains("Built into Hermes"), app.buttons["provider.anthropic"].label)
        scrollTo(app.buttons["provider.nous"], app)
        XCTAssertTrue(app.buttons["provider.nous"].exists && app.buttons["provider.claude-code"].exists, "signed-in accounts")
        XCTAssertFalse(app.buttons["provider.openai"].exists, "no key: not listed")
        XCTAssertFalse(app.buttons["provider.openai-codex"].exists, "not signed in: not listed")
        XCTAssertFalse(app.descendants(matching: .any)["env-key.OPENAI_API_KEY"].exists, "no list of unset keys")
        app.swipeDown(velocity: .fast)
        shot(app, "providers-list")

        // Rename: on the gateway, the id goes with it (the entry and its chats stay), and no key is sent.
        together.tap()
        let name = app.buttons["provider-page.name"]
        XCTAssertTrue(appears(name, app, "provider-page"))
        XCTAssertTrue(name.label.contains("Together AI"), name.label)
        shot(app, "provider-page-endpoint")
        name.tap()
        answerPrompt(app, "provider.rename-field", "Together Work", "Rename")
        XCTAssertTrue(waitUntil(timeout: 8) { !self.a.writes("POST /api/providers/custom-endpoints").isEmpty }, "saved")
        let rename = try XCTUnwrap(a.writes("POST /api/providers/custom-endpoints").last)
        XCTAssertTrue(same(rename["id"], "together"), "\(rename)")
        XCTAssertTrue(same(rename["name"], "Together Work"))
        XCTAssertTrue(rename["api_key"] is NSNull || rename["api_key"] == nil, "no key typed, none sent: \(rename)")
        XCTAssertTrue(waitUntil(timeout: 8) { name.label.contains("Together Work") }, name.label)
        back(app)
        XCTAssertTrue(appears(together, app, "providers-renamed", timeout: 8), "back on the list")
        XCTAssertTrue(waitUntil(timeout: 5) { together.label.contains("Together Work") }, together.label)

        // Add one: Test Connection fills in the address that answered and the first model.
        let add = app.buttons["custom-providers.add"]
        scrollTo(add, app)
        add.tap()
        let other = app.buttons["add-provider.other"]
        XCTAssertTrue(appears(app.buttons["add-provider.preset.groq"], app, "custom-provider-chooser"))
        scrollTo(other, app)   // below the presets: a list makes its rows as they scroll in
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        let newName = app.textFields["custom-provider.name"]
        XCTAssertTrue(appears(newName, app, "custom-provider-new"))
        newName.tap(); newName.typeText("Lab")
        let address = app.textFields["custom-provider.address"]
        address.tap(); address.typeText("http://10.0.0.5:8000")
        XCTAssertFalse(app.buttons["custom-provider.save"].isEnabled, "no model yet")
        app.buttons["custom-provider.test"].tap()
        let result = app.descendants(matching: .any)["custom-provider.test-result"]
        XCTAssertTrue(appears(result, app, "custom-provider-tested", timeout: 8))
        XCTAssertTrue(result.label.contains("Found 10 models"), result.label)
        XCTAssertEqual(address.value as? String, "http://10.0.0.5:8000/v1", "the address that answered")
        XCTAssertTrue(app.buttons["custom-provider.model"].label.contains("Llama"), app.buttons["custom-provider.model"].label)
        shot(app, "custom-provider-new-tested")
        app.buttons["custom-provider.save"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.a.writes("POST /api/providers/custom-endpoints").count == 2 }, "added")
        let added = try XCTUnwrap(a.writes("POST /api/providers/custom-endpoints").last)
        XCTAssertNil(added["id"], "a new one has no id: \(added)")
        XCTAssertTrue(same(added["base_url"], "http://10.0.0.5:8000/v1"))
        XCTAssertTrue(same(added["model"], "llama-3.3-70b"))
        XCTAssertNil(added["models"], "the found list isn't written into config.yaml")
        XCTAssertTrue(app.buttons["provider.custom:lab"].waitForExistence(timeout: 8), "listed")

        // Delete one from its page, after asking.
        let home = app.buttons["provider.custom:home-server"]
        scrollTo(home, app)
        home.tap()
        let remove = app.buttons["provider-page.remove"]
        scrollTo(remove, app)
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        let footer = app.descendants(matching: .any)["provider-page.remove-footer"]
        XCTAssertTrue(footer.label.hasPrefix("Removes it"), footer.label)
        shot(app, "provider-page-bottom")
        remove.tap()
        let confirm = app.alerts.buttons["Remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "asks first")
        confirm.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.a.writes("DELETE /api/providers/custom-endpoints/home-server").isEmpty }, "deleted")
        XCTAssertTrue(waitUntil(timeout: 8) { !home.exists }, "gone from the list")
    }

    @MainActor func testCP2_AddFromThePlusAndRemoveFromTheList() throws {
        let app = launchClean()
        openProviders(app)
        XCTAssertTrue(appears(app.buttons["provider.custom:together"], app, "cp2-list", timeout: 10))

        // + at the top of the page opens Add Provider.
        let plus = app.buttons["providers.add"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "+ in the bar")
        plus.tap()
        let groq = app.buttons["add-provider.preset.groq"]
        XCTAssertTrue(appears(groq, app, "cp2-chooser"))
        XCTAssertTrue(app.buttons["add-provider.preset.openrouter"].label.contains("Added"), "OpenRouter's key is set")
        XCTAssertFalse(groq.label.contains("Added"))
        shot(app, "provider-add-2-chooser")

        // A built-in service opens Hermes' own key, in the chooser's place.
        app.buttons["add-provider.preset.openrouter"].tap()
        XCTAssertTrue(appears(app.descendants(matching: .any)["env-editor.field"], app, "cp2-openrouter-key"), "OpenRouter's own key page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(appears(plus, app, "cp2-back-on-providers"), "Back goes to Providers, not the chooser")

        // A preset fills in the name and address; Test finds the models; Add saves it.
        plus.tap()
        XCTAssertTrue(appears(groq, app, "cp2-chooser-again"))
        groq.tap()
        let name = app.textFields["custom-provider.name"]
        XCTAssertTrue(appears(name, app, "cp2-groq-page"))
        XCTAssertEqual(name.value as? String, "Groq")
        XCTAssertEqual(app.textFields["custom-provider.address"].value as? String, "https://api.groq.com/openai/v1")
        app.buttons["custom-provider.test"].tap()
        XCTAssertTrue(appears(app.descendants(matching: .any)["custom-provider.test-result"], app, "cp2-groq-tested", timeout: 8))
        app.buttons["custom-provider.save"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.a.writes("POST /api/providers/custom-endpoints").isEmpty }, "added")
        let added = try XCTUnwrap(a.writes("POST /api/providers/custom-endpoints").last)
        XCTAssertTrue(same(added["name"], "Groq") && same(added["base_url"], "https://api.groq.com/openai/v1"), "\(added)")
        let groqRow = app.buttons["provider.custom:groq"]
        XCTAssertTrue(appears(groqRow, app, "cp2-groq-listed", timeout: 8), "listed")
        XCTAssertTrue(plus.exists, "back on Providers")

        // [provider-manager] Swipe Remove on one of your own: it is deleted, after asking.
        groqRow.swipeLeft()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "swipe shows Remove")
        shot(app, "provider-remove-1-swipe-endpoint")
        remove.tap()
        let confirm = app.alerts.buttons["Remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "asks first")
        confirm.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.a.writes("DELETE /api/providers/custom-endpoints/groq").isEmpty }, "deleted")
        XCTAssertTrue(waitUntil(timeout: 8) { !groqRow.exists }, "gone from the list")

        // A built-in with a key: Remove takes its key away, and the row goes (it is back under + as not added).
        let anthropic = app.buttons["provider.anthropic"]
        scrollTo(anthropic, app)
        anthropic.swipeLeft()
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "swipe shows Remove")
        shot(app, "provider-remove-2-swipe-key")
        remove.tap()
        let confirmRemove = app.alerts.buttons["Remove"]
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 5), "asks first")
        XCTAssertTrue(app.alerts.firstMatch.label.contains("Remove Anthropic?"), app.alerts.firstMatch.label)
        confirmRemove.tap()
        XCTAssertTrue(waitUntil(timeout: 8) {
            self.a.writes("DELETE /api/env").contains { same($0["key"], "ANTHROPIC_API_KEY") }
        }, "removed")
        XCTAssertTrue(waitUntil(timeout: 8) { !anthropic.exists }, "no key left: off the list")

        // An account Hermes can't sign out of says why; one it can is signed out.
        let claude = app.buttons["provider.claude-code"]
        scrollTo(claude, app)
        claude.swipeLeft()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        let cannot = app.alerts["Can’t Remove Claude Code"]
        XCTAssertTrue(cannot.waitForExistence(timeout: 5), "says why it can't")
        XCTAssertTrue(cannot.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("Sign out of it there") })
        shot(app, "provider-remove-3-cant")
        cannot.buttons["OK"].tap()
        XCTAssertTrue(claude.exists, "still listed")
        XCTAssertTrue(a.writes("DELETE /api/providers/oauth/claude-code").isEmpty)

        let nous = app.buttons["provider.nous"]
        scrollTo(nous, app)
        nous.swipeLeft()
        let signOut = app.buttons["Sign Out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5), "swipe shows Sign Out")
        shot(app, "provider-remove-4-swipe-sign-out")
        signOut.tap()
        let confirmSignOut = app.alerts.buttons["Sign Out"]
        XCTAssertTrue(confirmSignOut.waitForExistence(timeout: 5), "asks first")
        confirmSignOut.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.a.writes("DELETE /api/providers/oauth/nous").isEmpty }, "signed out")
        XCTAssertTrue(waitUntil(timeout: 8) { !nous.exists }, "signed out: off the list")
    }

    /// [provider-manager] A built-in: its name and its models' names are the app's own, a hidden model leaves the model
    /// chooser, and an added one joins it. Hermes is sent nothing but the real ids.
    @MainActor func testCP3_RenameHideAndAddModelsOnABuiltIn() throws {
        let app = launchClean()
        openProviders(app)
        let anthropic = app.buttons["provider.anthropic"]
        XCTAssertTrue(appears(anthropic, app, "cp3-list", timeout: 10))
        XCTAssertTrue(anthropic.label.contains("4 models shown"), anthropic.label)
        anthropic.tap()

        // Rename the provider (the app's name; Hermes keeps "Anthropic").
        let name = app.buttons["provider-page.name"]
        XCTAssertTrue(appears(name, app, "cp3-page"))
        name.tap()
        answerPrompt(app, "provider.rename-field", "Work Claude", "Rename", "provider-rename-prompt")
        XCTAssertTrue(waitUntil(timeout: 5) { name.label.contains("Work Claude") }, name.label)
        XCTAssertTrue(app.navigationBars["Work Claude"].waitForExistence(timeout: 5), "the page's title follows its name")

        // Rename a model, hide another, add one.
        let sonnet = app.buttons["provider-model.claude-sonnet-5"]
        XCTAssertTrue(appears(sonnet, app, "cp3-models"))
        sonnet.tap()
        answerPrompt(app, "provider-model.rename-field", "Sonnet Daily", "Rename", "provider-model-rename-prompt")
        XCTAssertTrue(waitUntil(timeout: 5) { sonnet.label.contains("Sonnet Daily") }, sonnet.label)
        let haiku = app.switches["provider-model.show.claude-haiku-5"]
        XCTAssertTrue(haiku.waitForExistence(timeout: 5))
        XCTAssertEqual(haiku.value as? String, "1")
        flip(haiku)
        XCTAssertTrue(waitUntil(timeout: 5) { haiku.value as? String == "0" }, "switched off")
        let addModel = app.buttons["provider-models.add"]
        scrollTo(addModel, app)
        addModel.tap()
        answerPrompt(app, "provider-models.add-field", "claude-opus-6-preview", "Add")
        XCTAssertTrue(app.buttons["provider-model.claude-opus-6-preview"].waitForExistence(timeout: 5), "added to the list")
        app.swipeDown(velocity: .fast)
        shot(app, "provider-page-show-switches")
        XCTAssertTrue(a.writes("POST /api/providers/custom-endpoints").isEmpty, "a built-in's names stay in the app")
        back(app)
        XCTAssertTrue(appears(anthropic, app, "cp3-list-after"))
        XCTAssertTrue(waitUntil(timeout: 5) { anthropic.label.contains("Work Claude") && anthropic.label.contains("4 of 5 models shown") },
                      anthropic.label)
        shot(app, "providers-list-renamed")

        // The model chooser: Work Claude's models, Sonnet renamed, Haiku gone, the added one there.
        openSection(app, "model")
        let main = app.buttons["config-page.model.main"]
        XCTAssertTrue(appears(main, app, "cp3-model-page"))
        main.tap()
        let row = app.buttons["main-model.model"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 8) { row.label.contains("Work Claude") }, "the provider's own name: \(row.label)")
        row.tap()
        let opus = app.buttons["model-option.claude-opus-5.5"]
        XCTAssertTrue(opus.waitForExistence(timeout: 8), "Work Claude's models")
        XCTAssertTrue(app.buttons["model-option.claude-sonnet-5"].label.contains("Sonnet Daily"), app.buttons["model-option.claude-sonnet-5"].label)
        XCTAssertFalse(app.buttons["model-option.claude-haiku-5"].exists, "hidden: not offered")
        XCTAssertTrue(app.buttons["model-option.claude-opus-6-preview"].exists, "the added model is offered")
        shot(app, "model-chooser-renamed-hidden")
        app.buttons["model-option.claude-sonnet-5"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { (self.a.state()["model"] as? [String: Any])?["model"] as? String == "claude-sonnet-5" },
                      "the real id is what Hermes gets")
    }

    /// [provider-manager] One of your own: Add Model… saves it on the gateway; Rename… and Remove… from the row's menu
    /// (the Mac's right-click).
    @MainActor func testCP4_EndpointAddModelAndRowMenu() throws {
        let app = launchClean()
        openProviders(app)
        let home = app.buttons["provider.custom:home-server"]
        XCTAssertTrue(appears(home, app, "cp4-list", timeout: 10))
        home.tap()
        let addModel = app.buttons["provider-models.add"]
        XCTAssertTrue(appears(addModel, app, "cp4-page"))
        addModel.tap()
        answerPrompt(app, "provider-models.add-field", "mistral-small-4", "Add")
        XCTAssertTrue(waitUntil(timeout: 8) { !self.a.writes("POST /api/providers/custom-endpoints").isEmpty }, "saved on the gateway")
        let saved = try XCTUnwrap(a.writes("POST /api/providers/custom-endpoints").last)
        XCTAssertTrue(same(saved["id"], "home-server"), "\(saved)")
        XCTAssertEqual(saved["models"] as? [String], ["mistral-small-4"], "\(saved)")
        XCTAssertTrue(saved["api_key"] is NSNull || saved["api_key"] == nil, "no key sent")
        XCTAssertTrue(app.buttons["provider-model.mistral-small-4"].waitForExistence(timeout: 8), "listed with the endpoint's models")
        back(app)

        // Touch and hold: Rename… and Remove….
        XCTAssertTrue(appears(home, app, "cp4-list-again"))
        home.press(forDuration: 1.2)
        let menuRename = app.buttons["provider.menu-rename"].exists ? app.buttons["provider.menu-rename"] : app.buttons["Rename…"]
        XCTAssertTrue(menuRename.waitForExistence(timeout: 5), "the row's menu has Rename…")
        shot(app, "provider-row-menu")
        menuRename.tap()
        answerPrompt(app, "provider.rename-field", "Basement GPU", "Rename")
        XCTAssertTrue(waitUntil(timeout: 8) { self.a.writes("POST /api/providers/custom-endpoints").count == 2 }, "renamed on the gateway")
        let renamed = try XCTUnwrap(a.writes("POST /api/providers/custom-endpoints").last)
        XCTAssertTrue(same(renamed["id"], "home-server") && same(renamed["name"], "Basement GPU"), "\(renamed)")
        XCTAssertTrue(waitUntil(timeout: 8) { home.label.contains("Basement GPU") }, home.label)
        XCTAssertTrue(app.navigationBars["Providers"].exists, "renamed from the list: the list keeps its title")

        home.press(forDuration: 1.2)
        let menuRemove = app.buttons["provider.menu-remove"].exists ? app.buttons["provider.menu-remove"] : app.buttons["Remove…"]
        XCTAssertTrue(menuRemove.waitForExistence(timeout: 5), "the row's menu has Remove…")
        menuRemove.tap()
        XCTAssertTrue(app.alerts.buttons["Remove"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(home.waitForExistence(timeout: 3), "Cancel keeps it")
        XCTAssertTrue(a.writes("DELETE /api/providers/custom-endpoints/home-server").isEmpty)
    }

    /// [provider-off] Owner 2026-11-15: "i want to clean out a bunch of providers and there isn't an easy way to do it".
    @MainActor func testCP5_TurnOffSelectSeveralAndRemove() throws {
        let app = launchClean()
        openProviders(app)
        let anthropic = app.buttons["provider.anthropic"], router = app.buttons["provider.openrouter"]
        let moa = app.buttons["provider.moa"], together = app.buttons["provider.custom:together"]
        XCTAssertTrue(appears(anthropic, app, "cp5-list", timeout: 10))
        // Every provider the model menus show has a row: Mixture of Agents has no key, account or address of its own.
        scrollTo(moa, app)
        XCTAssertTrue(moa.exists && moa.label.contains("Set up in Hermes"), moa.exists ? moa.label : "Mixture of Agents isn't listed")
        app.swipeDown(velocity: .fast)
        shot(app, "provider-off-1-list")

        // One switch: OpenRouter off. Its row says so, the list counts it, and the model chooser no longer offers it.
        let routerSwitch = app.switches["provider.on.openrouter"]
        scrollTo(routerSwitch, app)
        XCTAssertEqual(routerSwitch.value as? String, "1")
        flip(routerSwitch)
        XCTAssertTrue(waitUntil(timeout: 5) { routerSwitch.value as? String == "0" && router.label.hasSuffix("Off") }, router.label)
        XCTAssertTrue(a.writes("PUT /api/env").isEmpty && a.writes("DELETE /api/env").isEmpty, "its key is untouched")
        app.swipeDown(velocity: .fast)
        shot(app, "provider-off-2-one-off")
        openSection(app, "model")
        let main = app.buttons["config-page.model.main"]
        XCTAssertTrue(appears(main, app, "cp5-model-page"))
        main.tap()
        let row = app.buttons["main-model.model"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["model-option.claude-opus-5.5"].waitForExistence(timeout: 8), "Anthropic's models")
        XCTAssertFalse(app.buttons["model-option.x-ai/grok-5"].exists || app.buttons["model-option.qwen/qwen3-coder"].exists,
                       "OpenRouter is off: none of its models are offered")
        shot(app, "provider-off-3-chooser")

        // Select: three at once, off.
        openProviders(app)
        XCTAssertTrue(appears(anthropic, app, "cp5-list-again", timeout: 10))
        app.buttons["providers.select"].tap()
        XCTAssertTrue(appears(app.buttons["providers.select-off"], app, "cp5-select"))
        XCTAssertFalse(app.buttons["providers.select-off"].isEnabled, "nothing picked yet")
        XCTAssertFalse(app.switches["provider.on.anthropic"].exists, "ticks, not switches, while selecting")
        anthropic.tap()
        scrollTo(together, app); together.tap()
        scrollTo(moa, app); moa.tap()
        let count = app.staticTexts["providers.select-count"]
        XCTAssertTrue(waitUntil(timeout: 5) { count.label == "3 Selected" }, count.label)
        shot(app, "provider-off-4-select")
        app.buttons["providers.select-off"].tap()
        XCTAssertTrue(app.buttons["providers.select"].waitForExistence(timeout: 5), "Select ends once it has acted")
        XCTAssertTrue(waitUntil(timeout: 5) { anthropic.label.hasSuffix("Off") }, anthropic.label)
        scrollTo(moa, app)
        XCTAssertTrue(moa.label.hasSuffix("Off") && together.label.hasSuffix("Off"), "\(moa.label) / \(together.label)")
        let footer = app.staticTexts["providers.footer"]
        scrollTo(footer, app)
        XCTAssertTrue(footer.label.contains("4 off"), footer.label)
        app.swipeDown(velocity: .fast)
        shot(app, "provider-off-5-several-off")

        // Remove several, one confirm: Together goes; Mixture of Agents can't be removed here and stays off.
        app.buttons["providers.select"].tap()
        scrollTo(together, app); together.tap()
        scrollTo(moa, app); moa.tap()
        app.buttons["providers.select-remove"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(appears(alert, app, "cp5-remove-confirm"))
        XCTAssertTrue(alert.label.contains("Remove 1 Provider?") || alert.staticTexts["Remove 1 Provider?"].exists, alert.label)
        XCTAssertTrue(alert.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("turned off instead") }, "it says what can't be removed")
        shot(app, "provider-off-6-remove-confirm")
        confirmAlert(app, "Remove")
        XCTAssertTrue(waitUntil(timeout: 10) { !together.exists }, "Together AI is removed")
        XCTAssertTrue(waitUntil(timeout: 5) { self.a.writes("DELETE /api/providers/custom-endpoints/together").count == 1 }, "one delete on the gateway")
        scrollTo(moa, app)
        XCTAssertTrue(moa.exists && moa.label.hasSuffix("Off"), "still listed, off")
        XCTAssertTrue(app.buttons["providers.select"].waitForExistence(timeout: 5))

        // Everything back on at once.
        app.buttons["providers.select"].tap()
        app.buttons["providers.select-all"].tap()
        app.buttons["providers.select-on"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !anthropic.label.hasSuffix("Off") && !moa.label.hasSuffix("Off") }, anthropic.label)

        // The provider's page has the same switch; off, its models wait greyed.
        scrollTo(anthropic, app)
        anthropic.tap()
        let on = app.switches["provider-page.on"]
        XCTAssertTrue(appears(on, app, "cp5-page"))
        XCTAssertEqual(on.value as? String, "1")
        flip(on)
        XCTAssertTrue(waitUntil(timeout: 5) { on.value as? String == "0" })
        XCTAssertFalse(app.switches["provider-model.show.claude-haiku-5"].isEnabled, "its models wait while it is off")
        shot(app, "provider-off-7-page-off")
        back(app)
        XCTAssertTrue(waitUntil(timeout: 5) { anthropic.label.hasSuffix("Off") }, anthropic.label)
    }

    /// [moa-setup] Owner 2026-11-21: "The mixture of agents setup page needs all kinds of work. It's basically not
    /// usable." Providers › Mixture of Agents was the page every provider gets (a typed model ID, a Default Model). It
    /// is the Mixture of Agents page: its models, a new preset, the one /moa uses, delete, and the row's own switch.
    /// Seeded as his Hermes has it: one preset named `default`.
    @MainActor func testCP6_MixtureOfAgentsRowOpensItsSetup() throws {
        try a.control("/__settings/moa", ["default_preset": "default", "presets": [
            "default": moaPreset(references: [("openrouter", "deepseek/deepseek-v3.2"), ("anthropic", "claude-sonnet-5")]),
        ]])
        func moaState() -> [String: Any] { (a.state()["moa"] as? [String: Any]) ?? [:] }
        func presets() -> [String: Any] { (moaState()["presets"] as? [String: Any]) ?? [:] }
        func references(_ name: String) -> [[String: Any]] { ((presets()[name] as? [String: Any])?["reference_models"] as? [[String: Any]]) ?? [] }

        let app = launchClean()
        openProviders(app)
        let moa = app.buttons["provider.moa"]
        XCTAssertTrue(appears(moa, app, "cp6-list", timeout: 10))
        scrollTo(moa, app)
        XCTAssertTrue(moa.label.contains("1 preset"), "its row counts presets: \(moa.label)")
        moa.tap()

        // Its setup, not a provider's page.
        let on = app.switches["moa.enabled"]
        XCTAssertTrue(appears(on, app, "cp6-page", timeout: 10), "the Mixture of Agents page")
        XCTAssertEqual(on.value as? String, "1")
        XCTAssertFalse(app.buttons["provider-models.add"].exists || app.buttons["provider-page.default-model"].exists
                       || app.buttons["provider-page.name"].exists, "none of the provider page's rows")
        let first = app.buttons["moa.ref-0"], second = app.buttons["moa.ref-1"], aggregator = app.buttons["moa.aggregator"]
        XCTAssertTrue(first.exists && second.exists && aggregator.exists, "its reference models and its aggregator")
        XCTAssertTrue(first.label.contains("DeepSeek") && aggregator.label.contains("Opus"), "\(first.label) / \(aggregator.label)")
        let picker = app.descendants(matching: .any)["moa.preset"]
        XCTAssertTrue(picker.exists, "one preset still shows which")
        XCTAssertFalse(app.buttons["moa.preset-delete"].exists || app.buttons["moa.preset-default"].exists, "the only preset: nothing to delete or switch to")
        shot(app, "moa-setup-1-from-providers")

        // New Preset…: a copy of the one shown, saved on Hermes under a name with no spaces, and the one now shown.
        app.buttons["moa.preset-new"].tap()
        answerPrompt(app, "moa.preset-name", "Deep Research", "Add", "moa-setup-2-new-preset")
        XCTAssertTrue(waitUntil(timeout: 8) { references("deep_research").count == 2 }, "saved with the shown preset's models: \(presets().keys)")
        XCTAssertTrue(same(moaState()["default_preset"], "default"), "the default stays")
        let makeDefault = app.buttons["moa.preset-default"], delete = app.buttons["moa.preset-delete"]
        XCTAssertTrue(makeDefault.waitForExistence(timeout: 5) && delete.exists, "a second preset: Make Default and Delete Preset")
        XCTAssertTrue(app.staticTexts["moa.preset-footer"].label == "/moa uses Default.", app.staticTexts["moa.preset-footer"].label)
        shot(app, "moa-setup-3-second-preset")

        // Its second reference model goes; the last one stays (Hermes refuses a preset with none).
        second.swipeLeft()
        let swipeDelete = app.buttons["Delete"]
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 5), "swipe to remove a reference model")
        swipeDelete.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { references("deep_research").count == 1 }, "one reference model left on the new preset")
        XCTAssertEqual(references("default").count, 2, "the other preset is untouched")
        XCTAssertTrue(waitUntil(timeout: 5) { !second.exists })
        first.swipeLeft()
        XCTAssertFalse(app.buttons["Delete"].waitForExistence(timeout: 2), "the last reference model can't be removed")
        // With nothing to swipe to, the runner's swipe can land as a tap and open the row's chooser: back out of it.
        if app.buttons["model-chooser.provider"].waitForExistence(timeout: 1.5) { back(app) }
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(references("deep_research").count, 1, "still its one reference model")
        let writes = a.writes("PUT /api/model/moa").count

        // Make Default: the preset /moa uses, with the top level following it.
        makeDefault.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.same(moaState()["default_preset"], "deep_research") }, "\(String(describing: moaState()["default_preset"]))")
        XCTAssertEqual((moaState()["reference_models"] as? [Any])?.count, 1, "the top level is the default preset's")
        XCTAssertTrue(waitUntil(timeout: 5) { !makeDefault.exists }, "it is the default now")
        XCTAssertEqual(a.writes("PUT /api/model/moa").count, writes + 1, "one save")

        // Delete Preset, after one confirm: left out of what is saved, and the default moves back.
        delete.tap()
        XCTAssertTrue(appears(app.alerts.buttons["Delete"], app, "cp6-delete-confirm"))
        shot(app, "moa-setup-4-delete-confirm")
        confirmAlert(app, "Delete")
        XCTAssertTrue(waitUntil(timeout: 8) { Array(presets().keys) == ["default"] }, "\(presets().keys)")
        XCTAssertTrue(same(moaState()["default_preset"], "default"))
        XCTAssertTrue(waitUntil(timeout: 5) { second.exists && !delete.exists }, "back on the one preset, with its two models")

        // The switch is the row's own: off changes nothing on Hermes, and the list says Off.
        let saved = a.writes("PUT /api/model/moa").count
        flip(on)
        XCTAssertTrue(waitUntil(timeout: 5) { on.value as? String == "0" && !aggregator.isEnabled }, "off, and its rows wait")
        XCTAssertTrue(app.staticTexts["moa.footer"].label.hasPrefix("Off, it is in no model menu."), app.staticTexts["moa.footer"].label)
        shot(app, "moa-setup-5-off")
        back(app)
        XCTAssertTrue(waitUntil(timeout: 8) { moa.exists && moa.label.hasSuffix("Off") }, moa.label)
        XCTAssertEqual(a.writes("PUT /api/model/moa").count, saved, "nothing saved on Hermes")
        moa.tap()
        XCTAssertTrue(on.waitForExistence(timeout: 8))
        XCTAssertEqual(on.value as? String, "0", "off here as in the list")
        flip(on)
        XCTAssertTrue(waitUntil(timeout: 5) { on.value as? String == "1" && aggregator.isEnabled })
        back(app)
        XCTAssertTrue(waitUntil(timeout: 8) { moa.exists && !moa.label.hasSuffix("Off") && moa.label.contains("1 preset") }, moa.label)
        XCTAssertEqual(a.writes("PUT /api/model/moa").count, saved, "Hermes was already listing it: still nothing saved")
    }
}
