// Bend Fly Shop
// ResearcherCatchFlowManager.swift — Step-by-step confirmation flow for researcher catch recording.
//
// Encapsulates the researcher-specific conversational flow:
//   1. Identification — confirm species, lifecycle, sex (and location context)
//   2. Measurements  — show length/girth/weight calculated with confirmed species
//   3. Length confirmation
//   4. Girth confirmation
//   5. Final summary
//   6. Voice memo
//
// Species must be confirmed BEFORE measurements are shown, because the weight
// formula divisor depends on the species + river combination.
// Weight is always derived (never confirmed separately).
// Owned by CatchChatViewModel; only instantiated when the user role is .researcher.

import Combine
import Foundation

final class ResearcherCatchFlowManager: ObservableObject {

  // MARK: - Step Definitions

  enum Step: Equatable {
    case identification         // show location, species, lifecycle, sex for confirmation
    case confirmLength          // show estimated length, confirm or edit
    case confirmGirth           // show length + estimated girth, confirm or edit girth
    case finalSummary           // show all confirmed values + derived weight
    case studyParticipation     // "Are you participating in a study?" — Pit, Floy, Radio Telemetry
    case floyTagID              // conditional: enter Floy Tag ID (only if Floy selected)
    case sampleCollection       // "Are you taking samples?" — Yes / No
    case envelopeContents       // "What's in the envelope?" — Scale / Fin clip / Both
    case envelopeScan           // scan or type the envelope barcode (single envelope, contents already declared)
    case voiceMemo              // offer voice memo
    case complete
  }

  /// Study type selected by the researcher (nil = not participating).
  enum StudyType: String, Equatable {
    case pit = "Pit"
    case floy = "Floy"
    case radioTelemetry = "Radio Telemetry"
  }

  /// What's inside the sample envelope. The researcher declares this BEFORE
  /// scanning the envelope so the upload payload can map a single barcode to
  /// the correct downstream sample-type fields.
  ///
  /// `wireValues` is the backend `sample_contents` payload (string array).
  /// The upload mapping in `CatchChatViewModel.makeCatchSnapshot` reads this
  /// enum and emits `sampleEnvelopeId` + `sampleContents` together — both
  /// fields, or neither (the backend rejects one without the other).
  enum SampleContents: String, Equatable {
    case scale = "Scale"
    case finClip = "Fin clip"
    case both = "Both"

    var wireValues: [String] {
      switch self {
      case .scale: return ["scale"]
      case .finClip: return ["fin_clip"]
      case .both: return ["scale", "fin_clip"]
      }
    }

    /// Lowercase phrase used in the post-scan confirmation message
    /// ("Envelope A7K3F9 logged with scale + fin clip").
    var summaryPhrase: String {
      switch self {
      case .scale: return "scale"
      case .finClip: return "fin clip"
      case .both: return "scale + fin clip"
      }
    }
  }

  // MARK: - Published State

  @Published var currentStep: Step = .identification

  /// Anchor ID for the current step's Next/Confirm buttons in the chat UI.
  @Published var confirmAnchorID: UUID?

  /// Whether the flow should include the post-measurement research steps
  /// (study participation, sample collection, barcode scans).
  ///
  /// - `true` (default): researcher role and guides with the Conservation
  ///   toggle ON — flow goes finalSummary → studyParticipation → … → voiceMemo.
  /// - `false`: guides with Conservation OFF — flow short-circuits
  ///   finalSummary → voiceMemo, skipping research-only steps.
  ///
  /// Not `@Published` because this is a one-shot mode flag set at initialize
  /// time, not a value the UI observes for live updates.
  var includeStudyAndSampleSteps: Bool = true

  // Confirmed values (initialized from ML analysis, updated by user)
  @Published var species: String?
  @Published var lifecycleStage: String?
  @Published var sex: String?
  @Published var lengthInches: Double?
  @Published var girthInches: Double?
  @Published var weightLbs: Double?

  // Estimation flags
  @Published var girthIsEstimated: Bool = true
  @Published var weightIsEstimated: Bool = true

  // Estimation metadata
  @Published var divisor: Int = FishWeightEstimator.defaultDivisor
  @Published var divisorSource: String = "Default"
  @Published var girthRatio: Double = FishWeightEstimator.defaultGirthRatio
  @Published var girthRatioSource: String = "Default (freshwater average)"

  // Initial measurement estimates (captured when identification is confirmed,
  // BEFORE user edits length/girth). These use the confirmed species/divisor,
  // so they're meaningful for model training.
  var initialLengthForMeasurements: Double?
  var initialGirthInches: Double?
  var initialWeightLbs: Double?
  var initialGirthIsEstimated: Bool = true
  var initialWeightIsEstimated: Bool = true
  var initialDivisor: Int = FishWeightEstimator.defaultDivisor
  var initialDivisorSource: String = "Default"
  var initialGirthRatio: Double = FishWeightEstimator.defaultGirthRatio
  var initialGirthRatioSource: String = "Default (freshwater average)"

