import XCTest
@testable import SkeenaSystem

/// Unit tests for ResearcherCatchFlowManager's input validation:
/// profanity rejection, unparseable identification, non-numeric
/// length/girth handling, and the ≥3-letter species fallback threshold.
@MainActor
final class ResearcherCatchFlowManagerTests: XCTestCase {

  private var flow: ResearcherCatchFlowManager!

  override func setUp() {
    super.setUp()
    flow = ResearcherCatchFlowManager()
  }

  override func tearDown() {
    flow = nil
    super.tearDown()
  }

  /// Helper: initialize the flow with typical ML analysis values and land
  /// on the identification step, ready for applyEdit tests.
  private func initializeAtIdentification(
    species: String? = "Steelhead",
    length: Double? = 30
  ) {
    flow.initialize(
      species: species,
      lifecycleStage: nil,
      sex: nil,
      lengthInches: length,
      riverName: "Bulkley"
    )
    XCTAssertEqual(flow.currentStep, .identification)
  }

  /// Helper: advance past identification to the confirmLength step.
  private func advanceToConfirmLength(species: String? = "Steelhead", length: Double? = 30) {
    initializeAtIdentification(species: species, length: length)
    _ = flow.confirm() // identification → confirmLength
    XCTAssertEqual(flow.currentStep, .confirmLength)
  }

  /// Helper: advance past confirmLength to the confirmGirth step.
  private func advanceToConfirmGirth() {
    advanceToConfirmLength()
    _ = flow.confirm() // confirmLength → confirmGirth
    XCTAssertEqual(flow.currentStep, .confirmGirth)
  }

  /// Helper: advance to the floyTagID step via study selection.
  private func advanceToFloyTagID() {
    advanceToConfirmGirth()
    _ = flow.confirm() // confirmGirth → finalSummary
    XCTAssertEqual(flow.currentStep, .finalSummary)
    _ = flow.confirm() // finalSummary → studyParticipation
    XCTAssertEqual(flow.currentStep, .studyParticipation)
    _ = flow.selectStudy(.floy) // → floyTagID
    XCTAssertEqual(flow.currentStep, .floyTagID)
  }

  /// Helper: advance to the envelopeScan step via the contents-picker. Defaults
  /// to `.scale` contents — tests that don't care about contents can use this;
  /// tests that do should call `advanceToEnvelopeScan(contents:)` directly.
  private func advanceToEnvelopeScan(
    contents: ResearcherCatchFlowManager.SampleContents = .scale
  ) {
    advanceToConfirmGirth()
    _ = flow.confirm() // → finalSummary
    _ = flow.confirm() // → studyParticipation
    _ = flow.confirm() // skip study → sampleCollection
    XCTAssertEqual(flow.currentStep, .sampleCollection)
    // sampleCollection "Yes" is wired in the view model (advances to
    // .envelopeContents). At the flow-manager level we set the step directly
    // and call selectEnvelopeContents so the same advance semantics apply.
    flow.currentStep = .envelopeContents
    _ = flow.selectEnvelopeContents(contents)
    XCTAssertEqual(flow.currentStep, .envelopeScan)
  }

  // MARK: - Profanity rejection per step

  func testProfanity_identification_rejected() {
    initializeAtIdentification()
    let originalSpecies = flow.species

    let result = flow.applyEdit("fuck this fish")

    XCTAssertFalse(result.recognized, "Profane input must be rejected")
    XCTAssertFalse(result.autoAdvance)
    XCTAssertEqual(flow.currentStep, .identification, "Step must not advance on profanity")
    XCTAssertEqual(flow.species, originalSpecies, "Species must not be mutated by profane input")
    XCTAssertTrue(result.message.contains("keep it civil"), "Rejection message must contain 'keep it civil'")
  }

  func testProfanity_confirmLength_rejected() {
    advanceToConfirmLength()
    let originalLength = flow.lengthInches

    let result = flow.applyEdit("shit 32")

    XCTAssertFalse(result.recognized)
    XCTAssertEqual(flow.currentStep, .confirmLength)
    XCTAssertEqual(flow.lengthInches, originalLength, "Length must not be mutated by profane input")
    XCTAssertTrue(result.message.contains("keep it civil"))
  }

