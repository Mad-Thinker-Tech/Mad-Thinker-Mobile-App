import XCTest

/// Shared infrastructure for the Researcher catch-flow regression suites.
///
/// Hosts the page objects, sign-in helpers, fixture mapping, chat-flow
/// drivers, and the four "reusable scenarios" that the Phase 1 path-coverage
/// suite (`ResearcherUserFlowTests`) and the Phase 2 upload integration
/// suite (`ResearcherUploadIntegrationTests`) both run. Each subclass picks
/// its own setUp/tearDown policy:
///
/// - **Phase 1** (`ResearcherUserFlowTests`) launches every test with
///   `-resetSavedLocallyReportsForUITests` so each test sees an empty
///   Activities list. Verifies one isolated path per test.
/// - **Phase 2** (`ResearcherUploadIntegrationTests`) does NOT pass that
///   flag — reports accumulate across the 5 record tests so the 6th test
///   can drive the upload + assert against the backend. The class-level
///   `tearDown` still wipes everything once the suite finishes.
///
/// To add another reusable scenario: add a `runScenario_*` method here,
/// and call it from a `func test*()` method in either subclass.
class ResearcherCatchFlowTestBase: XCTestCase {

    var app: XCUIApplication!
    var loginPage: LoginPage!
    var picker: CommunityPickerPage!
    var switcher: CommunitySwitcherPage!
    var chat: CatchChatPage!

    let epicWatersName = "Epic Waters"

    // MARK: - Per-suite policy (overridable)

    /// When `true` (default), every test launches with
    /// `-resetSavedLocallyReportsForUITests` so its on-disk records are
    /// wiped before init. Phase 2 overrides this to `false` so the records
    /// from earlier tests stay around for the upload step.
    var perTestCleanupEnabled: Bool { true }

    // MARK: - Fixtures

    struct CatchFixture {
        let head: String
        let body: String
    }

    /// Resolve a fixture pair from a folder name under
    /// `SkeenaSystemUITests/Fixtures/`. Files are expected as
    /// `<basename> - 1.jpeg` (head) and `<basename> - 2.jpeg` (body).
    static func fixture(folder: String, basename: String) -> CatchFixture {
        // `#file` here resolves to this base file, so the path-suffix swap
        // walks up two segments (RegressionTests/<this-file>) before
        // diving into `Fixtures/...`.
        let prefix = #file
            .replacingOccurrences(of: "RegressionTests/ResearcherCatchFlowTestBase.swift",
                                  with: "Fixtures/\(folder)/\(basename)")
        return CatchFixture(head: "\(prefix) - 1.jpeg", body: "\(prefix) - 2.jpeg")
    }

    /// Per-test-method fixture mapping. Subclasses can extend it through
    /// their own `additionalFixtures` map (merged in `currentFixture`).
    /// Tests that don't drive the catch flow (switcher, manage profile)
    /// fall through to the Steelhead default — the env vars are unused.
    static let fixtureByTestName: [String: CatchFixture] = [
        // Phase 1: end-to-end record tests
        "testRecordCatchAppearsInActivities":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "testRecordSteelheadCatchWithOverridesAppearsInActivities":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "testRecordAtlanticSalmonCatchAppearsInActivities":
            fixture(folder: "AtlanticSalmon",  basename: "Atlantic Salmon"),
        "testRecordAtlanticSalmonCatchWithSamplingAppearsInActivities":
            fixture(folder: "AtlanticSalmon",  basename: "Atlantic Salmon"),
        "testRecordBrookTroutCatchAppearsInActivities":
            fixture(folder: "BrookTrout",      basename: "Brook"),
        // Phase 1: path-coverage tests
        "testTypeLocationWhenGPSCantMatch":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "testModifyLengthAcceptGirth":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "testResetButtonClearsChatMidFlow":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "testEditOnFinalSummaryUpdatesLocation":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "testDeleteUnuploadedCatchFromActivities":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "testEditCatchFromActivitiesUpdatesSpecies":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "testProfanityResponseAtFinalSummary":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "testRetakeHeadPhotoReturnsToHeadStep":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "testRecordObservationOpensSheet":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "testManageProfileButtonOpensManageProfile":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        // Phase 2: integration / upload tests
        "test01_recordCatchWithTypedLocation":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "test02_recordCatchWithLengthOverride":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "test03_recordCatchWithFinalSummaryEdit":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "test04_recordCatchWithSpeciesEditFromActivities":
            fixture(folder: "AtlanticSalmon",  basename: "Atlantic Salmon"),
        "test05_recordVanillaCatch":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
        "test06_uploadAllAccumulatedReports":
            fixture(folder: "Steelhead",       basename: "Steelhead"),
    ]

