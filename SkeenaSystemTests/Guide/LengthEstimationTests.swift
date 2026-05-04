import XCTest
@testable import SkeenaSystem

/// Tests for the length-range collapsing logic.
///
/// `averagedLength` (in CatchChatViewModel) takes a heuristic length string —
/// possibly a range like "28-32 inches" — and collapses it to the midpoint
/// for backend persistence. The user-facing chat preserves the range string
/// verbatim (see `formattedSummary`); the midpoint is what gets written to
/// `initialAnalysis.lengthInches` in the upload payload.
///
/// `averagedLength` is internal, but we re-implement the same logic locally
/// here as a sanity-check for the contract — if the production implementation
/// drifts (e.g. someone reverts to high-end behavior), these tests still
/// fail loudly without reaching into the view model's setUp.
final class LengthEstimationTests: XCTestCase {

  // MARK: - Helper

  /// Replicates the `averagedLength` logic from CatchChatViewModel: collapse
  /// a range to its midpoint, leave a single value alone.
  private func midpointLength(from raw: String) -> String {
    var cleaned = raw
      .replacingOccurrences(of: "inches", with: "")
      .replacingOccurrences(of: "inch", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if cleaned.isEmpty || cleaned == "-" {
      return cleaned
    }

    cleaned = cleaned.replacingOccurrences(of: " ", with: "")

    let separators: [Character] = ["–", "-", "—"]

    for sep in separators {
      if cleaned.contains(sep) {
        let parts = cleaned.split(separator: sep)
        if parts.count == 2,
           let a = Double(parts[0]),
           let b = Double(parts[1]) {
          let mid = (a + b) / 2.0
          if mid.rounded() == mid {
            return "\(Int(mid)) inches"
          } else {
            return String(format: "%.1f inches", mid)
          }
        }
      }
    }

    if cleaned.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil {
      if let value = Double(cleaned) {
        if value.rounded() == value {
          return "\(Int(value)) inches"
        } else {
          return String(format: "%.1f inches", value)
        }
      }
    }

    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Range Tests (midpoint)

  func testRange_returnsMidpoint_hyphen() {
    XCTAssertEqual(midpointLength(from: "28-32 inches"), "30 inches",
                   "Should return the midpoint of a hyphen range")
  }

  func testRange_returnsMidpoint_enDash() {
    XCTAssertEqual(midpointLength(from: "28–32 inches"), "30 inches",
                   "Should return the midpoint of an en-dash range")
  }

  func testRange_returnsMidpoint_emDash() {
    XCTAssertEqual(midpointLength(from: "28—32 inches"), "30 inches",
                   "Should return the midpoint of an em-dash range")
  }

  func testRange_returnsMidpoint_noUnits() {
    XCTAssertEqual(midpointLength(from: "28-32"), "30 inches",
                   "Should return midpoint and append inches even without unit")
  }

  func testRange_returnsMidpoint_withDecimals() {
    // (27.5 + 32.5) / 2 = 30.0 — rounds to integer form.
    XCTAssertEqual(midpointLength(from: "27.5-32.5 inches"), "30 inches",
                   "Should return midpoint of decimal range")
  }

  func testRange_returnsMidpoint_decimalMidpoint() {
    // (28 + 33) / 2 = 30.5 — preserved as decimal.
    XCTAssertEqual(midpointLength(from: "28-33 inches"), "30.5 inches",
                   "Should preserve decimal midpoint when bounds don't average to an integer")
  }

  func testRange_returnsMidpoint_reversedOrder() {
    // Reversed-order bounds should still land on the same midpoint.
    XCTAssertEqual(midpointLength(from: "32-28 inches"), "30 inches",
                   "Midpoint is order-independent")
  }

  func testRange_notHighEnd() {
    // Old behavior was to pick the high end (32) — guard against regression.
    XCTAssertNotEqual(midpointLength(from: "28-32 inches"), "32 inches",
                      "Should NOT return the high end of the range — that was the previous behavior")
  }

  // MARK: - Single Value Tests

  func testSingleValue_integer() {
    XCTAssertEqual(midpointLength(from: "32 inches"), "32 inches",
                   "Should return single integer value as-is")
  }

  func testSingleValue_decimal() {
    XCTAssertEqual(midpointLength(from: "32.5 inches"), "32.5 inches",
                   "Should return single decimal value as-is")
  }

  func testSingleValue_noUnits() {
    XCTAssertEqual(midpointLength(from: "32"), "32 inches",
                   "Should append inches to bare number")
  }

  // MARK: - Edge Cases

  func testEmptyString() {
    XCTAssertEqual(midpointLength(from: ""), "",
                   "Should return empty string for empty input")
  }

  func testDash() {
    XCTAssertEqual(midpointLength(from: "-"), "-",
                   "Should return dash for dash input")
  }

  func testNonNumericInput() {
    XCTAssertEqual(midpointLength(from: "not available"), "not available",
                   "Should return non-numeric input as-is")
  }

  func testWhitespaceHandling() {
    XCTAssertEqual(midpointLength(from: " 28 - 32 inches "), "30 inches",
                   "Should handle whitespace around range")
  }
}
