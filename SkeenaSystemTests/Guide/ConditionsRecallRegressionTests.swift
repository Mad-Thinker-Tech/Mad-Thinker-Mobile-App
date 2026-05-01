// ConditionsRecallRegressionTests.swift
// SkeenaSystemTests
//
// Regression tests for the conditions-recall fishery map (GuideFisheryMapView):
//   • Role gate — only guides can open the map (anglers/public/researchers
//     never see the entry point on FishingForecastResultView).
//   • Fuzzy river-name normalization — abbreviations / casing / punctuation
//     fold into the same canonical core.
//   • ±10% variance math — the on-screen "Pins within ±10%" claim is honest.
//   • MapReportDTO decoding — new fields (river, water_temp_c, water_level_ft)
//     are picked up from the response and missing fields decode as nil.
//
// These are pure value-type tests; no UI rendering, no Mapbox.

import XCTest
@testable import SkeenaSystem

@MainActor
final class ConditionsRecallRegressionTests: XCTestCase {

  // MARK: - Role gate (guide-only entry point)

  /// CRITICAL: the conditions-recall map exposes per-fishery historical
  /// catch / no-catch data. Other roles must not see the entry point.
  func testCanAccess_isTrueForGuide() {
    XCTAssertTrue(GuideFisheryMapView.canAccess(role: .guide))
  }

  func testCanAccess_isFalseForAngler() {
    XCTAssertFalse(GuideFisheryMapView.canAccess(role: .angler))
  }

  func testCanAccess_isFalseForPublic() {
    XCTAssertFalse(GuideFisheryMapView.canAccess(role: .public))
  }

  func testCanAccess_isFalseForResearcher() {
    XCTAssertFalse(GuideFisheryMapView.canAccess(role: .researcher))
  }

  /// Signed-out / unknown role must also be denied — there is no "default
  /// open" path to the map.
  func testCanAccess_isFalseForNilRole() {
    XCTAssertFalse(GuideFisheryMapView.canAccess(role: nil))
  }

  /// Lock the contract across every UserType. If a new role ships, this
  /// asserts the gate stays exact-match-on-guide rather than silently
  /// admitting the new case.
  func testCanAccess_onlyGuideAcrossAllUserTypes() {
    let allowed = AuthService.UserType.allCases.filter {
      GuideFisheryMapView.canAccess(role: $0)
    }
    XCTAssertEqual(allowed, [.guide])
  }

  // MARK: - Fuzzy river-name normalization

  func testNormalizeRiverName_stripsTrailingRiverSuffix() {
    XCTAssertEqual(GuideFisheryMapView.normalizeRiverName("Skeena River"), "skeena")
  }

  func testNormalizeRiverName_collapsesAbbreviation() {
    XCTAssertEqual(GuideFisheryMapView.normalizeRiverName("Skeena R."), "skeena")
  }

  func testNormalizeRiverName_isCaseInsensitive() {
    XCTAssertEqual(GuideFisheryMapView.normalizeRiverName("SKEENA river"), "skeena")
  }

  func testNormalizeRiverName_collapsesWhitespaceAndPunctuation() {
    XCTAssertEqual(GuideFisheryMapView.normalizeRiverName("skeena  river!"), "skeena")
  }

  func testNormalizeRiverName_preservesMultiWordCore() {
    XCTAssertEqual(
      GuideFisheryMapView.normalizeRiverName("Little Skeena Cr."),
      "little skeena"
    )
  }

  func testNormalizeRiverName_handlesAllSupportedSuffixes() {
    let cases: [(String, String)] = [
      ("Eagle Creek",  "eagle"),
      ("Eagle Cr.",    "eagle"),
      ("Stuart Lake",  "stuart"),
      ("Stuart Lk.",   "stuart"),
      ("Cold Stream",  "cold"),
      ("Cold Brook",   "cold"),
      ("Hood Canal",   "hood"),
      ("Puget Sound",  "puget"),
      ("Saanich Inlet", "saanich"),
      ("Tillamook Bay", "tillamook"),
      ("Big Pond",     "big"),
      ("Lost Lagoon",  "lost"),
    ]
    for (input, expected) in cases {
      XCTAssertEqual(
        GuideFisheryMapView.normalizeRiverName(input),
        expected,
        "Expected \"\(input)\" → \"\(expected)\""
      )
    }
  }

  func testNormalizeRiverName_passesThroughBareName() {
    XCTAssertEqual(GuideFisheryMapView.normalizeRiverName("Eagle"), "eagle")
  }

  func testNormalizeRiverName_emptyInputReturnsEmpty() {
    XCTAssertEqual(GuideFisheryMapView.normalizeRiverName(""), "")
  }

  /// Both sides of the compare go through the same function — variant pairs
  /// must collapse to the same core so the river filter accepts them.
  func testNormalizeRiverName_variantsCollapseToSameCore() {
    let variants = ["Skeena River", "Skeena R.", "skeena  river!", "SKEENA RIVER"]
    let cores = Set(variants.map(GuideFisheryMapView.normalizeRiverName))
    XCTAssertEqual(cores, ["skeena"])
  }

