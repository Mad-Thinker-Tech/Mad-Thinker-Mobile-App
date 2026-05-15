import XCTest
@testable import SkeenaSystem

/// Regression coverage for the `MLDiagnostics` provenance blob shipped to the
/// backend under `initialAnalysis.mlDiagnostics`. Pins:
///
/// 1. Codable round-trip — the on-disk `Data` blob persisted on
///    `CatchReport.mlDiagnostics` decodes back to the same struct, so the ML
///    pipeline doesn't silently lose signal between capture and upload.
/// 2. Optional-field encoding — fields that are nil are OMITTED from the
///    encoded JSON (no `null` keys leak server-side). Backend stores this as
///    JSONB so leaving keys absent keeps the column clean and makes future
///    `MLDiagnostics` schema additions cost-free.
/// 3. Nested-collection encoding — `speciesAlternatives`, `handLandmarks`,
///    `stageTimingsMs`, and `modelVersions` all decode/encode in their
///    expected JSON shapes.
/// 4. `CatchReport.mlDiagnostics: Data?` survives a standard Codable
///    round-trip so local catch persistence doesn't drop the blob between
///    `savedLocally` and upload.
final class MLDiagnosticsTests: XCTestCase {

  // MARK: - Codable round-trip

  func testRoundTrip_allFieldsPopulated_recoversIdentically() throws {
    let original = MLDiagnostics(
      speciesConfidence: 0.91,
      lifecycleStageConfidence: 0.62,
      sexConfidence: 0.78,
      lengthAtSpeciesCap: true,
      regressorBypassed: false,
      speciesAlternatives: [
        .init(label: "steelhead_holding", confidence: 0.91, isPrimary: true),
        .init(label: "steelhead_traveler", confidence: 0.07, isPrimary: false),
      ],
      speciesSoftmax: ["steelhead_holding": 0.91, "steelhead_traveler": 0.07, "chinook_salmon": 0.02],
      sexSoftmax: ["female": 0.78, "male": 0.22],
      regressorRawInches: 51.4,
      yoloFishConfidence: 0.88,
      yoloPersonConfidence: 0.94,
      fishBoxAspectRatio: 2.31,
      personFishOverlapRatio: 0.18,
      handLandmarks: [
        .init(handIndex: 0, landmarkIndex: 0, x: 0.5, y: 0.5, z: 0.0, visibility: 0.99, presence: 1.0),
        .init(handIndex: 0, landmarkIndex: 8, x: 0.62, y: 0.41, z: -0.02, visibility: 0.95, presence: 1.0),
      ],
      modelVersions: .init(
        yolo: "yolov8n-fish-2026.03",
        vitSpecies: "vit-tiny-species-2026.04",
        vitSex: "vit-tiny-sex-2026.04",
        lengthRegressor: "regressor-tree-2026.05"
      ),
      stageTimingsMs: [
        .init(stage: "yolo", ms: 38.2),
        .init(stage: "vitSpecies", ms: 91.5),
        .init(stage: "total", ms: 244.0),
      ],
      exifFlashFired: false,
      exifIso: 200,
      exifExposureSeconds: 1.0 / 250.0,
      exifFNumber: 1.8,
      exifFocalLengthMm: 5.7,
      exifFocalLength35mm: 26,
      exifLensModel: "iPhone 15 Pro back triple camera 6.86mm f/1.78",
      computedLuxApprox: 4200
    )

    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(MLDiagnostics.self, from: encoded)

    XCTAssertEqual(decoded, original,
      "Full-population round-trip lost information — diagnostic blob must survive disk/wire serialization byte-for-byte")
  }

  func testRoundTrip_emptyDiagnostics_recoversEmptyDiagnostics() throws {
    let empty = MLDiagnostics()
    let encoded = try JSONEncoder().encode(empty)
    let decoded = try JSONDecoder().decode(MLDiagnostics.self, from: encoded)
    XCTAssertEqual(decoded, empty)
  }

