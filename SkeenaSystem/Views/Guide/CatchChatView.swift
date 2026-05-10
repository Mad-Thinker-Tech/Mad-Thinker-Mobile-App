// Bend Fly Shop

import CoreLocation
import ImageIO
import MapboxMaps
import SwiftUI

struct CatchChatView: View {
  @ObservedObject var viewModel: CatchChatViewModel

  @State private var showSourceActionSheet = false
  @State private var showImagePicker = false
  @State private var imagePickerSource: ImagePicker.Source = .library

  // Voice memo sheet
  @State private var showVoiceNoteSheet = false

  // Sample envelope barcode scanner sheet — presented when the user taps
  // the "Scan" capsule on either the .scaleScan or .finScan step. The
  // sheet returns either a parsed envelope ID (handed off to the VM, routed
  // to the right field based on currentStep) or a manual-entry signal (just
  // dismiss and let the user type into the input bar).
  @State private var showSampleScanner = false

  // Study: show Yes/No first, then expand to type icons. Sample collection
  // is now driven by the chat-capsule row (Yes/No) plus per-step Scan/Type
  // capsules — no icon-expansion state needed for it.
  @State private var showStudyTypeIcons = false

  /// Whether the chat uses the scientific visual style ("Science mode" label).
  private var isResearcherMode: Bool { viewModel.isResearcherMode }

  /// True once the user has begun interacting (beyond the initial greeting).
  private var hasInteracted: Bool { viewModel.messages.count > 1 }

