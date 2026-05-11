import XCTest
@testable import SkeenaSystem

/// Tests for catch report archive logic and the catchDate separation fix.
///
/// Validates:
/// 1. Reports with old photos (catchDate) don't get immediately archived
/// 2. savedLocally reports are never archived regardless of age
/// 3. Only uploaded reports older than 14 days are archived
/// 4. catchDate is preserved separately from createdAt
final class CatchReportArchiveTests: XCTestCase {

  // MARK: - Helpers

  /// Calls the shared predicate so this test pins the real archive rule
  /// rather than duplicating logic. The threshold (`archiveAfterDays`) is
  /// xcconfig-driven, so this picks up whatever the active build config
  /// sets — currently 14.
  private func isArchived(_ report: CatchReport) -> Bool {
    AppEnvironment.shared.shouldArchive(
      uploaded: report.status == .uploaded,
      createdAt: report.createdAt
    )
  }

  private func createReport(
    createdAt: Date = Date(),
    catchDate: Date? = nil,
    status: CatchReportStatus = .savedLocally
  ) -> CatchReport {
    CatchReport(
      id: UUID(),
      createdAt: createdAt,
      catchDate: catchDate,
      status: status,
      memberId: "12345",
      lengthInches: 30
    )
  }

  // MARK: - catchDate Separation Tests

  func testCatchDateIsStoredSeparatelyFromCreatedAt() {
    let oldPhotoDate = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
    let report = createReport(createdAt: Date(), catchDate: oldPhotoDate)

    XCTAssertNotNil(report.catchDate, "catchDate should be set")
    XCTAssertNotEqual(report.createdAt, report.catchDate, "createdAt and catchDate should differ")
    XCTAssertTrue(report.catchDate! < report.createdAt, "catchDate (old photo) should be before createdAt")
  }

  func testCatchDateDefaultsToNil() {
    let report = createReport()
    XCTAssertNil(report.catchDate, "catchDate should default to nil when not provided")
  }

  func testCreatedAtIsAlwaysNow_notPhotoDate() {
    let oldPhotoDate = Calendar.current.date(byAdding: .month, value: -3, to: Date())!
    let beforeCreation = Date()
    let report = createReport(catchDate: oldPhotoDate)
    let afterCreation = Date()

    // createdAt should be approximately now, not the old photo date
    XCTAssertTrue(report.createdAt >= beforeCreation, "createdAt should be at or after test start")
    XCTAssertTrue(report.createdAt <= afterCreation, "createdAt should be at or before test end")
  }

  // MARK: - Archive Logic Tests

  func testSavedLocallyReport_neverArchived_evenIfOld() {
    let threeWeeksAgo = Calendar.current.date(byAdding: .day, value: -21, to: Date())!
    let report = createReport(createdAt: threeWeeksAgo, status: .savedLocally)

    XCTAssertFalse(isArchived(report), "savedLocally reports should never be archived regardless of age")
  }

  func testSavedLocallyReport_neverArchived_evenIfVeryOld() {
    let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: Date())!
    let report = createReport(createdAt: sixMonthsAgo, status: .savedLocally)

