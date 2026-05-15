// Bend Fly Shop

import AVFoundation
import Combine
import CoreLocation
import Foundation
import UIKit

enum ChatSender {
  case user
  case assistant
}

struct ChatMessage: Identifiable {
  let id = UUID()
  let sender: ChatSender
  let text: String?
  let image: UIImage?
}

/// Visual affordance for a capsule button in the chat flow.
/// - `green`: the ML top-1 or the currently confirmed value (the "primary" choice).
/// - `yellow`: a runner-up / alternative the user might pick instead.
/// - `red`: reject / disagree (only used by the location step).
/// - `grey`: neutral / "Unknown" option that carries no ML preference.
enum ChatCapsuleColor: Equatable {
  case green, yellow, red, grey
}

/// Semantic action dispatched when a capsule is tapped. Carried by the capsule
/// itself so the view doesn't need to know which identification sub-step is
/// active — the VM's `handleCapsuleTap(_:)` routes by action.
enum ChatCapsuleAction: Equatable {
  case confirmLocation
  case rejectLocation
  case skipLocation
  case selectSpecies(label: String)
  case selectLifecycle(stage: String)   // "Holding" | "Traveler"
  case selectSex(sex: String?)          // "Male" | "Female" | nil (Unknown)
  case keepAsBiCatch                    // user confirmed Bi-catch; keep species unknown
  case confirmIdentificationSummary     // final recap → advance to length
  case editLocationFromSummary          // identification summary "Edit location" — re-enter location, then return to summary
  case confirmMeasurement               // generic "confirm current measurement" (length/girth)
  // Pre-analysis (researcher/conservation entry points)
  case recordCatch                      // "What would you like to record?" → catch
  case recordObservation                // "What would you like to record?" → observation
  case confirmHeadPhoto                 // head photo confirm (conservation)
  case retakeHeadPhoto                  // head photo retake (conservation)
  // Post-measurement research flow
  case selectStudyType(rawValue: String) // "Floy" | "Pit" | "Radio Telemetry" (advances to .studyID)
  case skipStudy                        // "No" at .studyParticipation
  case selectSample(kind: String)       // "scale" | "fin" | "both" | "none" at .sampleCollection
  case openSampleScanner                // "Scan" capsule on either .scaleScan or .finScan
  case voiceMemoChoice(yes: Bool)       // add voice memo or skip
  case confirmID                        // study / scale / fin: accept typed ID
  case retryID                          // study / scale / fin: clear + re-prompt
}

struct ChatCapsule: Identifiable, Equatable {
  let id: String
  let label: String
  let color: ChatCapsuleColor
  /// Optional confidence shown as "72%" next to the label. Used for species;
  /// nil for confirm/reject, lifecycle, sex.
  let confidence: Float?
  let action: ChatCapsuleAction
}

final class CatchChatViewModel: ObservableObject {
  @Published var messages: [ChatMessage] = []
  @Published var userInput: String = ""
  @Published var isAssistantTyping: Bool = false

  // Show photo button inline after explainer
  @Published var showCaptureOptions: Bool = false

  /// The ID of the assistant message that the Upload button should anchor
  /// next to. Updated when the flow progresses from the head photo prompt to
  /// the primary fish photo prompt so the button "moves" with the chat.
  /// Nil means no explicit anchor — fall back to the first message when
  /// `showCaptureOptions == true`.
  @Published var uploadAnchorMessageID: UUID?

  // Voice notes attached to this catch (we currently keep the latest one only)
  @Published var attachedVoiceNotes: [LocalVoiceNote] = []

  // Show voice memo button next to a specific assistant message
  @Published var voiceMemoAnchorMessageID: UUID?

  // Save flow
  @Published var saveRequested: Bool = false
  @Published var catchLog: String?

  // Context from the header
  @Published private(set) var guideName: String = ""
  @Published private(set) var currentAnglerName: String = ""

  /// Whether this catch should be routed through the research-grade flow.
  /// Guides can opt in via the Conservation toggle on GuideLandingView.
  /// Researcher-role users always take the research flow regardless of this flag.
  /// Seeded by `ReportChatView` from `ConservationModeStore.shared` in `handleOnAppear`.
  @Published var conservationMode: Bool = false

    // Latest device location (from ReportChatView)
    private var currentLocation: CLLocation?

    // Photo's EXIF GPS, captured at upload time. Distinct from `currentLocation`
    // — `currentLocation` falls back to the device's live GPS when the photo
    // has no EXIF tag, but this property only ever holds an actual photo fix.
    // Used for the final-analysis map thumbnail, which must reflect where the
    // photo was taken, not where the phone happens to be sitting now.
    private var photoExifLocation: CLLocation?

    // Best timestamp for the current photo (EXIF or fallback)
    private var currentPhotoDate: Date?

  // Expose best photo timestamp (read-only)
  public var photoTimestamp: Date? { currentPhotoDate }

  // Expose location for confirmation screen (read-only)
  public var currentLocationForDisplay: CLLocation? { currentLocation }

  /// Read-only access to the EXIF-only photo location. Nil when the photo
  /// shipped without GPS metadata, even if a device fallback is available.
  public var photoExifLocationForDisplay: CLLocation? { photoExifLocation }

    // Latest analysis so we can update it from user corrections
    private var currentAnalysis: CatchPhotoAnalysis?

    // Initial analysis snapshot (before any user corrections)
    private var initialAnalysis: CatchPhotoAnalysis?

  // Saved photo filename (in PhotoStore)
  @Published var photoFilename: String?

  /// Filename of the close-up head photo, captured as the FIRST step of the
  /// conservation/research flow (before the primary fish photo). Nil outside
  /// of that flow or until the user uploads the head shot.
  @Published var headPhotoFilename: String?

  /// Filename of the head shot the user just uploaded but has not yet
  /// confirmed. Distinct from `headPhotoFilename` so a Retake can discard
  /// it without affecting any previously committed value. Promoted to
  /// `headPhotoFilename` on `confirmHeadPhoto()`.
  @Published var pendingHeadPhotoFilename: String?

  /// Anchor for the Confirm / Retake side buttons shown after a head photo
  /// is uploaded in the conservation/research flow. Nil outside that
  /// intermediate confirmation step.
  @Published var headConfirmAnchorMessageID: UUID?

  /// True when the chat is waiting for the user to upload the head photo
  /// before the regular fish-photo analysis pipeline runs. Only set in the
  /// conservation/research flow. Flipped off after the head photo is saved.
  @Published var awaitingHeadPhoto: Bool = false

  /// True when the researcher is choosing between recording a catch or observation.
  @Published var awaitingActivityChoice: Bool = false

  /// Anchor for the catch/observation choice buttons next to the initial prompt.
  var activityChoiceAnchorMessageID: UUID?

  /// Set to true by `chooseObservation()` so the view can present RecordObservationSheet.
  @Published var showRecordObservation: Bool = false

  /// Set to true when the user taps the "Yes" voice-memo capsule so the chat
  /// view can present its voice-note sheet. The view flips it back to false
  /// after consuming — matches the one-shot pattern of `showRecordObservation`.
  @Published var requestVoiceNoteSheet: Bool = false

  /// Set to true when the user taps the "Scan" capsule on either the
  /// `.scaleScan` or `.finScan` step so the chat view can present the
  /// envelope-barcode scanner sheet. The view flips it back to false after
  /// consuming — same one-shot pattern as `requestVoiceNoteSheet`. The view
  /// branches on `researcherFlow.currentStep` to route the scan result to
  /// the correct flow-manager handler.
  @Published var requestSampleScannerSheet: Bool = false

  /// One-shot toast shown when the picker fails to load a photo even after
  /// the iCloud-download fallback (e.g. user is offline and the photo's
  /// original isn't on the device). Auto-cleared by `presentPhotoLoadFailedToast`.
  @Published var showToast: Bool = false
  @Published var toastMessage: String = ""

  // Photo analyzer (modular)
    private let analyzer = CatchPhotoAnalyzer()

  /// Step-by-step flow driver used by ALL roles. For guides with Conservation
  /// OFF, `flow.includeStudyAndSampleSteps == false` short-circuits the
  /// finalSummary → voiceMemo transition so they skip research-only steps.
  /// Nil until a photo is analyzed.
  @Published var researcherFlow: ResearcherCatchFlowManager?

  /// Capsules rendered under the currently-anchored bubble. Drives the
  /// multi-step identification UI (location → species → lifecycle → sex).
  /// Empty outside the identification phase.
  @Published var chatCapsules: [ChatCapsule] = []

  /// Message ID the capsules are anchored to. Capsules render directly under
  /// whichever assistant bubble carries this ID.
  @Published var capsulesAnchorMessageID: UUID?

  /// Internal sub-step for the identification phase. Drives which capsule
  /// group is shown and how text input is interpreted. `.none` outside
  /// identification — the flow manager's own `currentStep` takes over from
  /// `.confirmLength` onward.
  private enum IdentificationSubStep {
    case none
    case confirmLocation       // ML matched a location — offer Confirm / Wrong
    case enterLocation         // user rejected; accepting typed input or Skip
    case confirmSpecies        // pick species from capsules (or type override)
    case enterBiCatchSpecies   // user confirmed Bi-catch; prompt for actual species
    case confirmLifecycle      // only when species is steelhead
    case confirmSex            // Male / Female / Unknown
    case confirmSummary        // final recap before advancing to length
  }
  private var identificationSubStep: IdentificationSubStep = .none

  /// Set when the user invokes Edit Location from the identification summary.
  /// `postLocationEntryStep` normally advances to species on completion — when
  /// this flag is true, the location-entry handlers jump straight back to the
  /// summary instead so the user doesn't have to re-confirm species, lifecycle,
  /// and sex they already approved.
  private var pendingLocationEditReturnsToSummary: Bool = false

  /// Saved analyzer result — the `speciesAlternatives` (top-1 + up to 2
  /// runners-up) get re-used when re-entering the species sub-step after a
  /// rejected edit.
  private var lastAnalysisAlternatives: [SpeciesCandidate] = []

  /// ML softmax confidence for the predicted species root (sums lifecycle
  /// variants — e.g. `steelhead_holding + steelhead_traveler`). Used to render
  /// the `%` on the green species capsule when the model was confident enough
  /// that no runner-ups were surfaced.
  private var lastAnalysisSpeciesConfidence: Float?

  /// Conditional probability of the predicted lifecycle stage given the root
  /// species. Rendered next to the green Holding/Traveler capsule.
  private var lastAnalysisLifecycleConfidence: Float?

  /// Softmax probability for the predicted sex. Rendered next to the green
  /// Male/Female capsule.
  private var lastAnalysisSexConfidence: Float?

  // High-level conversation state. Detailed step handling lives inside
  // ResearcherCatchFlowManager once a photo has been analyzed.
  private enum Step {
    case idle
    case researcherFlow    // delegates to ResearcherCatchFlowManager
  }

  private var step: Step = .idle

  /// Whether the current user is a researcher (checked once at photo analysis time).
  private var isResearcherRole: Bool {
    AuthService.shared.currentUserType == .researcher
  }

  // MARK: - Context updates

  func updateGuideContext(guide: String) {
    guideName = guide == "Guide" ? "" : guide
  }

  func updateAnglerContext(angler: String) {
    currentAnglerName = (angler == "Select" ? "" : angler)
  }

  func updateTripContext(trip: String) {
    // reserved for future contextual prompts
  }

