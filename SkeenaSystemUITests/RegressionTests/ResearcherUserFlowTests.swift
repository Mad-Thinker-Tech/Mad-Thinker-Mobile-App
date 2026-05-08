import XCTest

/// Phase 1 — path-coverage regression tests for the Researcher catch flow.
///
/// Each test launches the app with `-resetSavedLocallyReportsForUITests` so
/// it sees an empty Activities list (see `perTestCleanupEnabled` on the
/// shared base). Reuse the base class helpers + scenarios for any new test
/// that walks the same flow as one of the existing scenarios.
///
/// Test account: `geoff@madthinkerfishtech.com` — a Researcher in
/// "The Conservation Angler" (TCA) and an Angler in Epic Waters. Override
/// via `RESEARCHER_FLOW_EMAIL` / `RESEARCHER_FLOW_PASSWORD` env vars.
///
/// Run with:
///   xcodebuild test -workspace SkeenaSystem.xcworkspace \
///     -scheme SkeenaSystem \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///     -only-testing:SkeenaSystemUITests/ResearcherUserFlowTests
final class ResearcherUserFlowTests: ResearcherCatchFlowTestBase {

    // MARK: - Tests

    /// Logs in, switches to Epic Waters (Angler landing), and switches back to
    /// the starting community (TCA / Researcher landing).
    func testSwitchToEpicWatersAndBack() throws {
        let startingCommunity = try signInAndReachHomeLanding()
        attachScreenshot(named: "01_StartingLanding_\(startingCommunity)")

        let switchedToEpic = switcher.toggleAndExpect(epicWatersName, timeout: 30)
        XCTAssertTrue(switchedToEpic,
                      "Toolbar should report '\(epicWatersName)' after toggling community")
        attachScreenshot(named: "02_EpicWatersLanding")

        let switchedBack = switcher.toggleAndExpect(startingCommunity, timeout: 30)
        XCTAssertTrue(switchedBack,
                      "Toolbar should return to '\(startingCommunity)' after toggling back")
        attachScreenshot(named: "03_BackToStarting_\(startingCommunity)")
    }

    /// Records a Steelhead catch end-to-end (uses `Fixtures/Steelhead/`).
    func testRecordCatchAppearsInActivities() throws {
        try runRecordCatchFlow(label: "Steelhead")
    }

    /// Records an Atlantic Salmon catch end-to-end.
    func testRecordAtlanticSalmonCatchAppearsInActivities() throws {
        try runRecordCatchFlow(label: "AtlanticSalmon")
    }

    /// Records a Brook Trout catch end-to-end. Mirrors the basic Steelhead +
    /// Atlantic Salmon flows — accept all ML defaults, decline study /
    /// sample / voice memo. Exercises the brook_trout class added to
    /// ViTFishSpecies in commit 69102ae.
    func testRecordBrookTroutCatchAppearsInActivities() throws {
        try runRecordCatchFlow(label: "BrookTrout")
    }

    /// Records a Steelhead catch where the body photo's EXIF GPS
    /// (41.84, -123.19) lands inside the Klamath River (California) spine
    /// in the offline locator. Asserts the chat takes the `loc-confirm`
    /// path (river matched), the user accepts it, and the saved row's
    /// river text reflects the matched name. Exercises the
    /// EXIF → river-locator → loc-confirm code path that the original
    /// catch tests masked by passing nil exifLocation through the bypass.
    func testRecordSteelheadCatchWithLocationMatch() throws {
        executionTimeAllowance = 300
        _ = try signInAndReachHomeLanding()
        dismissSavePasswordPrompt()

        try runChatThroughLocationStep()

        // The whole point of this test: the EXIF-tagged body photo MUST
        // produce a loc-confirm capsule, not loc-skip. If loc-skip
        // appears the GPS reader is broken or the locator missed the
        // coords — both worth a hard failure rather than a silent
        // fallback to the typed-location path.
        XCTAssertTrue(chat.capsule("loc-confirm").exists,
                      "loc-confirm capsule should appear when the body photo's EXIF " +
                      "GPS matches a known river spine; only loc-skip is visible")
        XCTAssertFalse(chat.capsule("loc-skip").exists,
                       "loc-skip should NOT appear for a GPS-tagged photo that lands in " +
                       "a known river")

        XCTAssertTrue(chat.tapCapsule("loc-confirm", timeout: 5))

        try acceptIdentificationAndMeasurements()
        try declineAllResearchPrompts()
        try confirmAndAssertCatchInActivities(label: "Steelhead_LocConfirm",
                                              expectedLength: nil,
                                              expectedGirth: nil)

        // The saved row should display the matched river name. Match by
        // contains rather than exact equality so a future locator-data
        // refactor (e.g. trimming the "(California)" suffix) doesn't
        // brittle-fail the test for the wrong reason.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'catchReportRow_'"))
            .firstMatch
        let klamathPredicate = NSPredicate(format: "label CONTAINS %@", "Klamath River")
        XCTAssertTrue(row.staticTexts.matching(klamathPredicate).count > 0,
                      "Catch row should display the matched river ('Klamath River …')")
    }