  var body: some View {
    VStack(spacing: 0) {
      // Conservation-mode banner — shown only when a guide has routed
      // themselves into the research-grade flow via the Conservation toggle.
      // Researchers already get the scientific visual style and don't need
      // this cue (they know they're in research mode).
      if viewModel.conservationMode && !isResearcherMode {
        HStack(spacing: 6) {
          Image(systemName: "leaf.fill")
            .font(.brandCaption)
            .foregroundColor(.brandSuccess)
          Text("Conservation mode")
            .font(.brandCaption.weight(.semibold))
            .foregroundColor(.brandTextPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.brandSuccess.opacity(0.15))
        .accessibilityIdentifier("conservationModeBanner")
      }

      // Reset button — subtle, right-aligned, active only after interaction begins
      HStack {
        Spacer()
        Button {
          showStudyTypeIcons = false
          viewModel.resetForNewCatch()
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "arrow.counterclockwise")
            Text("Reset")
          }
          .font(.brandCaption)
          .foregroundColor(hasInteracted ? .white.opacity(0.5) : .white.opacity(0.15))
        }
        .disabled(!hasInteracted)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .accessibilityIdentifier("chatResetButton")
      }

      // Messages + inline capture options
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { idx, msg in
              messageRow(msg, index: idx)
            }

            // Typing / analyzing indicator
            if viewModel.isAssistantTyping {
              HStack(spacing: 8) {
                Image(systemName: "leaf.circle.fill")
                  .resizable()
                  .scaledToFit()
                  .frame(width: 24, height: 24)
                  .foregroundColor(.brandSuccess)
                  .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                HStack(spacing: 6) {
                  ProgressView()
                    .scaleEffect(0.8)
                  Text("Analyzing…")
                    .font(.brandFootnote)
                }
                .foregroundColor(.brandTextPrimary.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.brandStroke)
                .cornerRadius(16)

                Spacer(minLength: 40)
              }
              .padding(.top, 4)
            }
          }
          .padding(.horizontal, 4)
          .padding(.top, 4)
          // Extra bottom inset so the last bubble doesn't kiss the divider
          // above the input bar — measurements/final-analysis bubbles are
          // tall and were sometimes overlapping the separator line.
          .padding(.bottom, 20)
        }
        .modifier(ScrollIndicatorModifier())
        .onChange(of: viewModel.messages.count) { newCount in
          // Only auto-scroll when there is more than one message.
          // This keeps the very first message near the top, under the header.
          guard newCount > 1, let lastID = viewModel.messages.last?.id else { return }

          DispatchQueue.main.async {
            proxy.scrollTo(lastID, anchor: .bottom)
          }
        }
        // Re-scroll when study/sample icons expand so they aren't
        // clipped behind the input bar.
        .onChange(of: showStudyTypeIcons) { _ in
          scrollToBottom(proxy: proxy)
        }
      }

      // Subtle separator between messages and input
      Divider()
        .background(Color.brandStrokeStrong)

      inputBar
    }
    .background(Color.clear)
    .onChange(of: showSourceActionSheet) { presented in
      AppLogging.log("ShowSourceActionSheet changed: \(presented)", level: .debug, category: .angler)
      // UI-test bypass: instead of presenting the system photo source dialog
      // (and then PHPickerViewController, which XCUITest cannot drive), load
      // a fixture image from a path passed via launch environment and feed it
      // straight to the view model. The picker sheet is never presented.
      if presented, Self.isUITestingPhotoBypassEnabled {
        injectUITestFixturePhoto()
        showSourceActionSheet = false
      }
    }
    // Modern photo source dialog
    .confirmationDialog(
      "Add Photo",
      isPresented: $showSourceActionSheet,
      titleVisibility: .visible
    ) {
      Button("Camera") {
        AppLogging.log("Photo source selected: camera", level: .debug, category: .angler)
        imagePickerSource = .camera
        showImagePicker = true
      }
      Button("Photo Library") {
        AppLogging.log("Photo source selected: library", level: .debug, category: .angler)
        imagePickerSource = .library
        showImagePicker = true
      }
      Button("Cancel", role: .cancel) {}
    }

    .sheet(isPresented: $showImagePicker) {
      VStack {
        ImagePicker(source: imagePickerSource) { picked in
          let image = picked.image
          AppLogging.log("ImagePicker returned image: size=\(Int(image.size.width))x\(Int(image.size.height))", level: .debug, category: .angler)
          viewModel.handlePhotoSelected(picked)
        }
      }
      .onAppear {
        let src = (imagePickerSource == .camera) ? "camera" : "library"
        AppLogging.log("ImagePicker sheet appeared with source: \(src)", level: .debug, category: .angler)
      }
      .onDisappear {
        AppLogging.log("ImagePicker sheet disappeared", level: .debug, category: .angler)
      }
    }
    .sheet(isPresented: $showVoiceNoteSheet) {
      ChatVoiceNoteSheet { note in
        viewModel.attachVoiceNote(note)
      }
    }
    // The voice-memo step is now capsule-driven — a tap on the "Yes" capsule
    // flips `requestVoiceNoteSheet` on the VM. Mirror it into the view's
    // local sheet binding and reset the flag immediately so it's one-shot.
    // Using the single-param onChange signature since the project still
    // deploys to iOS 16.6 (the two-param variant is iOS 17+).
    .onChange(of: viewModel.requestVoiceNoteSheet) { requested in
      if requested {
        // UI-test bypass: simulator has no microphone, so we never present
        // the recording sheet. Instead, build a synthetic LocalVoiceNote
        // (with a tiny stub audio file so the upload pipeline's
        // `data.isEmpty` guard passes) and attach it directly. The voice
        // memo data still flows through VoiceNoteStore → catch JSON →
        // upload payload, end-to-end.
        if Self.isUITestingActive {
          Self.injectUITestFixtureVoiceNote(into: viewModel)
          viewModel.requestVoiceNoteSheet = false
          return
        }
        showVoiceNoteSheet = true
        viewModel.requestVoiceNoteSheet = false
      }
    }
    .sheet(isPresented: $showSampleScanner) {
      EnvelopeBarcodeScanner(
        onScan: { id in
          showSampleScanner = false
          // Route the parsed barcode to the right flow-manager handler
          // based on which step the user is currently on.
          switch viewModel.researcherFlow?.currentStep {
          case .scaleScan:
            viewModel.researcherRecordScannedScaleEnvelope(id)
          case .finScan:
            viewModel.researcherRecordScannedFinEnvelope(id)
          default:
            // Defensive: shouldn't happen — the scanner is only presented
            // from one of the two scan steps.
            break
          }
        },
        onManualEntry: {
          // Dismiss the scanner; the chat input bar is always live so the
          // user can immediately type the ID. Capsules on the bubble stay
          // intact in case they change their mind.
          showSampleScanner = false
        },
        onCancel: {
          showSampleScanner = false
        }
      )
    }
    .onChange(of: viewModel.requestSampleScannerSheet) { requested in
      if requested {
        showSampleScanner = true
        viewModel.requestSampleScannerSheet = false
      }
    }
  }

  // MARK: - Input bar

  private var inputBar: some View {
    HStack(spacing: 8) {
      TextField("Type your message…", text: $viewModel.userInput)
        .submitLabel(.send)
        .onSubmit {
          viewModel.sendCurrentInput()
          hideKeyboard()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.brandSurface)
        .cornerRadius(16)
        .foregroundColor(.brandTextPrimary)
        .accessibilityIdentifier("chatInputField")

      Button(action: {
        viewModel.sendCurrentInput()
        hideKeyboard()
      }) {
        Image(systemName: "paperplane.fill")
          .font(.system(size: 16, weight: .semibold))
          .padding(8)
      }
      .foregroundColor(.brandTextPrimary)
      .background(
        viewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? Color.brandStrokeStrong
          : Color.brandAccent
      )
      .cornerRadius(16)
      .disabled(
        viewModel.userInput
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty
      )
      .accessibilityIdentifier("chatSendButton")
    }
    .padding(.top, 6)
    .padding(.horizontal, 4)
  }

  // MARK: - Researcher step buttons

  // MARK: - Inline choice buttons (rendered below message)

  @ViewBuilder
  private var researcherInlineChoices: some View {
    let step = viewModel.researcherFlow?.currentStep

    if step == .studyParticipation {
      HStack(spacing: 12) {
        choiceButton("Pit", icon: "tag.fill", disabled: true) {}
        choiceButton("Floy", icon: "tag.fill", disabled: false) {
          viewModel.researcherSelectStudy(.floy)
        }
        choiceButton("Radio", icon: "antenna.radiowaves.left.and.right", disabled: true) {}
        choiceButton("No", icon: "forward.fill", disabled: false) {
          viewModel.researcherConfirm()
        }
      }
    }
  }

  private func choiceButton(_ label: String, icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.brandTitle3)
        .foregroundColor(disabled ? .gray : .white)
        .frame(minWidth: 40)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Color.brandTextPrimary.opacity(disabled ? 0.05 : 0.12))
        .cornerRadius(12)
    }
    .disabled(disabled)
  }

  // MARK: - Researcher side buttons (right of message)

  @ViewBuilder
  private var researcherStepButtons: some View {
    let step = viewModel.researcherFlow?.currentStep

    if step == .studyParticipation {
      if showStudyTypeIcons {
        // Study type options: Pit (disabled), Floy, Radio (disabled)
        Button {} label: {
          VStack(spacing: 4) {
            Image(systemName: "tag.fill").font(.brandTitle3)
            Text("Pit").font(.brandCaption)
          }.foregroundColor(.brandTextSecondary)
        }
        .disabled(true)

        Button {
          showStudyTypeIcons = false
          viewModel.researcherSelectStudy(.floy)
        } label: {
          VStack(spacing: 4) {
            Image(systemName: "tag.fill").font(.brandTitle3)
            Text("Floy").font(.brandCaption)
          }
        }

        Button {} label: {
          VStack(spacing: 4) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.brandTitle3)
            Text("Radio").font(.brandCaption)
          }.foregroundColor(.brandTextSecondary)
        }
        .disabled(true)
      } else {
        // Yes / No
        Button { showStudyTypeIcons = true } label: {
          Image(systemName: "checkmark.circle.fill").font(.brandTitle2)
        }
        Button {
          viewModel.researcherConfirm()
        } label: {
          Image(systemName: "xmark.circle.fill").font(.brandTitle2)
        }
      }
    } else if step == .sampleCollection || step == .finPrompt {
      // Yes/No prompt steps. Yes routes through the VM (advances flow +
      // posts next bubble); No is just researcherConfirm().
      let yesAction: ChatCapsuleAction = (step == .sampleCollection)
        ? .sampleCollect(yes: true)
        : .finChoice(yes: true)
      Button {
        viewModel.handleCapsuleTap(yesAction)
      } label: {
        Image(systemName: "checkmark.circle.fill").font(.brandTitle2)
      }
      Button {
        viewModel.researcherConfirm()
      } label: {
        Image(systemName: "xmark.circle.fill").font(.brandTitle2)
      }
    } else if step == .floyTagID {
      if let tag = viewModel.researcherFlow?.floyTagNumber, !tag.isEmpty {
        Button {
          viewModel.researcherConfirm()
        } label: {
          Image(systemName: "checkmark.circle.fill")
            .font(.brandTitle2)
        }
      }
    } else if step == .scaleScan || step == .finScan {
      // Show the camera-scan icon as a side affordance whenever the user is
      // on a scan step — even before they engage the capsule on the bubble
      // — so the scanner is one tap away. Once a barcode has been captured,
      // also surface the Confirm checkmark.
      Button {
        viewModel.handleCapsuleTap(.openSampleScanner)
      } label: {
        Image(systemName: "barcode.viewfinder").font(.brandTitle2)
      }
      let captured: String? = (step == .scaleScan)
        ? viewModel.researcherFlow?.scaleEnvelopeId
        : viewModel.researcherFlow?.finEnvelopeId
      if let code = captured, !code.isEmpty {
        Button {
          viewModel.researcherConfirm()
        } label: {
          Image(systemName: "checkmark.circle.fill")
            .font(.brandTitle2)
        }
      }
    } else {
      let useConfirmStyle = step == .identification || step == .confirmLength || step == .confirmGirth || step == .finalSummary
      let isFinalSummary = step == .finalSummary
      Button {
        viewModel.researcherConfirm()
      } label: {
        Image(systemName: useConfirmStyle ? "checkmark.circle.fill" : "arrow.right.circle.fill")
          .font(isFinalSummary ? .largeTitle : .title2)
          .foregroundColor(isFinalSummary ? .green : .white)
      }
      .accessibilityIdentifier(isFinalSummary ? "researcherFinalConfirmButton" : "researcherStepConfirmButton")
    }
  }

  private func hideKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.endEditing(true)
    #endif
  }

  // MARK: - UI test photo bypass

  /// True when the test runner has launched the app with `-uiTesting` AND
  /// supplied at least one fixture photo path via launch environment. Gates
  /// the picker bypass so production runs are completely unaffected.
  private static var isUITestingPhotoBypassEnabled: Bool {
    guard CommandLine.arguments.contains("-uiTesting") else { return false }
    let env = ProcessInfo.processInfo.environment
    return env["UI_TEST_HEAD_IMAGE_PATH"] != nil || env["UI_TEST_BODY_IMAGE_PATH"] != nil
  }

  /// Load a fixture image from disk and route it through the same
  /// `handlePhotoSelected` entry point the real picker uses. Picks the
  /// head-vs-body image based on the view model's current step.
  ///
  /// Reads EXIF GPS from the file via ImageIO so the river-locator code
  /// path actually exercises when the fixture carries coordinates. Without
  /// this, every UI-test catch would hit the loc-skip branch — masking the
  /// loc-confirm / river-match path.
  private func injectUITestFixturePhoto() {
    let env = ProcessInfo.processInfo.environment
    let key = viewModel.awaitingHeadPhoto ? "UI_TEST_HEAD_IMAGE_PATH" : "UI_TEST_BODY_IMAGE_PATH"
    guard
      let path = env[key],
      let image = UIImage(contentsOfFile: path)
    else {
      AppLogging.log("UI-test photo bypass: missing image for \(key)", level: .warn, category: .angler)
      return
    }
    let exifLocation = Self.readEXIFLocation(fromFileAt: path)
    let picked = PickedPhoto(image: image, exifDate: Date(), exifLocation: exifLocation)
    let gpsTag = exifLocation.map { String(format: "%.4f,%.4f", $0.coordinate.latitude, $0.coordinate.longitude) } ?? "no-gps"
    AppLogging.log("UI-test photo bypass: injected \(key) (\(Int(image.size.width))x\(Int(image.size.height)), \(gpsTag))",
                   level: .info, category: .angler)
    viewModel.handlePhotoSelected(picked)
  }

  /// Pulls GPS lat/long out of a JPEG/HEIC's EXIF block. `UIImage` strips
  /// metadata, so we open the file fresh via `CGImageSource` and read the
  /// `kCGImagePropertyGPSDictionary` directly. Returns nil if either the
  /// file has no GPS block or one of the four expected keys (latitude,
  /// longitude, and the N/S + E/W reference letters) is missing.
  private static func readEXIFLocation(fromFileAt path: String) -> CLLocation? {
    let url = URL(fileURLWithPath: path)
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
      let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
      let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
      let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double
    else {
      return nil
    }
    // EXIF stores magnitudes as positive numbers and uses a separate "Ref"
    // letter to indicate the hemisphere ("S" or "W" → negate).
    let latRef = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) ?? "N"
    let lonRef = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) ?? "E"
    let signedLat = (latRef.uppercased() == "S") ? -lat : lat
    let signedLon = (lonRef.uppercased() == "W") ? -lon : lon
    return CLLocation(latitude: signedLat, longitude: signedLon)
  }

  // MARK: - UI test voice-memo bypass

  /// True whenever the test runner has launched the app with `-uiTesting`.
  /// Used by the voice-note path to swap the AVFoundation recording sheet
  /// for a synthetic note on the simulator (no real microphone exists).
  private static var isUITestingActive: Bool {
    CommandLine.arguments.contains("-uiTesting")
  }

  /// Build a `LocalVoiceNote` with synthetic audio + transcript and
  /// attach it to the in-flight catch through the same `attachVoiceNote`
  /// path the real recording sheet uses. The voice memo file gets written
  /// under `Documents/VoiceNotes/note_<uuid>.m4a` exactly where
  /// `UploadCatchReport.loadVoiceMemo` expects it.
  ///
  /// Audio bytes are intentionally synthetic — `loadVoiceMemo` validates
  /// non-emptiness only (no format check), so a 32-byte stub satisfies
  /// the upload pipeline. The transcript is hardcoded but recognizable
  /// from a backend row check.
  private static func injectUITestFixtureVoiceNote(into viewModel: CatchChatViewModel) {
    let stubAudioBytes: [UInt8] = [
      // Minimal MP4/M4A "ftyp" box header — won't actually play but
      // satisfies any naive "looks like an m4a" sniffing on the wire.
      0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70,
      0x4D, 0x34, 0x41, 0x20, 0x00, 0x00, 0x00, 0x00,
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D,
      0x6D, 0x70, 0x34, 0x32, 0x00, 0x00, 0x00, 0x00,
    ]
    let tmpURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("uitest_voice_\(UUID().uuidString).m4a")
    do {
      try Data(stubAudioBytes).write(to: tmpURL)
    } catch {
      AppLogging.log("UI-test voice bypass: failed to write stub audio: \(error)", level: .warn, category: .audio)
      return
    }
    let note = VoiceNoteStore.shared.addNew(
      audioTempURL: tmpURL,
      transcript: "UI test integration voice memo",
      language: "en-US",
      onDevice: true,
      sampleRate: 24000,
      location: nil,
      duration: 1.5
    )
    AppLogging.log("UI-test voice bypass: injected note id=\(note.id.uuidString)", level: .info, category: .audio)
    viewModel.attachVoiceNote(note)
  }

  private func scrollToBottom(proxy: ScrollViewProxy) {
    guard let lastID = viewModel.messages.last?.id else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
    }
  }

  // MARK: - Message rows

  @ViewBuilder
  private func messageRow(_ message: ChatMessage, index: Int) -> some View {
    let showResearcherButtons = (viewModel.researcherFlow?.confirmAnchorID == message.id)
    let showCapsules = (viewModel.capsulesAnchorMessageID == message.id
                        && !viewModel.chatCapsules.isEmpty)

    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 8) {
        if message.sender == .assistant {
          Image(systemName: "leaf.circle.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 24, height: 24)
            .foregroundColor(.brandSuccess)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

          bubble(message, isUser: false)
            .frame(maxWidth: .infinity, alignment: .leading)

          // The Upload button follows the explicit anchor when set (so it
          // can move from the head-photo prompt to the fish-photo prompt in
          // conservation mode). Falls back to the first message when no
          // anchor is set (legacy single-prompt behavior).
          let showPhotoButton: Bool = {
            guard viewModel.showCaptureOptions else { return false }
            if let anchor = viewModel.uploadAnchorMessageID {
              return anchor == message.id
            }
            return index == 0
          }()
          let showVoiceButton = (viewModel.voiceMemoAnchorMessageID == message.id)
          let showHeadConfirmButtons = (viewModel.headConfirmAnchorMessageID == message.id)
          let showActivityChoice = (viewModel.activityChoiceAnchorMessageID == message.id && viewModel.awaitingActivityChoice)
          let showSideResearcherButtons = showResearcherButtons

          // Right-side icon area. Sized to content rather than a fixed 140 pt —
          // a fixed reservation forced the bubble to wrap one-liners like
          // "Hi Chris, upload a photo of the fish" even when only one small
          // icon was visible. Hidden entirely during the multi-step capsule
          // identification flow so bubbles can stretch full width.
          if !showCapsules {
          HStack(spacing: 12) {
            if showPhotoButton {
              Button {
                AppLogging.log("Upload button tapped for photo source selection", level: .debug, category: .angler)
                showSourceActionSheet = true
              } label: {
                Image(systemName: "camera.fill")
                  .font(.brandTitle2)
              }
              .accessibilityIdentifier("chatPhotoUploadButton")
            }

            // Confirm / Retake for the conservation head-photo capture.
            if showHeadConfirmButtons {
              Button {
                viewModel.confirmHeadPhoto()
              } label: {
                Image(systemName: "checkmark.circle.fill")
                  .font(.brandTitle2)
              }
              .accessibilityIdentifier("chatHeadConfirmButton")

              Button {
                viewModel.retakeHeadPhoto()
              } label: {
                Image(systemName: "arrow.counterclockwise")
                  .font(.brandTitle2)
              }
              .accessibilityIdentifier("chatHeadRetakeButton")
            }

            // Activity choice: catch (pencil) or observation (mic).
            if showActivityChoice {
              Button {
                viewModel.chooseCatch()
              } label: {
                VStack(spacing: 2) {
                  Image(systemName: "square.and.pencil")
                    .font(.brandTitle2)
                  Text("Catch")
                    .font(.brandCaption2)
                }
              }
              .accessibilityIdentifier("chatChooseCatchButton")

              Button {
                viewModel.chooseObservation()
              } label: {
                VStack(spacing: 2) {
                  Image(systemName: "mic.fill")
                    .font(.brandTitle2)
                  Text("Observation")
                    .font(.brandCaption2)
                }
              }
              .accessibilityIdentifier("chatChooseObservationButton")
            }

            // Voice memo: Yes (opens recorder) / No (skip)
            if showVoiceButton {
              Button {
                showVoiceNoteSheet = true
              } label: {
                Image(systemName: "checkmark.circle.fill")
                  .font(.brandTitle2)
              }

              Button {
                viewModel.researcherSkipVoiceMemo()
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .font(.brandTitle2)
              }
            }

            if showSideResearcherButtons {
              researcherStepButtons
            }
          }
          .foregroundColor(.brandTextPrimary)
          .fixedSize(horizontal: true, vertical: false)
          } // end if !showCapsules

        } else {
          Spacer(minLength: 40)
          bubble(message, isUser: true)
        }
      }

      // Capsule row — rendered directly below the anchored bubble during the
      // multi-step identification flow (location → species → lifecycle → sex).
      // Indented to align with the bubble (32 pt = 24 pt avatar + 8 pt HStack spacing).
      if showCapsules {
        capsuleRow
          .padding(.leading, 32)
          .padding(.top, 2)
      }
    }
  }

  /// Generic capsule row — renders whichever set the VM currently exposes.
  /// Colors: green = primary/confirm, yellow = alternative, red = reject,
  /// grey = neutral (e.g. "Skip" or "Unknown").
  @ViewBuilder
  private var capsuleRow: some View {
    HStack(spacing: 8) {
      ForEach(viewModel.chatCapsules) { capsule in
        Button {
          viewModel.handleCapsuleTap(capsule.action)
        } label: {
          HStack(spacing: 6) {
            Text(capsule.label)
              .font(.brandFootnote.weight(.medium))
            if let conf = capsule.confidence {
              Text(String(format: "%.0f%%", conf * 100))
                .font(.brandCaption2)
                .opacity(0.85)
            }
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(
            Capsule()
              .fill(capsuleFill(capsule.color))
          )
          .overlay(
            Capsule()
              .stroke(capsuleBorder(capsule.color), lineWidth: 1)
          )
          .foregroundColor(.brandTextPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(capsule.label)
        .accessibilityIdentifier("chatCapsule_\(capsule.id)")
      }
    }
  }

  private func capsuleFill(_ color: ChatCapsuleColor) -> Color {
    switch color {
    case .green:  return Color.brandSuccess.opacity(0.25)
    case .yellow: return Color.yellow.opacity(0.25)
    case .red:    return Color.brandError.opacity(0.25)
    case .grey:   return Color.brandTextSecondary.opacity(0.25)
    }
  }

  private func capsuleBorder(_ color: ChatCapsuleColor) -> Color {
    switch color {
    case .green:  return Color.brandSuccess.opacity(0.9)
    case .yellow: return Color.yellow.opacity(0.9)
    case .red:    return Color.brandError.opacity(0.9)
    case .grey:   return Color.brandTextSecondary.opacity(0.9)
    }
  }

  @ViewBuilder
  private func bubble(_ message: ChatMessage, isUser: Bool) -> some View {
    if let img = message.image {
      Image(uiImage: img)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 16)
            .stroke(Color.brandTextPrimary.opacity(0.4), lineWidth: 1)
        )
        .padding(2)
    } else if let text = message.text {
      // Style "Final Analysis" title in blue when it's the first line
      if !isUser && text.hasPrefix("Final Analysis") {
        finalAnalysisBubble(text, coordinate: viewModel.photoExifLocationForDisplay?.coordinate)
      } else if !isUser && text.contains("§") {
        // The "§" separator splits primary content (estimates, prompts)
        // from secondary supporting text (hints, calculation metadata).
        // Used by every role now that the unified flow runs through
        // ResearcherCatchFlowManager — not just researchers.
        researcherBubble(text)
      } else {
        Text(predictionStyledText(text))
          .font(.brandSubheadline)
          .foregroundColor(.brandTextPrimary)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(isUser ? Color.brandAccent : Color.brandStroke)
          .cornerRadius(16)
      }
    }
  }
  /// Renders a researcher-mode bubble where text before "§" is primary (estimates/actuals)
  /// and text after "§" is secondary (smaller, grey supporting text).
  private func researcherBubble(_ text: String) -> some View {
    let parts = text.components(separatedBy: "\n§\n")
    let primary = parts.first ?? text
    let secondary = parts.count > 1 ? parts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) : nil

    return VStack(alignment: .leading, spacing: 6) {
      Text(predictionStyledText(primary))
        .font(.brandSubheadline)
        .foregroundColor(.brandTextPrimary)
      if let secondary, !secondary.isEmpty {
        Text(predictionStyledText(secondary))
          .font(.brandCaption)
          .foregroundColor(.brandTextSecondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.brandStroke)
    .cornerRadius(16)
  }

  /// Renders the final analysis bubble with a blue title line.
  /// In researcher mode, text after "§" is rendered as smaller grey supporting text.
  /// When `coordinate` is non-nil, a small location-pin map sits between the
  /// title and the body — omitted entirely when no GPS is available.
  private func finalAnalysisBubble(_ text: String, coordinate: CLLocationCoordinate2D?) -> some View {
    let sections = text.components(separatedBy: "\n§\n")
    let mainSection = sections.first ?? text
    let supporting = sections.count > 1 ? sections.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) : nil

    let lines = mainSection.components(separatedBy: "\n")
    let title = lines.first ?? ""
    let body = lines.dropFirst().joined(separator: "\n")

    return VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.brandSubheadline.weight(.semibold))
        .foregroundColor(.brandAccent)
      if let coordinate, CLLocationCoordinate2DIsValid(coordinate) {
        FinalAnalysisMapThumbnail(coordinate: coordinate)
      }
      if !body.isEmpty {
        Text(predictionStyledText(body))
          .font(.brandSubheadline)
          .foregroundColor(.brandTextPrimary)
      }
      if isResearcherMode, let supporting, !supporting.isEmpty {
        Text(predictionStyledText(supporting))
          .font(.brandCaption)
          .foregroundColor(.brandTextSecondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.brandStroke)
    .cornerRadius(16)
  }

  /// Strips `**…**` markers from a chat message and colors the wrapped runs in
  /// `.brandSuccess` (green) so model predictions visually pop without showing
  /// literal asterisks. Text outside markers inherits the bubble's default
  /// `foregroundColor`. Unmatched openers are passed through verbatim so a
  /// message that happens to contain `**` doesn't get truncated.
  private func predictionStyledText(_ raw: String) -> AttributedString {
    var result = AttributedString()
    var remaining = Substring(raw)
    while let openRange = remaining.range(of: "**") {
      let prefix = remaining[..<openRange.lowerBound]
      if !prefix.isEmpty {
        result += AttributedString(String(prefix))
      }
      let afterOpen = remaining[openRange.upperBound...]
      if let closeRange = afterOpen.range(of: "**") {
        let inner = String(afterOpen[..<closeRange.lowerBound])
        var styled = AttributedString(inner)
        styled.foregroundColor = .brandSuccess
        result += styled
        remaining = afterOpen[closeRange.upperBound...]
      } else {
        // Unmatched opener — preserve the literal characters so we never eat content.
        result += AttributedString("**" + String(afterOpen))
        remaining = Substring("")
      }
    }
    if !remaining.isEmpty {
      result += AttributedString(String(remaining))
    }
    return result
  }
}