  /// Reset all state so the researcher can record another catch from the same landing view.
  func resetForNewCatch() {
    messages = []
    userInput = ""
    isAssistantTyping = false
    showCaptureOptions = false
    attachedVoiceNotes = []
    voiceMemoAnchorMessageID = nil
    saveRequested = false
    catchLog = nil
    photoFilename = nil
    headPhotoFilename = nil
    pendingHeadPhotoFilename = nil
    headConfirmAnchorMessageID = nil
    awaitingHeadPhoto = false
    awaitingActivityChoice = false
    activityChoiceAnchorMessageID = nil
    showRecordObservation = false
    researcherFlow = nil
    currentAnalysis = nil
    initialAnalysis = nil
    currentPhotoDate = nil
    photoExifLocation = nil
    lastAnalysisAlternatives = []
    lastAnalysisSpeciesConfidence = nil
    lastAnalysisLifecycleConfidence = nil
    lastAnalysisSexConfidence = nil
    step = .idle
    startConversationIfNeeded()
  }

  func updateLocation(_ location: CLLocation?) {
    // Once a photo with EXIF GPS has been processed, freeze `currentLocation`
    // at the photo's fix — don't let the device's live-tracking GPS clobber
    // it. ReportChatView pumps device GPS in here continuously while the
    // user is in the chat; without this guard a catch saved an hour after
    // the photo was taken would end up stamped at the user's current
    // location (e.g., the parking lot) instead of the actual fish-on
    // location encoded in the photo. Pre-photo state still tracks live GPS
    // (photoExifLocation is nil), and `resetForNewCatch()` clears the
    // freeze so the next flow starts fresh.
    if photoExifLocation != nil { return }
    currentLocation = location
  }

  // MARK: - Conversation start (triggered by angler selection)

  func startConversationIfNeeded() {
    guard messages.isEmpty else { return }

    let namePart: String
    if isResearcherRole, let first = AuthService.shared.currentFirstName, !first.isEmpty {
      namePart = "\(first), "
    } else {
      namePart = guideName.isEmpty ? "" : "\(guideName), "
    }

    // Researchers get a choice between recording a catch or an observation.
    // Guides with Conservation ON go straight to the head-photo prompt.
    // Everyone else gets the regular fish photo prompt.
    let firstPrompt: ChatMessage
    if isResearcherRole {
      awaitingActivityChoice = true
      firstPrompt = appendAssistant("Hi \(namePart)what would you like to do?")
      activityChoiceAnchorMessageID = firstPrompt.id
      // Capsule UX for the catch/observation choice. The underlying
      // awaitingActivityChoice + activityChoiceAnchorMessageID state stays
      // intact (other dismissal logic depends on it); the icon column just
      // auto-hides when capsules are present.
      capsulesAnchorMessageID = firstPrompt.id
      chatCapsules = [
        ChatCapsule(id: "activity-catch",       label: "Report a Catch",        color: .green, confidence: nil, action: .recordCatch),
        ChatCapsule(id: "activity-observation", label: "Record an Observation", color: .green, confidence: nil, action: .recordObservation),
      ]
      step = .idle
      return
    } else if conservationMode {
      awaitingHeadPhoto = true
      firstPrompt = appendAssistant("Hi \(namePart)let's start with a close-up photo of the fish's head.\n§\nThis photo will be used to uniquely identify the fish.")
    } else {
      firstPrompt = appendAssistant("Hi \(namePart)upload a photo of the fish")
    }

    // Anchor the Upload button to this first prompt. It will re-anchor to
    // the "now upload the full fish" prompt after the head photo is captured.
    uploadAnchorMessageID = firstPrompt.id
    showCaptureOptions = true
    step = .idle
  }

  /// Whether the chat should use the scientific visual style.
  var isResearcherMode: Bool {
    isResearcherRole
  }

  // MARK: - Activity choice (researcher only)

  /// Researcher tapped the catch (pencil) button — start the head-photo flow.
  func chooseCatch() {
    awaitingActivityChoice = false
    activityChoiceAnchorMessageID = nil

    awaitingHeadPhoto = true
    let prompt = appendAssistant("Let's get started with a photo of the fish's head.\n§\nThis photo will be used to uniquely identify the fish.")
    uploadAnchorMessageID = prompt.id
    showCaptureOptions = true
  }

  /// Researcher tapped the observation (microphone) button — signal the view
  /// to present RecordObservationSheet.
  func chooseObservation() {
    awaitingActivityChoice = false
    activityChoiceAnchorMessageID = nil
    showRecordObservation = true
  }

    // MARK: - Photo load failure

