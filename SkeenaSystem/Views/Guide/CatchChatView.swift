// Bend Fly Shop

import SwiftUI

struct CatchChatView: View {
  @ObservedObject var viewModel: CatchChatViewModel

  @State private var showSourceActionSheet = false
  @State private var showImagePicker = false
  @State private var imagePickerSource: ImagePicker.Source = .library

  // Voice memo sheet
  @State private var showVoiceNoteSheet = false

  // Envelope barcode scanner sheet — presented when the user taps the "Scan"
  // capsule on the .envelopeScan step. The sheet returns either a parsed
  // envelope ID (handed off to the VM) or a manual-entry signal (just dismiss
  // and let the user type into the input bar).
  @State private var showEnvelopeScanner = false

  // Study: show Yes/No first, then expand to type icons. Sample collection no
  // longer uses an icon-expansion pattern — the contents capsule row is posted
  // directly to the bubble by `postEnvelopeContentsStep`, and the side icons
  // for `.sampleCollection` are now just Yes/No.
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
            .font(.caption)
            .foregroundColor(.green)
          Text("Conservation mode")
            .font(.caption.weight(.semibold))
            .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.15))
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
          .font(.caption)
          .foregroundColor(hasInteracted ? .white.opacity(0.5) : .white.opacity(0.15))
        }
        .disabled(!hasInteracted)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
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
                  .foregroundColor(.green)
                  .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                HStack(spacing: 6) {
                  ProgressView()
                    .scaleEffect(0.8)
                  Text("Analyzing…")
                    .font(.footnote)
                }
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.12))
                .cornerRadius(16)

                Spacer(minLength: 40)
              }
              .padding(.top, 4)
            }
          }
          .padding(.horizontal, 4)
          .padding(.top, 4)
          .padding(.bottom, 8)
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
        .background(Color.white.opacity(0.15))

      inputBar
    }
    .background(Color.clear)
    .onChange(of: showSourceActionSheet) { presented in
      AppLogging.log("ShowSourceActionSheet changed: \(presented)", level: .debug, category: .angler)
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
        showVoiceNoteSheet = true
        viewModel.requestVoiceNoteSheet = false
      }
    }
    .sheet(isPresented: $showEnvelopeScanner) {
      EnvelopeBarcodeScanner(
        onScan: { id in
          showEnvelopeScanner = false
          viewModel.researcherRecordScannedEnvelope(id)
        },
        onManualEntry: {
          // Dismiss the scanner; the chat input bar is always live so the
          // user can immediately type the ID. Capsules on the bubble stay
          // intact in case they change their mind.
          showEnvelopeScanner = false
        },
        onCancel: {
          showEnvelopeScanner = false
        }
      )
    }
    .onChange(of: viewModel.requestEnvelopeScannerSheet) { requested in
      if requested {
        showEnvelopeScanner = true
        viewModel.requestEnvelopeScannerSheet = false
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
        .background(Color.white.opacity(0.08))
        .cornerRadius(16)
        .foregroundColor(.white)

      Button(action: {
        viewModel.sendCurrentInput()
        hideKeyboard()
      }) {
        Image(systemName: "paperplane.fill")
          .font(.system(size: 16, weight: .semibold))
          .padding(8)
      }
      .foregroundColor(.white)
      .background(
        viewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? Color.white.opacity(0.15)
          : Color.blue
      )
      .cornerRadius(16)
      .disabled(
        viewModel.userInput
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty
      )
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
    } else if step == .envelopeContents {
      HStack(spacing: 12) {
        choiceButton("Scale", icon: "fish.fill", disabled: false) {
          viewModel.researcherSelectEnvelopeContents(.scale)
        }
        choiceButton("Fin clip", icon: "scissors", disabled: false) {
          viewModel.researcherSelectEnvelopeContents(.finClip)
        }
        choiceButton("Both", icon: "plus.circle.fill", disabled: false) {
          viewModel.researcherSelectEnvelopeContents(.both)
        }
      }
    }
  }

  private func choiceButton(_ label: String, icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundColor(disabled ? .gray : .white)
        .frame(minWidth: 40)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Color.white.opacity(disabled ? 0.05 : 0.12))
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
            Image(systemName: "tag.fill").font(.title3)
            Text("Pit").font(.caption)
          }.foregroundColor(.gray)
        }
        .disabled(true)

        Button {
          showStudyTypeIcons = false
          viewModel.researcherSelectStudy(.floy)
        } label: {
          VStack(spacing: 4) {
            Image(systemName: "tag.fill").font(.title3)
            Text("Floy").font(.caption)
          }
        }

        Button {} label: {
          VStack(spacing: 4) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.title3)
            Text("Radio").font(.caption)
          }.foregroundColor(.gray)
        }
        .disabled(true)
      } else {
        // Yes / No
        Button { showStudyTypeIcons = true } label: {
          Image(systemName: "checkmark.circle.fill").font(.title2)
        }
        Button {
          viewModel.researcherConfirm()
        } label: {
          Image(systemName: "xmark.circle.fill").font(.title2)
        }
      }
    } else if step == .sampleCollection {
      // Yes (advance to .envelopeContents and post the contents capsule row)
      // / No (skip to voice memo). The Yes path is handled in the VM.
      Button {
        viewModel.handleCapsuleTap(.sampleCollect(yes: true))
      } label: {
        Image(systemName: "checkmark.circle.fill").font(.title2)
      }
      Button {
        viewModel.researcherConfirm()
      } label: {
        Image(systemName: "xmark.circle.fill").font(.title2)
      }
    } else if step == .envelopeContents {
      // Pure capsule-driven step (Scale / Fin clip / Both live on the bubble).
      // The side column intentionally has no buttons here so the user's eye is
      // drawn to the capsule row.
      EmptyView()
    } else if step == .floyTagID {
      if let tag = viewModel.researcherFlow?.floyTagNumber, !tag.isEmpty {
        Button {
          viewModel.researcherConfirm()
        } label: {
          Image(systemName: "checkmark.circle.fill")
            .font(.title2)
        }
      }
    } else if step == .envelopeScan {
      // Show the camera-scan icon as a side affordance whenever the user is
      // on this step — even before they've engaged the capsule on the bubble
      // — so the scanner is one tap away. Once a barcode has been captured,
      // also surface the Confirm checkmark.
      Button {
        viewModel.handleCapsuleTap(.openEnvelopeScanner)
      } label: {
        Image(systemName: "barcode.viewfinder").font(.title2)
      }
      if let code = viewModel.researcherFlow?.envelopeBarcode, !code.isEmpty {
        Button {
          viewModel.researcherConfirm()
        } label: {
          Image(systemName: "checkmark.circle.fill")
            .font(.title2)
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
    }
  }

  private func hideKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.endEditing(true)
    #endif
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
            .foregroundColor(.green)
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
                  .font(.title2)
              }
            }

            // Confirm / Retake for the conservation head-photo capture.
            if showHeadConfirmButtons {
              Button {
                viewModel.confirmHeadPhoto()
              } label: {
                Image(systemName: "checkmark.circle.fill")
                  .font(.title2)
              }

              Button {
                viewModel.retakeHeadPhoto()
              } label: {
                Image(systemName: "arrow.counterclockwise")
                  .font(.title2)
              }
            }

            // Activity choice: catch (pencil) or observation (mic).
            if showActivityChoice {
              Button {
                viewModel.chooseCatch()
              } label: {
                VStack(spacing: 2) {
                  Image(systemName: "square.and.pencil")
                    .font(.title2)
                  Text("Catch")
                    .font(.caption2)
                }
              }

              Button {
                viewModel.chooseObservation()
              } label: {
                VStack(spacing: 2) {
                  Image(systemName: "mic.fill")
                    .font(.title2)
                  Text("Observation")
                    .font(.caption2)
                }
              }
            }

            // Voice memo: Yes (opens recorder) / No (skip)
            if showVoiceButton {
              Button {
                showVoiceNoteSheet = true
              } label: {
                Image(systemName: "checkmark.circle.fill")
                  .font(.title2)
              }

              Button {
                viewModel.researcherSkipVoiceMemo()
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .font(.title2)
              }
            }

            if showSideResearcherButtons {
              researcherStepButtons
            }
          }
          .foregroundColor(.white)
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
              .font(.footnote.weight(.medium))
            if let conf = capsule.confidence {
              Text(String(format: "%.0f%%", conf * 100))
                .font(.caption2)
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
          .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(capsule.label)
      }
    }
  }

  private func capsuleFill(_ color: ChatCapsuleColor) -> Color {
    switch color {
    case .green:  return Color.green.opacity(0.25)
    case .yellow: return Color.yellow.opacity(0.25)
    case .red:    return Color.red.opacity(0.25)
    case .grey:   return Color.gray.opacity(0.25)
    }
  }

  private func capsuleBorder(_ color: ChatCapsuleColor) -> Color {
    switch color {
    case .green:  return Color.green.opacity(0.9)
    case .yellow: return Color.yellow.opacity(0.9)
    case .red:    return Color.red.opacity(0.9)
    case .grey:   return Color.gray.opacity(0.9)
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
            .stroke(Color.white.opacity(0.4), lineWidth: 1)
        )
        .padding(2)
    } else if let text = message.text {
      // Style "Final Analysis" title in blue when it's the first line
      if !isUser && text.hasPrefix("Final Analysis") {
        finalAnalysisBubble(text)
      } else if !isUser && text.contains("§") {
        // The "§" separator splits primary content (estimates, prompts)
        // from secondary supporting text (hints, calculation metadata).
        // Used by every role now that the unified flow runs through
        // ResearcherCatchFlowManager — not just researchers.
        researcherBubble(text)
      } else {
        Text(text)
          .font(.subheadline)
          .foregroundColor(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(isUser ? Color.blue : Color.white.opacity(0.12))
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
      Text(primary)
        .font(.subheadline)
        .foregroundColor(.white)
      if let secondary, !secondary.isEmpty {
        Text(secondary)
          .font(.caption)
          .foregroundColor(.gray)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.white.opacity(0.12))
    .cornerRadius(16)
  }

  /// Renders the final analysis bubble with a blue title line.
  /// In researcher mode, text after "§" is rendered as smaller grey supporting text.
  private func finalAnalysisBubble(_ text: String) -> some View {
    let sections = text.components(separatedBy: "\n§\n")
    let mainSection = sections.first ?? text
    let supporting = sections.count > 1 ? sections.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) : nil

    let lines = mainSection.components(separatedBy: "\n")
    let title = lines.first ?? ""
    let body = lines.dropFirst().joined(separator: "\n")

    return VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundColor(.blue)
      if !body.isEmpty {
        Text(body)
          .font(.subheadline)
          .foregroundColor(.white)
      }
      if isResearcherMode, let supporting, !supporting.isEmpty {
        Text(supporting)
          .font(.caption)
          .foregroundColor(.gray)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.white.opacity(0.12))
    .cornerRadius(16)
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
    tv.backgroundColor = UIColor.white.withAlphaComponent(0.08)
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
          .font(.headline)
          .foregroundColor(.white)
          .multilineTextAlignment(.center)
          .padding(.top, 8)

        HStack(spacing: 24) {
          // Main record / pause button
          ZStack {
            Circle()
              .strokeBorder(Color.white.opacity(0.35), lineWidth: 2)
              .frame(width: 120, height: 120)

            Circle()
              .fill(recorder.isRecording && !recorder.isPaused
                ? Color.red.opacity(0.7)
                : Color.white.opacity(0.15))
              .frame(width: 100, height: 100)

            Image(systemName: micButtonIcon)
              .font(.system(size: 36, weight: .bold))
              .foregroundColor(.white)
          }
          .onTapGesture { toggleRecording() }

          // Stop button – only visible while recording (active or paused)
          if recorder.isRecording {
            ZStack {
              Circle()
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 2)
                .frame(width: 64, height: 64)

              Circle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 52, height: 52)

              Image(systemName: "stop.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.red)
            }
            .onTapGesture { stopRecording() }
          }
        }
        .padding(.vertical, 8)
          
        Text(String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60))
          .font(.headline)
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
                .font(.body)
                .foregroundColor(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.white.opacity(0.08))
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
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
              DarkChatTextEditor(text: $transcriptSnapshot)
                .frame(maxHeight: 340)
            }
            .frame(maxHeight: 360)
          }
        }

        if let error = errorMessage {
          Text(error)
            .font(.footnote)
            .foregroundColor(.red)
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
          .background(Color.white.opacity(0.12))
          .cornerRadius(12)
          .foregroundColor(.white)

          Button("Save") {
            saveNote()
          }
          .frame(maxWidth: .infinity)
          .padding()
          .background(Color.blue)
          .cornerRadius(12)
          .foregroundColor(.white)
          .disabled(recorder.currentTempURL() == nil)
        }
      }
      .padding()
      .background(Color.black.ignoresSafeArea())
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
