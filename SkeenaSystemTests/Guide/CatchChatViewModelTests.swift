import XCTest
@testable import SkeenaSystem

/// Tests for CatchChatViewModel's text-parsing helpers, correction logic,
/// formatted summary generation, and catch snapshot creation. Helpers are
/// exercised against the real implementation via `@testable import`.
final class CatchChatViewModelTests: XCTestCase {

  // MARK: - Properties

  private var vm: CatchChatViewModel!

  override func setUp() {
    super.setUp()
    vm = CatchChatViewModel()
  }

  override func tearDown() {
    vm = nil
    super.tearDown()
  }

  // MARK: - cleanedField Tests

  func testCleanedField_removesModelAnnotation() {
    XCTAssertEqual(vm.cleanedField("Steelhead (model)"), "Steelhead")
  }

  func testCleanedField_removesEstimateAnnotation() {
    XCTAssertEqual(vm.cleanedField("32-36 inches (estimate)"), "32-36 inches")
  }

  func testCleanedField_removesPhotoEstimateAnnotation() {
    XCTAssertEqual(vm.cleanedField("32-36 inches (photo estimate)"), "32-36 inches")
  }

  func testCleanedField_removesNeedsCustomModel() {
    XCTAssertEqual(vm.cleanedField("Unknown (needs custom model)"), "Unknown")
  }

  func testCleanedField_collapsesDoubleSpaces() {
    XCTAssertEqual(vm.cleanedField("Steelhead  Traveler"), "Steelhead Traveler")
  }

  func testCleanedField_trimsWhitespace() {
    XCTAssertEqual(vm.cleanedField("  Steelhead  "), "Steelhead")
  }

  func testCleanedField_emptyString_returnsEmpty() {
    XCTAssertEqual(vm.cleanedField(""), "")
  }

  // MARK: - stripLeadingLabel Tests

  func testStripLeadingLabel_removesSpeciesLabel() {
    XCTAssertEqual(vm.stripLeadingLabel("Species: Steelhead", label: "species"), "Steelhead")
  }

  func testStripLeadingLabel_caseInsensitive() {
    XCTAssertEqual(vm.stripLeadingLabel("SPECIES: Steelhead", label: "species"), "Steelhead")
  }

  func testStripLeadingLabel_removesSexLabel() {
    XCTAssertEqual(vm.stripLeadingLabel("Sex: Male", label: "sex"), "Male")
  }

  func testStripLeadingLabel_noMatchingLabel_returnsCleanedValue() {
    XCTAssertEqual(vm.stripLeadingLabel("Steelhead Traveler", label: "species"), "Steelhead Traveler")
  }

  func testStripLeadingLabel_nilInput_returnsEmpty() {
    XCTAssertEqual(vm.stripLeadingLabel(nil, label: "species"), "")
  }

  func testStripLeadingLabel_alsoRemovesModelAnnotation() {
    XCTAssertEqual(vm.stripLeadingLabel("Species (model): steelhead traveler", label: "species"), "steelhead traveler")
  }

  // MARK: - prettySex Tests

  func testPrettySex_capitalizeMale() {
    XCTAssertEqual(vm.prettySex("male"), "Male")
  }

  func testPrettySex_capitalizeFemale() {
    XCTAssertEqual(vm.prettySex("female"), "Female")
  }

  func testPrettySex_alreadyCapitalized() {
    XCTAssertEqual(vm.prettySex("Male"), "Male")
  }

  func testPrettySex_nonStandardPassesThrough() {
    XCTAssertEqual(vm.prettySex("hen"), "hen")
    XCTAssertEqual(vm.prettySex("buck"), "buck")
    XCTAssertEqual(vm.prettySex("Unknown"), "Unknown")
  }

  // MARK: - splitSpecies Tests

  func testSplitSpecies_steelheadTraveler_splitsLifecycleStage() {
    let (species, stage) = vm.splitSpecies("steelhead traveler")
    XCTAssertEqual(species, "Steelhead")
    XCTAssertEqual(stage, "Traveler")
  }

  func testSplitSpecies_steelheadHolding_splitsLifecycleStage() {
    let (species, stage) = vm.splitSpecies("steelhead holding")
    XCTAssertEqual(species, "Steelhead")
    XCTAssertEqual(stage, "Holding")
  }

  func testSplitSpecies_chinookSalmon_resolvesDisplayName() {
    let (species, stage) = vm.splitSpecies("chinook salmon")
    XCTAssertEqual(species, "Chinook Salmon")
    XCTAssertNil(stage)
  }

