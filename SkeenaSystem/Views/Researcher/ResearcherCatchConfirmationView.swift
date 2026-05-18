// Bend Fly Shop
//
// ResearcherCatchConfirmationView.swift — Review screen shown after the
// researcher completes the chat flow. Displays all collected data for
// confirmation before saving. Edit mode allows inline corrections.

import CoreLocation
import SwiftUI

struct ResearcherCatchConfirmationView: View {
  @ObservedObject var chatVM: CatchChatViewModel
  let onConfirm: () -> Void
  let onCancel: () -> Void

  @State private var isEditing = false
  @State private var showDeleteConfirmation = false
  @State private var showSavedConfirmation = false

  // Editable copies (initialized from flow in onAppear)
  @State private var editSpecies = ""
  @State private var editLifecycleStage = ""
  @State private var editSex = ""
  @State private var editLength = ""
  @State private var editGirth = ""
  @State private var editFloyTag = ""
  @State private var editScaleEnvelopeId = ""
  @State private var editFinEnvelopeId = ""

  var body: some View {
    NavigationView {
      ZStack {
        Color.researcherBackground.ignoresSafeArea()

        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text("Review Catch Report")
              .font(.brandTitle3.weight(.bold))
              .foregroundColor(.researcherTextPrimary)
              .padding(.bottom, 4)

            Group {
              readOnlyRow(label: "Name", value: researcherName)
              readOnlyRow(label: "GPS", value: gpsString)

              if isEditing {
                editableRow(label: "Species", text: $editSpecies)
                editableRow(label: "Stage", text: $editLifecycleStage)
                editableRow(label: "Sex", text: $editSex)
                editableRow(label: "Length", text: $editLength, placeholder: "inches")
                editableRow(label: "Girth", text: $editGirth, placeholder: "inches")
              } else {
                readOnlyRow(label: "Species", value: speciesString)
                readOnlyRow(label: "Sex", value: sexString)
                readOnlyRow(label: "Length", value: lengthString)
                readOnlyRow(label: "Girth", value: girthString)
              }
              readOnlyRow(label: "Weight", value: weightString)
            }

            Group {
              readOnlyRow(label: "Study", value: studyString)

              if isEditing {
                editableRow(label: "Floy Tag ID", text: $editFloyTag)
              } else {
                readOnlyRow(label: "Floy Tag ID", value: floyTagString)
              }

              if isEditing {
                editableRow(label: "Scale Barcode", text: $editScaleEnvelopeId)
                editableRow(label: "Fin Clip Barcode", text: $editFinEnvelopeId)
              } else {
                readOnlyRow(label: "Scale Barcode", value: scaleEnvelopeIdString)
                readOnlyRow(label: "Fin Clip Barcode", value: finEnvelopeIdString)
              }

              readOnlyRow(label: "Voice Memo", value: voiceMemoString)
            }

            Spacer(minLength: 24)

            HStack(spacing: 12) {
              if isEditing {
                Button(action: cancelEdit) {
                  Text("Cancel")
                    .font(.brandHeadline.weight(.bold))
                    .foregroundColor(.researcherTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.researcherTextPrimary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button(action: saveEdits) {
                  Text("Save")
                    .font(.brandHeadline.weight(.bold))
                    .foregroundColor(.researcherTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.researcherAccent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
              } else {
                Button(action: startEditing) {
                  Text("Edit")
                    .font(.brandHeadline.weight(.bold))
                    .foregroundColor(.researcherTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.researcherTextPrimary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button { showSavedConfirmation = true } label: {
                  Text("Confirm")
                    .font(.brandHeadline.weight(.bold))
                    .foregroundColor(.researcherTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.researcherAccent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("catchConfirmationConfirmButton")
              }
            }
          }
          .padding(20)
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          if !isEditing {
            Button("Cancel") { showDeleteConfirmation = true }
              .foregroundColor(.researcherTextPrimary)
          }
        }
      }
      .alert("Delete Catch Report", isPresented: $showDeleteConfirmation) {
        Button("Delete", role: .destructive) { onCancel() }
        Button("Keep Editing", role: .cancel) {}
      } message: {
        Text("Canceling will delete this catch report. This cannot be undone.")
      }
      .alert("Catch Report Saved", isPresented: $showSavedConfirmation) {
        Button("OK") { onConfirm() }
          .accessibilityIdentifier("catchSavedAlertOKButton")
      } message: {
        Text("Your catch report has been saved locally. When you have service, please upload for processing.")
      }
    }
    .preferredColorScheme(.dark)
  }

  // MARK: - Edit actions

  private func startEditing() {
    guard let flow = chatVM.researcherFlow else { return }
    editSpecies = flow.species ?? ""
    editLifecycleStage = flow.lifecycleStage ?? ""
    editSex = flow.sex ?? ""
    editLength = flow.lengthInches.map { $0.rounded() == $0 ? "\(Int($0))" : String(format: "%.1f", $0) } ?? ""
    editGirth = flow.girthInches.map { String(format: "%.1f", $0) } ?? ""
    editFloyTag = flow.studyTagId ?? ""
    editScaleEnvelopeId = flow.scaleEnvelopeId ?? ""
    editFinEnvelopeId = flow.finEnvelopeId ?? ""
    isEditing = true
  }

  private func cancelEdit() {
    isEditing = false
  }

  private func saveEdits() {
    guard let flow = chatVM.researcherFlow else { return }

    let trimmedSpecies = editSpecies.trimmingCharacters(in: .whitespaces)
    if !trimmedSpecies.isEmpty { flow.species = trimmedSpecies }

    let trimmedStage = editLifecycleStage.trimmingCharacters(in: .whitespaces)
    flow.lifecycleStage = trimmedStage.isEmpty ? nil : trimmedStage

    let trimmedSex = editSex.trimmingCharacters(in: .whitespaces)
    if !trimmedSex.isEmpty { flow.sex = trimmedSex }

    if let len = Double(editLength.trimmingCharacters(in: .whitespaces)) {
      flow.lengthInches = len
    }
    if let gir = Double(editGirth.trimmingCharacters(in: .whitespaces)) {
      flow.girthInches = gir
      flow.girthIsEstimated = false
    }

    // Recalculate weight from updated length/girth
    flow.recalculate()

    let trimmedFloy = editFloyTag.trimmingCharacters(in: .whitespaces)
    flow.studyTagId = trimmedFloy.isEmpty ? nil : trimmedFloy

    let trimmedScale = editScaleEnvelopeId.trimmingCharacters(in: .whitespaces)
    flow.scaleEnvelopeId = trimmedScale.isEmpty ? nil : trimmedScale

    let trimmedFinClip = editFinEnvelopeId.trimmingCharacters(in: .whitespaces)
    flow.finEnvelopeId = trimmedFinClip.isEmpty ? nil : trimmedFinClip

    isEditing = false
  }

  // MARK: - Data extraction

  private var researcherName: String {
    let first = AuthService.shared.currentFirstName ?? ""
    let last = AuthService.shared.currentLastName ?? ""
    let full = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
    return full.isEmpty ? "-" : full
  }

  private var gpsString: String {
    if let loc = chatVM.currentLocationForDisplay {
      return String(format: "%.4f, %.4f", loc.coordinate.latitude, loc.coordinate.longitude)
    }
    return "-"
  }

  private var speciesString: String {
    if let flow = chatVM.researcherFlow, let s = flow.species, !s.isEmpty {
      if let stage = flow.lifecycleStage, !stage.isEmpty {
        return "\(s) (\(stage))"
      }
      return s
    }
    return "-"
  }

  private var sexString: String {
    chatVM.researcherFlow?.sex ?? "-"
  }

  private var lengthString: String {
    if let l = chatVM.researcherFlow?.lengthInches {
      return l.rounded() == l ? "\(Int(l)) inches" : String(format: "%.1f inches", l)
    }
    return "-"
  }

  private var girthString: String {
    if let g = chatVM.researcherFlow?.girthInches {
      return String(format: "%.1f inches", g)
    }
    return "-"
  }

  private var weightString: String {
    if let w = chatVM.researcherFlow?.weightLbs {
      return String(format: "%.1f lbs", w)
    }
    return "-"
  }

  private var studyString: String {
    chatVM.researcherFlow?.studyType?.rawValue ?? "None"
  }

  private var floyTagString: String {
    chatVM.researcherFlow?.studyTagId ?? "None"
  }

  private var scaleEnvelopeIdString: String {
    chatVM.researcherFlow?.scaleEnvelopeId ?? "None"
  }

  private var finEnvelopeIdString: String {
    chatVM.researcherFlow?.finEnvelopeId ?? "None"
  }

  private var voiceMemoString: String {
    chatVM.attachedVoiceNotes.isEmpty ? "None" : "Attached"
  }

  // MARK: - Row helpers

  private func readOnlyRow(label: String, value: String) -> some View {
    HStack(alignment: .top) {
      Text(label)
        .font(.brandSubheadline.weight(.semibold))
        .foregroundColor(.researcherTextPrimary.opacity(0.6))
        .frame(width: 120, alignment: .leading)
      Text(value)
        .font(.brandSubheadline)
        .foregroundColor(.researcherTextPrimary)
      Spacer()
    }
    .padding(.vertical, 4)
  }

  private func editableRow(label: String, text: Binding<String>, placeholder: String = "") -> some View {
    HStack(alignment: .center) {
      Text(label)
        .font(.brandSubheadline.weight(.semibold))
        .foregroundColor(.researcherTextPrimary.opacity(0.6))
        .frame(width: 120, alignment: .leading)
      TextField(placeholder, text: text)
        .font(.brandSubheadline)
        .foregroundColor(.researcherTextPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.researcherTextPrimary.opacity(0.1))
        .cornerRadius(8)
    }
    .padding(.vertical, 2)
  }
}