    /// Surface a toast when both the PHPicker fast path and the PHImageManager
    /// iCloud-download fallback fail. Auto-dismisses after 4 seconds so the
    /// user can tap Upload again and try a different photo without manually
    /// clearing the message.
    func presentPhotoLoadFailedToast() {
      AppLogging.log("[CatchChat] presenting photo-load-failed toast", level: .info, category: .catch)
      toastMessage = "Couldn't load that photo from iCloud — check your connection or pick a different shot."
      showToast = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
        self?.showToast = false
      }
    }

    // MARK: - Photo analysis entry point

    func handlePhotoSelected(_ picked: PickedPhoto) {
      let pixelW = Int(picked.image.size.width * picked.image.scale)
      let pixelH = Int(picked.image.size.height * picked.image.scale)
      AppLogging.log("[CatchChat] handlePhotoSelected: awaitingHeadPhoto=\(awaitingHeadPhoto) size=\(Int(picked.image.size.width))x\(Int(picked.image.size.height)) pixels=\(pixelW)x\(pixelH) cgImage=\(picked.image.cgImage != nil) exifDate=\(picked.exifDate != nil) exifLocation=\(picked.exifLocation != nil)", level: .info, category: .catch)

      // Conservation/research flow captures the HEAD photo first, before the
      // primary fish photo. Route this upload to the head-photo handler and
      // skip the ML analysis pipeline — we'll run analysis on the NEXT upload.
      if awaitingHeadPhoto {
        AppLogging.log("[CatchChat] routing to head-photo handler", level: .debug, category: .catch)
        handleHeadPhotoSelected(picked)
        return
      }

      // 1. Decide which location to use: EXIF first, then whatever ReportChatView last gave us
      let bestLocation = picked.exifLocation ?? currentLocation

      // Remember this as the current location for later (logs, catch snapshot, etc.)
      currentLocation = bestLocation
      // Capture the photo's own EXIF GPS separately — the final-analysis map
      // thumbnail only renders when this is non-nil, so a device-fallback
      // location won't drag a misleading pin into the bubble.
      photoExifLocation = picked.exifLocation

      // 2. Decide which timestamp to use: EXIF first, then "now"
      let bestDate = picked.exifDate ?? Date()
      currentPhotoDate = bestDate

      // 3. Show the image itself as a chat bubble from the user
      messages.append(ChatMessage(sender: .user, text: nil, image: picked.image))
      AppLogging.log("[CatchChat] full-body photo appended to chat messages (count=\(messages.count))", level: .debug, category: .catch)

      // 4. Persist the photo to disk via PhotoStore and remember filename.
      // Wrapped in do/catch (was `try?`) so JPEG-encode or disk-write failures
      // surface in logs — they'd otherwise silently leave photoFilename=nil
      // and the user sees an empty bubble after the chat re-renders.
      do {
        let filename = try PhotoStore.shared.save(image: picked.image)
        self.photoFilename = filename
        AppLogging.log("[CatchChat] full-body photo persisted: filename=\(filename)", level: .info, category: .catch)
      } catch {
        self.photoFilename = nil
        AppLogging.log("[CatchChat] full-body photo PERSIST FAILED: \(error.localizedDescription) — chat bubble will display from memory but upload will have no file", level: .error, category: .catch)
      }

      // 5. Clear any old buttons / analysis state from previous catches.
      // The Upload button goes away now that the primary photo has been
      // captured; the flow takes over from here.
      voiceMemoAnchorMessageID = nil
      uploadAnchorMessageID = nil
      showCaptureOptions = false
      initialAnalysis = nil
      currentAnalysis = nil

      // 6. We're now analyzing – show typing indicator
      isAssistantTyping = true

      Task {
        // Artificial pause so user sees "thinking" state
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

          let analysis = await analyzer.analyze(
            image: picked.image,
            location: bestLocation
          )

        await MainActor.run {
          self.isAssistantTyping = false
          self.currentAnalysis = analysis

          // Capture the very first analysis as the "initial" snapshot.
          if self.initialAnalysis == nil {
            self.initialAnalysis = analysis
          }

          // All roles use the same step-by-step flow (identification → length
          // → girth → final summary → voice memo). Researchers and guides who
          // opted into Conservation additionally get the post-measurement
          // research steps (study participation, sample collection, barcode
          // scans). Guides with Conservation OFF jump straight from the final
          // summary to the voice memo offer.
          self.beginResearcherFlow(analysis: analysis)
        }
      }
    }

  /// Handles the close-up head photo uploaded as the first step of the
  /// conservation/research flow. Persists the image to PhotoStore as a
  /// *pending* filename and shows a Confirm / Retake prompt so the user can
  /// verify the shot before the chat advances to the full-body photo request.
  ///
  /// The ML analysis pipeline deliberately does NOT run on the head photo —
  /// analysis is for the full-body shot that drives species identification and
  /// length estimation. The head photo is metadata for research, stored
  /// alongside the catch and uploaded to the v5 `catch.headPhoto` field.
  ///
  /// `awaitingHeadPhoto` stays true until `confirmHeadPhoto()` is called, so a
  /// retake still routes through this handler rather than the analysis path.
  private func handleHeadPhotoSelected(_ picked: PickedPhoto) {
    // Show the image in the chat as user content.
    messages.append(ChatMessage(sender: .user, text: nil, image: picked.image))

    // Persist to the same CatchPhotos directory as the primary photo. This is
    // a *pending* file: if the user taps Retake we delete it via
    // PhotoStore.delete(filename:) before saving the replacement.
    if let filename = try? PhotoStore.shared.save(image: picked.image) {
      self.pendingHeadPhotoFilename = filename
    } else {
      self.pendingHeadPhotoFilename = nil
    }

    // Hide the Upload button while the user decides. It comes back anchored
    // to a different prompt on either Confirm or Retake.
    showCaptureOptions = false
    uploadAnchorMessageID = nil

    let confirmPrompt = appendAssistant("Tap Confirm to continue, or Retake to try again.")
    headConfirmAnchorMessageID = confirmPrompt.id
    // Capsule UX for head-photo confirm/retake. headConfirmAnchorMessageID
    // stays set so any remaining icon-based behavior works in isolation; the
    // capsules are the primary affordance now (right-side icon column is
    // auto-hidden while capsules are anchored here).
    capsulesAnchorMessageID = confirmPrompt.id
    chatCapsules = [
      ChatCapsule(id: "head-confirm", label: "Confirm", color: .green, confidence: nil, action: .confirmHeadPhoto),
      ChatCapsule(id: "head-retake",  label: "Retake",  color: .grey,  confidence: nil, action: .retakeHeadPhoto),
    ]
  }

  /// User confirmed the pending head photo. Promote the pending filename to
  /// the committed `headPhotoFilename` and advance the chat to the full-body
  /// fish photo prompt — this is the transition that `handleHeadPhotoSelected`
  /// used to perform inline before the confirmation step was added.
  func confirmHeadPhoto() {
    guard pendingHeadPhotoFilename != nil else { return }

    headPhotoFilename = pendingHeadPhotoFilename
    pendingHeadPhotoFilename = nil
    headConfirmAnchorMessageID = nil
    awaitingHeadPhoto = false

    let nextPrompt = appendAssistant("Got it. Please upload a photo of the full fish.\n§\nHold the fish with the head to the left for the best measurement analysis.")
    uploadAnchorMessageID = nextPrompt.id
    showCaptureOptions = true
  }

  /// User wants to retake the head photo. Discard the pending file and
  /// re-anchor the Upload button to a new prompt. We intentionally leave
  /// the previous photo bubble and "how does this look?" message in the
  /// chat log — consistent with the rest of this flow, which never rewrites
  /// history.
  func retakeHeadPhoto() {
    if let pending = pendingHeadPhotoFilename {
      PhotoStore.shared.delete(filename: pending)
    }
    pendingHeadPhotoFilename = nil
    headConfirmAnchorMessageID = nil
    // awaitingHeadPhoto stays true so the next upload still routes to
    // handleHeadPhotoSelected() rather than the analysis pipeline.

    let retakePrompt = appendAssistant("No problem — upload another close-up of the head.")
    uploadAnchorMessageID = retakePrompt.id
    showCaptureOptions = true
  }

  // MARK: - Flow branching

  private func beginResearcherFlow(analysis: CatchPhotoAnalysis) {
    step = .researcherFlow

    // Parse species/stage from analysis
    let (speciesName, stage) = splitSpecies(analysis.species)
    let sexValue = stripLeadingLabel(analysis.sex, label: "sex")
    let prettySexValue = prettySex(sexValue)

    // Extract numeric length
    let rawLen = cleanedField(analysis.estimatedLength ?? "")
    let lengthValue: Double? = extractLengthInches(from: rawLen).map(Double.init)

    // Resolve the river name and GPS fallback label separately. `riverName`
    // is only set when the ML analyzer matched a real water body; anything
    // starting with "No river detected for" / "No rivers configured for" is a
    // diagnostic string and should be treated as "unknown" so the flow can
    // fall back to GPS coords for display. `gpsLocationText` is the
    // display-only fallback — it never makes it into the upload's river
    // label, and the actual GPS lat/long continue to flow through
    // `currentLocation` untouched.
    let cleanedRiverForFlow = cleanedField(analysis.riverName ?? "")
    let hasRealRiver = !cleanedRiverForFlow.isEmpty
      && !cleanedRiverForFlow.hasPrefix("No river detected for")
      && !cleanedRiverForFlow.hasPrefix("No rivers configured for")
    let gpsFallback: String? = {
      if let loc = currentLocation {
        return String(format: "%.4f, %.4f", loc.coordinate.latitude, loc.coordinate.longitude)
      }
      return nil
    }()

    // Create and initialize the researcher flow manager.
    //
    // Post-measurement research steps (study, sample, barcode scan) are only
    // included for researchers and for guides who opted into Conservation on
    // the landing view. Guides with Conservation OFF run identification →
    // length → girth → final summary → voice memo, skipping the extras.
    let flow = ResearcherCatchFlowManager()
    flow.includeStudyAndSampleSteps = isResearcherRole || conservationMode

    // Bi-catch branch: the ML sex classifier's output is meaningless when the
    // species classifier bailed to "other" — skip sex and force the user to
    // correct the species before proceeding.
    let isBiCatch = speciesName.lowercased() == "bi-catch"
    let sexForFlow: String? = isBiCatch
      ? nil
      : (prettySexValue.isEmpty ? nil : prettySexValue)

    // The initial estimate is a range whenever the heuristic was used and
    // the value didn't clamp to the species cap. Regressor outputs and
    // at-cap heuristic outputs are single-valued, so they don't trigger the
    // range-display path at the confirm-length step.
    let isRangeEstimate = (analysis.lengthSource == .heuristic) && !analysis.lengthAtSpeciesCap
    // Clean the original analyzer string ("14-17 inches (photo estimate)" →
    // "14-17 inches") so the prompt can show the range verbatim. Only set
    // when it's actually a range — otherwise nil.
    let rangeDisplay: String? = {
      guard isRangeEstimate else { return nil }
      let cleaned = cleanedField(analysis.estimatedLength ?? "")
      return cleaned.isEmpty ? nil : cleaned
    }()

    flow.initialize(
      species: speciesName.isEmpty || speciesName == "-" ? nil : speciesName,
      lifecycleStage: stage,
      sex: sexForFlow,
      lengthInches: lengthValue,
      lengthAtSpeciesCap: analysis.lengthAtSpeciesCap,
      lengthIsRangeEstimate: isRangeEstimate,
      lengthRangeDisplay: rangeDisplay,
      riverName: hasRealRiver ? cleanedRiverForFlow : nil,
      gpsLocationText: gpsFallback
    )
    researcherFlow = flow

    // Remember the ML runner-ups so we can re-post the species step if the
    // user backs out of a correction mid-flow.
    lastAnalysisAlternatives = analysis.speciesAlternatives
    // Stash the model's per-prediction confidences so the capsules can
    // surface them as a `%` next to each ML pick.
    lastAnalysisSpeciesConfidence = analysis.speciesConfidence
    lastAnalysisLifecycleConfidence = analysis.lifecycleStageConfidence
    lastAnalysisSexConfidence = analysis.sexConfidence

    // Kick off the multi-step capsule flow. Location is always offered —
    // either as a Confirm/Wrong pair when the analyzer matched something, or
    // as an Entry prompt (type or Skip) when no match came through. The user
    // should never be forced past an unknown location without the chance to
    // supply one.
    if hasRealRiver {
      postLocationConfirmStep()
    } else {
      postLocationEntryStep(afterReject: false)
    }
  }

  // MARK: - Multi-step identification UI

  /// Post the bubble + capsules for the location-confirmation step.
  /// Shown only when the ML analyzer matched a named river / water body.
  private func postLocationConfirmStep() {
    guard let flow = researcherFlow, let river = flow.riverName else {
      // Defensive — shouldn't happen because callers gate on hasRealRiver.
      postSpeciesStep()
      return
    }
    identificationSubStep = .confirmLocation

    let primary: String
    // The river name is intentionally not wrapped in ** markers so it
    // renders in the bubble's default text color (white) rather than the
    // green prediction-styling used elsewhere. Per UX direction:
    // location-match copy reads as a natural sentence, not a highlighted
    // prediction.
    if let gps = flow.gpsLocationText, !gps.isEmpty {
      primary = "I matched your location to the \(river) (\(gps))."
    } else {
      primary = "I matched your location to the \(river)."
    }
    let msg = appendAssistant("\(primary)\n§\nIs that correct?")
    capsulesAnchorMessageID = msg.id
    chatCapsules = [
      ChatCapsule(id: "loc-confirm", label: "Yes", color: .green, confidence: nil, action: .confirmLocation),
      ChatCapsule(id: "loc-reject",  label: "No",  color: .red,   confidence: nil, action: .rejectLocation),
    ]
  }

  /// Prompt the user to type a location or Skip. Three variants:
  ///  • `afterReject` — user rejected an auto-matched river; ask for a correction.
  ///  • GPS available but unmatched — show the raw coords and ask for the fishery name.
  ///  • No GPS at all — tell the user location services may be off, offer manual entry.
  private func postLocationEntryStep(afterReject: Bool) {
    identificationSubStep = .enterLocation

    let primary: String
    let secondary: String
    if afterReject {
      primary = "No problem."
      secondary = "Type the correct location below, or tap Skip."
    } else if let gps = researcherFlow?.gpsLocationText, !gps.isEmpty {
      primary = "GPS: \(gps)"
      secondary = "Type the fishery below, or tap Skip."
    } else {
      primary = "Location not detected. Enable Camera Location in Settings."
      secondary = "Enter manually (e.g. Babine River) or tap Skip."
    }

    let msg = appendAssistant("\(primary)\n§\n\(secondary)")
    capsulesAnchorMessageID = msg.id
    chatCapsules = [
      ChatCapsule(id: "loc-skip", label: "Skip", color: .grey, confidence: nil, action: .skipLocation)
    ]
  }

  /// Post the bubble + capsules for the species step. Steelhead variants collapse
  /// into a single "Steelhead" capsule regardless of lifecycle — lifecycle is
  /// confirmed at the next step when the user picks steelhead.
  private func postSpeciesStep() {
    guard let flow = researcherFlow else { return }
    identificationSubStep = .confirmSpecies

    let summary: String
    if let species = flow.species, !species.isEmpty {
      let suffix: String
      if let conf = lastAnalysisSpeciesConfidence, conf < 1.0 {
        suffix = String(format: " %.0f%%", conf * 100)
      } else {
        suffix = ""
      }
      summary = "Species: **\(species)\(suffix)**"
    } else {
      summary = "Species: **Unknown**"
    }

    let msg = appendAssistant("\(summary)\n§\nConfirm, pick an alternative, or type a different species name.")
    capsulesAnchorMessageID = msg.id
    chatCapsules = buildSpeciesCapsules(alternatives: lastAnalysisAlternatives)
  }

  /// Build the species capsule group. Collapses steelhead_holding /
  /// steelhead_traveler into a single "Steelhead" capsule — lifecycle is
  /// confirmed at the next sub-step.
  private func buildSpeciesCapsules(alternatives: [SpeciesCandidate]) -> [ChatCapsule] {
    // Deduplicate steelhead variants — sum their probs, keep the primary flag
    // if either variant was the ML top-1.
    var seenSpeciesKeys: [String: (confidence: Float, isPrimary: Bool)] = [:]
    for alt in alternatives {
      let key = Self.speciesKey(forLabel: alt.label)
      if let existing = seenSpeciesKeys[key] {
        seenSpeciesKeys[key] = (
          confidence: existing.confidence + alt.confidence,
          isPrimary: existing.isPrimary || alt.isPrimary
        )
      } else {
        seenSpeciesKeys[key] = (confidence: alt.confidence, isPrimary: alt.isPrimary)
      }
    }

    // If there were no alternatives (high-confidence ML), synthesize a single
    // confirm capsule for the current species. Use the actual ML root
    // confidence (sum across lifecycle variants) so the user still sees a `%`
    // next to the species name; fall back to the sentinel `1.0` (suppressed
    // in the view) when no confidence was passed through.
    if seenSpeciesKeys.isEmpty, let species = researcherFlow?.species, !species.isEmpty {
      let key = species.lowercased()
      let conf = lastAnalysisSpeciesConfidence ?? 1.0
      seenSpeciesKeys[key] = (confidence: conf, isPrimary: true)
    }

    // Order: primary (green) first, then runner-up (yellow).
    let ordered = seenSpeciesKeys
      .sorted { $0.value.isPrimary && !$1.value.isPrimary }
      .sorted { $0.value.confidence > $1.value.confidence }

    var capsules: [ChatCapsule] = ordered.map { key, meta in
      let displayLabel = Self.displayName(forSpeciesKey: key)
      // The leading candidate's name + probability is rendered in the bubble
      // above; the green capsule just confirms it. Alternatives still show
      // their species name with the model's confidence.
      return ChatCapsule(
        id: "species-\(key)",
        label: meta.isPrimary ? "Confirm" : displayLabel,
        color: meta.isPrimary ? .green : .yellow,
        confidence: meta.isPrimary ? nil : (meta.confidence < 1.0 ? meta.confidence : nil),
        action: .selectSpecies(label: key)
      )
    }

    // Rainbow trout ↔ steelhead taxonomy: steelhead is the sea-run lifecycle
    // of rainbow trout, and the ViT classifier frequently picks one when the
    // user means the other. When the primary prediction is rainbow trout,
    // surface a "Steelhead" alternative unconditionally — no confidence
    // shown, since the choice is taxonomic, not probabilistic. Selecting it
    // routes via `selectSpecies(label: "steelhead")`, which `speciesWithLifecycle`
    // already routes to the lifecycle step (Holding / Traveler).
    let primaryKey = ordered.first(where: { $0.value.isPrimary })?.key
    let alreadyHasSteelhead = seenSpeciesKeys["steelhead"] != nil
    if primaryKey == "rainbow trout", !alreadyHasSteelhead {
      capsules.append(
        ChatCapsule(
          id: "species-steelhead",
          label: "Steelhead",
          color: .yellow,
          confidence: nil,
          action: .selectSpecies(label: "steelhead")
        )
      )
    }
    return capsules
  }

  /// Post the bubble + capsules for the lifecycle step. Reached when the user
  /// picked a species that has a holding/traveler lifecycle dimension (see
  /// `speciesWithLifecycle`). The ML-predicted stage (if any) is highlighted
  /// green and rendered first; the remaining stage is yellow.
  private func postLifecycleStep() {
    guard let flow = researcherFlow else { return }
    identificationSubStep = .confirmLifecycle

    let mlStage = flow.originalLifecycleStage?.lowercased() ?? ""
    // Use the confirmed species name in the prompt (e.g. "steelhead",
    // "atlantic salmon") so the question reads naturally for any species
    // routed to this step. Falls back to "fish" if species is somehow unset.
    let speciesPhrase = (flow.species?.lowercased()).flatMap {
      $0.isEmpty ? nil : $0
    } ?? "fish"
    let msg = appendAssistant("Is this a holding or traveling \(speciesPhrase)?\n§\nTap to confirm.")
    capsulesAnchorMessageID = msg.id

    let holdingColor: ChatCapsuleColor = (mlStage == "holding") ? .green : .yellow
    let travelerColor: ChatCapsuleColor = (mlStage == "traveler") ? .green : .yellow
    // Show the model's conditional confidence on whichever capsule reflects
    // the ML pick — only one of the two will be green per call.
    let holdingConf: Float? = (mlStage == "holding") ? lastAnalysisLifecycleConfidence : nil
    let travelerConf: Float? = (mlStage == "traveler") ? lastAnalysisLifecycleConfidence : nil

    let holding = ChatCapsule(id: "lc-holding",  label: "Holding",  color: holdingColor,  confidence: holdingConf,  action: .selectLifecycle(stage: "Holding"))
    let traveler = ChatCapsule(id: "lc-traveler", label: "Traveler", color: travelerColor, confidence: travelerConf, action: .selectLifecycle(stage: "Traveler"))

    // Render the higher-probability prediction first. With no ML pick (or an
    // unrecognized stage), fall back to Holding-first ordering.
    chatCapsules = (mlStage == "traveler") ? [traveler, holding] : [holding, traveler]
  }

  /// Post the bubble + capsules for the sex step. The ML prediction (if any)
  /// is green and rendered leftmost; the other real sex is yellow in the
  /// middle; Unknown is always grey and rightmost. When no ML prediction
  /// came through, Male and Female are both yellow and order is Male first.
  private func postSexStep() {
    guard let flow = researcherFlow else { return }
    identificationSubStep = .confirmSex

    // Surface the ML prediction inline as a value the user can confirm or
    // swap, mirroring the length / girth confirmation pattern. The
    // predicted sex is wrapped in ** so `predictionStyledText` paints it
    // green; "Unknown" is shown as the prediction when no ML pick is
    // available (e.g. Bi-catch path) so the bubble still reads cleanly.
    let predictedLabel: String
    switch flow.originalSex?.lowercased() {
    case "male":   predictedLabel = "Male"
    case "female": predictedLabel = "Female"
    default:       predictedLabel = "Unknown"
    }
    let msg = appendAssistant("Sex: **\(predictedLabel)**\n§\nConfirm, or pick an alternative.")
    capsulesAnchorMessageID = msg.id

    let male = ChatCapsule(id: "sex-male",   label: "Male",   color: .yellow, confidence: nil, action: .selectSex(sex: "Male"))
    let female = ChatCapsule(id: "sex-female", label: "Female", color: .yellow, confidence: nil, action: .selectSex(sex: "Female"))
    let unknown = ChatCapsule(id: "sex-unknown", label: "Unknown", color: .grey,  confidence: nil, action: .selectSex(sex: nil))

    // The sex classifier's softmax probability is rendered as `%` on whichever
    // capsule matches the ML pick (only one is green per call).
    let mlSexConf = lastAnalysisSexConfidence

    switch flow.originalSex?.lowercased() {
    case "male":
      // Predicted male → [Male (green), Female (yellow), Unknown (grey)]
      chatCapsules = [
        ChatCapsule(id: male.id, label: male.label, color: .green, confidence: mlSexConf, action: male.action),
        female,
        unknown,
      ]
    case "female":
      // Predicted female → [Female (green), Male (yellow), Unknown (grey)]
      chatCapsules = [
        ChatCapsule(id: female.id, label: female.label, color: .green, confidence: mlSexConf, action: female.action),
        male,
        unknown,
      ]
    default:
      // No prediction (e.g. Bi-catch path) — no green, Male first by convention.
      chatCapsules = [male, female, unknown]
    }
  }

  /// Post a summary of everything just confirmed (location, species,
  /// lifecycle if applicable, sex) with a single green "Looks good" capsule.
  /// User taps it to advance to the length step — this gives them one last
  /// chance to visually verify before measurements kick in.
  private func postIdentificationSummaryStep() {
    guard let flow = researcherFlow else { return }
    identificationSubStep = .confirmSummary

    var lines: [String] = ["Perfect, specimen attributes are:"]
    if let river = flow.riverName, !river.isEmpty {
      lines.append("• Location: \(river)")
    } else if let gps = flow.gpsLocationText, !gps.isEmpty {
      lines.append("• Location: \(gps)")
    } else {
      lines.append("• Location: —")
    }
    if let species = flow.species, !species.isEmpty {
      lines.append("• Species: \(species)")
    } else {
      lines.append("• Species: —")
    }
    if let stage = flow.lifecycleStage, !stage.isEmpty {
      lines.append("• Lifecycle: \(stage)")
    }
    if let sex = flow.sex, !sex.isEmpty {
      lines.append("• Sex: \(sex)")
    } else {
      lines.append("• Sex: Unknown")
    }

    let primary = lines.joined(separator: "\n")
    let msg = appendAssistant("\(primary)\n§\nMake any updates using the message box below.")
    capsulesAnchorMessageID = msg.id
    chatCapsules = [
      ChatCapsule(
        id: "summary-confirm",
        label: "Continue",
        color: .green,
        confidence: nil,
        action: .confirmIdentificationSummary
      ),
      ChatCapsule(
        id: "summary-edit-location",
        label: "Edit location",
        color: .grey,
        confidence: nil,
        action: .editLocationFromSummary
      ),
    ]
  }

  /// Advance the flow manager past identification once the user has confirmed
  /// the summary. Runs the same cascade the old single-step confirmation did:
  /// re-estimate length if species was corrected, snapshot initial estimates,
  /// move into `.confirmLength`.
  private func finishIdentificationPhase() {
    identificationSubStep = .none
    chatCapsules = []
    capsulesAnchorMessageID = nil
    researcherConfirm()
  }

  // MARK: - Capsule tap dispatch

  /// Central dispatch for any capsule tap during the identification sub-flow.
  /// Keeps the view a dumb renderer — the capsule carries its own action.
  ///
  /// Note: `researcherFlow` is nil before the first photo is analyzed, so the
  /// pre-analysis capsule actions (record-catch / observation / head-photo
  /// confirm / retake) are handled up front before the flow-required cases.
  func handleCapsuleTap(_ action: ChatCapsuleAction) {
    // Pre-analysis actions — no researcherFlow yet.
    switch action {
    case .recordCatch:
      chatCapsules = []
      capsulesAnchorMessageID = nil
      chooseCatch()
      return
    case .recordObservation:
      chatCapsules = []
      capsulesAnchorMessageID = nil
      chooseObservation()
      return
    case .confirmHeadPhoto:
      chatCapsules = []
      capsulesAnchorMessageID = nil
      confirmHeadPhoto()
      return
    case .retakeHeadPhoto:
      chatCapsules = []
      capsulesAnchorMessageID = nil
      retakeHeadPhoto()
      return
    default:
      break
    }

    // All remaining actions require an active flow.
    guard let flow = researcherFlow else { return }

    switch action {
    case .confirmLocation:
      // Location as-is — advance to species.
      postSpeciesStep()

    case .rejectLocation:
      // Clear the ML-detected location since the user disagrees with it.
      flow.riverName = nil
      flow.riverNameWasCorrected = true
      postLocationEntryStep(afterReject: true)

    case .skipLocation:
      // Leave riverName nil (user declined to supply). When this entry was
      // launched from the summary's Edit Location capsule, jump back there;
      // otherwise advance to species as normal.
      if pendingLocationEditReturnsToSummary {
        pendingLocationEditReturnsToSummary = false
        postIdentificationSummaryStep()
      } else {
        postSpeciesStep()
      }

    case .editLocationFromSummary:
      // Clear the current river name and re-open the location entry step.
      // When the user submits (or skips), the location-entry handlers route
      // back to the summary instead of advancing to species — the rest of
      // identification has already been confirmed.
      flow.riverName = nil
      flow.riverNameWasCorrected = true
      pendingLocationEditReturnsToSummary = true
      postLocationEntryStep(afterReject: true)

    case .selectSpecies(let key):
      applySpeciesSelection(key: key)

    case .selectLifecycle(let stage):
      flow.lifecycleStage = stage
      postSexStep()

    case .selectSex(let sex):
      flow.sex = sex
      postIdentificationSummaryStep()

    case .keepAsBiCatch:
      // User accepted Bi-catch as the final species. Sex is meaningless for
      // an unidentified fish, so skip the sex step and jump straight to
      // summary. `flow.sex` stays nil → summary shows "Sex: Unknown".
      flow.sex = nil
      postIdentificationSummaryStep()

    case .confirmIdentificationSummary:
      finishIdentificationPhase()

    case .confirmMeasurement:
      // Single green Confirm capsule at .confirmLength / .confirmGirth —
      // simply advance the flow manager which posts the next bubble and
      // re-attaches capsules if the new step warrants them.
      researcherConfirm()

    case .recordCatch, .recordObservation, .confirmHeadPhoto, .retakeHeadPhoto:
      // Handled by the pre-analysis switch above — unreachable here.
      return

    // MARK: Post-measurement research steps (study / sample / voice)

    case .skipStudy:
      chatCapsules = []
      capsulesAnchorMessageID = nil
      // "No" at the consolidated study step — equivalent to confirming past
      // .studyParticipation. confirm() advances to .sampleCollection.
      researcherConfirm()

    case .selectStudyType(let rawValue):
      chatCapsules = []
      capsulesAnchorMessageID = nil
      guard let type = ResearcherCatchFlowManager.StudyType(rawValue: rawValue) else { return }
      // All three study types (Floy / Pit / Radio Telemetry) advance to
      // the generic .studyID step. The chat manager's `selectStudy(_:)`
      // sets `studyType` so downstream prompts and labels carry the
      // correct study name.
      researcherSelectStudy(type)

    case .selectSample(let kind):
      chatCapsules = []
      capsulesAnchorMessageID = nil
      guard let flow = researcherFlow else { return }
      let selection: ResearcherCatchFlowManager.SampleSelection
      switch kind {
      case "scale": selection = .scale
      case "fin":   selection = .fin
      case "both":  selection = .both
      default:      selection = .none
      }
      let (message, _) = flow.selectSample(selection)
      let msg = appendAssistant(message)
      flow.confirmAnchorID = msg.id
      // Scale/Fin/Both — attach the Scan / Type capsule pair on the new
      // barcode-prompt bubble. None — go straight to voice memo, which
      // attaches its own capsules via attachCapsulesIfNeeded.
      switch selection {
      case .scale, .fin, .both:
        attachSampleScanCapsules(to: msg.id)
      case .none:
        attachVoiceMemoCapsules(to: msg.id)
      }

    case .openSampleScanner:
      // Pure UI signal — the chat view observes this and presents the
      // scanner sheet. The view branches on currentStep to route the result
      // to the right flow-manager handler.
      requestSampleScannerSheet = true

    case .voiceMemoChoice(let yes):
      chatCapsules = []
      capsulesAnchorMessageID = nil
      if yes {
        // Signal the view to present the voice-note sheet.
        requestVoiceNoteSheet = true
      } else {
        researcherSkipVoiceMemo()
      }

    case .confirmID:
      // Generic "accept typed ID" for Floy / Scale / Fin Tip steps. Works
      // identically to a checkmark-icon tap: advance the flow manager which
      // transitions to the next step and re-attaches capsules if warranted.
      researcherConfirm()

    case .retryID:
      // Clear whichever stored ID matches the current step, re-post the
      // original "Please enter the X" prompt, and keep the user on the same
      // step so they can type again.
      chatCapsules = []
      capsulesAnchorMessageID = nil
      switch flow.currentStep {
      case .studyID:
        flow.studyTagId = nil
        let typeName = flow.studyType?.rawValue ?? "Study"
        let msg = appendAssistant("Please enter the \(typeName) ID")
        flow.confirmAnchorID = msg.id
      case .scaleScan:
        // Two distinct retry modes:
        //   (a) "Type instead" tapped on the initial scan/type prompt before
        //       anything was captured — clear capsules and let them use the
        //       input bar without posting an extra bubble.
        //   (b) An ID was already captured and they're reconsidering — drop
        //       the value and re-post the prompt with Scan/Type capsules.
        let hadValue = flow.scaleEnvelopeId != nil
        flow.scaleEnvelopeId = nil
        if hadValue {
          let msg = appendAssistant("Scan the scale barcode, or type the ID.")
          flow.confirmAnchorID = msg.id
          attachSampleScanCapsules(to: msg.id)
        }
      case .finScan:
        let hadValue = flow.finEnvelopeId != nil
        flow.finEnvelopeId = nil
        if hadValue {
          let msg = appendAssistant("Scan the fin clip barcode, or type the ID.")
          flow.confirmAnchorID = msg.id
          attachSampleScanCapsules(to: msg.id)
        }
      default:
        break
      }
    }
  }

  /// Attach the Confirm / Retry capsule pair to an existing bubble. Used after
  /// the user types a Floy / Scale / Fin Tip ID and the flow echoes it back
  /// for confirmation.
  private func attachConfirmRetryIDCapsules(to anchor: UUID) {
    capsulesAnchorMessageID = anchor
    chatCapsules = [
      ChatCapsule(id: "id-confirm", label: "Confirm", color: .green, confidence: nil, action: .confirmID),
      ChatCapsule(id: "id-retry",   label: "Retry",   color: .grey,  confidence: nil, action: .retryID),
    ]
  }

  /// Apply a species choice from the species-step capsules. Uses the same
  /// update path text entry would, so `speciesWasCorrected` fires correctly
  /// and the downstream length-re-estimation cascade still runs when the user
  /// confirms sex.
  private func applySpeciesSelection(key: String) {
    guard let flow = researcherFlow else { return }

    flow.species = Self.displayName(forSpeciesKey: key)
    // Drop any stale lifecycle from the ML prediction unless the chosen species
    // has a holding/traveler dimension. The lifecycle step will write a fresh
    // one for those; for everything else it must stay nil.
    if !Self.speciesWithLifecycle.contains(key) {
      flow.lifecycleStage = nil
    }

    // Routing by species:
    //   - Species with lifecycle (steelhead, atlantic salmon, …) → lifecycle
    //     sub-step (holding vs traveler).
    //   - "Other" (Bi-catch) → prompt the user to name the actual species,
    //     since "Bi-catch" isn't a useful final classification.
    //   - Everything else → skip straight to sex.
    if Self.speciesWithLifecycle.contains(key) {
      postLifecycleStep()
    } else if key == "other" {
      postBiCatchSpeciesEntryStep()
    } else {
      postSexStep()
    }
  }

  /// Prompt the user to type the actual species after they confirmed Bi-catch
  /// as the primary species at the species step. Offers a single grey
  /// "Keep as Bi-catch" escape hatch — tapping it skips sex entirely and
  /// jumps to the summary since sex is meaningless for unidentified species.
  private func postBiCatchSpeciesEntryStep() {
    identificationSubStep = .enterBiCatchSpecies

    let msg = appendAssistant("Got it — this was a bi-catch.\n§\nType the actual species name below, or tap Keep as Bi-catch if you don't know.")
    capsulesAnchorMessageID = msg.id
    chatCapsules = [
      ChatCapsule(id: "bc-keep", label: "Keep as Bi-catch", color: .grey, confidence: nil, action: .keepAsBiCatch)
    ]
  }

  /// Resolves a raw model label (e.g. `"chinook_salmon"` or `"steelhead_holding"`)
  /// to the user-facing display name. Mirrors the lookup `splitSpecies` performs
  /// when it parses the analyzer's species string, so a capsule tap produces the
  /// same downstream text a manual type would.
  ///
  /// Exposed for the chat view to render capsule labels with the same
  /// hyphenation / casing conventions the rest of the chat uses
  /// (e.g. `"Sea-Run Trout"`, not the auto-capitalized `"Sea Run Trout"`).
  static func displayName(forLabel label: String) -> String {
    displayName(forSpeciesKey: Self.speciesKey(forLabel: label))
  }

  /// Resolves an already-collapsed species key (e.g. `"steelhead"`,
  /// `"atlantic salmon"`) to its user-facing display name via
  /// `speciesDisplayNames`, falling back to a capitalized form.
  static func displayName(forSpeciesKey key: String) -> String {
    if let mapped = speciesDisplayNames[key] { return mapped }
    return key.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
  }

  /// Canonical dictionary key used for species comparisons — the raw model
  /// label with the underscore stripped and any lifecycle suffix dropped.
  /// Example: `"steelhead_holding" → "steelhead"`, `"chinook_salmon" → "chinook salmon"`.
  static func speciesKey(forLabel label: String) -> String {
    let parts = label.replacingOccurrences(of: "_", with: " ").split(separator: " ")
    let lifecycle: Set<String> = ["holding", "traveler"]
    let speciesParts: [Substring]
    if let last = parts.last, lifecycle.contains(String(last).lowercased()) {
      speciesParts = Array(parts.dropLast())
    } else {
      speciesParts = parts
    }
    return speciesParts.joined(separator: " ").lowercased()
  }

  // MARK: - Researcher flow actions (called from CatchChatView)

  /// Researcher confirms the current step.
  func researcherConfirm() {
    guard let flow = researcherFlow else { return }

    // Advancing past the current step ⇒ any capsules on the previous bubble
    // are stale. This is a belt-and-suspenders clear — the multi-step
    // identification flow already clears as it advances.
    chatCapsules = []
    capsulesAnchorMessageID = nil

    // If confirming identification and species was corrected, re-estimate length
    // using the corrected species before advancing to measurements.
    if flow.currentStep == .identification && flow.speciesWasCorrected {
      reEstimateLengthForCorrectedSpecies(flow: flow)
    }

    flow.confirmAnchorID = nil

    let nextMessage = flow.confirm()

    if flow.currentStep == .voiceMemo {
      let msg = appendAssistant(nextMessage)
      voiceMemoAnchorMessageID = msg.id
      attachVoiceMemoCapsules(to: msg.id)
    } else if flow.currentStep == .complete {
      // Trigger save
      saveRequested = true
    } else if !nextMessage.isEmpty {
      let msg = appendAssistant(nextMessage)
      flow.confirmAnchorID = msg.id

      // Anchor the new capsule UX for measurements + post-measurement research
      // steps. Length / girth get a single green Confirm capsule; study /
      // sample get a Yes/No pair; everything else continues to use the
      // icon-column confirm pattern.
      switch flow.currentStep {
      case .confirmLength, .confirmGirth:
        attachConfirmMeasurementCapsule(to: msg.id)
      case .finalSummary:
        // Mirrors the .confirmLength / .confirmGirth pattern — a single
        // green capsule below the analysis bubble. Renamed "Next" instead
        // of "Confirm" because the user is acknowledging the summary and
        // advancing to the (researcher-only) study / sample / voice flow,
        // not confirming an editable value.
        attachNextStepCapsule(to: msg.id)
      case .studyParticipation:
        attachStudyParticipationCapsules(to: msg.id)
      case .sampleCollection:
        attachSampleCollectionCapsules(to: msg.id)
      default:
        break
      }
    }
  }

  /// Attach the single green "Confirm" capsule used at `.confirmLength` and
  /// `.confirmGirth`. Tap routes through `researcherConfirm()` which advances
  /// the flow manager to the next step (girth or final summary).
  private func attachConfirmMeasurementCapsule(to anchor: UUID) {
    capsulesAnchorMessageID = anchor
    chatCapsules = [
      ChatCapsule(
        id: "measure-confirm",
        label: "Confirm",
        color: .green,
        confidence: nil,
        action: .confirmMeasurement
      )
    ]
  }

  /// Attach the single green "Next" capsule used at `.finalSummary` to
  /// advance into the researcher-only study / sample / voice flow (or
  /// straight to voice memo for guides with Conservation OFF). Same wiring
  /// as the Confirm capsule above — routes through `researcherConfirm()`.
  private func attachNextStepCapsule(to anchor: UUID) {
    capsulesAnchorMessageID = anchor
    chatCapsules = [
      ChatCapsule(
        id: "final-next",
        label: "Next",
        color: .green,
        confidence: nil,
        action: .confirmMeasurement
      )
    ]
  }

  /// Attach a generic [Yes (green)] [No (grey)] capsule pair to an existing bubble.
  private func attachYesNoCapsules(
    to anchor: UUID,
    yesAction: ChatCapsuleAction,
    noAction: ChatCapsuleAction
  ) {
    capsulesAnchorMessageID = anchor
    chatCapsules = [
      ChatCapsule(id: "cap-yes", label: "Yes", color: .green, confidence: nil, action: yesAction),
      ChatCapsule(id: "cap-no",  label: "No",  color: .grey,  confidence: nil, action: noAction),
    ]
  }

  /// Attach the voice-memo Yes / Maybe later capsules to the voice-prompt bubble.
  private func attachVoiceMemoCapsules(to anchor: UUID) {
    capsulesAnchorMessageID = anchor
    chatCapsules = [
      ChatCapsule(id: "voice-yes",  label: "Yes",         color: .green, confidence: nil, action: .voiceMemoChoice(yes: true)),
      ChatCapsule(id: "voice-skip", label: "Maybe later", color: .grey,  confidence: nil, action: .voiceMemoChoice(yes: false)),
    ]
  }

  /// Attach the four-option capsule row to the "Are you participating in a
  /// study?" bubble. Floy / Pit / Radio are all green (positive picks that
  /// advance to the .studyID step); No is grey (skip).
  private func attachStudyParticipationCapsules(to anchor: UUID) {
    capsulesAnchorMessageID = anchor
    chatCapsules = [
      ChatCapsule(id: "study-floy",  label: "Floy",  color: .green, confidence: nil, action: .selectStudyType(rawValue: "Floy")),
      ChatCapsule(id: "study-pit",   label: "Pit",   color: .green, confidence: nil, action: .selectStudyType(rawValue: "Pit")),
      ChatCapsule(id: "study-radio", label: "Radio", color: .green, confidence: nil, action: .selectStudyType(rawValue: "Radio Telemetry")),
      ChatCapsule(id: "study-no",    label: "No",    color: .grey,  confidence: nil, action: .skipStudy),
    ]
  }

  /// Attach the four-option capsule row to the "Are you taking a sample?"
  /// bubble. Scale / Fin / Both are green (positive picks that route to
  /// the matching barcode-scan step); No is grey (skip to voice memo).
  private func attachSampleCollectionCapsules(to anchor: UUID) {
    capsulesAnchorMessageID = anchor
    chatCapsules = [
      ChatCapsule(id: "sample-scale", label: "Scale", color: .green, confidence: nil, action: .selectSample(kind: "scale")),
      ChatCapsule(id: "sample-fin",   label: "Fin",   color: .green, confidence: nil, action: .selectSample(kind: "fin")),
      ChatCapsule(id: "sample-both",  label: "Both",  color: .green, confidence: nil, action: .selectSample(kind: "both")),
      ChatCapsule(id: "sample-none",  label: "No",    color: .grey,  confidence: nil, action: .selectSample(kind: "none")),
    ]
  }

  /// Attach the sample-scan capsule pair (Scan / Type instead) to either the
  /// scale-envelope or the fin-clip-envelope scan bubble. The action is
  /// generic across both steps — the chat view branches on currentStep when
  /// the scanner sheet returns a result.
  private func attachSampleScanCapsules(to anchor: UUID) {
    capsulesAnchorMessageID = anchor
    chatCapsules = [
      ChatCapsule(id: "sample-scan", label: "Scan",         color: .green, confidence: nil, action: .openSampleScanner),
      ChatCapsule(id: "sample-type", label: "Type instead", color: .grey,  confidence: nil, action: .retryID),
    ]
  }

  /// Researcher edits the current step value via text input.
  ///
  /// Identification-phase sub-steps (location entry, species) have their own
  /// text-input handling; later flow-manager steps (length, girth, floy, etc.)
  /// fall through to the shared `flow.applyEdit` path.
  func researcherApplyEdit(_ text: String) {
    guard let flow = researcherFlow else { return }

    // Multi-step identification: interpret text based on which sub-step we're
    // on rather than funneling through the flow manager's multi-field parser.
    switch identificationSubStep {
    case .enterLocation:
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        flow.riverName = trimmed
        flow.riverNameWasCorrected = true
      }
      // Whether the user typed something or not, advance. When the entry was
      // launched from the summary's Edit Location capsule, return to the
      // summary instead of marching back through species/lifecycle/sex.
      chatCapsules = []
      capsulesAnchorMessageID = nil
      if pendingLocationEditReturnsToSummary {
        pendingLocationEditReturnsToSummary = false
        postIdentificationSummaryStep()
      } else {
        postSpeciesStep()
      }
      return

    case .confirmSpecies, .enterBiCatchSpecies:
      // Allow free-text override at the species step (or after Bi-catch was
      // confirmed and the user now wants to name the actual species). Reuse
      // the flow manager's species parser for consistency with the
      // pre-capsule behavior — it handles "species: X" prefixes and the
      // knownSpecies map.
      flow.confirmAnchorID = nil
      let (_, _, recognized) = flow.applyEdit(text)
      if !recognized {
        let msg = appendAssistant("I didn't catch a species name there. Tap one of the capsules above or type a species (e.g. \"Rainbow Trout\", \"Chinook\").")
        flow.confirmAnchorID = msg.id
        return
      }
      chatCapsules = []
      capsulesAnchorMessageID = nil
      // Advance based on the resolved species. Species with a holding/traveler
      // dimension (see `speciesWithLifecycle`) → lifecycle step; everything
      // else → sex. If the user (from Bi-catch entry) typed a salmonid here,
      // the normal lifecycle/sex sequence applies.
      let resolvedKey = (flow.species ?? "").lowercased()
      if Self.speciesWithLifecycle.contains(resolvedKey) {
        postLifecycleStep()
      } else {
        postSexStep()
      }
      return

    case .confirmLocation, .confirmLifecycle, .confirmSex:
      // These steps are capsule-driven — typed input at these moments is
      // unexpected but still useful to parse if it's clearly a species name
      // or location. Fall through to the shared parser.
      break

    case .confirmSummary:
      // Summary step: accept typed corrections for any identification field
      // (species, sex, lifecycle, location) and re-render the summary so the
      // user sees the updated recap. If the edit changed the species, the
      // length cascade will still re-run when they tap Continue — that path
      // is handled in `researcherConfirm()`.
      //
      // Uses the *structured* parser (no species free-text fallback) so an
      // unrecognized proper noun like "Battenkill" gets routed to the
      // missing-location slot instead of silently overwriting species.
      flow.confirmAnchorID = nil
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let recognized = flow.parseStructuredEdit(text)
      if !recognized {
        // Parser couldn't match species/sex/lifecycle/explicit-location
        // prefix. If it's non-empty, assume the user is supplying a
        // location (proper-noun river/lake name).
        if !trimmed.isEmpty {
          flow.riverName = trimmed
          flow.riverNameWasCorrected = true
        } else {
          let msg = appendAssistant("I didn't catch that. Try a species (e.g. \"Rainbow Trout\"), sex (\"male\"/\"female\"), lifecycle (\"holding\"/\"traveler\"), or a location.")
          flow.confirmAnchorID = msg.id
          return
        }
      }
      chatCapsules = []
      capsulesAnchorMessageID = nil
      postIdentificationSummaryStep()
      return

    case .none:
      // Outside identification — measurements, research steps, etc.
      break
    }

    flow.confirmAnchorID = nil

    let (updatedPrompt, autoAdvanced, recognized) = flow.applyEdit(text)

    if !recognized {
      // Input was empty, profane, or unparseable — show the step's re-prompt
      // verbatim (no "Got it, updated:" prefix). Keep capsules on screen in
      // this case since the user hasn't successfully resolved the ambiguity.
      let msg = appendAssistant(updatedPrompt)
      flow.confirmAnchorID = msg.id
      return
    }

    // A recognized edit resolved the identification (species/sex/lifecycle/
    // location) — capsules are stale, clear them so they don't linger on the
    // re-rendered bubble.
    chatCapsules = []
    capsulesAnchorMessageID = nil

    if autoAdvanced {
      // Value entry (length/girth number) auto-confirmed the previous step
      // and advanced. Post the next bubble and attach the measurement
      // Confirm capsule when landing on another .confirmLength/.confirmGirth
      // step. .finalSummary keeps its larger green checkmark icon in the
      // side column — no capsule needed there.
      let msg = appendAssistant(updatedPrompt)
      flow.confirmAnchorID = msg.id
      if flow.currentStep == .confirmLength || flow.currentStep == .confirmGirth {
        attachConfirmMeasurementCapsule(to: msg.id)
      }
    } else if flow.currentStep == .finalSummary {
      // User edited an identification field at the final step. Post the
      // re-rendered finalAnalysisText as-is (no "Got it, updated:" prefix)
      // so the bubble dispatcher still matches the "Final Analysis" prefix
      // and keeps the blue-title styling.
      let msg = appendAssistant(updatedPrompt)
      flow.confirmAnchorID = msg.id
    } else {
      let msg = appendAssistant("Got it, updated:\n\(updatedPrompt)")
      flow.confirmAnchorID = msg.id
      // ID-entry steps (Study / Scale / Fin) echo the typed value back
      // with a Confirm/Retry capsule pair — Confirm advances, Retry
      // clears the stored value and re-prompts.
      if flow.currentStep == .studyID
          || flow.currentStep == .scaleScan
          || flow.currentStep == .finScan {
        attachConfirmRetryIDCapsules(to: msg.id)
      }
    }
  }

  /// Researcher selects a study type (Floy / Pit / Radio Telemetry) at the
  /// consolidated `.studyParticipation` step. The flow manager posts the
  /// "Please enter the <StudyName> ID" prompt; the user types the ID into
  /// the input bar, after which the typed-echo bubble gets its own
  /// Confirm/Retry capsules (see applyEdit handling).
  func researcherSelectStudy(_ type: ResearcherCatchFlowManager.StudyType) {
    guard let flow = researcherFlow else { return }
    flow.confirmAnchorID = nil

    let (message, _) = flow.selectStudy(type)
    let msg = appendAssistant(message)
    flow.confirmAnchorID = msg.id
  }

  /// Researcher answered Yes at .sampleCollection. Advances the flow manager
  /// to .scaleScan and posts the "Scan the scale envelope" prompt with the
  /// Scan + Type-instead capsule pair.
  func researcherBeginScaleScan() {
    guard let flow = researcherFlow else { return }
    flow.confirmAnchorID = nil

    let (message, _) = flow.beginScaleScan()
    let msg = appendAssistant(message)
    flow.confirmAnchorID = msg.id
    attachSampleScanCapsules(to: msg.id)
  }

  /// Researcher answered Yes at .finPrompt. Advances the flow manager to
  /// .finScan and posts the "Scan the fin clip envelope" prompt.
  func researcherBeginFinScan() {
    guard let flow = researcherFlow else { return }
    flow.confirmAnchorID = nil

    let (message, _) = flow.beginFinScan()
    let msg = appendAssistant(message)
    flow.confirmAnchorID = msg.id
    attachSampleScanCapsules(to: msg.id)
  }

  /// Called by the chat view after the scanner sheet returns a scale-envelope
  /// barcode. Stores the parsed ID on the flow manager and posts the
  /// confirmation bubble with Confirm/Retry capsules.
  func researcherRecordScannedScaleEnvelope(_ id: String) {
    guard let flow = researcherFlow else { return }
    flow.confirmAnchorID = nil

    let message = flow.recordScannedScaleEnvelope(id: id)
    let msg = appendAssistant(message)
    flow.confirmAnchorID = msg.id
    attachConfirmRetryIDCapsules(to: msg.id)
  }

  /// Called by the chat view after the scanner sheet returns a fin-clip-
  /// envelope barcode.
  func researcherRecordScannedFinEnvelope(_ id: String) {
    guard let flow = researcherFlow else { return }
    flow.confirmAnchorID = nil

    let message = flow.recordScannedFinEnvelope(id: id)
    let msg = appendAssistant(message)
    flow.confirmAnchorID = msg.id
    attachConfirmRetryIDCapsules(to: msg.id)
  }

  /// Researcher skips voice memo from the voice memo step.
  func researcherSkipVoiceMemo() {
    guard let flow = researcherFlow else { return }
    voiceMemoAnchorMessageID = nil
    flow.currentStep = .complete
    saveRequested = true
  }

  /// Re-estimate length when the researcher corrects the species during identification.
  /// The regressor uses species index as an input feature, and some species (e.g. sea_run_trout)
  /// bypass the regressor entirely. Changing species can dramatically affect the length estimate.
  private func reEstimateLengthForCorrectedSpecies(flow: ResearcherCatchFlowManager) {
    guard let fv = initialAnalysis?.featureVector else {
      AppLogging.log("reEstimateLength: no feature vector available, keeping original length", level: .warn, category: .ml)
      return
    }

    let result = analyzer.reEstimateLength(
      originalFV: fv,
      correctedSpecies: flow.species,
      correctedLifecycleStage: flow.lifecycleStage
    )

    if let newLength = result.lengthInches {
      let oldLength = flow.lengthInches
      flow.lengthInches = newLength
      flow.lengthSource = result.source
      flow.lengthAtSpeciesCap = result.atSpeciesCap
      // Re-estimation always returns a single value, never a range — so
      // the range-display path at confirmLength no longer applies.
      flow.lengthIsRangeEstimate = false
      flow.lengthRangeDisplay = nil
      AppLogging.log({
        "Species corrected: re-estimated length from \(oldLength.map { String(format: "%.1f", $0) } ?? "nil") " +
        "to \(String(format: "%.1f", newLength)) inches (source: \(result.source.rawValue))" +
        (result.atSpeciesCap ? " [AT SPECIES CAP]" : "")
      }, level: .info, category: .ml)
    }
  }

  // MARK: - Sending user messages

  func sendCurrentInput() {
    let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    messages.append(ChatMessage(sender: .user, text: trimmed, image: nil))
    userInput = ""
    handleUserResponse(trimmed)
  }

  // MARK: - Dialog policy

  private func handleUserResponse(_ text: String) {
    let lower = text.lowercased()

    // Global "save" command (still supported)
    if lower == "save" || lower == "save catch" || lower == "save this" {
      triggerSave()
      return
    }

    switch step {
    case .researcherFlow:
      // In the step-by-step flow, user text is treated as an edit for the
      // current step (identification / length / girth / etc.).
      researcherApplyEdit(text)

    case .idle:
      if ResearcherCatchFlowManager.containsProfanity(text) {
        appendAssistant("Let's keep it civil. You can upload another photo, record a voice memo, or tell me about the catch.")
      } else {
        appendAssistant("You can upload another photo, record a voice memo, or tell me more about the catch here.")
      }
    }
  }

  // Called from the UI if needed
  func triggerSave() {
    performSave()
  }

  // MARK: - Voice memo decision (now vs later)

  // MARK: - Helpers

  @discardableResult
  private func appendAssistant(_ text: String) -> ChatMessage {
    let msg = ChatMessage(sender: .assistant, text: text, image: nil)
    messages.append(msg)
    return msg
  }

  /// Label used in place of a named water body when neither the river
  /// locator nor the water-body locator produced a match. Falls back to a
  /// formatted lat/long derived from `currentLocation` so the pending-upload
  /// row shows something useful to the user instead of a diagnostic string.
  /// The raw GPS is still uploaded separately via the snapshot's latitude
  /// and longitude fields — this string is display-only.
  private func unresolvedLocationLabel() -> String {
    if let loc = currentLocation {
      return String(format: "%.4f, %.4f", loc.coordinate.latitude, loc.coordinate.longitude)
    }
    return "Unknown location"
  }

  func cleanedField(_ s: String) -> String {
    var t = s
    let junk = [
      "(model)",
      "(needs custom model)",
      "(estimate)",
      "(photo estimate)"
    ]
    for token in junk {
      t = t.replacingOccurrences(of: token, with: "")
    }
    while t.contains("  ") {
      t = t.replacingOccurrences(of: "  ", with: " ")
    }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func stripLeadingLabel(_ raw: String?, label: String) -> String {
    guard let raw else { return "" }
    let cleaned = cleanedField(raw)
    let lower = cleaned.lowercased()

    guard lower.hasPrefix(label.lowercased()) else {
      return cleaned
    }

    var remainder = cleaned.dropFirst(label.count)
    while let first = remainder.first,
          first == ":" || first == " " {
      remainder = remainder.dropFirst()
    }

    return String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func prettySex(_ raw: String) -> String {
    let lower = raw.lowercased()
    if lower == "male" || lower == "female" {
      return raw.capitalized
    }
    return raw
  }

  /// Maps internal model labels to user-facing species names.
  /// Keys must match the lowercased, underscore-stripped output of `speciesLabels`
  /// in `CatchPhotoAnalyzer.swift`. When adding a species, update both in lockstep
  /// (see the `/new-species` slash command in `.claude/commands/`).
  static let speciesDisplayNames: [String: String] = [
    "atlantic salmon": "Atlantic Salmon",
    "brook trout": "Brook Trout",
    "brown trout": "Brown Trout",
    "chinook salmon": "Chinook Salmon",
    "lingcod": "Lingcod",
    "musky": "Musky",
    "rainbow trout": "Rainbow Trout",
    "sea run trout": "Sea-Run Trout",
    "steelhead": "Steelhead",
    "striped bass": "Striped Bass",
    "other": "Bi-catch",
  ]

  /// Species keys (lowercased, space-separated — same form as `speciesDisplayNames`
  /// keys) that have a holding/traveler lifecycle dimension and trigger the
  /// lifecycle-confirmation sub-step in the researcher chat flow. Any species
  /// that has `<species>_holding` / `<species>_traveler` variants in the model's
  /// `speciesLabels` belongs here.
  static let speciesWithLifecycle: Set<String> = [
    "steelhead",
    "atlantic salmon",
  ]

  func splitSpecies(_ raw: String?) -> (species: String, stage: String?) {
    let valueOnly = stripLeadingLabel(raw, label: "species")
    if valueOnly.isEmpty { return ("-", nil) }

    // Check if the value is the "unable to detect" sentinel
    if valueOnly.lowercased().contains("unable to") {
      return (valueOnly, nil)
    }

    let parts = valueOnly.split(separator: " ").map { String($0) }

    // Only "holding" and "traveler" are valid lifecycle stages.
    // If the last word is one of these, split it off; otherwise the entire string is the species.
    let lifecycleKeywords = ["holding", "traveler"]
    if let lastWord = parts.last, lifecycleKeywords.contains(lastWord.lowercased()) {
      let speciesParts = parts.dropLast()
      let speciesRaw = speciesParts.map { $0.lowercased() }.joined(separator: " ")
      let species = Self.speciesDisplayNames[speciesRaw]
        ?? speciesParts.map { $0.capitalized }.joined(separator: " ")
      let stage = lastWord.capitalized
      return (species.isEmpty ? "-" : species, stage)
    }

    // No lifecycle stage — look up the full string as a display name
    let speciesRaw = parts.map { $0.lowercased() }.joined(separator: " ")
    let species = Self.speciesDisplayNames[speciesRaw]
      ?? valueOnly.capitalized
    return (species, nil)
  }

  /// Collapse a length string like "20-25 inches" to its midpoint ("23 inches").
  /// Used by `extractLengthInches` to produce the single-value Int that gets
  /// persisted (final + initialAnalysis) and by anywhere else that needs a
  /// scalar form. The user-facing chat preserves the range — see
  /// `formattedSummary` — so this midpoint never reaches the bubble; only
  /// the database row.
  func averagedLength(from raw: String) -> String {
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

  private func formattedSummary(from analysis: CatchPhotoAnalysis?) -> String {
    guard let a = analysis else { return "No details yet." }

    var parts: [String] = []

      let cleaned = cleanedField(a.riverName ?? "")

      if !cleaned.isEmpty
          && !cleaned.hasPrefix("No river detected for")
          && !cleaned.hasPrefix("No rivers configured for") {
        // Normal case: show the matched river / water body name
        parts.append("Location: \(cleaned)")
      } else if let loc = currentLocation {
        // No river match — show raw GPS coordinates
        parts.append(String(
          format: "Location: %.4f, %.4f",
          loc.coordinate.latitude,
          loc.coordinate.longitude
        ))
      } else {
        parts.append("Location: No GPS coordinates available")
      }

    let (species, stage) = splitSpecies(a.species)
    if !species.isEmpty, species != "-" {
      parts.append("Species: \(species)")
    }
    if let stage, !stage.isEmpty {
      parts.append("Lifecycle stage: \(stage)")
    }

    let sexValueRaw = stripLeadingLabel(a.sex, label: "sex")
    if !sexValueRaw.isEmpty {
      let pretty = prettySex(sexValueRaw)
      parts.append("Sex: \(pretty)")
    }

    if let lengthRaw = a.estimatedLength {
      let cleanedLen = cleanedField(lengthRaw)
      let lower = cleanedLen.lowercased()
      if lower.contains("not available") {
        parts.append("Estimated length: Inconclusive, please manually enter in the chat below")
      } else if !cleanedLen.isEmpty {
        // Preserve the analyzer's display string verbatim — ranges like
        // "20-25 inches" stay as ranges so the user can see the uncertainty.
        // The midpoint is computed separately for backend persistence via
        // `extractLengthInches`.
        parts.append("Estimated length: **\(cleanedLen)**")
      }
    }

    // Include girth/weight for researcher flow
    if let flow = researcherFlow {
      if let g = flow.girthInches {
        let prefix = flow.girthIsEstimated ? "~" : ""
        parts.append("Estimated girth: **\(prefix)\(String(format: "%.1f inches", g))**")
      }
      if let w = flow.weightLbs {
        let prefix = flow.weightIsEstimated ? "~" : ""
        parts.append("Estimated weight: **\(prefix)\(String(format: "%.1f lbs", w))**")
      }
    }

    return parts.isEmpty ? "No details yet." : parts.joined(separator: "\n")
  }

  // MARK: - Save command

  private func performSave() {
    var lines: [String] = []

    if isResearcherRole {
      let first = AuthService.shared.currentFirstName ?? ""
      let last = AuthService.shared.currentLastName ?? ""
      let full = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
      lines.append("Researcher: \(full.isEmpty ? "-" : full)")
    } else {
      lines.append("Guide: \(guideName.isEmpty ? "-" : guideName)")
      lines.append("Angler: \(currentAnglerName.isEmpty ? "-" : currentAnglerName)")
    }

    // The flow holds the authoritative post-confirmation values (they reflect
    // any edits the user made to species, length, girth, river, etc.). Prefer
    // the flow's river name if the user corrected it; otherwise fall back to
    // the ML-detected value on currentAnalysis. GPS coords continue to come
    // from `currentLocation` below — they're never overwritten by chat edits.
    let flowRiver = researcherFlow?.riverName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let analysisRiver = cleanedField(currentAnalysis?.riverName ?? "")
    let rawRiver = !flowRiver.isEmpty ? flowRiver : analysisRiver
    let saveRiver = rawRiver.isEmpty ? unresolvedLocationLabel() : rawRiver
    lines.append("River: \(saveRiver)")

    if let flow = researcherFlow {
      lines.append("Species: \(flow.species?.isEmpty == false ? flow.species! : "-")")
      lines.append("Lifecycle stage: \(flow.lifecycleStage ?? "-")")
      lines.append("Sex: \(flow.sex?.isEmpty == false ? flow.sex! : "-")")
      if let l = flow.lengthInches {
        lines.append("Estimated length: **\(String(format: "%.1f inches", l))**")
      } else {
        lines.append("Estimated length: -")
      }
      if let g = flow.girthInches {
        let prefix = flow.girthIsEstimated ? "~" : ""
        lines.append("Estimated girth: **\(prefix)\(String(format: "%.1f inches", g))**")
      }
      if let w = flow.weightLbs {
        let prefix = flow.weightIsEstimated ? "~" : ""
        lines.append("Estimated weight: **\(prefix)\(String(format: "%.1f lbs", w))**")
      }
    } else {
      // Defensive — shouldn't happen now that every photo analysis creates a flow.
      lines.append("Species: -")
      lines.append("Lifecycle stage: -")
      lines.append("Sex: -")
      lines.append("Estimated length: -")
    }

    if let loc = currentLocation {
      lines.append(String(
        format: "Location: %.5f, %.5f",
        loc.coordinate.latitude,
        loc.coordinate.longitude
      ))
    } else {
      lines.append("Location: -")
    }

    if let note = attachedVoiceNotes.last {
      lines.append("Voice memo: YES (id: \(note.id.uuidString))")
    } else {
      lines.append("Voice memo: NO")
    }

    let logText = lines.joined(separator: "\n")
    self.catchLog = logText

    AppLogging.log("================ CATCH LOG ================", level: .info, category: .catch)
    AppLogging.log({ logText }, level: .debug, category: .catch)
    AppLogging.log("===========================================", level: .info, category: .catch)

    appendAssistant(
      """
      Got it, here's the catch summary I'm saving:

      \(logText)

      Saving catch now…
      """
    )

    saveRequested = true
  }

  // MARK: - Voice note attachment

  func attachVoiceNote(_ note: LocalVoiceNote) {
    if let previous = attachedVoiceNotes.last {
      VoiceNoteStore.shared.delete(previous)
      attachedVoiceNotes.removeAll()
    }

    attachedVoiceNotes.append(note)

    Task { @MainActor in
      self.appendAssistant(
        "🎙 Voice memo recorded. You can also re-record later — I'll always use the latest version."
      )

      try? await Task.sleep(nanoseconds: 1_000_000_000)

      // Every flow (guide + researcher, Conservation on or off) now runs
      // through ResearcherCatchFlowManager. A researcherFlow is always set by
      // the time a voice memo is attachable.
      guard let flow = self.researcherFlow else { return }
      self.voiceMemoAnchorMessageID = nil
      flow.currentStep = .complete

      let summaryText = flow.finalAnalysisText()
      self.appendAssistant(summaryText)
      self.appendAssistant("Saving catch now...")
      self.triggerSave()
    }
  }

  // MARK: - Catch snapshot

  struct CatchSnapshot {
    var guideName: String
    var anglerName: String

    var riverName: String?
    var species: String?
    var lifecycleStage: String?
    var sex: String?
    var lengthInches: Int?

    var latitude: Double?
    var longitude: Double?
    var voiceNoteId: UUID?
    var photoFilename: String?
    /// Filename of the close-up head shot captured in the conservation/research
    /// flow, if present. Maps to `CatchReport.headPhotoFilename` and the v5
    /// upload field `catch.headPhoto`.
    var headPhotoFilename: String?

    var initialRiverName: String?
    var initialSpecies: String?
    var initialLifecycleStage: String?
    var initialSex: String?
    var initialLengthInches: Int?

    /// JSON-encoded ML feature vector from initial analysis (26 features).
    var mlFeatureVector: Data?
    /// How the length was estimated: "regressor", "heuristic", or "manual".
    var lengthSource: String?
    /// Version of the LengthRegressor model that produced the estimate.
    var modelVersion: String?
    /// JSON-encoded `MLDiagnostics`: confidences, raw model outputs, multi-
    /// model versions, stage timings, landmarks, EXIF. See model docstring.
    var mlDiagnostics: Data?

    // Girth & weight estimation (researcher flow) — final confirmed values.
    // The "is estimated" flags live only on ResearcherCatchFlowManager; they're
    // deliberately not carried through the snapshot because they aren't
    // persisted or uploaded.
    var girthInches: Double?
    var weightLbs: Double?
    var weightDivisor: Int?
    var weightDivisorSource: String?
    var girthRatio: Double?
    var girthRatioSource: String?

    // Initial measurement estimates (calculated with confirmed species, before user edits length/girth)
    var initialLengthForMeasurements: Double?
    var initialGirthInches: Double?
    var initialWeightLbs: Double?
    var initialWeightDivisor: Int?
    var initialWeightDivisorSource: String?
    var initialGirthRatio: Double?
    var initialGirthRatioSource: String?

    /// Whether this catch participated in the conservation (research-grade) flow.
    /// True for researchers and for guides who toggled Conservation on.
    /// Maps to the v5 upload field `catch.conservationOptIn`.
    var conservationOptIn: Bool

    /// Whether the user opted this catch OUT of ML training data use.
    /// Only `true` for public users who turned off the toggle in
    /// ManageProfileView → Privacy. Always `false` for guides, anglers,
    /// and researchers. Maps to `catch.mlTrainingOptOut`.
    var mlTrainingOptOut: Bool

    // Research tag / sample IDs — only populated when the researcher chose a
    // corresponding study or sample type during the post-measurement flow.
    // Map to the v5 upload fields of the same name.
    var floyId: String?
    var pitId: String?
    /// Scale envelope barcode — populated whenever the researcher answered
    /// Yes at sample-collection (scales are always taken when sampling).
    var scaleEnvelopeId: String?
    /// Fin clip envelope barcode — populated only when the researcher
    /// answered Yes at the fin-clip prompt and scanned the second envelope.
    var finEnvelopeId: String?
  }

  func makeCatchSnapshot() -> CatchSnapshot? {
    guard let analysis = currentAnalysis else {
      return nil
    }

    // Prefer the flow's river name if the user corrected it during the
    // identification step; otherwise use the ML-detected value. When the
    // user explicitly rejected/skipped the location, trust the flow's nil
    // exclusively — falling back to the ML name would resurrect a value the
    // user just discarded. GPS latitude/longitude continue to be read from
    // `currentLocation` below and are never overwritten by chat edits.
    let flowRiverRaw = researcherFlow?.riverName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let analysisRiverRaw = cleanedField(analysis.riverName ?? "")
    let userTouchedLocation = researcherFlow?.riverNameWasCorrected ?? false
    let cleanedRiverRaw: String
    if userTouchedLocation {
      cleanedRiverRaw = flowRiverRaw
    } else {
      cleanedRiverRaw = !flowRiverRaw.isEmpty ? flowRiverRaw : analysisRiverRaw
    }
    // Empty after the above means no name was ever supplied — upload nil so
    // the backend records the absence cleanly. GPS still travels via
    // latitude/longitude below.
    let finalRiver: String? = cleanedRiverRaw.isEmpty ? nil : cleanedRiverRaw

    let (species, stage) = splitSpecies(analysis.species)
    let sexValueRaw = stripLeadingLabel(analysis.sex, label: "sex")
    let prettySexValue = prettySex(sexValueRaw)
    let rawLen = cleanedField(analysis.estimatedLength ?? "")

    let lengthInches = extractLengthInches(from: rawLen)

    let initRiver = cleanedField(initialAnalysis?.riverName ?? "")
    let (initSpecies, initStage) = splitSpecies(initialAnalysis?.species)
    let initSexRaw = stripLeadingLabel(initialAnalysis?.sex, label: "sex")
    let initPrettySex = prettySex(initSexRaw)
    let initRawLen = cleanedField(initialAnalysis?.estimatedLength ?? "")
    let initLengthInches = extractLengthInches(from: initRawLen)

    // Use researcher flow values if available (overrides ML-only analysis)
    let finalSpecies: String?
    let finalStage: String?
    let finalSex: String?
    let finalLength: Int?

    if let flow = researcherFlow {
      finalSpecies = flow.species
      finalStage = flow.lifecycleStage
      finalSex = flow.sex
      finalLength = flow.lengthInches.map { Int(round($0)) }
    } else {
      finalSpecies = species.isEmpty || species == "-" ? nil : species
      finalStage = stage
      finalSex = prettySexValue.isEmpty ? nil : prettySexValue
      finalLength = lengthInches
    }

    return CatchSnapshot(
      guideName: guideName,
      anglerName: currentAnglerName,
      riverName: finalRiver,
      species: finalSpecies,
      lifecycleStage: finalStage,
      sex: finalSex,
      lengthInches: finalLength,
      latitude: currentLocation?.coordinate.latitude,
      longitude: currentLocation?.coordinate.longitude,
      voiceNoteId: attachedVoiceNotes.last?.id,
      photoFilename: photoFilename,
      headPhotoFilename: headPhotoFilename,
      initialRiverName: initRiver.isEmpty ? nil : initRiver,
      initialSpecies: initSpecies.isEmpty || initSpecies == "-" ? nil : initSpecies,
      initialLifecycleStage: initStage,
      initialSex: initPrettySex.isEmpty ? nil : initPrettySex,
      initialLengthInches: initLengthInches,
      mlFeatureVector: initialAnalysis?.featureVector.flatMap { try? JSONEncoder().encode($0) },
      lengthSource: researcherFlow?.lengthSource?.rawValue
        ?? (currentAnalysis?.lengthSource ?? initialAnalysis?.lengthSource)?.rawValue,
      modelVersion: initialAnalysis?.modelVersion,
      mlDiagnostics: encodeMLDiagnostics(from: initialAnalysis),
      girthInches: researcherFlow?.girthInches,
      weightLbs: researcherFlow?.weightLbs,
      weightDivisor: researcherFlow?.divisor,
      weightDivisorSource: researcherFlow?.divisorSource,
      girthRatio: researcherFlow?.girthRatio,
      girthRatioSource: researcherFlow?.girthRatioSource,
      initialLengthForMeasurements: researcherFlow?.initialLengthForMeasurements,
      initialGirthInches: researcherFlow?.initialGirthInches,
      initialWeightLbs: researcherFlow?.initialWeightLbs,
      initialWeightDivisor: researcherFlow?.initialDivisor,
      initialWeightDivisorSource: researcherFlow?.initialDivisorSource,
      initialGirthRatio: researcherFlow?.initialGirthRatio,
      initialGirthRatioSource: researcherFlow?.initialGirthRatioSource,
      conservationOptIn: isResearcherRole || conservationMode,
      mlTrainingOptOut: AuthService.shared.currentUserType == .public
        ? MLTrainingOptOutStore.shared.isOptedOut
        : false,
      // The unified .studyID chat step captures one ID per catch into
      // `studyTagId`; here we dispatch it to the right CatchReport column
      // based on the chosen `studyType`. Radio Telemetry has no backend
      // column today — its ID is captured in the chat for UX continuity
      // but won't make it to the server until the schema adds a column.
      //
      // Sample envelopes:
      //   * scaleEnvelopeId: set when Scale or Both was picked at the
      //     consolidated sample step.
      //   * finEnvelopeId: set when Fin or Both was picked.
      floyId: routeStudyId(forType: .floy),
      pitId: routeStudyId(forType: .pit),
      scaleEnvelopeId: nonEmpty(researcherFlow?.scaleEnvelopeId),
      finEnvelopeId: nonEmpty(researcherFlow?.finEnvelopeId)
    )
  }

  /// Returns `studyTagId` only when the researcher picked the supplied
  /// study type; otherwise nil. Used by the snapshot builder to fan a
  /// single captured ID out to the right per-type column.
  private func routeStudyId(forType type: ResearcherCatchFlowManager.StudyType) -> String? {
    guard let flow = researcherFlow,
          flow.studyType == type else { return nil }
    return nonEmpty(flow.studyTagId)
  }

  /// Build the `MLDiagnostics` provenance blob from the initial (pre-user-
  /// correction) analysis snapshot and JSON-encode it for storage on the
  /// `CatchReport`. Returns nil when no analysis ran (e.g. researcher
  /// quick-capture without a photo) so the field stays absent server-side.
  ///
  /// This first pass only pulls fields the analyzer already computes and
  /// surfaces today; richer fields (raw model outputs, multi-model versions,
  /// stage timings, hand landmarks, EXIF) are populated by upcoming
  /// `CatchPhotoAnalyzer` instrumentation work. The codable shape is forward-
  /// compatible — every field is optional, so older diagnostics survive
  /// decode unchanged once the new fields start arriving.
  private func encodeMLDiagnostics(from analysis: CatchPhotoAnalysis?) -> Data? {
    guard let analysis else { return nil }
    let alternatives: [MLDiagnostics.SpeciesAlternative]? = analysis.speciesAlternatives.isEmpty
      ? nil
      : analysis.speciesAlternatives.map {
          MLDiagnostics.SpeciesAlternative(
            label: $0.label, confidence: $0.confidence, isPrimary: $0.isPrimary
          )
        }
    let versions: MLDiagnostics.ModelVersions? = analysis.modelVersion.map {
      MLDiagnostics.ModelVersions(lengthRegressor: $0)
    }
    let diagnostics = MLDiagnostics(
      speciesConfidence: analysis.speciesConfidence,
      lifecycleStageConfidence: analysis.lifecycleStageConfidence,
      sexConfidence: analysis.sexConfidence,
      lengthAtSpeciesCap: analysis.lengthAtSpeciesCap,
      speciesAlternatives: alternatives,
      modelVersions: versions
    )
    return try? JSONEncoder().encode(diagnostics)
  }

  /// Trim + nil-coalesce so empty strings never leak into the snapshot.
  private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else { return nil }
    return trimmed
  }

  func extractLengthInches(from raw: String) -> Int? {
    if raw.isEmpty { return nil }

    let normalized = averagedLength(from: raw)
    let digits = normalized.filter { "0123456789.".contains($0) }
    guard !digits.isEmpty else { return nil }

    if let value = Double(digits) {
      return Int(round(value))
    }
    return nil
  }
}

#if canImport(UIKit)
extension UIApplication {
  func endEditing(_ force: Bool) {
    connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }?
      .endEditing(force)
  }
}
#endif