    /// Records a Steelhead catch where the user OVERRIDES every ML guess.
    func testRecordSteelheadCatchWithOverridesAppearsInActivities() throws {
        try runRecordCatchFlowWithOverrides(label: "Steelhead_Overrides")
    }

    /// Records an Atlantic Salmon catch with the full research add-ons:
    /// Yes to Floy study (tag "Red-19282"), Yes to scale sample
    /// ("282928403-2"), Yes to fin clip ("2038202-1-1"), No to voice memo.
    func testRecordAtlanticSalmonCatchWithSamplingAppearsInActivities() throws {
        try runRecordCatchFlowWithSampling(label: "AtlanticSalmon_Sampling",
                                           floyTag: "Red-19282",
                                           scaleEnvelope: "282928403-2",
                                           finEnvelope: "2038202-1-1")
    }

    // MARK: - Path-coverage tests (10)

    /// Type a location at the loc-skip step instead of skipping.
    func testTypeLocationWhenGPSCantMatch() throws {
        try runScenario_typeLocationWhenGPSCantMatch()
    }

    /// Modify length, accept girth as-is.
    func testModifyLengthAcceptGirth() throws {
        try runScenario_modifyLengthAcceptGirth()
    }

    /// Reset button mid-flow should wipe the chat and re-post the activity
    /// choice. Phase-1-only — the reset itself doesn't produce a catch.
    func testResetButtonClearsChatMidFlow() throws {
        executionTimeAllowance = 180
        _ = try signInAndReachHomeLanding()
        dismissSavePasswordPrompt()

        XCTAssertTrue(chat.tapCapsule("activity-catch", timeout: 15))
        XCTAssertTrue(chat.tap(chat.photoUploadButton))
        XCTAssertTrue(chat.tapCapsule("head-confirm", timeout: 15))

        XCTAssertTrue(chat.photoUploadButton.waitForExistence(timeout: 15),
                      "Body-photo upload button should appear before reset")
        XCTAssertTrue(chat.tap(chat.resetButton),
                      "Reset button should be tappable mid-flow")

        XCTAssertTrue(chat.capsule("activity-catch").waitForExistence(timeout: 10),
                      "Activity-choice 'Report a Catch' capsule should reappear after reset")
        XCTAssertTrue(chat.capsule("activity-observation").exists,
                      "Activity-choice 'Record an Observation' capsule should reappear after reset")
        XCTAssertFalse(chat.photoUploadButton.exists,
                       "Photo upload button from the abandoned flow should NOT persist after reset")

        attachScreenshot(named: "Reset_BackToActivityChoice")
    }

    /// At `.finalSummary` the user can patch any identification field by
    /// typing. Free-text becomes the river name.
    func testEditOnFinalSummaryUpdatesLocation() throws {
        try runScenario_editOnFinalSummaryUpdatesLocation()
    }

    /// Save a catch then swipe-to-delete it from Activities.
    func testDeleteUnuploadedCatchFromActivities() throws {
        executionTimeAllowance = 300
        try runRecordCatchFlow(label: "DeleteSetup")

        let rowsPredicate = NSPredicate(format: "identifier BEGINSWITH 'catchReportRow_'")
        let firstRow = app.descendants(matching: .any).matching(rowsPredicate).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        let rowID = firstRow.identifier

        firstRow.swipeLeft()
        let deleteSwipeButton = app.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteSwipeButton.waitForExistence(timeout: 5),
                      "Delete swipe action should appear after swipeLeft on a saved row")
        deleteSwipeButton.tap()