  func testProfanity_confirmGirth_rejected() {
    advanceToConfirmGirth()
    let originalGirth = flow.girthInches

    let result = flow.applyEdit("bullshit")

    XCTAssertFalse(result.recognized)
    XCTAssertEqual(flow.currentStep, .confirmGirth)
    XCTAssertEqual(flow.girthInches, originalGirth)
    XCTAssertTrue(result.message.contains("keep it civil"))
  }

  func testProfanity_floyTagID_rejected() {
    advanceToFloyTagID()

    let result = flow.applyEdit("asshole")

    XCTAssertFalse(result.recognized)
    XCTAssertEqual(flow.currentStep, .floyTagID)
    XCTAssertNil(flow.floyTagNumber, "Floy tag must not be set from profane input")
    XCTAssertTrue(result.message.contains("keep it civil"))
  }

  func testProfanity_envelopeScan_rejected() {
    advanceToEnvelopeScan()

    let result = flow.applyEdit("dick")

    XCTAssertFalse(result.recognized)
    XCTAssertEqual(flow.currentStep, .envelopeScan)
    XCTAssertNil(flow.envelopeBarcode)
    XCTAssertTrue(result.message.contains("keep it civil"))
  }

  // MARK: - Envelope-based sample collection

  /// One envelope, scale-only contents: applyEdit captures the typed barcode
  /// and confirm() advances straight to voice memo (no second scan step).
  func testEnvelopeScan_typedScaleOnly_advancesToVoiceMemo() {
    advanceToEnvelopeScan(contents: .scale)
    XCTAssertEqual(flow.sampleContents, .scale)

    let edit = flow.applyEdit("SMP-A7K3F9")
    XCTAssertTrue(edit.recognized)
    XCTAssertEqual(flow.envelopeBarcode, "SMP-A7K3F9")

    _ = flow.confirm()
    XCTAssertEqual(flow.currentStep, .voiceMemo)
  }

  /// "Both" contents still produces a single envelope barcode — the contents
  /// declaration is what tells the upload mapping to populate both legacy
  /// fields. Verifies the flow doesn't accidentally re-introduce a second
  /// scan step.
  func testEnvelopeScan_bothContents_singleScanAdvancesToVoiceMemo() {
    advanceToEnvelopeScan(contents: .both)
    XCTAssertEqual(flow.sampleContents, .both)

    _ = flow.applyEdit("SMP-B2M8Q1")
    _ = flow.confirm()
    XCTAssertEqual(flow.currentStep, .voiceMemo)
    XCTAssertEqual(flow.envelopeBarcode, "SMP-B2M8Q1")
  }

  /// The scanner-sheet entry point bypasses applyEdit — `recordScannedEnvelope`
  /// stores the parsed ID directly and produces the same confirmation copy as
  /// the manual-entry path. Guards against the chat view drifting away from the
  /// flow manager's storage shape.
  func testEnvelopeScan_recordScanned_storesBarcodeAndPromptsConfirmation() {
    advanceToEnvelopeScan(contents: .finClip)

    let message = flow.recordScannedEnvelope(id: "A7K3F9")

    XCTAssertEqual(flow.envelopeBarcode, "A7K3F9")
    XCTAssertTrue(message.contains("Envelope: A7K3F9"))
    XCTAssertTrue(message.contains("fin clip"))
  }

  /// Sample-contents wire format mirrors the planned backend `sampleContents`
  /// payload. If this test fails, the upload mapping in CatchChatViewModel and
  /// the Loveable backend contract have diverged.
  func testSampleContents_wireValuesMatchBackendShape() {
    XCTAssertEqual(ResearcherCatchFlowManager.SampleContents.scale.wireValues, ["scale"])
    XCTAssertEqual(ResearcherCatchFlowManager.SampleContents.finClip.wireValues, ["fin_clip"])
    XCTAssertEqual(ResearcherCatchFlowManager.SampleContents.both.wireValues, ["scale", "fin_clip"])
  }

  func testContainsProfanity_standaloneMatch() {
    XCTAssertTrue(ResearcherCatchFlowManager.containsProfanity("fuck"))
    XCTAssertTrue(ResearcherCatchFlowManager.containsProfanity("SHIT"))
    XCTAssertTrue(ResearcherCatchFlowManager.containsProfanity("What the fuck"))
  }

