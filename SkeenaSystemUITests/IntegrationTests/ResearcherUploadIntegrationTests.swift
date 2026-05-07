import XCTest

/// Phase 2 — integration tests that accumulate catch reports across 5
/// independent record flows, then upload all of them at once and verify
/// the backend received them.
///
/// Unlike Phase 1 (`ResearcherUserFlowTests`), this suite does NOT pass
/// `-resetSavedLocallyReportsForUITests` between tests — `perTestCleanupEnabled`
/// is overridden to `false`, so each test launches with the prior tests'
/// catches still on disk. After the 6th test runs, the inherited
/// `class func tearDown()` wipes everything so the simulator is clean for
/// the next run.
///
/// Test sequencing relies on alphabetical method ordering:
///   `test01_*` → `test02_*` → ... → `test06_*`. XCTest runs methods in
///   alphabetical order within a class, so the numeric prefixes guarantee
///   the record tests finish before `test06` triggers the upload.
///
/// The first 4 tests reuse the path-coverage scenarios from Phase 1
/// (`runScenario_*` on `ResearcherCatchFlowTestBase`) so the accumulated
/// catches cover a representative spread: typed location, length override,
/// final-summary edit, post-save species edit. Test 5 is a vanilla catch
/// to round out the set with one untouched record. Test 6 taps the upload
/// button on Activities and asserts the success alert.
///
/// Run with:
///   xcodebuild test -workspace SkeenaSystem.xcworkspace \
///     -scheme SkeenaSystem \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///     -only-testing:SkeenaSystemUITests/ResearcherUploadIntegrationTests
final class ResearcherUploadIntegrationTests: ResearcherCatchFlowTestBase {

    // MARK: - Suite policy

    /// Disable per-test cleanup. Tests 1-5 each save one report; test 6
    /// uploads ALL FIVE in a single batch. If we wiped between tests
    /// there'd be nothing left to upload.
    override var perTestCleanupEnabled: Bool { false }

    // MARK: - Tests (alphabetical order is the run order — keep `test0N_` prefixes)

    /// Catch #1 — typed location at the loc-skip step (Babine River).
    func test01_recordCatchWithTypedLocation() throws {
        try runScenario_typeLocationWhenGPSCantMatch(label: "Phase2_TypedLocation")
    }

    /// Catch #2 — length override (ML+5"), girth accepted as-is.
    func test02_recordCatchWithLengthOverride() throws {
        try runScenario_modifyLengthAcceptGirth(label: "Phase2_LengthOverride")
    }

    /// Catch #3 — final-summary edit (location patched to "Bitterroot River").
    func test03_recordCatchWithFinalSummaryEdit() throws {
        try runScenario_editOnFinalSummaryUpdatesLocation(label: "Phase2_FinalSummaryEdit")
    }

    /// Catch #4 — record + open detail view + edit Species ("Coho Salmon").
    /// Uses the Atlantic Salmon fixture (see `fixtureByTestName`) so the
    /// initial ML species differs from the post-edit species, giving the
    /// upload a row whose pre-edit + post-edit values are observably
    /// different.
    func test04_recordCatchWithSpeciesEditFromActivities() throws {
        try runScenario_editCatchFromActivitiesUpdatesSpecies(label: "Phase2_SpeciesEdit")
    }

    /// Catch #5 — vanilla flow, accept every ML default. Gives the
    /// 5-report portfolio one "untouched" baseline to compare against.
    func test05_recordVanillaCatch() throws {
        try runRecordCatchFlow(label: "Phase2_Vanilla")
    }

