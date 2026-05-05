import XCTest
@testable import SkeenaSystem

/// Tests for `WeatherSnapshotService.hourLabel(from:)`. The function pairs
/// the backend's hourly forecast timestamp with the formatter the
/// guide-landing weather strip uses; a regression here surfaces as the full
/// ISO date being word-wrapped across the hourly column (the bug fixed by
/// commit `ab9cf4d`).
///
/// The output uses `DateFormatting.hourAMPM` which doesn't pin a locale, so
/// the AM/PM suffix follows the device's default. CI runs the iOS simulator
/// in en_US by default, so "2pm" / "12am" are stable expectations.
final class WeatherSnapshotServiceTests: XCTestCase {

  // MARK: - Happy path: both separators the backend has shipped

  func testHourLabel_isoTSeparator() {
    XCTAssertEqual(WeatherSnapshotService.hourLabel(from: "2026-03-31T14:00"), "2pm")
    XCTAssertEqual(WeatherSnapshotService.hourLabel(from: "2026-03-31T09:00"), "9am")
  }

  func testHourLabel_spaceSeparator() {
    // Regression guard for commit ab9cf4d — the function originally split on
    // "T" only, so when the backend started returning space-separated
    // timestamps the entire date string was rendered.
    XCTAssertEqual(WeatherSnapshotService.hourLabel(from: "2026-05-05 14:00"), "2pm")
    XCTAssertEqual(WeatherSnapshotService.hourLabel(from: "2026-05-05 21:00"), "9pm")
  }

  // MARK: - AM/PM rollover boundaries

  func testHourLabel_midnightAndNoon() {
    XCTAssertEqual(WeatherSnapshotService.hourLabel(from: "2026-05-05T00:00"), "12am",
                   "Midnight should render as 12am, not 0am")
    XCTAssertEqual(WeatherSnapshotService.hourLabel(from: "2026-05-05T12:00"), "12pm",
                   "Noon should render as 12pm, not 0pm")
  }

  func testHourLabel_lateEveningHours() {
    XCTAssertEqual(WeatherSnapshotService.hourLabel(from: "2026-05-05T23:00"), "11pm")
    XCTAssertEqual(WeatherSnapshotService.hourLabel(from: "2026-05-05T13:00"), "1pm")
  }

  // MARK: - Malformed input — never dump the full date string

  /// Bare time strings (no date) should still parse cleanly via the suffix(5)
  /// fallback rather than rendering verbatim.
  func testHourLabel_bareTimeStringStillParses() {
    XCTAssertEqual(WeatherSnapshotService.hourLabel(from: "14:00"), "2pm")
    XCTAssertEqual(WeatherSnapshotService.hourLabel(from: "00:00"), "12am")
  }

  /// Garbage input should fall back to the trailing 5 chars instead of the
  /// whole date string. The key invariant: never return something multi-line.
  func testHourLabel_unparseableInputReturnsShortFallback() {
    let result = WeatherSnapshotService.hourLabel(from: "not-a-date")
    XCTAssertEqual(result.count, 5,
                   "Fallback must be a short suffix, never the full input — the column word-wraps")
  }

  /// Empty input edge case — must not crash and must not return a multi-line
  /// string.
  func testHourLabel_emptyInputReturnsEmpty() {
    XCTAssertEqual(WeatherSnapshotService.hourLabel(from: ""), "")
  }
}