  func testContainsProfanity_punctuationSplit() {
    // "fuck!" splits into ["fuck"] — should match
    XCTAssertTrue(ResearcherCatchFlowManager.containsProfanity("fuck!"))
    // "f***ing" splits into ["f", "ing"] — should NOT match (partial tokens)
    XCTAssertFalse(ResearcherCatchFlowManager.containsProfanity("f***ing"))
  }

  func testContainsProfanity_cleanInput() {
    XCTAssertFalse(ResearcherCatchFlowManager.containsProfanity("Steelhead"))
    XCTAssertFalse(ResearcherCatchFlowManager.containsProfanity("rainbow trout female"))
    XCTAssertFalse(ResearcherCatchFlowManager.containsProfanity("32"))
    XCTAssertFalse(ResearcherCatchFlowManager.containsProfanity(""))
  }

  // MARK: - Unparseable identification

  func testIdentification_singleLetter_rejected() {
    initializeAtIdentification()
    let originalSpecies = flow.species

    let result = flow.applyEdit("x")

    XCTAssertFalse(result.recognized, "Single letter must be rejected")
    XCTAssertEqual(flow.species, originalSpecies, "Species must not change on single-letter input")
    XCTAssertTrue(result.message.contains("didn't catch that"))
  }

  func testIdentification_twoLetters_rejected() {
    initializeAtIdentification()
    let originalSpecies = flow.species

    let result = flow.applyEdit("xx")

    XCTAssertFalse(result.recognized, "Two-letter input must be rejected")
    XCTAssertEqual(flow.species, originalSpecies)
  }

  func testIdentification_emptyString_rejected() {
    initializeAtIdentification()

    let result = flow.applyEdit("")

    XCTAssertFalse(result.recognized, "Empty input must be rejected")
  }

  func testIdentification_whitespaceOnly_rejected() {
    initializeAtIdentification()

    let result = flow.applyEdit("   ")

    XCTAssertFalse(result.recognized, "Whitespace-only input must be rejected")
  }

  func testIdentification_knownSpecies_recognized() {
    initializeAtIdentification(species: nil)

    let result = flow.applyEdit("steelhead")

    XCTAssertTrue(result.recognized)
    XCTAssertEqual(flow.species, "Steelhead")
    XCTAssertEqual(flow.currentStep, .identification, "Identification stays until user confirms")
  }

  // MARK: - Non-numeric length/girth

  func testLength_pureText_rejected() {
    advanceToConfirmLength()

    let result = flow.applyEdit("big fish")

    XCTAssertFalse(result.recognized, "Non-numeric length must be rejected")
    XCTAssertEqual(flow.currentStep, .confirmLength, "Must stay on confirmLength")
    XCTAssertTrue(result.message.contains("didn't catch that"))
  }

  func testLength_validNumber_advances() {
    advanceToConfirmLength()

    let result = flow.applyEdit("32")

    XCTAssertTrue(result.recognized)
    XCTAssertTrue(result.autoAdvance)
    XCTAssertEqual(flow.currentStep, .confirmGirth)
    XCTAssertEqual(flow.lengthInches, 32)
  }

  func testLength_embeddedNumber_extracted() {
    advanceToConfirmLength()

    let result = flow.applyEdit("about 28 inches")

    XCTAssertTrue(result.recognized)
    XCTAssertTrue(result.autoAdvance)
    XCTAssertEqual(flow.lengthInches, 28)
    XCTAssertEqual(flow.currentStep, .confirmGirth)
  }

  func testGirth_pureText_rejected() {
    advanceToConfirmGirth()

    let result = flow.applyEdit("not sure")

    XCTAssertFalse(result.recognized)
    XCTAssertEqual(flow.currentStep, .confirmGirth, "Must stay on confirmGirth")
    XCTAssertTrue(result.message.contains("didn't catch that"))
  }