    /// Catch #6 — drive the upload, then verify each report landed in the
    /// Supabase `catch_reports` table with the same `report_id` and species
    /// the mobile app showed.
    ///
    /// The DB assertion runs only when both `SUPABASE_TEST_URL` and
    /// `SUPABASE_TEST_KEY` are exported in the test process's environment;
    /// otherwise it `XCTSkip`s with a clear note so the in-app upload
    /// assertion still runs.
    func test06_uploadAllAccumulatedReports() throws {
        executionTimeAllowance = 600
        _ = try signInAndReachHomeLanding()
        dismissSavePasswordPrompt()

        // Open Activities. The toolbar label carries a pending count
        // (e.g. "5 pending uploads, Activities") — match by suffix.
        let activitiesBtn = app.buttons.matching(
            NSPredicate(format: "label ENDSWITH 'Activities'")
        ).firstMatch
        XCTAssertTrue(activitiesBtn.waitForExistence(timeout: 15),
                      "Activities tab button should be visible on landing")
        activitiesBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Confirm that the prior 5 record tests really did leave 5 rows.
        let rowsPredicate = NSPredicate(format: "identifier BEGINSWITH 'catchReportRow_'")
        let rows = app.descendants(matching: .any).matching(rowsPredicate)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15),
                      "Activities should show at least one accumulated report")
        let preUploadCount = rows.count
        XCTAssertGreaterThanOrEqual(
            preUploadCount, 5,
            "Expected ≥5 pending reports from prior tests; found \(preUploadCount). " +
            "Did one of test01-test05 fail or get skipped?"
        )
        attachScreenshot(named: "Phase2_BeforeUpload_\(preUploadCount)Rows")

        // Capture each pending row's (reportId, displayedSpecies) BEFORE
        // the upload — the post-upload sectioning may shuffle UI order
        // and we want the "what the app showed the user" snapshot as our
        // ground truth for the backend cross-check.
        let expected = capturePendingReportSnapshot(rows: rows)
        XCTAssertEqual(expected.count, preUploadCount,
                       "Should be able to parse a (reportId, species) snapshot from every pending row")

        // Tap the upload toolbar button (`arrow.up.circle`).
        let uploadBtn = app.buttons["arrow.up.circle"]
        XCTAssertTrue(uploadBtn.waitForExistence(timeout: 10),
                      "Upload toolbar button should be visible on Activities")
        uploadBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // 5 reports × photos × Supabase round-trip can take a while.
        let completeAlert = app.alerts["Upload Complete"]
        XCTAssertTrue(completeAlert.waitForExistence(timeout: 300),
                      "Upload should complete and surface 'Upload Complete' alert")

        let messageText = completeAlert.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Uploaded")
        ).firstMatch
        XCTAssertTrue(messageText.waitForExistence(timeout: 5),
                      "Upload-complete alert should include an 'Uploaded N…' message")
        attachScreenshot(named: "Phase2_UploadCompleteAlert")

        completeAlert.buttons["OK"].firstMatch.tap()

        let uploadedChip = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "Uploaded")
        ).firstMatch
        XCTAssertTrue(uploadedChip.waitForExistence(timeout: 30),
                      "At least one row should show 'Uploaded' status after the upload completes")

        attachScreenshot(named: "Phase2_AfterUpload_\(preUploadCount)Rows")

        try assertReportsLandedInSupabase(expected: expected)
    }

    // MARK: - Pre-upload row capture

    /// One pending row's worth of "what the user saw" — used as ground
    /// truth for the post-upload Supabase cross-check.
    private struct ExpectedReport {
        /// Lowercase UUID string from the `catchReportRow_<uuid>` identifier
        /// suffix. Matches the `report_id` column in Supabase.
        let reportId: String
        /// First static-text label inside the row, which is rendered by
        /// `CatchReportRow.speciesText`. Falls back to "Unknown Species"
        /// when the local report has no species.
        let species: String
    }

    /// Walk each pending `catchReportRow_*` and grab the report UUID
    /// (from the identifier) plus the visible species text. Done BEFORE
    /// the upload so we don't race the post-upload section reshuffle.
    private func capturePendingReportSnapshot(rows: XCUIElementQuery) -> [ExpectedReport] {
        var snapshot: [ExpectedReport] = []
        for i in 0..<rows.count {
            let row = rows.element(boundBy: i)
            let identifier = row.identifier
            let prefix = "catchReportRow_"
            guard identifier.hasPrefix(prefix) else { continue }
            let reportId = String(identifier.dropFirst(prefix.count))

            // The species label is the row's first static text (see
            // `CatchReportRow.body` — `speciesText` is the headline).
            let firstStatic = row.staticTexts.allElementsBoundByIndex.first
            let species = firstStatic?.label ?? ""
            snapshot.append(ExpectedReport(reportId: reportId, species: species))
        }
        return snapshot
    }

    // MARK: - Backend assertion

    /// For each pre-upload `(reportId, species)` pair, fetch the row from
    /// `catch_reports` via the service-role REST endpoint and assert:
    ///
    /// 1. **Existence** — exactly one row matches the `report_id`. This is
    ///    the core "did the upload land" check.
    /// 2. **Species match** — the row's `species` column equals the species
    ///    the mobile app displayed pre-upload. Proves the upload pipeline
    ///    didn't drop or transform the field.
    ///
    /// Skips cleanly with `XCTSkip` if the env vars aren't set, leaving
    /// the in-app upload portion of the test as the only verification.
    private func assertReportsLandedInSupabase(expected: [ExpectedReport]) throws {
        let creds = ProcessInfo.processInfo.environment
        guard creds["SUPABASE_TEST_URL"] != nil,
              creds["SUPABASE_TEST_KEY"] != nil
        else {
            throw XCTSkip(
                "Supabase row-level assertions skipped — export " +
                "SUPABASE_TEST_URL and SUPABASE_TEST_KEY before " +
                "running xcodebuild test. Uploaded \(expected.count) " +
                "reports via the app; the in-app completion alert was " +
                "the only verification this run."
            )
        }

        let client = try SupabaseTestClient.fromEnvironment()
        var failures: [String] = []

        for report in expected {
            let rows: [[String: Any]]
            do {
                rows = try client.fetchCatchReport(reportId: report.reportId)
            } catch {
                failures.append("[\(report.reportId)] fetch failed: \(error)")
                continue
            }

            guard rows.count == 1 else {
                failures.append("[\(report.reportId)] expected 1 matching row, got \(rows.count)")
                continue
            }
            let row = rows[0]

            // Species column. Supabase column names are snake_case; the
            // upload payload calls it just `species`. If the schema ever
            // renames it (e.g. `fish_species`), update this lookup.
            let dbSpecies = (row["species"] as? String) ?? ""
            if dbSpecies != report.species {
                failures.append(
                    "[\(report.reportId)] species mismatch — " +
                    "app displayed '\(report.species)', backend has '\(dbSpecies)'"
                )
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Supabase row checks failed (\(failures.count)/\(expected.count)):\n" +
            failures.joined(separator: "\n")
        )
    }
}