  // Study participation
  @Published var studyType: StudyType?
  @Published var floyTagNumber: String?

  // Sample collection — single envelope per catch; `sampleContents` declares
  // what's inside, and `envelopeBarcode` holds the scanned (or manually typed)
  // barcode ID. Both nil when the researcher declined to take samples.
  @Published var sampleContents: SampleContents?
  @Published var envelopeBarcode: String?

  // Length estimation source (updated when species correction triggers re-estimation)
  var lengthSource: LengthEstimateSource?

  // River / water-body name for this catch. Holds either the ML-detected
  // river, the user's correction from the identification chat step, or nil
  // when no river could be determined. Used for:
  //   (1) the divisor lookup in `FishWeightEstimator` (unknown names fall
  //       through to the default divisor), and
  //   (2) the "Location:" line in identification + final summary bubbles.
  // Uploaded as the catch's river label. GPS latitude/longitude are stored
  // separately on the snapshot and are never overwritten by user edits here.
  var riverName: String?

  /// GPS-coordinate fallback label ("lat, lon") shown in the Location: line
  /// when `riverName` is nil — i.e., the ML analyzer couldn't match a river
  /// and the user hasn't typed a correction yet. Display-only: never written
  /// back into `riverName` or uploaded as the river label.
  var gpsLocationText: String?

  /// True once the user has corrected the river name via the chat. Used by
  /// the snapshot path to prefer `riverName` over the ML-detected value.
  /// Mirrors `speciesWasCorrected`.
  var riverNameWasCorrected: Bool = false

  // Original ML-detected species (for detecting if user changed it)
  var originalSpecies: String?
  var originalLifecycleStage: String?
  /// Original ML-detected sex (Male / Female / nil). Used by the capsule
  /// identification flow to highlight the model's prediction green and the
  /// remaining known sex yellow — the user still gets a third "Unknown" grey
  /// capsule. Does not affect upload semantics; `sex` is what's persisted.
  var originalSex: String?

  /// Whether the researcher changed the species from the original ML detection.
  var speciesWasCorrected: Bool {
    let current = species?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    let original = originalSpecies?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return current != original
  }

  /// Callback for posting assistant messages to the chat. Set by CatchChatViewModel.
  var postMessage: ((String) -> UUID)?

  // MARK: - Initialization

  /// Initialize from ML analysis results.
  /// Does NOT compute girth/weight yet — those depend on species, which must be
  /// confirmed first. Initial measurement estimates are snapshotted when the
  /// identification step is confirmed (see `confirm()`).
  func initialize(
    species: String?,
    lifecycleStage: String?,
    sex: String?,
    lengthInches: Double?,
    riverName: String?,
    gpsLocationText: String? = nil
  ) {
    self.species = species
    self.lifecycleStage = lifecycleStage
    self.sex = sex
    self.lengthInches = lengthInches
    self.riverName = riverName
    self.gpsLocationText = gpsLocationText
    self.riverNameWasCorrected = false
    self.originalSpecies = species
    self.originalLifecycleStage = lifecycleStage
    self.originalSex = sex

    currentStep = .identification
    AppLogging.log("[ResearcherFlow] Initialized: species=\(species ?? "nil") lifecycle=\(lifecycleStage ?? "nil") sex=\(sex ?? "nil") length=\(lengthInches.map { String($0) } ?? "nil") river=\(riverName ?? "nil")", level: .info, category: .research)
  }

  // MARK: - Step Advancement