    var currentFixture: CatchFixture {
        // `XCTestCase.name` is "-[ClassName methodName]". Strip the wrapper.
        let methodName = name
            .components(separatedBy: " ").last?
            .replacingOccurrences(of: "]", with: "") ?? name
        return Self.fixtureByTestName[methodName]
            ?? Self.fixture(folder: "Steelhead", basename: "Steelhead")
    }

    var testEmail: String {
        ProcessInfo.processInfo.environment["RESEARCHER_FLOW_EMAIL"] ?? "geoff@madthinkerfishtech.com"
    }

    var testPassword: String {
        ProcessInfo.processInfo.environment["RESEARCHER_FLOW_PASSWORD"] ?? "Fatbikesk123"
    }

    // MARK: - Setup / teardown

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        addUIInterruptionMonitor(withDescription: "System Dialogs") { alert in
            for label in ["Not Now", "Don't Save", "Cancel", "OK"] {
                if alert.buttons[label].exists {
                    alert.buttons[label].tap()
                    return true
                }
            }
            return false
        }

        app = XCUIApplication()
        var args = [
            "-uiTesting",
            "-resetAuthForUITests",
            "-suppressWelcomeForUITests",
        ]
        if perTestCleanupEnabled {
            args.append("-resetSavedLocallyReportsForUITests")
        }
        app.launchArguments += args
        app.launchEnvironment["UITestingDisableAnimations"] = "1"
        let fixture = currentFixture
        app.launchEnvironment["UI_TEST_HEAD_IMAGE_PATH"] = fixture.head
        app.launchEnvironment["UI_TEST_BODY_IMAGE_PATH"] = fixture.body
        app.launch()