// MARK: - Final analysis map thumbnail

/// Static-feeling Mapbox thumbnail used inside the final-analysis bubble.
/// All gestures are disabled — this is purely visual context for the catch
/// location, not a navigable map. Mirrors the `.outdoors` style used by the
/// rest of the app's map surfaces for visual consistency.
private struct FinalAnalysisMapThumbnail: View {
  let coordinate: CLLocationCoordinate2D

  /// Coordinate-bearing wrapper so `PointAnnotationGroup` can diff-by-id when
  /// the bubble re-renders. The id is derived from the coordinate so the map
  /// reuses the same annotation when the same catch is shown again.
  private struct Pin: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
  }

  private var pin: Pin {
    Pin(
      id: String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude),
      coordinate: coordinate
    )
  }

  /// Most gesture flags default to true — flip them all off so the thumbnail
  /// can't intercept the chat scroll.
  private var disabledGestures: GestureOptions {
    var opts = GestureOptions()
    opts.panEnabled = false
    opts.pinchEnabled = false
    opts.rotateEnabled = false
    opts.pinchZoomEnabled = false
    opts.pinchPanEnabled = false
    opts.pitchEnabled = false
    opts.doubleTapToZoomInEnabled = false
    opts.doubleTouchToZoomOutEnabled = false
    opts.quickZoomEnabled = false
    opts.simultaneousRotateAndPinchZoomEnabled = false
    return opts
  }

  var body: some View {
    Map(initialViewport: .camera(center: coordinate, zoom: 11, bearing: 0, pitch: 0)) {
      PointAnnotationGroup([pin]) { p in
        PointAnnotation(coordinate: p.coordinate)
          .image(.init(image: MapPinImage.pin(), name: "final-analysis-pin"))
          .iconAnchor(.bottom)
      }
    }
    .mapStyle(.outdoors)
    .gestureOptions(disabledGestures)
    .frame(height: 140)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .allowsHitTesting(false)
  }
}