  /// Confirm the current step and advance to the next one. Returns the message to post.
  func confirm() -> String {
    AppLogging.log("[ResearcherFlow] Confirming step: \(currentStep)", level: .debug, category: .research)
    switch currentStep {
    case .identification:
      // Species/sex/lifecycle confirmed — now calculate measurements for the first time
      // using the confirmed species (which determines the correct divisor + regressor path).
      // Note: if species was corrected, the ViewModel has already re-estimated length
      // via reEstimateLengthForCorrectedSpecies() before calling confirm().
      recalculate()

      // Snapshot the initial measurement estimates AFTER species confirmation.
      // These reflect the first estimates shown to the researcher (computed with
      // the correct species/divisor). Comparing initial vs. final measurements
      // provides training data for improving the estimation formula.
      snapshotInitialEstimates()

      currentStep = .confirmLength
      return lengthPrompt()

    case .confirmLength:
      // Length is required before we can compute girth or weight. If the ML
      // analyzer couldn't produce one and the user hasn't typed a measured
      // value yet, stay on this step and prompt them explicitly. This keeps
      // guides (Conservation OFF) from advancing with a nil length.
      guard lengthInches != nil else {
        return lengthPrompt()
      }
      // Length confirmed — recalculate girth/weight with confirmed length, show girth
      recalculate()
      currentStep = .confirmGirth
      return girthPrompt()

    case .confirmGirth:
      // After girth is confirmed, go straight to final summary (weight is derived)
      recalculateWeightOnly()
      currentStep = .finalSummary
      return finalAnalysisText()

    case .finalSummary:
      // Guides with Conservation OFF skip the research-only post-measurement
      // steps and jump straight to the voice memo offer.
      if includeStudyAndSampleSteps {
        currentStep = .studyParticipation
        return "Are you participating in a study?"
      } else {
        currentStep = .voiceMemo
        return "Would you like to add a voice memo for this catch?"
      }

    case .studyParticipation:
      // "No" was selected (confirm = skip). Move to sample collection.
      studyType = nil
      currentStep = .sampleCollection
      return "Are you taking a sample?"

    case .floyTagID:
      // Floy tag submitted or skipped → sample collection
      currentStep = .sampleCollection
      return "Are you taking a sample?"

    case .sampleCollection:
      // "No" was selected. Clear any prior envelope state and move on.
      sampleContents = nil
      envelopeBarcode = nil
      currentStep = .voiceMemo
      return "Would you like to add a voice memo for this catch?"

    case .envelopeContents:
      // Capsule-driven step (Scale / Fin clip / Both). A bare `confirm()` here
      // is treated as a no-op — the user must pick a contents value via
      // selectEnvelopeContents() to advance.
      return ""

    case .envelopeScan:
      // Envelope barcode confirmed (scanned or typed). Advance to voice memo.
      currentStep = .voiceMemo
      return "Would you like to add a voice memo for this catch?"

    case .voiceMemo:
      currentStep = .complete
      return ""

    case .complete:
      return ""
    }
  }

  // MARK: - Edit Handling

  /// Apply a user correction at the current step, recalculate downstream values.
  /// Returns (message, shouldAutoAdvance, recognized).
  /// - `recognized = false` means the input was rejected (empty, profane, or
  ///   unparseable); callers should show the message as-is without a
  ///   "Got it, updated:" prefix.
  /// When a numeric value is entered for length or girth, it auto-advances to
  /// the next step.
  func applyEdit(_ text: String) -> (message: String, autoAdvance: Bool, recognized: Bool) {
    let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

    // Global profanity screen — never persist profane text into species/ID
    // fields. Reply with the step-appropriate re-prompt.
    if Self.containsProfanity(text) {
      return (profanityReply(for: currentStep), false, false)
    }

    switch currentStep {
    case .identification:
      let recognized = parseIdentificationEdit(text, lower: lower)
      if !recognized {
        return (
          "I didn't catch that — please enter a species name (e.g., \"Steelhead\" or \"species: exotic X\"), a sex (male/female), a lifecycle stage (holding, traveler, spawning, kelt, smolt, resident), or a location (e.g., \"Kispiox River\", \"Howe Sound\", or \"location: Bulkley\").",
          false,
          false
        )
      }
      // Don't recalculate yet — measurements aren't shown until confirmed
      return (identificationPrompt(), false, true)

    case .confirmLength:
      if let num = extractNumber(from: text) {
        lengthInches = num
        recalculate()
        // Auto-advance: entering a number counts as confirming length
        currentStep = .confirmGirth
        return (girthPrompt(), true, true)
      }
      return (
        "I didn't catch that — please enter the length in inches (e.g., 28 or 28.5).",
        false,
        false
      )

    case .confirmGirth:
      if let num = extractNumber(from: text) {
        girthInches = num
        girthIsEstimated = false
        recalculateWeightOnly()
        // Auto-advance: entering a number counts as confirming girth
        currentStep = .finalSummary
        return (finalAnalysisText(), true, true)
      }
      return (
        "I didn't catch that — please enter the girth in inches (e.g., 14 or 14.5).",
        false,
        false
      )

    case .floyTagID:
      // Store the Floy Tag ID but don't advance — show it for confirmation
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        floyTagNumber = trimmed
        return ("Floy Tag ID: \(trimmed)\n§\nConfirm, or type a corrected value.", false, true)
      }
      return ("Please enter the Floy Tag ID.", false, false)

    case .envelopeScan:
      // Single envelope barcode — typed manually as the fallback path when
      // the user opts out of the scanner. Stored bare; `recordScannedEnvelope`
      // is the parallel path used by the scanner sheet.
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        envelopeBarcode = trimmed
        return (envelopeConfirmationMessage(id: trimmed), false, true)
      }
      return ("Please enter the envelope ID.", false, false)