  func testSplitSpecies_atlanticSalmon_resolvesDisplayName() {
    let (species, stage) = vm.splitSpecies("atlantic salmon")
    XCTAssertEqual(species, "Atlantic Salmon")
    XCTAssertNil(stage)
  }

  func testSplitSpecies_lingcod_resolvesDisplayName() {
    let (species, stage) = vm.splitSpecies("lingcod")
    XCTAssertEqual(species, "Lingcod")
    XCTAssertNil(stage)
  }

  func testSplitSpecies_seaRunTrout_resolvesDisplayNameWithHyphen() {
    let (species, stage) = vm.splitSpecies("sea run trout")
    XCTAssertEqual(species, "Sea-Run Trout")
    XCTAssertNil(stage)
  }

  func testSplitSpecies_other_resolvesToBicatch() {
    let (species, stage) = vm.splitSpecies("other")
    XCTAssertEqual(species, "Bi-catch")
    XCTAssertNil(stage)
  }

  func testSplitSpecies_singleWordUnknown_capitalizes() {
    let (species, stage) = vm.splitSpecies("grayling")
    XCTAssertEqual(species, "Grayling")
    XCTAssertNil(stage)
  }

  func testSplitSpecies_nil_returnsDash() {
    let (species, stage) = vm.splitSpecies(nil)
    XCTAssertEqual(species, "-")
    XCTAssertNil(stage)
  }

  func testSplitSpecies_empty_returnsDash() {
    let (species, stage) = vm.splitSpecies("")
    XCTAssertEqual(species, "-")
    XCTAssertNil(stage)
  }

  func testSplitSpecies_withLabel_stripsLabel() {
    let (species, stage) = vm.splitSpecies("Species (model): steelhead holding")
    XCTAssertEqual(species, "Steelhead")
    XCTAssertEqual(stage, "Holding")
  }

  /// Only `holding` and `traveler` are lifecycle stages — anything else stays
  /// part of the species string. Guards the `splitSpecies` parser narrowing
  /// (see CatchChatViewModel.swift line ~1471).
  func testSplitSpecies_nonLifecycleTrailingWord_isNotStripped() {
    let (species, stage) = vm.splitSpecies("rainbow lake")
    XCTAssertEqual(species, "Rainbow Lake")
    XCTAssertNil(stage, "'lake' is not a lifecycle keyword and must not be split off")
  }

  func testSplitSpecies_belowThresholdSentinel_passesThrough() {
    let (species, stage) = vm.splitSpecies("Species: Unable to confidently detect")
    XCTAssertTrue(species.lowercased().contains("unable to"),
                  "'Unable to confidently detect' sentinel must not be parsed as species words")
    XCTAssertNil(stage)
  }

  // MARK: - averagedLength Tests
  //
  // averagedLength returns the *midpoint* of any range — used to produce the
  // single Int that gets persisted to the backend as initialAnalysis.lengthInches.
  // The user-facing chat preserves the range string verbatim; the midpoint
  // never reaches the bubble.

  func testAveragedLength_rangeWithHyphen_returnsMidpoint() {
    XCTAssertEqual(vm.averagedLength(from: "32-36 inches"), "34 inches")
  }

  func testAveragedLength_rangeWithEnDash_returnsMidpoint() {
    XCTAssertEqual(vm.averagedLength(from: "32–36 inches"), "34 inches")
  }

  func testAveragedLength_rangeWithEmDash_returnsMidpoint() {
    XCTAssertEqual(vm.averagedLength(from: "32—36 inches"), "34 inches")
  }

  func testAveragedLength_singleInteger_returnsWithInches() {
    XCTAssertEqual(vm.averagedLength(from: "36"), "36 inches")
  }

  func testAveragedLength_singleDecimal_returnsWithInches() {
    XCTAssertEqual(vm.averagedLength(from: "32.5"), "32.5 inches")
  }

  func testAveragedLength_empty_returnsEmpty() {
    XCTAssertEqual(vm.averagedLength(from: ""), "")
  }

  func testAveragedLength_dash_returnsDash() {
    XCTAssertEqual(vm.averagedLength(from: "-"), "-")
  }

  func testAveragedLength_reversedRange_stillReturnsMidpoint() {
    // Range bounds may arrive in either order; midpoint is order-independent.
    XCTAssertEqual(vm.averagedLength(from: "36-32 inches"), "34 inches")
  }

