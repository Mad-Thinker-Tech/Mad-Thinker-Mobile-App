import XCTest
@testable import SkeenaSystem

/// Regression tests for `FishingForecastRequestView.sortByConditions(...)`.
///
/// The conditions list orders fisheries by metric availability so guides land
/// on the most-useful fisheries first:
///   0 — both water level and water temperature
///   1 — water level only
///   2 — water temperature only
///   3 — neither (or no batch entry yet)
/// Ties within a bucket break alphabetically (case-insensitive).
@MainActor
final class ConditionsListOrderingTests: XCTestCase {

  /// All four buckets, alphabetical within each.
  func testSortByConditions_bucketsByMetricAvailability() {
    let sources = [
      "Bulkley", "Skeena", "Babine",       // both
      "Copper", "Kispiox",                  // level only
      "Morice",                             // temp only
      "Lakelse", "Kalum"                    // neither
    ]
    let levelOnly: Set<String> = ["Copper", "Kispiox"]
    let tempOnly: Set<String> = ["Morice"]
    let both: Set<String> = ["Bulkley", "Skeena", "Babine"]

    let ordered = FishingForecastRequestView.sortByConditions(
      sources: sources,
      hasLevel: { both.contains($0) || levelOnly.contains($0) },
      hasTemp:  { both.contains($0) || tempOnly.contains($0) }
    )

    XCTAssertEqual(ordered, [
      "Babine", "Bulkley", "Skeena",  // bucket 0
      "Copper", "Kispiox",            // bucket 1
      "Morice",                       // bucket 2
      "Kalum", "Lakelse"              // bucket 3
    ])
  }

  /// Pre-batch state: `batchConditions` is empty, so `hasLevel`/`hasTemp`
  /// return false for everything. Result must collapse to alphabetical so
  /// the list looks stable until the batch arrives.
  func testSortByConditions_emptyBatch_isAlphabetical() {
    let sources = ["Skeena", "Babine", "Bulkley", "Kalum"]
    let ordered = FishingForecastRequestView.sortByConditions(
      sources: sources,
      hasLevel: { _ in false },
      hasTemp:  { _ in false }
    )
    XCTAssertEqual(ordered, ["Babine", "Bulkley", "Kalum", "Skeena"])
  }

  /// Bucket order is strict: a level-only fishery must rank above a
  /// temp-only fishery even when the temp-only name sorts first
  /// alphabetically. Locks the user-requested precedence.
  func testSortByConditions_levelOnlyBeatsTempOnly_regardlessOfName() {
    let ordered = FishingForecastRequestView.sortByConditions(
      sources: ["Apple", "Zebra"],
      hasLevel: { $0 == "Zebra" },   // Zebra has level only
      hasTemp:  { $0 == "Apple" }    // Apple has temp only
    )
    XCTAssertEqual(ordered, ["Zebra", "Apple"])
  }

  /// Both-metrics fishery must rank above any single-metric fishery, even
  /// when the both-metrics name sorts last alphabetically.
  func testSortByConditions_bothBeatsSingleMetric() {
    let ordered = FishingForecastRequestView.sortByConditions(
      sources: ["Apple", "Banana", "Zebra"],
      hasLevel: { $0 == "Zebra" || $0 == "Apple" },
      hasTemp:  { $0 == "Zebra" || $0 == "Banana" }
    )
    // Zebra has both; Apple has level only; Banana has temp only.
    XCTAssertEqual(ordered, ["Zebra", "Apple", "Banana"])
  }

  /// Alphabetical tiebreak is case-insensitive — guides may type or
  /// configure water bodies with inconsistent casing and the order should
  /// not flip on capital letters.
  func testSortByConditions_alphabeticalTiebreakIsCaseInsensitive() {
    let ordered = FishingForecastRequestView.sortByConditions(
      sources: ["babine", "Bulkley", "BABCOCK"],
      hasLevel: { _ in true },
      hasTemp:  { _ in true }
    )
    XCTAssertEqual(ordered, ["BABCOCK", "babine", "Bulkley"])
  }

  /// Empty input returns empty — guards the Conservation/empty-community
  /// case where no rivers/water bodies are configured.
  func testSortByConditions_emptySourcesReturnsEmpty() {
    let ordered = FishingForecastRequestView.sortByConditions(
      sources: [],
      hasLevel: { _ in true },
      hasTemp:  { _ in true }
    )
    XCTAssertTrue(ordered.isEmpty)
  }
}