        loginPage = LoginPage(app: app)
        picker = CommunityPickerPage(app: app)
        switcher = CommunitySwitcherPage(app: app)
        chat = CatchChatPage(app: app)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        loginPage = nil
        picker = nil
        switcher = nil
        chat = nil
        try super.tearDownWithError()
    }

    /// Final cleanup launch — wipes the on-disk records the last test
    /// saved so the simulator's Activities list comes up empty for the
    /// next human or CI run. Inherited by both Phase 1 and Phase 2 — each
    /// subclass gets its own invocation since `class func tearDown()` is
    /// scoped per-class.
    override class func tearDown() {
        let cleanup = XCUIApplication()
        cleanup.launchArguments += [
            "-uiTesting",
            "-resetSavedLocallyReportsForUITests",
        ]
        cleanup.launch()
        Thread.sleep(forTimeInterval: 0.5)
        cleanup.terminate()
        super.tearDown()
    }

    // MARK: - Sign-in / save-password

    /// Signs in, dismisses the save-password sheet, taps the home-community
    /// tile in the picker if it appears, and waits for the AppHeader to
    /// settle on the home-community landing. Returns the home community's
    /// display name (e.g. "The Conservation Angler").
    @discardableResult
    func signInAndReachHomeLanding() throws -> String {
        XCTAssertTrue(loginPage.isDisplayed, "Login screen should be visible at launch")
        let signedIn = loginPage.signIn(email: testEmail, password: testPassword, timeout: 60)
        XCTAssertTrue(signedIn, "App should navigate away from login screen after sign-in")

        dismissSavePasswordPrompt()

        if picker.isDisplayed {
            let homeTile = nonEpicWatersTile()
            XCTAssertNotNil(homeTile, "Expected a non-Epic-Waters community tile in the picker")
            homeTile?.tap()
        }

        guard let startingCommunity = switcher.currentCommunityName(timeout: 30) else {
            XCTFail("AppHeader community-name label never appeared after sign-in.")
            throw XCTSkip("Could not determine starting community")
        }
        XCTAssertFalse(startingCommunity.isEmpty, "Starting community name should be non-empty")
        XCTAssertNotEqual(startingCommunity, epicWatersName,
                          "Test account should land on its home community, not Epic Waters")
        return startingCommunity
    }

    /// Dismisses the iOS "Save Password?" sheet that appears after sign-in.
    /// In iOS 26 the sheet is owned by a system service whose elements
    /// aren't reachable via per-process XCUIApplication queries — we detect
    /// it by polling for the "Save Password?" static text and tap "Not Now"
    /// at its known screen coordinate.
    func dismissSavePasswordPrompt() {
        let savePromptText = app.staticTexts["Save Password?"]
        guard savePromptText.waitForExistence(timeout: 15) else { return }
        let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let notNowCenter = normalized.withOffset(CGVector(dx: 127, dy: 547))
        notNowCenter.tap()
        _ = savePromptText.waitForNonExistence(timeout: 5)
    }

    /// First `communityTile_*` button in the picker that isn't Epic Waters.
    func nonEpicWatersTile() -> XCUIElement? {
        let predicate = NSPredicate(format:
            "identifier BEGINSWITH 'communityTile_' AND identifier != %@",
            "communityTile_\(epicWatersName)")
        let matches = app.buttons.matching(predicate)
        return matches.count > 0 ? matches.element(boundBy: 0) : nil
    }

    func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Number / value formatting

    /// Format an inches value the same way the user would type it: drop the
    /// fractional part if it's a whole number, otherwise one decimal place.
    func formatInchesForInput(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    // MARK: - Reusable chat-flow building blocks

    /// Drives the chat from activity-choice through both photo uploads,
    /// stopping at the location step.
    func runChatThroughLocationStep() throws {
        XCTAssertTrue(chat.tapCapsule("activity-catch", timeout: 15))
        XCTAssertTrue(chat.tap(chat.photoUploadButton))
        XCTAssertTrue(chat.tapCapsule("head-confirm", timeout: 15))
        XCTAssertTrue(chat.tap(chat.photoUploadButton))
        let locSkip = chat.capsule("loc-skip")
        let locConfirm = chat.capsule("loc-confirm")
        let appeared = locSkip.waitForExistence(timeout: 60)
            || locConfirm.waitForExistence(timeout: 5)
        XCTAssertTrue(appeared, "ML analysis + location prompt should resolve within 60s")
    }

    /// After the location step, accept species/lifecycle/sex and tap
    /// `summary-confirm` to advance into the measurements phase.
    func acceptSpeciesLifecycleSexAndSummary() throws {
        XCTAssertTrue(chat.tapFirstCapsule(withIDPrefix: "species-", timeout: 30))
        _ = chat.tapFirstCapsule(withIDPrefix: "lc-", timeout: 8)
        XCTAssertTrue(chat.tapFirstCapsule(withIDPrefix: "sex-", timeout: 30))
        XCTAssertTrue(chat.tapCapsule("summary-confirm", timeout: 30))
    }

    /// After `summary-confirm`, accept length + girth defaults and reach the
    /// final-summary step (side-button visible).
    func acceptIdentificationAndMeasurements() throws {
        try acceptSpeciesLifecycleSexAndSummary()
        XCTAssertTrue(chat.tapCapsule("measure-confirm", timeout: 30))
        _ = chat.capsule("measure-confirm").waitForNonExistence(timeout: 5)
        XCTAssertTrue(chat.tapCapsule("measure-confirm", timeout: 30))
        XCTAssertTrue(chat.tap(chat.researcherFinalConfirmButton, timeout: 30))
    }

    /// Drive the chat all the way to `.finalSummary` (side-button visible,
    /// no capsule attached). Caller still needs to advance via the side
    /// button or by typing edits.
    func runChatThroughFinalSummary() throws {
        try runChatThroughLocationStep()
        _ = chat.tapCapsule("loc-skip", timeout: 60)
        try acceptSpeciesLifecycleSexAndSummary()
        XCTAssertTrue(chat.tapCapsule("measure-confirm", timeout: 30))
        _ = chat.capsule("measure-confirm").waitForNonExistence(timeout: 5)
        XCTAssertTrue(chat.tapCapsule("measure-confirm", timeout: 30))
        XCTAssertTrue(chat.researcherFinalConfirmButton.waitForExistence(timeout: 30))
    }

    /// Tap No to study, No to sample, Maybe later to voice memo so the
    /// flow reaches the saveRequested → confirmation cover state.
    func declineAllResearchPrompts() throws {
        XCTAssertTrue(chat.tapCapsule("cap-no", timeout: 30),
                      "Study Yes/No capsules should appear")
        _ = chat.capsule("cap-no").waitForNonExistence(timeout: 5)
        XCTAssertTrue(chat.tapCapsule("cap-no", timeout: 30),
                      "Sample Yes/No capsules should appear after study=No")
        XCTAssertTrue(chat.tapCapsule("voice-skip", timeout: 30),
                      "Voice-memo capsules should appear after sample=No")
    }

    /// Walks the post-chat confirmation flow (Confirm full-screen → "Catch
    /// Report Saved" alert → tap Activities) and asserts a
    /// `catchReportRow_*` is present. Optionally asserts the rendered
    /// length matches `expectedLength`.
    func confirmAndAssertCatchInActivities(label: String,
                                           expectedLength: Double?,
                                           expectedGirth _: Double?) throws {
        let confirmBtn = app.buttons["catchConfirmationConfirmButton"]
        XCTAssertTrue(confirmBtn.waitForExistence(timeout: 30),
                      "Catch confirmation 'Confirm' button should appear after voice-memo skip")
        confirmBtn.tap()

        let okBtn = app.alerts.buttons["OK"].firstMatch
        XCTAssertTrue(okBtn.waitForExistence(timeout: 15),
                      "Saved-confirmation alert OK button should appear after Confirm")
        okBtn.tap()

        attachScreenshot(named: "01_\(label)_CatchSaved_BackOnLanding")

        let activitiesBtn = app.buttons.matching(
            NSPredicate(format: "label ENDSWITH 'Activities'")
        ).firstMatch
        XCTAssertTrue(activitiesBtn.waitForExistence(timeout: 15),
                      "Activities tab button should be visible on landing")
        activitiesBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let predicate = NSPredicate(format: "identifier BEGINSWITH 'catchReportRow_'")
        let rows = app.descendants(matching: .any).matching(predicate)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15),
                      "Newly saved catch report should appear in Activities → Reports")

        if let expected = expectedLength {
            let lengthLabel = "\(Int(expected))\""
            let row = rows.firstMatch
            XCTAssertTrue(
                row.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", lengthLabel)).count > 0,
                "Catch row should display the typed length \(lengthLabel)"
            )
        }
        attachScreenshot(named: "02_\(label)_ActivitiesShowsNewCatch")
    }

    // MARK: - Reusable scenarios

    /// Records a Steelhead catch where the user types a custom location at
    /// the loc-skip step, accepts every other ML default, declines all
    /// research prompts, and asserts the saved row carries the typed
    /// location. Phase 1 covers the path; Phase 2 reuses to seed an
    /// upload candidate with a deliberately user-typed river name.
    func runScenario_typeLocationWhenGPSCantMatch(label: String = "TypedLocation") throws {
        executionTimeAllowance = 300
        _ = try signInAndReachHomeLanding()
        dismissSavePasswordPrompt()

        try runChatThroughLocationStep()
        let typedRiver = "Babine River"
        XCTAssertTrue(chat.sendText(typedRiver),
                      "Should be able to type a location at the loc-skip prompt")

        try acceptIdentificationAndMeasurements()
        try declineAllResearchPrompts()
        try confirmAndAssertCatchInActivities(label: label,
                                              expectedLength: nil,
                                              expectedGirth: nil)

        let predicate = NSPredicate(format: "label CONTAINS %@", typedRiver)
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'catchReportRow_'"))
            .firstMatch
        XCTAssertTrue(row.staticTexts.matching(predicate).count > 0,
                      "Catch row should display typed river name '\(typedRiver)'")
    }

    /// Records a Steelhead catch where the user types a length override
    /// (ML+5") and accepts ML girth as-is. Verifies length and girth are
    /// independent inputs.
    func runScenario_modifyLengthAcceptGirth(label: String = "LengthOverrideOnly") throws {
        executionTimeAllowance = 300
        _ = try signInAndReachHomeLanding()
        dismissSavePasswordPrompt()

        try runChatThroughLocationStep()
        _ = chat.tapCapsule("loc-skip", timeout: 60)
        try acceptSpeciesLifecycleSexAndSummary()

        guard let mlLength = chat.numericValue(inBubbleContaining: "Estimated length:", timeout: 30) else {
            XCTFail("Length-confirm bubble should contain a numeric estimate")
            return
        }
        let overrideLength = mlLength + 5
        XCTAssertTrue(chat.sendText(formatInchesForInput(overrideLength)),
                      "Should be able to type length override")

        XCTAssertTrue(chat.tapCapsule("measure-confirm", timeout: 30),
                      "Girth-confirm capsule should appear after length is typed")

        XCTAssertTrue(chat.tap(chat.researcherFinalConfirmButton, timeout: 30))
        try declineAllResearchPrompts()
        try confirmAndAssertCatchInActivities(label: label,
                                              expectedLength: overrideLength,
                                              expectedGirth: nil)
    }

    /// Records a Steelhead catch where the user edits the location at the
    /// `.finalSummary` step (typing a river name there is treated as a
    /// `riverName` patch by the structured-edit parser).
    func runScenario_editOnFinalSummaryUpdatesLocation(label: String = "FinalSummaryEdit") throws {
        executionTimeAllowance = 300
        _ = try signInAndReachHomeLanding()
        dismissSavePasswordPrompt()

        try runChatThroughFinalSummary()

        let editedRiver = "Bitterroot River"
        XCTAssertTrue(chat.sendText(editedRiver),
                      "Should be able to type an edit at final-summary")

        XCTAssertTrue(chat.tap(chat.researcherFinalConfirmButton, timeout: 30),
                      "Final-summary confirm button should still be present after edit")

        try declineAllResearchPrompts()
        try confirmAndAssertCatchInActivities(label: label,
                                              expectedLength: nil,
                                              expectedGirth: nil)

        let predicate = NSPredicate(format: "label CONTAINS %@", editedRiver)
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'catchReportRow_'"))
            .firstMatch
        XCTAssertTrue(row.staticTexts.matching(predicate).count > 0,
                      "Catch row should display edited river '\(editedRiver)'")
    }

    /// Records a baseline catch (whatever `runRecordCatchFlow`-equivalent
    /// flow), then opens its detail view from Activities and edits the
    /// Species field. Verifies the Reports list reflects the edit.
    func runScenario_editCatchFromActivitiesUpdatesSpecies(label: String = "SpeciesEdited") throws {
        executionTimeAllowance = 300
        try runRecordCatchFlow(label: "EditSetup_\(label)")

        let firstRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'catchReportRow_'"))
            .firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        firstRow.tap()

        let detail = CatchReportDetailPage(app: app)
        XCTAssertTrue(detail.editButton.waitForExistence(timeout: 10),
                      "Detail-view Edit button should appear")
        detail.editButton.tap()

        let edited = "Coho Salmon"
        XCTAssertTrue(detail.setField(.species, to: edited, timeout: 10),
                      "Should be able to overwrite the Species field in edit mode")

        XCTAssertTrue(detail.saveButton.waitForExistence(timeout: 5),
                      "Save button should be visible while editing")
        detail.saveButton.tap()

        let updatedPredicate = NSPredicate(format: "label CONTAINS %@", edited)
        let updatedRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'catchReportRow_'"))
            .containing(updatedPredicate)
            .firstMatch
        XCTAssertTrue(updatedRow.waitForExistence(timeout: 10),
                      "Reports list should show a row containing the edited species '\(edited)'")
        attachScreenshot(named: "EditCatch_SpeciesUpdated_\(label)")
    }

    // MARK: - Catch-flow drivers (used by record-and-save tests)

    /// Records a catch end-to-end: activity → photos → ML → species/sex →
    /// length/girth → final summary → No to study/sample/voice → Confirm.
    /// The fixture pair used is determined by `currentFixture` (i.e. the
    /// running test's name).
    func runRecordCatchFlow(label: String) throws {
        executionTimeAllowance = 300
        _ = try signInAndReachHomeLanding()
        dismissSavePasswordPrompt()

        XCTAssertTrue(chat.tapCapsule("activity-catch", timeout: 15),
                      "Activity-choice 'Report a Catch' capsule should appear on landing")
        XCTAssertTrue(chat.tap(chat.photoUploadButton),
                      "Photo upload button should appear after choosing 'Report a Catch'")
        XCTAssertTrue(chat.tapCapsule("head-confirm", timeout: 15),
                      "Head-confirm capsule should appear after head photo is selected")
        XCTAssertTrue(chat.tap(chat.photoUploadButton),
                      "Photo upload button should re-appear for the body photo")

        if !chat.tapCapsule("loc-skip", timeout: 60) {
            XCTAssertTrue(chat.tapCapsule("loc-confirm", timeout: 5),
                          "Expected either loc-skip or loc-confirm after ML analysis")
        }
        try acceptIdentificationAndMeasurements()
        try declineAllResearchPrompts()
        try confirmAndAssertCatchInActivities(label: label,
                                              expectedLength: nil,
                                              expectedGirth: nil)
    }
}