  func testAveragedLength_decimalRange_returnsMidpoint() {
    XCTAssertEqual(vm.averagedLength(from: "30.5-33.5 inches"), "32 inches")
  }

  // MARK: - extractLengthInches Tests

  func testExtractLengthInches_simpleInteger() {
    XCTAssertEqual(vm.extractLengthInches(from: "36 inches"), 36)
  }

  func testExtractLengthInches_decimalRounds() {
    XCTAssertEqual(vm.extractLengthInches(from: "32.5 inches"), 33)
  }

  func testExtractLengthInches_rangeReturnsMidpoint() {
    XCTAssertEqual(vm.extractLengthInches(from: "32-36 inches"), 34)
  }

  func testExtractLengthInches_empty_returnsNil() {
    XCTAssertNil(vm.extractLengthInches(from: ""))
  }

  func testExtractLengthInches_dash_returnsNil() {
    XCTAssertNil(vm.extractLengthInches(from: "-"))
  }

  func testExtractLengthInches_noDigits_returnsNil() {
    XCTAssertNil(vm.extractLengthInches(from: "not available"))
  }

  // MARK: - Context Update Tests (public interface)

  func testUpdateGuideContext_guideDefault_becomesEmpty() {
    vm.updateGuideContext(guide: "Guide")
    XCTAssertEqual(vm.guideName, "")
  }

  func testUpdateGuideContext_realName_isPreserved() {
    vm.updateGuideContext(guide: "Mike Johnson")
    XCTAssertEqual(vm.guideName, "Mike Johnson")
  }

  func testUpdateAnglerContext_selectDefault_becomesEmpty() {
    vm.updateAnglerContext(angler: "Select")
    XCTAssertEqual(vm.currentAnglerName, "")
  }

  func testUpdateAnglerContext_realName_isPreserved() {
    vm.updateAnglerContext(angler: "John Doe")
    XCTAssertEqual(vm.currentAnglerName, "John Doe")
  }

  // MARK: - makeCatchSnapshot Tests (public interface)

  func testMakeCatchSnapshot_noAnalysis_returnsNil() {
    XCTAssertNil(vm.makeCatchSnapshot(), "Should return nil when no analysis has been performed")
  }

  // MARK: - startConversationIfNeeded Tests

  func testStartConversation_addsInitialMessage() {
    vm.startConversationIfNeeded()
    XCTAssertFalse(vm.messages.isEmpty, "Should have at least one message after starting conversation")
    XCTAssertTrue(vm.showCaptureOptions, "Should show capture options after conversation start")
  }

  func testStartConversation_idempotent() {
    vm.startConversationIfNeeded()
    let count = vm.messages.count
    vm.startConversationIfNeeded()
    XCTAssertEqual(vm.messages.count, count, "Starting conversation again should not add more messages")
  }

  func testStartConversation_includesGuideName() {
    vm.updateGuideContext(guide: "Mike")
    vm.startConversationIfNeeded()
    let text = vm.messages.first?.text ?? ""
    XCTAssertTrue(text.contains("Mike"), "First message should include guide name")
  }

  // MARK: - sendCurrentInput Tests (correction pipeline via public API)

  func testSendCurrentInput_emptyInput_doesNothing() {
    vm.startConversationIfNeeded()
    let count = vm.messages.count
    vm.userInput = "   "
    vm.sendCurrentInput()
    XCTAssertEqual(vm.messages.count, count, "Should not add messages for whitespace-only input")
  }

  // MARK: - Voice note attachment tests

  func testAttachedVoiceNotes_initiallyEmpty() {
    XCTAssertTrue(vm.attachedVoiceNotes.isEmpty, "Voice notes should be empty initially")
  }

  // MARK: - Initial state tests

  func testInitialState_isNotTyping() {
    XCTAssertFalse(vm.isAssistantTyping)
  }

  func testInitialState_messagesEmpty() {
    XCTAssertTrue(vm.messages.isEmpty)
  }

  func testInitialState_userInputEmpty() {
    XCTAssertEqual(vm.userInput, "")
  }

  func testInitialState_photoFilenameNil() {
    XCTAssertNil(vm.photoFilename)
  }

  func testInitialState_saveNotRequested() {
    XCTAssertFalse(vm.saveRequested)
  }

  func testInitialState_catchLogNil() {
    XCTAssertNil(vm.catchLog)
  }
}