// MARK: - Scroll indicator helper

private struct ScrollIndicatorModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 16.0, *) {
      content.scrollIndicators(.visible)
    } else {
      content
    }
  }
}

// MARK: - ChatVoiceNoteSheet (unchanged except requested removals)

// MARK: - DarkChatTextEditor (UIViewRepresentable for reliable dark background)

private struct DarkChatTextEditor: UIViewRepresentable {
  @Binding var text: String

  func makeUIView(context: Context) -> UITextView {
    let tv = UITextView()
    tv.backgroundColor = UIColor.brandSurface
    tv.textColor = .white
    tv.font = UIFont.preferredFont(forTextStyle: .body)
    tv.isEditable = true
    tv.isScrollEnabled = true
    tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
    tv.delegate = context.coordinator
    tv.layer.cornerRadius = 12
    tv.clipsToBounds = true
    return tv
  }

  func updateUIView(_ uiView: UITextView, context: Context) {
    if uiView.text != text {
      uiView.text = text
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  final class Coordinator: NSObject, UITextViewDelegate {
    var text: Binding<String>
    init(text: Binding<String>) { self.text = text }
    func textViewDidChange(_ textView: UITextView) {
      text.wrappedValue = textView.text
    }
  }
}

struct ChatVoiceNoteSheet: View {
  @Environment(\.dismiss) private var dismiss
  let onSaved: (LocalVoiceNote) -> Void

  @StateObject private var recorder = SpeechRecorder(maxDuration: 60)

  @State private var isStarting = false
  @State private var errorMessage: String?
    
  @State private var remainingSeconds: Int = 60
  @State private var countdownTimer: Timer?
  @State private var isFlashingWarning: Bool = false
  @State private var transcriptSnapshot: String = ""
  @State private var hasRecordedAudio: Bool = false

  var body: some View {
    NavigationView {
      VStack(spacing: 16) {
        Text("Record a memo for this catch")
          .font(.brandHeadline)
          .foregroundColor(.brandTextPrimary)
          .multilineTextAlignment(.center)
          .padding(.top, 8)

        HStack(spacing: 24) {
          // Main record / pause button
          ZStack {
            Circle()
              .strokeBorder(Color.brandTextPrimary.opacity(0.35), lineWidth: 2)
              .frame(width: 120, height: 120)

            Circle()
              .fill(recorder.isRecording && !recorder.isPaused
                ? Color.brandError.opacity(0.7)
                : Color.brandStrokeStrong)
              .frame(width: 100, height: 100)

            Image(systemName: micButtonIcon)
              .font(.system(size: 36, weight: .bold))
              .foregroundColor(.brandTextPrimary)
          }
          .onTapGesture { toggleRecording() }

          // Stop button – only visible while recording (active or paused)
          if recorder.isRecording {
            ZStack {
              Circle()
                .strokeBorder(Color.brandTextPrimary.opacity(0.35), lineWidth: 2)
                .frame(width: 64, height: 64)

              Circle()
                .fill(Color.brandStrokeStrong)
                .frame(width: 52, height: 52)

              Image(systemName: "stop.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.brandError)
            }
            .onTapGesture { stopRecording() }
          }
        }
        .padding(.vertical, 8)
          
        Text(String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60))
          .font(.brandHeadline)
          .foregroundColor(timerColor)
          .opacity(timerOpacity)
    
        ZStack {
          // Live transcript while recording (or before recording starts)
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                Text(
                  transcriptSnapshot.isEmpty
                    ? "Transcript will appear here as you speak…"
                    : transcriptSnapshot
                )
                .font(.brandBody)
                .foregroundColor(.brandTextPrimary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.brandSurface)
                .cornerRadius(12)

                Color.clear
                  .frame(height: 1)
                  .id("TranscriptBottom")
              }
            }
            .onChange(of: recorder.partialTranscript) { newValue in
              if !newValue.isEmpty {
                transcriptSnapshot = newValue
              }
              withAnimation {
                proxy.scrollTo("TranscriptBottom", anchor: .bottom)
              }
            }
            .frame(maxHeight: 360)
          }
          .opacity(!recorder.isRecording && hasRecordedAudio ? 0 : 1)

          // Editable transcript after recording stops
          if !recorder.isRecording && hasRecordedAudio {
            VStack(alignment: .leading, spacing: 4) {
              Text("Tap to edit transcript")
                .font(.brandCaption)
                .foregroundColor(.brandTextPrimary.opacity(0.5))
              DarkChatTextEditor(text: $transcriptSnapshot)
                .frame(maxHeight: 340)
            }
            .frame(maxHeight: 360)
          }
        }

        if let error = errorMessage {
          Text(error)
            .font(.brandFootnote)
            .foregroundColor(.brandError)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }

        Spacer()

        HStack {
          Button("Cancel") {
            stopRecording()
            dismiss()
          }
          .frame(maxWidth: .infinity)
          .padding()
          .background(Color.brandStroke)
          .cornerRadius(12)
          .foregroundColor(.brandTextPrimary)

          Button("Save") {
            saveNote()
          }
          .frame(maxWidth: .infinity)
          .padding()
          .background(Color.brandAccent)
          .cornerRadius(12)
          .foregroundColor(.brandTextPrimary)
          .disabled(recorder.currentTempURL() == nil)
        }
      }
      .padding()
      .background(Color.brandBackground.ignoresSafeArea())
      .navigationBarHidden(true)
    }
  }
  private var micButtonIcon: String {
    if !recorder.isRecording {
      return "mic.fill"
    } else if recorder.isPaused {
      return "play.fill"
    } else {
      return "pause.fill"
    }
  }

  private var timerColor: Color {
    recorder.isRecording && remainingSeconds <= 10 ? .red : .white
  }

  private var timerOpacity: Double {
    (recorder.isRecording && remainingSeconds <= 10 && isFlashingWarning) ? 0.3 : 1.0
  }

  private func toggleRecording() {
    if recorder.isRecording {
      if recorder.isPaused {
        // Resume
        recorder.resume()
        startCountdown()
      } else {
        // Pause
        recorder.pause()
        pauseCountdown()
      }
    } else {
      // Start fresh
      isStarting = true
      errorMessage = nil

      Task {
        do {
          try await recorder.start()

          // Start countdown *after* recording is active
          await MainActor.run {
            hasRecordedAudio = true
            remainingSeconds = 60
            startCountdown()
          }
        } catch {
          await MainActor.run {
            errorMessage = error.localizedDescription
            stopCountdown()
          }
        }

        await MainActor.run {
          isStarting = false
        }
      }
    }
  }

  private func stopRecording() {
    recorder.stop()
    stopCountdown()
  }

  private func startCountdown() {
    countdownTimer?.invalidate()
    isFlashingWarning = false

    countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
      // If recording stopped for any reason, stop the timer.
      if !recorder.isRecording {
        stopCountdown()
        return
      }

      if remainingSeconds > 0 {
        remainingSeconds -= 1
      }

      // Flash in last 10 seconds
      if remainingSeconds <= 10 && remainingSeconds > 0 {
        isFlashingWarning.toggle()
      } else {
        isFlashingWarning = false
      }

      // Hard stop at 0
      if remainingSeconds <= 0 {
        stopCountdown()
        recorder.stop()
      }
    }

    RunLoop.main.add(countdownTimer!, forMode: .common)
  }

  private func pauseCountdown() {
    countdownTimer?.invalidate()
    countdownTimer = nil
    isFlashingWarning = false
  }

  private func stopCountdown() {
    countdownTimer?.invalidate()
    countdownTimer = nil
    remainingSeconds = 60
    isFlashingWarning = false
  }

  private func saveNote() {
    stopRecording()

    guard let tempURL = recorder.currentTempURL() else {
      errorMessage = "No audio recorded"
      return
    }

    let duration = recorder.totalDurationSec()
    let note = VoiceNoteStore.shared.addNew(
      audioTempURL: tempURL,
      transcript: transcriptSnapshot,
      language: recorder.languageCode,
      onDevice: recorder.onDeviceRecognition,
      sampleRate: recorder.sampleRate,
      location: nil,
      duration: duration
    )

    onSaved(note)
    dismiss()
  }
}