  // MARK: - JSON shape

  func testEncoding_omitsNilFields_keepsBlobLean() throws {
    // Only set two fields; everything else nil. The encoded JSON must not
    // include keys for the nil fields — that would clutter the JSONB column
    // and complicate later analytics over the corpus.
    let partial = MLDiagnostics(speciesConfidence: 0.85, lengthAtSpeciesCap: true)

    let encoded = try JSONEncoder().encode(partial)
    let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    XCTAssertNotNil(json)

    XCTAssertEqual(json?.keys.sorted(), ["lengthAtSpeciesCap", "speciesConfidence"],
      "Encoded JSON must contain only populated keys; nil-valued fields should be absent. Actual keys: \(json?.keys.sorted() ?? [])")
  }

  func testEncoding_speciesAlternatives_serializesAsArrayOfObjects() throws {
    let diagnostics = MLDiagnostics(speciesAlternatives: [
      .init(label: "steelhead_holding", confidence: 0.88, isPrimary: true),
      .init(label: "rainbow_trout", confidence: 0.09, isPrimary: false),
    ])

    let encoded = try JSONEncoder().encode(diagnostics)
    let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    let alternatives = json?["speciesAlternatives"] as? [[String: Any]]

    XCTAssertEqual(alternatives?.count, 2)
    XCTAssertEqual(alternatives?[0]["label"] as? String, "steelhead_holding")
    XCTAssertEqual(alternatives?[0]["isPrimary"] as? Bool, true)
    XCTAssertEqual(alternatives?[1]["isPrimary"] as? Bool, false)
  }

  func testEncoding_modelVersions_serializesAsNestedObject() throws {
    let diagnostics = MLDiagnostics(modelVersions: .init(
      yolo: "yolo-1", vitSpecies: "vit-spec-2", vitSex: "vit-sex-3", lengthRegressor: "reg-4"
    ))

    let encoded = try JSONEncoder().encode(diagnostics)
    let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    let versions = json?["modelVersions"] as? [String: Any]

    XCTAssertEqual(versions?["yolo"] as? String, "yolo-1")
    XCTAssertEqual(versions?["vitSpecies"] as? String, "vit-spec-2")
    XCTAssertEqual(versions?["vitSex"] as? String, "vit-sex-3")
    XCTAssertEqual(versions?["lengthRegressor"] as? String, "reg-4")
  }

  // MARK: - CatchReport persistence

  func testCatchReport_mlDiagnosticsField_survivesCodableRoundTrip() throws {
    let diagnostics = MLDiagnostics(
      speciesConfidence: 0.91,
      lengthAtSpeciesCap: true,
      regressorBypassed: false
    )
    let blob = try JSONEncoder().encode(diagnostics)

    let report = CatchReport(
      id: UUID(),
      memberId: "M-test-1",
      lengthInches: 30,
      mlDiagnostics: blob
    )

    let encoded = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(CatchReport.self, from: encoded)

    XCTAssertEqual(decoded.mlDiagnostics, blob,
      "CatchReport.mlDiagnostics must round-trip through the same Codable path used by local catch persistence; otherwise pending uploads lose the diagnostic blob between capture and online sync")

    let recoveredDiagnostics = try JSONDecoder().decode(MLDiagnostics.self, from: decoded.mlDiagnostics ?? Data())
    XCTAssertEqual(recoveredDiagnostics, diagnostics)
  }

  func testCatchReport_nilMLDiagnostics_decodesCleanly() throws {
    // Legacy reports on disk pre-date this field; they decode with
    // `mlDiagnostics == nil`. Pin the contract so future schema changes
    // don't accidentally make the field required.
    let report = CatchReport(id: UUID(), memberId: "M-legacy", lengthInches: 20)
    let encoded = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(CatchReport.self, from: encoded)
    XCTAssertNil(decoded.mlDiagnostics)
  }
}
