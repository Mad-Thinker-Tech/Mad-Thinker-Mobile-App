// Bend Fly Shop
//
// ActivitiesObservationsTab.swift — "Observations" tab inside ActivitiesView.
// Two sections:
//   • Marks  — non-catch activity reports (active, farmed, promising, passed)
//   • Notes  — voice memo observations with transcripts
//
// Uploads are handled by the parent ActivitiesView's unified Upload button
// via UploadCoordinator. This tab only manages display and deletion.

import SwiftUI

struct ActivitiesObservationsTab: View {
  /// Prefix for the row line that names who logged the report. Renamed from
  /// "Guide" so the same row can be reused across roles (kept in sync with
  /// `FarmedReportsListView.activityRowMemberLabel`).
  static let activityRowMemberLabel = "Member"

  @ObservedObject private var farmedStore = FarmedReportStore.shared
  @ObservedObject private var observationStore = ObservationStore.shared

  // MARK: - Body

  var body: some View {
    List {
      // ── Marks section ──────────────────────────────────────────
      Section {
        if farmedStore.reports.isEmpty {
          Text("No activity marks yet")
            .font(.brandSubheadline)
            .foregroundColor(.brandTextSecondary)
            .listRowBackground(Color.brandBackground)
        } else {
          ForEach(farmedStore.reports) { report in
            MarkRow(report: report)
              .listRowBackground(Color.brandBackground)
          }
          .onDelete(perform: deleteMarks)
        }
      } header: {
        Text("Marks")
          .font(.brandHeadline)
          .foregroundColor(.brandTextPrimary)
      }

      // ── Notes section ──────────────────────────────────────────
      Section {
        if observationStore.observations.isEmpty {
          Text("No observations yet")
            .font(.brandSubheadline)
            .foregroundColor(.brandTextSecondary)
            .listRowBackground(Color.brandBackground)
        } else {
          ForEach(observationStore.observations) { obs in
            NavigationLink(destination: ObservationDetailView(observation: obs)) {
              NoteRow(observation: obs)
            }
            .listRowBackground(Color.brandBackground)
          }
          .onDelete(perform: deleteNotes)
        }
      } header: {
        Text("Notes")
          .font(.brandHeadline)
          .foregroundColor(.brandTextPrimary)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Color.brandBackground)
    .onAppear {
      farmedStore.purgeOldUploaded()
      farmedStore.refresh()
    }
  }

  // MARK: - Delete

  private func deleteMarks(at offsets: IndexSet) {
    for index in offsets {
      let report = farmedStore.reports[index]
      if report.status == .savedLocally {
        farmedStore.delete(report)
      }
    }
  }

  private func deleteNotes(at offsets: IndexSet) {
    for index in offsets {
      let obs = observationStore.observations[index]
      if let noteId = obs.voiceNoteId,
         let note = VoiceNoteStore.shared.notes.first(where: { $0.id == noteId }) {
        VoiceNoteStore.shared.delete(note)
      }
      observationStore.delete(obs)
    }
  }
}

// MARK: - Mark Row (non-catch activity report)

private struct MarkRow: View {
  let report: FarmedReport

  private static let timestampFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateStyle = .medium
    df.timeStyle = .short
    return df
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(report.eventType.displayName)
          .font(.brandSubheadline.weight(.semibold))
          .foregroundColor(.brandTextPrimary)
        Spacer()
        Text(report.status.rawValue)
          .font(.brandCaption2)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(report.status == .uploaded ? Color.brandSuccess.opacity(0.12) : Color.brandAccent.opacity(0.12))
          .foregroundColor(report.status == .uploaded ? .brandSuccess : .brandAccent)
          .clipShape(Capsule())
      }
      Text(Self.timestampFormatter.string(from: report.createdAt))
        .font(.brandCaption)
        .foregroundColor(.brandTextSecondary)
      if !report.guideName.isEmpty {
        Text("\(ActivitiesObservationsTab.activityRowMemberLabel): \(report.guideName)")
          .font(.brandCaption)
          .foregroundColor(.brandTextSecondary)
      }
    }
    .padding(.vertical, 2)
    .deleteDisabled(report.status != .savedLocally)
  }
}

// MARK: - Note Row (voice memo observation)

private struct NoteRow: View {
  let observation: Observation

  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(observation.transcript.isEmpty ? "No transcript" : observation.transcript)
        .font(.brandBody)
        .foregroundColor(.brandTextPrimary)
        .lineLimit(2)
      HStack {
        Text(Self.timeFormatter.string(from: observation.createdAt))
          .font(.brandCaption)
          .foregroundColor(.brandTextSecondary)
        if observation.lat != nil {
          Image(systemName: "location.fill")
            .font(.brandCaption2)
            .foregroundColor(.brandTextSecondary)
        }
        Spacer()
        Text(observation.status.rawValue)
          .font(.brandCaption2)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(observation.status == .uploaded ? Color.brandSuccess.opacity(0.12) : Color.brandAccent.opacity(0.12))
          .foregroundColor(observation.status == .uploaded ? .brandSuccess : .brandAccent)
          .clipShape(Capsule())
      }
    }
    .padding(.vertical, 2)
  }
}