    case .finalSummary:
      // Accept typed updates to any identification field after measurements
      // are done. Uses the structured parser (free-text species fallback
      // disabled) so a proper-noun river name like "Bitterroot River" routes
      // to riverName instead of silently overwriting species. Species /
      // river changes can affect the weight-divisor lookup, so we
      // recalculate before re-rendering.
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let recognized = parseStructuredEdit(text)
      if !recognized {
        if trimmed.isEmpty {
          return (
            "I didn't catch that. Try a species (e.g. \"Rainbow Trout\"), sex (\"male\"/\"female\"), lifecycle (\"holding\"/\"traveler\"), or a location.",
            false,
            false
          )
        }
        // Unrecognized non-empty text at the final step is almost always a
        // location the user wants to fill in — mirror the identification
        // summary's behavior.
        riverName = trimmed
        riverNameWasCorrected = true
      }
      recalculate()
      return (finalAnalysisText(), false, true)

    default:
      // .studyParticipation, .sampleCollection, .envelopeContents, .voiceMemo,
      // .complete — these are button-driven steps; typed input isn't expected.
      return (
        "I'm not expecting typed input right now — use the buttons above, or upload a new photo.",
        false,
        false
      )
    }
  }

  /// Standard message shown after the envelope ID is captured (scanned or
  /// typed). Includes the contents declared at the prior step so the
  /// researcher can verify both at once before tapping Confirm.
  private func envelopeConfirmationMessage(id: String) -> String {
    let contents = sampleContents?.summaryPhrase ?? "samples"
    return "Envelope: \(id)\nContents: \(contents)\n§\nConfirm, or scan / type a corrected value."
  }

  /// Called by the scanner sheet after a successful scan. Stores the parsed
  /// envelope ID and posts the same confirmation prompt the manual-entry path
  /// produces. The chat view is responsible for attaching the Confirm/Retry
  /// capsules to the resulting bubble.
  func recordScannedEnvelope(id: String) -> String {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    envelopeBarcode = trimmed.isEmpty ? nil : trimmed
    return envelopeConfirmationMessage(id: envelopeBarcode ?? "")
  }

  /// Step-appropriate re-prompt when the user's input was rejected by the
  /// profanity screen. Kept separate from the main switch so we don't mix
  /// rejection messaging into the happy-path prompts.
  private func profanityReply(for step: Step) -> String {
    switch step {
    case .identification:
      return "Let's keep it civil. Please enter a species name, sex (male/female), lifecycle stage, or location."
    case .confirmLength:
      return "Let's keep it civil. Please enter the length in inches (e.g., 28 or 28.5)."
    case .confirmGirth:
      return "Let's keep it civil. Please enter the girth in inches (e.g., 14 or 14.5)."
    case .floyTagID:
      return "Let's keep it civil. Please enter the Floy Tag ID."
    case .envelopeScan:
      return "Let's keep it civil. Please enter the envelope ID."
    default:
      return "Let's keep it civil. Use the buttons above, or upload a new photo."
    }
  }

  // MARK: - Study & Sample Selection

  /// Called when the researcher selects a study type (Pit, Floy, Radio Telemetry).
  func selectStudy(_ type: StudyType) -> (message: String, nextStep: Step) {
    studyType = type

    if type == .floy {
      currentStep = .floyTagID
      return ("Study: \(type.rawValue)\n§\nPlease enter the Floy Tag ID.", .floyTagID)
    } else {
      // Pit and Radio Telemetry don't have follow-up yet
      currentStep = .sampleCollection
      return ("Study: \(type.rawValue)\n§\nAre you taking samples?", .sampleCollection)
    }
  }

  /// Called when the researcher declares what's in the envelope (Scale, Fin
  /// clip, or Both). Advances to the envelope-scan step where the barcode is
  /// either scanned or typed.
  func selectEnvelopeContents(_ contents: SampleContents) -> (message: String, nextStep: Step) {
    sampleContents = contents
    currentStep = .envelopeScan
    return (
      "Contents: \(contents.rawValue)\n§\nScan the envelope, or type the ID.",
      .envelopeScan
    )
  }

  // MARK: - Initial Estimate Snapshot

  /// Captures the current measurement values as the "initial estimates".
  /// Called once when transitioning from identification → measurements,
  /// AFTER species is confirmed and length has been re-estimated if needed.
  private func snapshotInitialEstimates() {
    initialLengthForMeasurements = lengthInches
    initialGirthInches = girthInches
    initialWeightLbs = weightLbs
    initialGirthIsEstimated = girthIsEstimated
    initialWeightIsEstimated = weightIsEstimated
    initialDivisor = divisor
    initialDivisorSource = divisorSource
    initialGirthRatio = girthRatio
    initialGirthRatioSource = girthRatioSource
  }

  // MARK: - Recalculation

  /// Recalculate girth and weight from current length, species, and river.
  func recalculate() {
    guard let length = lengthInches, length > 0 else {
      girthInches = nil
      weightLbs = nil
      return
    }

    if girthIsEstimated {
      // Full recalculation: girth + weight from length
      let estimate = FishWeightEstimator.estimate(
        lengthInches: length,
        species: species,
        river: riverName
      )
      girthInches = estimate.girthInches
      weightLbs = estimate.weightLbs
      divisor = estimate.divisor
      divisorSource = estimate.divisorSource
      girthRatio = estimate.girthRatio
      girthRatioSource = estimate.girthRatioSource
      weightIsEstimated = true
    } else {
      // Girth was manually set; only recalculate weight
      recalculateWeightOnly()
    }
  }

  /// Recalculate weight only (when girth was manually overridden).
  private func recalculateWeightOnly() {
    guard let length = lengthInches, length > 0,
          let girth = girthInches, girth > 0 else {
      weightLbs = nil
      return
    }

    let estimate = FishWeightEstimator.estimateWeight(
      lengthInches: length,
      girthInches: girth,
      species: species,
      river: riverName
    )
    weightLbs = estimate.weightLbs
    divisor = estimate.divisor
    divisorSource = estimate.divisorSource
    weightIsEstimated = true
  }

  // MARK: - Prompt Generation

  /// Identification step: show location, species, lifecycle, sex (no measurements).
  /// Location is shown first because it's the field most often visible in the
  /// initial analysis and the first thing a user scans to verify.
  func identificationSummary() -> String {
    var lines: [String] = []

    // Only show the location line when the analyzer matched a named river or
    // water body. When we only have raw GPS (no match), hide the line from
    // the confirmation prompt — the coordinates still flow into the final
    // summary and the upload payload via `gpsLocationText` / `currentLocation`.
    if let r = riverName, !r.isEmpty {
      lines.append("Location: \(r)")
    }

    if let s = species, !s.isEmpty {
      if let stage = lifecycleStage, !stage.isEmpty {
        lines.append("Species: \(s) (\(stage))")
      } else {
        lines.append("Species: \(s)")
      }
    } else {
      lines.append("Species: Unknown")
    }

    if let sx = sex, !sx.isEmpty {
      lines.append("Sex: \(sx)")
    } else if species?.lowercased() == "bi-catch" {
      // Bi-catch: don't pretend to know the sex — the classifier's output is
      // meaningless for OOD species.
      lines.append("Sex: -")
    } else {
      lines.append("Sex: Unknown")
    }

    return lines.joined(separator: "\n")
  }

  /// Identification prompt shown when user edits species/sex/location.
  func identificationPrompt() -> String {
    let summary = identificationSummary()
    let hasLocation = (riverName?.isEmpty == false)
    let currentIsBiCatch = (species?.lowercased() == "bi-catch")
    let wasBiCatch = (originalSpecies?.lowercased() == "bi-catch")

    let tail: String
    if currentIsBiCatch {
      tail = "This was a bi-catch, please provide the name of the species below."
    } else if wasBiCatch {
      // User just corrected the species away from Bi-catch. Sex was never
      // reliably detected, so prompt for it as optional.
      tail = "If you know the sex of the fish enter it below, otherwise let's move on to measurements."
    } else if hasLocation {
      tail = "Confirm the species, sex, and location, or type corrections."
    } else {
      tail = "Confirm the species and sex, or type corrections."
    }
    return "\(summary)\n§\n\(tail)"
  }

  private func lengthPrompt() -> String {
    // When the ML analyzer couldn't estimate a length, ask the user to enter
    // one manually. Confirm has no meaning without a value to confirm.
    guard let length = lengthInches else {
      return "Length not detected from the photo.\n§\nPlease type a measured length in inches (e.g. \"32\") to continue."
    }
    return "Estimated length: \(formatLength(length))\n§\nConfirm, or type a new value (e.g. \"32\")."
  }

  private func girthPrompt() -> String {
    let lengthDisplay = lengthInches.map { formatLength($0) } ?? "Unknown"
    let girthDisplay = girthInches.map { formatGirth($0) } ?? "Unknown"

    var lines: [String] = []
    lines.append("Length: \(lengthDisplay)")
    lines.append("Estimated girth: \(girthDisplay)")

    lines.append("§")
    if girthIsEstimated {
      lines.append("Girth estimated using \(girthRatio) x length ratio")
      lines.append("(\(girthRatioSource))")
    } else {
      lines.append("Using measured girth (not estimated)")
    }

    lines.append("")
    lines.append("Confirm the girth, or type a measured value.")

    return lines.joined(separator: "\n")
  }

  /// Final analysis showing derived weight with the inputs used for the calculation.
  func finalAnalysisText() -> String {
    var lines: [String] = ["Final Analysis"]

    // Location: show the confirmed river/water-body name, or an em-dash when
    // the user skipped it. We intentionally do NOT fall back to displaying
    // raw GPS coordinates here — the user chose not to name a location, so
    // surfacing lat/lon as "Location" is misleading. GPS still flows into
    // the upload payload via `currentLocation` on the snapshot path,
    // independent of this display string.
    if let r = riverName, !r.isEmpty {
      lines.append("Location: \(r)")
    } else {
      lines.append("Location: —")
    }
    if let s = species, !s.isEmpty {
      if let stage = lifecycleStage, !stage.isEmpty {
        lines.append("Species: \(s) (\(stage))")
      } else {
        lines.append("Species: \(s)")
      }
    }
    if let sx = sex, !sx.isEmpty {
      lines.append("Sex: \(sx)")
    }
    if let l = lengthInches {
      lines.append("Length: \(formatLength(l))")
    }
    if let g = girthInches {
      let prefix = girthIsEstimated ? "~" : ""
      lines.append("Girth: \(prefix)\(formatGirth(g))")
    }
    if let w = weightLbs {
      lines.append("Weight: ~\(formatWeight(w))")
    }

    // Derivation details
    lines.append("§")
    lines.append("Calculation inputs:")
    lines.append("  Divisor: \(divisor) (\(divisorSource))")
    if girthIsEstimated {
      lines.append("  Girth ratio: \(girthRatio) x length (\(girthRatioSource))")
    } else {
      lines.append("  Girth: manually measured")
    }
    lines.append("  Formula: length x girth\u{00B2} / divisor")

    return lines.joined(separator: "\n")
  }

  // MARK: - Parsing Helpers

  // Known sex keywords — used to separate sex from species in free-text input
  private static let sexKeywords: Set<String> = ["male", "female", "hen", "buck"]

  // Lifecycle stage keywords — stripped from species candidate
  private static let stageKeywords: Set<String> = ["holding", "traveler", "spawning", "kelt", "smolt", "resident"]

  // Water-body suffix words the user might include when typing a location
  // correction ("Kispiox River", "Morice Creek", "Howe Sound", "Rideau Canal").
  // Presence of any of these tokens in the user's message routes the edit to
  // the location field instead of species. Kept broad on purpose — the
  // alternative (users discovering they must prefix with "location:") is worse.
  private static let waterBodyKeywords: Set<String> = [
    // Flowing water
    "river", "creek", "stream", "brook", "run", "fork", "branch",
    "tributary", "rio", "beck", "burn", "wash",
    // Still / inland water
    "lake", "pond", "reservoir", "tarn", "loch", "lough",
    // Coastal / tidal
    "sound", "bay", "inlet", "cove", "harbor", "harbour",
    "estuary", "fjord", "fiord", "lagoon", "bayou",
    // Artificial / narrow
    "canal", "channel", "slough", "strait",
  ]

  // Explicit prefix keywords a user can type to unambiguously mark an edit
  // as a location correction — e.g. "location: Kispiox", "river: Bulkley",
  // "at: Howe Sound". Matched only at the start of the trimmed input.
  private static let locationPrefixKeywords: [String] = [
    "location", "river", "creek", "lake", "water", "waterbody",
    "spot", "place", "where", "at",
  ]

  // Lightweight profanity screen — keeps freeform input out of species/ID fields
  // when it would otherwise be stored verbatim and uploaded. Conservative list;
  // matches on whole-word tokens only (so "scunthorpe" won't trip "cunt").
  private static let profanityTokens: Set<String> = [
    "fuck", "fucking", "fucker", "fucked",
    "shit", "shitty", "bullshit",
    "bitch", "bitches",
    "cunt", "asshole", "bastard",
    "dick", "piss", "cock", "pussy", "twat", "wanker"
  ]

  /// Returns true if `text` contains any token from `profanityTokens`.
  /// Splits on non-letters so punctuation doesn't bypass the check.
  static func containsProfanity(_ text: String) -> Bool {
    let tokens = text.lowercased().split { !$0.isLetter }.map(String.init)
    for token in tokens where profanityTokens.contains(token) { return true }
    return false
  }

  // Known species names the user might type (lowercase). Maps to display name.
  private static let knownSpecies: [String: String] = [
    "steelhead":        "Steelhead",
    "chinook":          "Chinook Salmon",
    "king":             "Chinook Salmon",
    "king salmon":      "Chinook Salmon",
    "chinook salmon":   "Chinook Salmon",
    "coho":             "Coho Salmon",
    "silver":           "Coho Salmon",
    "coho salmon":      "Coho Salmon",
    "rainbow":          "Rainbow Trout",
    "rainbow trout":    "Rainbow Trout",
    "sea-run trout":    "Sea-Run Trout",
    "sea run trout":    "Sea-Run Trout",
    "brown trout":      "Brown Trout",
    "brook trout":      "Brook Trout",
    "brook":            "Brook Trout",
    "cutthroat":        "Cutthroat Trout",
    "cutthroat trout":  "Cutthroat Trout",
    "arctic char":      "Arctic Char",
    "char":             "Arctic Char",
    "grayling":         "Grayling",
    "atlantic salmon":  "Atlantic Salmon",
    "largemouth bass":  "Largemouth Bass",
    "smallmouth bass":  "Smallmouth Bass",
    "northern pike":    "Northern Pike",
    "pike":             "Northern Pike",
    "pink salmon":      "Pink Salmon",
    "chum salmon":      "Chum Salmon",
    "sockeye salmon":   "Sockeye Salmon",
    "sockeye":          "Sockeye Salmon",
  ]

  /// Parse user's freeform identification edit. Returns `true` if we could
  /// recognize any species / sex / lifecycle / location content — callers use
  /// this to distinguish a real update from unparseable input (keyboard
  /// mashing, out-of-context chatter) and prompt the user again.
  ///
  /// Ordering is deliberate so the same message can't be classified as both
  /// a species and a location:
  ///   1. Species via `species:` prefix (explicit, always wins).
  ///   2. Species via `knownSpecies` exact match — runs BEFORE water-body
  ///      inference so "Brook" (a known species AND a water-body keyword)
  ///      stays Brook Trout rather than becoming a river name.
  ///   3. Location via `location:` / `river:` / `at:` prefix.
  ///   4. Location via water-body keyword inference ("Kispiox River",
  ///      "Howe Sound"), skipped when a species match already handled the
  ///      message.
  ///   5. Sex + lifecycle — always run so "Howe Sound male" or
  ///      "Steelhead kelt" set both fields in one message.
  ///   6. Species free-text fallback — gated: only accepts input with no
  ///      water-body token and no `location:` prefix, so location
  ///      corrections can never leak into species the way they used to.
  /// Structured-only variant of `parseIdentificationEdit` that disables the
  /// "anything ≥3 chars becomes the species" free-text fallback (step 7 in
  /// the ordering below).
  ///
  /// Used at the summary step where the user's intent is usually to fill in
  /// a missing location — a single proper-noun river name like "Battenkill"
  /// has no water-body token, isn't in `knownSpecies`, and would otherwise
  /// be misclassified as a species by the fallback. Callers can then route
  /// unrecognized text to `riverName` themselves.
  func parseStructuredEdit(_ text: String) -> Bool {
    if Self.containsProfanity(text) { return false }
    let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return parseIdentificationEdit(text, lower: lower, allowSpeciesFreeTextFallback: false)
  }

  private func parseIdentificationEdit(
    _ text: String,
    lower: String,
    allowSpeciesFreeTextFallback: Bool = true
  ) -> Bool {
    let tokens = lower.split { !$0.isLetter }.map(String.init)
    let noiseWords = Self.sexKeywords.union(Self.stageKeywords)
    var recognized = false
    var speciesUpdated = false
    var lifecycleUpdated = false
    var locationUpdated = false

    // 1. Species via `species:` / `species is` prefix (explicit).
    if let val = valueAfterKeyword("species", in: text, lower: lower), !val.isEmpty {
      species = val
      speciesUpdated = true
      recognized = true
    }

    // 2. Species via known-name match. Must run BEFORE water-body inference
    //    so "brook" (in both knownSpecies and waterBodyKeywords) stays as a
    //    species, and multi-word known names like "rainbow trout" resolve
    //    before a later token like "stream" could flip them to location.
    if !speciesUpdated {
      let speciesTokens = tokens.filter { !noiseWords.contains($0) }
      let candidate = speciesTokens.joined(separator: " ")
      if let displayName = Self.knownSpecies[candidate] {
        species = displayName
        speciesUpdated = true
        recognized = true
      }
    }

    // 3. Location via explicit prefix — only when no species match already
    //    claimed this message.
    if !speciesUpdated {
      if let val = locationPrefixValue(in: text, lower: lower), !val.isEmpty {
        riverName = val
        riverNameWasCorrected = true
        locationUpdated = true
        recognized = true
      }
    }

    // 4. Location via water-body keyword inference. Same guard as (3).
    if !speciesUpdated && !locationUpdated {
      let hasWaterBodyToken = tokens.contains { Self.waterBodyKeywords.contains($0) }
      if hasWaterBodyToken {
        let locationText = text
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .components(separatedBy: .whitespaces)
          .filter { !noiseWords.contains($0.lowercased()) }
          .joined(separator: " ")
        if !locationText.isEmpty {
          riverName = locationText
          riverNameWasCorrected = true
          locationUpdated = true
          recognized = true
        }
      }
    }

    // 5. Sex — keyword form first, then standalone tokens. Always runs so it
    //    can combine with a location or species edit in the same message.
    if let val = valueAfterKeyword("sex", in: text, lower: lower), !val.isEmpty {
      sex = val.capitalized
      recognized = true
    } else {
      if tokens.contains("male") { sex = "Male"; recognized = true }
      else if tokens.contains("female") { sex = "Female"; recognized = true }
      else if tokens.contains("hen") { sex = "Hen"; recognized = true }
      else if tokens.contains("buck") { sex = "Buck"; recognized = true }
    }

    // 6. Lifecycle stage — also combinable with species or location.
    for keyword in Self.stageKeywords {
      if tokens.contains(keyword) {
        lifecycleStage = keyword.capitalized
        lifecycleUpdated = true
        recognized = true
        break
      }
    }

    // 7. Species free-text fallback — the escape hatch for species names we
    //    don't have in `knownSpecies` yet (e.g. "tiger muskie", "walleye").
    //    Gated to skip whenever the message looks like a location, so
    //    corrections like "Columbia River" can't leak into species the way
    //    the ungated ≥3-char fallback used to allow. Also gated off at the
    //    summary step (via `allowSpeciesFreeTextFallback: false`) so proper-
    //    noun river names like "Battenkill" don't get misclassified when the
    //    user's real intent is to supply a missing location.
    if allowSpeciesFreeTextFallback, !speciesUpdated && !locationUpdated {
      let hasWaterBodyToken = tokens.contains { Self.waterBodyKeywords.contains($0) }
      let speciesTokens = tokens.filter { !noiseWords.contains($0) }
      let candidate = speciesTokens.joined(separator: " ")
      if !hasWaterBodyToken && candidate.count >= 3 {
        species = text
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .components(separatedBy: " ")
          .filter { !noiseWords.contains($0.lowercased()) }
          .joined(separator: " ")
        speciesUpdated = true
        recognized = true
      }
    }

    // When the user corrects the species but doesn't say anything about
    // lifecycle stage, drop the old stage. The analyzer attaches
    // "(Holding)" / "(Traveler)" to Steelhead specifically; if the user
    // reclassifies the fish as Rainbow Trout, the steelhead-specific stage
    // no longer applies and would otherwise linger as "Rainbow Trout (Holding)".
    if speciesUpdated && !lifecycleUpdated {
      lifecycleStage = nil
    }

    return recognized
  }

  /// Matches the explicit location-prefix form ("location: X", "river: X",
  /// "at: X", ...) only at the START of the trimmed message. Returns the
  /// value after the colon or " is ", or nil if the message doesn't start
  /// with one of `locationPrefixKeywords`.
  private func locationPrefixValue(in text: String, lower: String) -> String? {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedLower = lower.trimmingCharacters(in: .whitespacesAndNewlines)
    for keyword in Self.locationPrefixKeywords {
      let colonPrefix = "\(keyword):"
      if trimmedLower.hasPrefix(colonPrefix) {
        return String(trimmedText.dropFirst(colonPrefix.count))
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      let isPrefix = "\(keyword) is "
      if trimmedLower.hasPrefix(isPrefix) {
        return String(trimmedText.dropFirst(isPrefix.count))
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return nil
  }

  private func valueAfterKeyword(_ keyword: String, in text: String, lower: String) -> String? {
    guard let range = lower.range(of: keyword) else { return nil }
    let tail = text[range.upperBound...]
    if let isRange = tail.range(of: " is ") {
      return String(tail[isRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    } else if let colonRange = tail.range(of: ":") {
      return String(tail[colonRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func extractNumber(from text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Try to find a number pattern
    if let range = trimmed.range(of: #"(\d+(\.\d+)?)"#, options: .regularExpression) {
      return Double(String(trimmed[range]))
    }
    return nil
  }

  // MARK: - Formatting

  private func formatLength(_ inches: Double) -> String {
    if inches.rounded() == inches {
      return "\(Int(inches)) inches"
    }
    return String(format: "%.1f inches", inches)
  }

  private func formatGirth(_ inches: Double) -> String {
    return String(format: "%.1f inches", inches)
  }

  private func formatWeight(_ lbs: Double) -> String {
    return String(format: "%.1f lbs", lbs)
  }
}