        let confirmDelete = app.alerts.buttons["Delete"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5),
                      "Delete-confirmation alert should appear")
        confirmDelete.tap()

        let deletedRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", rowID)).firstMatch
        XCTAssertTrue(deletedRow.waitForNonExistence(timeout: 10),
                      "Deleted row \(rowID) should no longer exist in Activities")

        attachScreenshot(named: "DeleteCatch_RowGone")
    }

    /// Record + save → tap row → edit Species → save. Verify the row
    /// reflects the updated species.
    func testEditCatchFromActivitiesUpdatesSpecies() throws {
        try runScenario_editCatchFromActivitiesUpdatesSpecies()
    }

    /// Typing profanity at any researcher step posts the "Let's keep it
    /// civil" reply instead of being persisted as a value.
    func testProfanityResponseAtFinalSummary() throws {
        executionTimeAllowance = 300
        _ = try signInAndReachHomeLanding()
        dismissSavePasswordPrompt()

        try runChatThroughFinalSummary()

        XCTAssertTrue(chat.sendText("this fish is shit"),
                      "Should be able to type into the chat input")

        let civility = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Let's keep it civil")
        ).firstMatch
        XCTAssertTrue(civility.waitForExistence(timeout: 10),
                      "Profanity should trigger the 'Let's keep it civil' civility reply")

        XCTAssertTrue(chat.researcherFinalConfirmButton.exists,
                      "Final-summary confirm button should still be present after profanity reply")

        attachScreenshot(named: "Profanity_CivilityReply")
    }

    /// Upload the head photo, tap Retake, then upload again. Verifies the
    /// retake path resets pending state and re-prompts for a head photo.
    func testRetakeHeadPhotoReturnsToHeadStep() throws {
        executionTimeAllowance = 180
        _ = try signInAndReachHomeLanding()
        dismissSavePasswordPrompt()

        XCTAssertTrue(chat.tapCapsule("activity-catch", timeout: 15))
        XCTAssertTrue(chat.tap(chat.photoUploadButton))

        XCTAssertTrue(chat.tapCapsule("head-retake", timeout: 15),
                      "Head-retake capsule should appear after head photo upload")

        XCTAssertTrue(chat.photoUploadButton.waitForExistence(timeout: 15),
                      "Photo upload button should re-appear after Retake")
        chat.photoUploadButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(chat.capsule("head-confirm").waitForExistence(timeout: 15),
                      "Head-confirm capsule should appear again after the second head upload")

        attachScreenshot(named: "Retake_HeadConfirmAgain")
    }

    /// Tapping "Record an Observation" opens the `RecordObservationSheet`.
    func testRecordObservationOpensSheet() throws {
        executionTimeAllowance = 120
        _ = try signInAndReachHomeLanding()
        dismissSavePasswordPrompt()

        XCTAssertTrue(chat.tapCapsule("activity-observation", timeout: 15),
                      "'Record an Observation' capsule should appear at activity-choice")

        let sheetMarker = app.staticTexts["Record a field observation"]
        XCTAssertTrue(sheetMarker.waitForExistence(timeout: 10),
                      "RecordObservationSheet should present after choosing observation")

        attachScreenshot(named: "Observation_SheetPresented")
    }

    /// Tapping the person.circle nav button pushes `ManageProfileView`.
    func testManageProfileButtonOpensManageProfile() throws {
        executionTimeAllowance = 120
        _ = try signInAndReachHomeLanding()
        dismissSavePasswordPrompt()

        let manageBtn = app.buttons["manageProfileButton"]
        XCTAssertTrue(manageBtn.waitForExistence(timeout: 15),
                      "Manage-profile nav-bar button should appear on Researcher landing")
        manageBtn.tap()

        let manageProfile = ManageProfilePage(app: app)
        XCTAssertTrue(manageProfile.isDisplayed,
                      "ManageProfileView should be shown after tapping manageProfileButton")

        attachScreenshot(named: "ManageProfile_Opened")
    }

    // MARK: - Phase-1-only flow drivers

    /// Variant of `runRecordCatchFlow` that overrides every ML pick:
    /// flips lifecycle, flips sex, types ML+3" length, types ML-1" girth.
    private func runRecordCatchFlowWithOverrides(label: String) throws {
        executionTimeAllowance = 300
        _ = try signInAndReachHomeLanding()
        dismissSavePasswordPrompt()

        try runChatThroughLocationStep()
        dismissLocationStep()

        XCTAssertTrue(chat.tapFirstCapsule(withIDPrefix: "species-", timeout: 30),
                      "Species capsules should appear after location step")

        XCTAssertTrue(chat.tapSecondCapsule(withIDPrefix: "lc-", timeout: 15),
                      "Steelhead lifecycle capsules should appear; test requires the alternative to ML to be tappable")
        XCTAssertTrue(chat.tapSecondCapsule(withIDPrefix: "sex-", timeout: 30),
                      "Sex capsules should expose at least an alternative to the ML pick")

        XCTAssertTrue(chat.tapCapsule("summary-confirm", timeout: 30),
                      "Identification-summary 'Continue' capsule should appear after sex")

        guard let mlLength = chat.numericValue(inBubbleContaining: "Estimated length:", timeout: 30) else {
            XCTFail("Length-confirm bubble should contain a numeric estimate")
            return
        }
        let overrideLength = mlLength + 3
        XCTAssertTrue(chat.sendText(formatInchesForInput(overrideLength)),
                      "Should be able to type the new length into the chat input")

        guard let mlGirth = chat.numericValue(inBubbleContaining: "Estimated girth:", timeout: 30) else {
            XCTFail("Girth-confirm bubble should contain a numeric estimate")
            return
        }
        let overrideGirth = mlGirth - 1
        XCTAssertTrue(chat.sendText(formatInchesForInput(overrideGirth)),
                      "Should be able to type the new girth into the chat input")

        XCTAssertTrue(chat.tap(chat.researcherFinalConfirmButton, timeout: 30),
                      "Final-summary confirm button should appear after girth")
        try declineAllResearchPrompts()

        try confirmAndAssertCatchInActivities(label: label,
                                              expectedLength: overrideLength,
                                              expectedGirth: overrideGirth)
    }

    /// Variant of `runRecordCatchFlow` that says Yes to study (Floy tag),
    /// Yes to sample (scale envelope), Yes to fin clip, No to voice memo.
    private func runRecordCatchFlowWithSampling(label: String,
                                                floyTag: String,
                                                scaleEnvelope: String,
                                                finEnvelope: String) throws {
        executionTimeAllowance = 360
        _ = try signInAndReachHomeLanding()
        dismissSavePasswordPrompt()

        try runChatThroughLocationStep()
        dismissLocationStep()
        XCTAssertTrue(chat.tapFirstCapsule(withIDPrefix: "species-", timeout: 30))
        _ = chat.tapFirstCapsule(withIDPrefix: "lc-", timeout: 8)
        XCTAssertTrue(chat.tapFirstCapsule(withIDPrefix: "sex-", timeout: 30))
        XCTAssertTrue(chat.tapCapsule("summary-confirm", timeout: 30))
        XCTAssertTrue(chat.tapCapsule("measure-confirm", timeout: 30),
                      "Length-confirm capsule should appear")
        _ = chat.capsule("measure-confirm").waitForNonExistence(timeout: 5)
        XCTAssertTrue(chat.tapCapsule("measure-confirm", timeout: 30),
                      "Girth-confirm capsule should appear")
        XCTAssertTrue(chat.tap(chat.researcherFinalConfirmButton, timeout: 30),
                      "Final-summary confirm button should appear")

        XCTAssertTrue(chat.tapCapsule("cap-yes", timeout: 30),
                      "Study Yes/No capsules should appear after final summary")
        XCTAssertTrue(chat.tapCapsule("study-floy", timeout: 30),
                      "Study-type capsules (study-floy etc.) should appear after study=Yes")

        XCTAssertTrue(chat.sendText(floyTag),
                      "Should be able to type the Floy Tag ID into the chat input")
        XCTAssertTrue(chat.tapCapsule("id-confirm", timeout: 30),
                      "Floy-tag confirm capsule should appear after typed entry")

        _ = chat.capsule("cap-yes").waitForNonExistence(timeout: 5)
        XCTAssertTrue(chat.tapCapsule("cap-yes", timeout: 30),
                      "Sample Yes/No capsules should appear after Floy tag confirmed")

        XCTAssertTrue(chat.sendText(scaleEnvelope),
                      "Should be able to type the scale envelope ID")
        _ = chat.capsule("id-confirm").waitForNonExistence(timeout: 5)
        XCTAssertTrue(chat.tapCapsule("id-confirm", timeout: 30),
                      "Scale-envelope confirm capsule should appear after typed entry")

        _ = chat.capsule("cap-yes").waitForNonExistence(timeout: 5)
        XCTAssertTrue(chat.tapCapsule("cap-yes", timeout: 30),
                      "Fin Yes/No capsules should appear after scale envelope confirmed")

        XCTAssertTrue(chat.sendText(finEnvelope),
                      "Should be able to type the fin envelope ID")
        _ = chat.capsule("id-confirm").waitForNonExistence(timeout: 5)
        XCTAssertTrue(chat.tapCapsule("id-confirm", timeout: 30),
                      "Fin-envelope confirm capsule should appear after typed entry")

        XCTAssertTrue(chat.tapCapsule("voice-skip", timeout: 30),
                      "Voice-memo capsules should appear after fin envelope confirmed")

        try confirmAndAssertCatchInActivities(label: label,
                                              expectedLength: nil,
                                              expectedGirth: nil)
    }
}