  func testGirth_validNumber_advances() {
    advanceToConfirmGirth()

    let result = flow.applyEdit("14.5")

    XCTAssertTrue(result.recognized)
    XCTAssertTrue(result.autoAdvance)
    XCTAssertEqual(flow.currentStep, .finalSummary)
    XCTAssertEqual(flow.girthInches, 14.5)
    XCTAssertFalse(flow.girthIsEstimated, "User-entered girth must not be flagged as estimated")
  }

  func testGirth_embeddedNumber_extracted() {
    advanceToConfirmGirth()

    let result = flow.applyEdit("measured 15 inches")

    XCTAssertTrue(result.recognized)
    XCTAssertEqual(flow.girthInches, 15)
    XCTAssertEqual(flow.currentStep, .finalSummary)
  }

  // MARK: - ≥3-letter fallback threshold

  func testFallback_twoCharCandidate_rejected() {
    initializeAtIdentification(species: "Steelhead")
    let originalSpecies = flow.species

    // "ab" is 2 chars after stripping noise words — below threshold
    let result = flow.applyEdit("ab")

    XCTAssertFalse(result.recognized)
    XCTAssertEqual(flow.species, originalSpecies, "Species must not change for <3-char candidate")
  }

  func testFallback_threeCharCandidate_accepted() {
    initializeAtIdentification(species: nil)

    let result = flow.applyEdit("abc")

    XCTAssertTrue(result.recognized, "≥3-char unknown word must be accepted as species")
    XCTAssertEqual(flow.species, "abc")
  }

  func testFallback_noiseStrippedBelow3_sexStillRecognized() {
    // "male x" — species candidate after stripping "male" is "x" (1 char, rejected),
    // but sex = Male should still be recognized.
    initializeAtIdentification(species: "Steelhead")
    let originalSpecies = flow.species

    let result = flow.applyEdit("male x")

    XCTAssertTrue(result.recognized, "Sex keyword must still be recognized even if species candidate is too short")
    XCTAssertEqual(flow.sex, "Male")
    XCTAssertEqual(flow.species, originalSpecies, "Species must not change when leftover is <3 chars")
  }

  func testFallback_multiWordUnknown_accepted() {
    initializeAtIdentification(species: nil)

    let result = flow.applyEdit("tiger muskie")

    XCTAssertTrue(result.recognized)
    XCTAssertEqual(flow.species, "tiger muskie")
  }

  // MARK: - Location corrections

  /// Regression test for the original bug: typing a location correction
  /// during the identification step used to overwrite the species field via
  /// the ungated ≥3-char species fallback. Location edits must NOT mutate
  /// species.
  func testLocation_correctionDoesNotOverwriteSpecies() {
    initializeAtIdentification(species: "Steelhead")

    let result = flow.applyEdit("Columbia River")

    XCTAssertTrue(result.recognized)
    XCTAssertEqual(flow.species, "Steelhead", "Species must NOT be overwritten by a location correction")
    XCTAssertEqual(flow.riverName, "Columbia River")
    XCTAssertTrue(flow.riverNameWasCorrected)
  }

  func testLocation_waterBodyToken_setsRiverName() {
    initializeAtIdentification()

    let result = flow.applyEdit("Kispiox River")

    XCTAssertTrue(result.recognized)
    XCTAssertEqual(flow.riverName, "Kispiox River")
    XCTAssertTrue(flow.riverNameWasCorrected)
  }

  func testLocation_explicitPrefix_setsRiverName() {
    initializeAtIdentification()

    let result = flow.applyEdit("location: Morice")

    XCTAssertTrue(result.recognized)
    XCTAssertEqual(flow.riverName, "Morice")
    XCTAssertTrue(flow.riverNameWasCorrected)
  }