  /// Documents the known trade-off: distinct fisheries that share a leading
  /// word and differ only in suffix collide. Keep this test so a future
  /// refactor that "fixes" the collision (good!) flags this acceptance
  /// criterion for review.
  func testNormalizeRiverName_knownCollision_HoodRiver_HoodCanal() {
    let core1 = GuideFisheryMapView.normalizeRiverName("Hood River")
    let core2 = GuideFisheryMapView.normalizeRiverName("Hood Canal")
    XCTAssertEqual(core1, core2,
                   "Known limitation — distinct water bodies with shared leading word collapse")
  }

  // MARK: - ±10% variance math

  func testWithinTenPercent_equalValuesPass() {
    XCTAssertTrue(GuideFisheryMapView.withinTenPercent(report: 9.5, current: 9.5))
  }

  func testWithinTenPercent_belowTenPercentPasses() {
    // |9.5 - 10| = 0.5; tolerance = 1.0 → passes
    XCTAssertTrue(GuideFisheryMapView.withinTenPercent(report: 9.5, current: 10.0))
  }

  func testWithinTenPercent_exactlyTenPercentPasses() {
    // |9.0 - 10| = 1.0; tolerance = 1.0 → passes (≤ boundary inclusive)
    XCTAssertTrue(GuideFisheryMapView.withinTenPercent(report: 9.0, current: 10.0))
  }

  func testWithinTenPercent_aboveTenPercentFails() {
    // |8.9 - 10| = 1.1; tolerance = 1.0 → fails
    XCTAssertFalse(GuideFisheryMapView.withinTenPercent(report: 8.9, current: 10.0))
  }

  func testWithinTenPercent_symmetricAroundCurrent() {
    XCTAssertTrue(GuideFisheryMapView.withinTenPercent(report: 11.0, current: 10.0))
    XCTAssertFalse(GuideFisheryMapView.withinTenPercent(report: 11.1, current: 10.0))
  }

  /// Sub-zero water temperatures are real (winter steelhead). The math uses
  /// |current| for tolerance so cold values still produce the expected band.
  func testWithinTenPercent_handlesNegativeCurrent() {
    // current = -5, tolerance = 0.5 → -5.5 to -4.5 passes
    XCTAssertTrue(GuideFisheryMapView.withinTenPercent(report: -4.6, current: -5.0))
    XCTAssertFalse(GuideFisheryMapView.withinTenPercent(report: -4.0, current: -5.0))
  }

  /// Edge case: current = 0 collapses tolerance to 0. Only an exact-zero
  /// report passes. Surfaces if a freshwater gauge briefly reads zero.
  func testWithinTenPercent_zeroCurrentRequiresExactReport() {
    XCTAssertTrue(GuideFisheryMapView.withinTenPercent(report: 0.0, current: 0.0))
    XCTAssertFalse(GuideFisheryMapView.withinTenPercent(report: 0.01, current: 0.0))
  }

  // MARK: - MapReportDTO decoding (new fields)

  /// Full payload — all three new fields present. Verifies snake_case
  /// (`water_temp_c`, `water_level_ft`) keys decode into camelCase Swift
  /// properties.
  func testMapReportDTO_decodesNewFields() throws {
    let json = #"""
    {
      "id": "abc-123",
      "type": "catch",
      "date": "2026-04-30T14:00:00.000Z",
      "latitude": 54.6,
      "longitude": -127.6,
      "river": "Skeena River",
      "water_temp_c": 9.2,
      "water_level_ft": 4.3,
      "species": "Steelhead",
      "lengthInches": 32,
      "memberId": "MAD4ZQ7H9"
    }
    """#.data(using: .utf8)!

    let dto = try JSONDecoder().decode(MapReportDTO.self, from: json)
    XCTAssertEqual(dto.id, "abc-123")
    XCTAssertEqual(dto.river, "Skeena River")
    XCTAssertEqual(dto.waterTempC, 9.2)
    XCTAssertEqual(dto.waterLevelFt, 4.3)
  }

  /// Older / un-enriched reports return null for the new fields. Decoding
  /// must succeed with the optionals as nil — neither the conditions-recall
  /// view nor the existing GuideFullMapView should crash on these.
  func testMapReportDTO_decodesNullNewFields() throws {
    let json = #"""
    {
      "id": "abc-123",
      "type": "passed",
      "date": "2026-04-30T14:00:00.000Z",
      "latitude": 54.6,
      "longitude": -127.6,
      "river": null,
      "water_temp_c": null,
      "water_level_ft": null
    }
    """#.data(using: .utf8)!

    let dto = try JSONDecoder().decode(MapReportDTO.self, from: json)
    XCTAssertNil(dto.river)
    XCTAssertNil(dto.waterTempC)
    XCTAssertNil(dto.waterLevelFt)
  }

  /// Backwards compat: older response variants that omit the new fields
  /// entirely still decode (the keys are absent, not just null). Guards
  /// against a regression where adding the new fields makes them required.
  func testMapReportDTO_decodesMissingNewFieldsAsNil() throws {
    let json = #"""
    {
      "id": "abc-123",
      "type": "catch",
      "date": "2026-04-30T14:00:00.000Z",
      "latitude": 54.6,
      "longitude": -127.6
    }
    """#.data(using: .utf8)!

    let dto = try JSONDecoder().decode(MapReportDTO.self, from: json)
    XCTAssertNil(dto.river)
    XCTAssertNil(dto.waterTempC)
    XCTAssertNil(dto.waterLevelFt)
  }
}
