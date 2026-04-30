import XCTest
@testable import SkeenaSystem

/// Regression tests for the ML-pipeline species contracts that are easy to
/// silently break and hard to detect at runtime:
///
/// - `speciesLabels` order. The Python `ImageFolder` training pipeline assigns
///   class indices alphabetically; the LengthRegressor consumes
///   `species_index` as a feature. Inserting/reordering labels without
///   retraining silently degrades length predictions.
/// - `regressorBypassSpecies`. Previously declared inline at two sites in
///   CatchPhotoAnalyzer.swift and easy to drift; consolidated into a single
///   static set whose membership we lock here.
/// - `CatchChatViewModel.speciesDisplayNames`. Must stay in lockstep with
///   `speciesLabels` so a model class always renders to a user-facing name.
/// - The below-threshold sentinel string ("Species: Unable to confidently
///   detect"). The chat parser depends on this exact phrase to bypass the
///   species-name lookup; if the producer drifts, the parser silently treats
///   the sentinel as a species name.
///
/// When you add a new species, this file is the "lockstep checklist" — every
/// failing test names exactly which file/edit was missed. See
/// docs/new-species-onboarding.md and `/new-species`.
final class CatchPhotoAnalyzerSpeciesRegressionTests: XCTestCase {

  // MARK: - speciesLabels

  /// The training pipeline assigns class indices in alphabetical order over
  /// `ImageFolder`'s subdirectory names. If this array drifts from that order
  /// (e.g. a new label appended at the end instead of inserted), the
  /// LengthRegressor's `species_index` feature points at the wrong class.
  func testSpeciesLabels_areAlphabeticallyOrdered() {
    let labels = CatchPhotoAnalyzer.speciesLabels
    XCTAssertEqual(labels, labels.sorted(),
                   "speciesLabels must stay in alphabetical order to match Python ImageFolder training. Did you append a new species at the end instead of inserting it?")
  }

  /// Locks the exact 9-class set — any addition or removal here is a deliberate
  /// model retrain and must update this assertion in lockstep.
  func testSpeciesLabels_exactSet() {
    XCTAssertEqual(
      Set(CatchPhotoAnalyzer.speciesLabels),
      Set([
        "atlantic_salmon_holding",
        "atlantic_salmon_traveler",
        "brown_trout",
        "chinook_salmon",
        "lingcod",
        "other",
        "sea_run_trout",
        "steelhead_holding",
        "steelhead_traveler"
      ]),
      "Adding/removing a species requires retraining ViTFishSpecies AND LengthRegressor — see docs/new-species-onboarding.md"
    )
  }

  func testSpeciesLabels_brownTroutAtIndex2() {
    XCTAssertEqual(CatchPhotoAnalyzer.speciesLabels[2], "brown_trout",
                   "Alphabetical order: brown_trout should sit at index 2, between atlantic_salmon_traveler (1) and chinook_salmon (3)")
  }

  func testSpeciesLabels_chinookSalmonAtIndex3() {
    XCTAssertEqual(CatchPhotoAnalyzer.speciesLabels[3], "chinook_salmon",
                   "Alphabetical order: chinook_salmon should sit at index 3, between brown_trout (2) and lingcod (4)")
  }

  func testSpeciesLabels_lingcodAtIndex4() {
    XCTAssertEqual(CatchPhotoAnalyzer.speciesLabels[4], "lingcod",
                   "Alphabetical order: lingcod should sit at index 4, between chinook_salmon (3) and other (5)")
  }

  // MARK: - regressorBypassSpecies

  /// Species in this set use the heuristic length estimator instead of the
  /// CoreML regressor — typically because we don't have enough training data
  /// to calibrate the regressor for that class yet.
  func testRegressorBypassSpecies_includesAllUncalibratedClasses() {
    let bypass = CatchPhotoAnalyzer.regressorBypassSpecies
    XCTAssertTrue(bypass.contains("atlantic_salmon_holding"))
    XCTAssertTrue(bypass.contains("atlantic_salmon_traveler"))
    XCTAssertTrue(bypass.contains("brown_trout"))
    XCTAssertTrue(bypass.contains("chinook_salmon"))
    XCTAssertTrue(bypass.contains("lingcod"))
    XCTAssertTrue(bypass.contains("sea_run_trout"))
    XCTAssertTrue(bypass.contains("other"))
  }

  /// Steelhead is the calibrated class — both lifecycle stages must run
  /// through the regressor.
  func testRegressorBypassSpecies_excludesSteelheadStages() {
    XCTAssertFalse(CatchPhotoAnalyzer.regressorBypassSpecies.contains("steelhead_holding"),
                   "Steelhead is the regressor's calibrated class — bypass would skip the model")
    XCTAssertFalse(CatchPhotoAnalyzer.regressorBypassSpecies.contains("steelhead_traveler"))
  }

  /// Every member of `regressorBypassSpecies` must be a valid `speciesLabels`
  /// entry. A typo in the bypass set silently fails to match anything.
  func testRegressorBypassSpecies_allMembersAreValidSpeciesLabels() {
    let validLabels = Set(CatchPhotoAnalyzer.speciesLabels)
    for label in CatchPhotoAnalyzer.regressorBypassSpecies {
      XCTAssertTrue(validLabels.contains(label),
                    "regressorBypassSpecies contains '\(label)' which is not in speciesLabels — typo or stale entry")
    }
  }

  // MARK: - speciesDisplayNames lockstep

  /// Every species in the model output (after stripping the lifecycle suffix)
  /// must have a user-facing display name. A missing entry silently falls back
  /// to `.capitalized`, which produces ugly strings like "Sea_Run_Trout".
  func testSpeciesDisplayNames_coversAllModelLabels() {
    let displayMap = CatchChatViewModel.speciesDisplayNames

    for rawLabel in CatchPhotoAnalyzer.speciesLabels {
      // Mirror the analyzer's transform: underscores → spaces, then strip the
      // trailing lifecycle stage if present.
      let humanized = rawLabel.replacingOccurrences(of: "_", with: " ")
      let stripped = humanized
        .replacingOccurrences(of: " holding", with: "")
        .replacingOccurrences(of: " traveler", with: "")

      XCTAssertNotNil(displayMap[stripped],
                      "speciesDisplayNames is missing key '\(stripped)' for model label '\(rawLabel)' — add to CatchChatViewModel.speciesDisplayNames")
    }
  }

  func testSpeciesDisplayNames_chinookSalmon() {
    XCTAssertEqual(CatchChatViewModel.speciesDisplayNames["chinook salmon"], "Chinook Salmon")
  }

  func testSpeciesDisplayNames_lingcod() {
    XCTAssertEqual(CatchChatViewModel.speciesDisplayNames["lingcod"], "Lingcod")
  }

  func testSpeciesDisplayNames_otherMapsToBicatch() {
    // Public-facing copy uses "Bi-catch" rather than "Other" for the catch-all
    // class. Lock it in — UI copy regressions would otherwise pass silently.
    XCTAssertEqual(CatchChatViewModel.speciesDisplayNames["other"], "Bi-catch")
  }

  // The below-threshold sentinel handshake (analyzer emits "Species: Unable
  // to confidently detect" when ViT confidence < SPECIES_DETECTION_THRESHOLD,
  // and the chat parser bypasses species-name lookup on lowercased
  // "unable to") is verified in CatchChatViewModelTests so the parser side
  // can use the setUp-managed view model. Don't duplicate it here.
}