  /// Covers the broader water-body keyword set — rivers, coastal bodies,
  /// and canals all need to route to the location field. One representative
  /// from each category is enough for wiring coverage.
  ///
  /// Reuses the shared `flow` from `setUp` rather than allocating a fresh
  /// ResearcherCatchFlowManager per iteration: rapid-fire MainActor-isolated
  /// deinits trigger the `swift_task_deinitOnExecutorMainActorBackDeploy`
  /// malloc-free crash on the iOS 26.2 simulator (see CLAUDE.md).
  func testLocation_variousWaterBodyKeywords_recognized() {
    let cases: [(input: String, expected: String)] = [
      ("Howe Sound",        "Howe Sound"),
      ("Tofino Inlet",      "Tofino Inlet"),
      ("Rideau Canal",      "Rideau Canal"),
      ("Deschutes Creek",   "Deschutes Creek"),
      ("Lake Simcoe",       "Lake Simcoe"),
      ("Pacific Estuary",   "Pacific Estuary"),
    ]

    for (input, expected) in cases {
      flow.initialize(
        species: "Steelhead",
        lifecycleStage: nil,
        sex: nil,
        lengthInches: 30,
        riverName: "Bulkley"
      )
      let r = flow.applyEdit(input)
      XCTAssertTrue(r.recognized, "Should recognize '\(input)' as a location")
      XCTAssertEqual(flow.riverName, expected, "Should capture '\(expected)' as riverName")
      XCTAssertEqual(flow.species, "Steelhead", "Species must stay unchanged for '\(input)'")
    }
  }

  /// "brook" is both a known species (Brook Trout) AND a water-body keyword.
  /// Species lookup must run first so a bare "brook" stays a species.
  func testLocation_brookResolvesAsSpecies_notLocation() {
    initializeAtIdentification(species: nil)
    let originalRiver = flow.riverName

    let result = flow.applyEdit("brook")

    XCTAssertTrue(result.recognized)
    XCTAssertEqual(flow.species, "Brook Trout", "'brook' must resolve as Brook Trout, not a water-body")
    XCTAssertEqual(flow.riverName, originalRiver, "riverName must not change when the input is a known species")
    XCTAssertFalse(flow.riverNameWasCorrected)
  }

  /// Location + sex in the same message should update both fields.
  func testLocation_combinedWithSex() {
    initializeAtIdentification(species: "Steelhead")

    let result = flow.applyEdit("Morice River female")

    XCTAssertTrue(result.recognized)
    XCTAssertEqual(flow.riverName, "Morice River", "Sex token should be stripped from the river name")
    XCTAssertEqual(flow.sex, "Female")
    XCTAssertEqual(flow.species, "Steelhead", "Species unchanged when both location and sex are present")
  }

  // MARK: - Happy-path step progression

  func testStepProgression_identificationThroughFinalSummary() {
    initializeAtIdentification()

    _ = flow.confirm() // identification → confirmLength
    XCTAssertEqual(flow.currentStep, .confirmLength)

    _ = flow.confirm() // confirmLength → confirmGirth (length was pre-set to 30)
    XCTAssertEqual(flow.currentStep, .confirmGirth)

    _ = flow.confirm() // confirmGirth → finalSummary
    XCTAssertEqual(flow.currentStep, .finalSummary)
  }

  func testApplyEdit_buttonDrivenStep_returnsNotRecognized() {
    // Advance past finalSummary into studyParticipation, which is the first
    // button-driven step (see ResearcherCatchFlowManager.applyEdit's default
    // case). finalSummary itself accepts typed input — see the dedicated test
    // below.
    advanceToConfirmGirth()
    _ = flow.confirm() // confirmGirth → finalSummary
    _ = flow.confirm() // finalSummary → studyParticipation
    XCTAssertEqual(flow.currentStep, .studyParticipation)

    let result = flow.applyEdit("some random text")

    XCTAssertFalse(result.recognized)
    XCTAssertTrue(result.message.contains("not expecting typed input"))
  }

  func testApplyEdit_finalSummary_treatsUnrecognizedTextAsRiverNameCorrection() {
    advanceToConfirmGirth()
    _ = flow.confirm() // confirmGirth → finalSummary
    XCTAssertEqual(flow.currentStep, .finalSummary)

    // "Battenkill" has no water-body keyword, no species match, and the
    // free-text species fallback is gated OFF at finalSummary — so the
    // structured parser rejects it. The finalSummary branch then promotes
    // unrecognized non-empty text to riverName as a correction (see the
    // comment at ResearcherCatchFlowManager.applyEdit's .finalSummary case).
    let result = flow.applyEdit("Battenkill")

    XCTAssertTrue(result.recognized, "finalSummary always returns recognized=true; rejection is via riverName override")
    XCTAssertEqual(flow.riverName, "Battenkill")
    XCTAssertTrue(flow.riverNameWasCorrected)
  }
}