    XCTAssertFalse(isArchived(report), "savedLocally reports should never be archived even if months old")
  }

  func testUploadedReport_notArchived_ifRecent() {
    let report = createReport(createdAt: Date(), status: .uploaded)

    XCTAssertFalse(isArchived(report), "Recently uploaded report should not be archived")
  }

  func testUploadedReport_notArchived_ifWithin14Days() {
    let thirteenDaysAgo = Calendar.current.date(byAdding: .day, value: -13, to: Date())!
    let report = createReport(createdAt: thirteenDaysAgo, status: .uploaded)

    XCTAssertFalse(isArchived(report), "Uploaded report within 14 days should not be archived")
  }

  func testUploadedReport_archived_ifOlderThan14Days() {
    let fifteenDaysAgo = Calendar.current.date(byAdding: .day, value: -15, to: Date())!
    let report = createReport(createdAt: fifteenDaysAgo, status: .uploaded)

    XCTAssertTrue(isArchived(report), "Uploaded report older than 14 days should be archived")
  }

  func testUploadedReport_archived_ifVeryOld() {
    let twoMonthsAgo = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
    let report = createReport(createdAt: twoMonthsAgo, status: .uploaded)

    XCTAssertTrue(isArchived(report), "Uploaded report from 2 months ago should be archived")
  }

  // MARK: - The Original Bug Scenario

  func testOldPhotoDoesNotCauseImmediateArchive() {
    // Simulate the fixed flow: user picks an old photo, but createdAt is now
    let oldPhotoDate = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
    let report = createReport(
      createdAt: Date(),        // Report created now
      catchDate: oldPhotoDate,  // Photo is from 2 months ago
      status: .savedLocally
    )

    XCTAssertFalse(isArchived(report), "Report with old photo should NOT be archived when just created")
  }

  func testOldPhotoReport_staysActive_afterUpload() {
    // After uploading, report should still be active since createdAt is recent
    let oldPhotoDate = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
    let report = createReport(
      createdAt: Date(),
      catchDate: oldPhotoDate,
      status: .uploaded
    )

    XCTAssertFalse(isArchived(report), "Recently uploaded report with old photo should stay active")
  }

  // MARK: - Upload DTO Backwards Compatibility

  func testUploadShouldUseCatchDate_whenAvailable() {
    let oldPhotoDate = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
    let report = createReport(createdAt: Date(), catchDate: oldPhotoDate)

    // Replicate the DTO mapping logic: r.catchDate ?? r.createdAt
    let createdAtForServer = report.catchDate ?? report.createdAt

    XCTAssertEqual(createdAtForServer, oldPhotoDate, "Server should receive the catch date (photo EXIF date)")
  }

  func testUploadShouldFallbackToCreatedAt_whenNoCatchDate() {
    let report = createReport(createdAt: Date(), catchDate: nil)

    // Replicate the DTO mapping logic: r.catchDate ?? r.createdAt
    let createdAtForServer = report.catchDate ?? report.createdAt

    XCTAssertEqual(createdAtForServer, report.createdAt, "Server should receive createdAt when no catchDate")
  }

  // MARK: - List Filtering Tests

  func testActiveReportsFilter() {
    let now = Date()
    let threeWeeksAgo = Calendar.current.date(byAdding: .day, value: -21, to: now)!

    let reports = [
      createReport(createdAt: now, status: .savedLocally),           // Active: savedLocally is always active
      createReport(createdAt: threeWeeksAgo, status: .savedLocally), // Active: savedLocally is always active
      createReport(createdAt: now, status: .uploaded),               // Active: uploaded and recent
      createReport(createdAt: threeWeeksAgo, status: .uploaded),     // Archived: uploaded and old
    ]

    let active = reports.filter { !isArchived($0) }
    let archived = reports.filter { isArchived($0) }

    XCTAssertEqual(active.count, 3, "Should have 3 active reports")
    XCTAssertEqual(archived.count, 1, "Should have 1 archived report")
    XCTAssertEqual(archived.first?.status, .uploaded, "Archived report should be uploaded")
  }

  // MARK: - Configurable Archive Threshold (ARCHIVE_AFTER_DAYS)

  /// The archive window is xcconfig-driven via `ARCHIVE_AFTER_DAYS`. The
  /// helper's `overrideArchiveAfterDays` lets tests pin behavior at custom
  /// windows without relying on the build config. Reset to nil in tearDown
  /// so other tests pick up the xcconfig default again.
  override func tearDown() {
    AppEnvironment.shared.overrideArchiveAfterDays = nil
    super.tearDown()
  }

  func testArchiveThreshold_overrideShortensWindow_flipsRecentReportToArchived() {
    AppEnvironment.shared.overrideArchiveAfterDays = 3
    let fourDaysAgo = Calendar.current.date(byAdding: .day, value: -4, to: Date())!
    let report = createReport(createdAt: fourDaysAgo, status: .uploaded)

    XCTAssertTrue(isArchived(report),
                  "With a 3-day window, a 4-day-old uploaded report should archive")
  }

  func testArchiveThreshold_overrideLengthensWindow_keepsOldReportActive() {
    AppEnvironment.shared.overrideArchiveAfterDays = 60
    let twentyDaysAgo = Calendar.current.date(byAdding: .day, value: -20, to: Date())!
    let report = createReport(createdAt: twentyDaysAgo, status: .uploaded)

    XCTAssertFalse(isArchived(report),
                   "With a 60-day window, a 20-day-old uploaded report should still be active")
  }

  func testArchiveThreshold_overrideZero_archivesEveryUploadedReportImmediately() {
    AppEnvironment.shared.overrideArchiveAfterDays = 0
    let oneSecondAgo = Date(timeIntervalSinceNow: -1)
    let report = createReport(createdAt: oneSecondAgo, status: .uploaded)

    XCTAssertTrue(isArchived(report),
                  "With a 0-day window, any uploaded report should archive immediately")
  }

  func testArchiveThreshold_overrideZero_stillSparesUnuploadedReports() {
    AppEnvironment.shared.overrideArchiveAfterDays = 0
    let twoMonthsAgo = Calendar.current.date(byAdding: .day, value: -60, to: Date())!
    let report = createReport(createdAt: twoMonthsAgo, status: .savedLocally)

    XCTAssertFalse(isArchived(report),
                   "Locally-saved reports must never archive even with a 0-day window")
  }
}
