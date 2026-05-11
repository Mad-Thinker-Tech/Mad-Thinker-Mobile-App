// Bend Fly Shop
//
// ActivitiesView.swift — Tabbed container for the "Activities" toolbar
// destination. Houses Reports (catch history) and Observations (marks +
// notes) behind a segmented picker. Designed for easy tab extension.
//
// The toolbar provides a single Upload button that sequences catch reports →
// no-catch marks → observations via UploadCoordinator, and an Archive
// button for viewing older uploaded catches.

import SwiftUI
import UIKit

struct ActivitiesView: View {

  // MARK: - Tab definition (add new cases to grow the picker)

  enum Tab: String, CaseIterable, Identifiable {
    case reports = "Reports"
    case observations = "Observations"

    var id: String { rawValue }
  }

  @State private var selectedTab: Tab = .reports
  @Environment(\.dismiss) private var dismiss

  // Stores — observed so pending counts and archive state stay fresh
  @ObservedObject private var catchStore = CatchReportStore.shared
  @ObservedObject private var farmedStore = FarmedReportStore.shared
  @ObservedObject private var observationStore = ObservationStore.shared

  // Upload state
  @State private var isUploading = false
  @State private var uploadProgress: Double = 0
  @State private var uploadPhase: String = "Preparing…"
  @State private var uploadResultMessage = ""
  @State private var showUploadAlert = false

  // Archive navigation
  @State private var showArchive = false

  private let coordinator = UploadCoordinator()

  // MARK: - Derived counts

  private var pendingCatches: [CatchReport] {
    catchStore.reports.filter { $0.status == .savedLocally }
  }

  private var pendingMarks: [FarmedReport] {
    farmedStore.reports.filter { $0.status == .savedLocally }
  }

  private var pendingNotes: [Observation] {
    observationStore.observations.filter { $0.status == .savedLocally }
  }

  private var totalPending: Int {
    pendingCatches.count + pendingMarks.count + pendingNotes.count
  }

  private var archivedCatches: [CatchReport] {
    catchStore.reports.filter {
      AppEnvironment.shared.shouldArchive(
        uploaded: $0.status == .uploaded,
        createdAt: $0.createdAt
      )
    }
  }

  // MARK: - Catch uploader factory (mirrors ReportsListView pattern)

  private var catchUploader: UploadCatchReport {
    let apiKey = ((Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let endpoint = CatchReportUploadAPI.endpointURL() ?? URL(string: "https://invalid.local")!
    return UploadCatchReport(
      config: .init(
        endpoint: endpoint,
        appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
        apiKey: apiKey
      )
    )
  }

  // MARK: - Body

  var body: some View {
    DarkPageTemplate(bottomToolbar: {
      RoleAwareToolbar(activeTab: "activities")
    }) {
      VStack(spacing: 0) {
        // Segmented picker — sits at the top, fixed
        Picker("", selection: $selectedTab) {
          ForEach(Tab.allCases) { tab in
            Text(tab.rawValue).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)

        // Tab content fills remaining space
        switch selectedTab {
        case .reports:
          ReportsListView(embedded: true)
        case .observations:
          ActivitiesObservationsTab()
        }
      }
      // Upload progress overlay
      .overlay {
        if isUploading {
          ZStack {
            Color.brandScrim.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 20) {
              ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.6)
                .tint(.white)

              Text(uploadPhase)
                .font(.brandHeadline)
                .foregroundColor(.brandTextPrimary)
                .multilineTextAlignment(.center)

              ProgressView(value: uploadProgress, total: 1.0)
                .progressViewStyle(.linear)
                .tint(.brandAccent)
                .frame(width: 200)

              Text("\(Int(uploadProgress * 100))%")
                .font(.brandCaption)
                .foregroundColor(.brandTextSecondary)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
          }
          .animation(.easeInOut(duration: 0.2), value: isUploading)
        }
      }
    }
    .navigationTitle("Activities")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button { dismiss() } label: {
          Image(systemName: "chevron.left")
        }
      }

      ToolbarItem(placement: .navigationBarTrailing) {
        HStack(spacing: 16) {
          // Upload all pending items
          Button { startUploadAll() } label: {
            Image(systemName: "arrow.up.circle")
          }
          .disabled(isUploading || totalPending == 0)

          // Archive
          Button { showArchive = true } label: {
            Image(systemName: "archivebox")
          }
          .disabled(archivedCatches.isEmpty)
        }
      }
    }
    .navigationDestination(isPresented: $showArchive) {
      CatchReportArchiveListView(reports: archivedCatches)
    }
    .alert(isUploading ? "Uploading…" : "Upload Complete",
           isPresented: $showUploadAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(uploadResultMessage)
    }
  }

  // MARK: - Upload All

  private func startUploadAll() {
    isUploading = true
    uploadProgress = 0
    uploadPhase = "Preparing…"
    uploadResultMessage = ""

    Task {
      await AuthStore.shared.refreshFromSupabase()

      let memberId = AuthService.shared.currentMemberId ?? ""

      coordinator.uploadAll(
        catches: pendingCatches,
        marks: pendingMarks,
        observations: pendingNotes,
        memberId: memberId,
        catchUploader: catchUploader,
        progress: { p in
          self.uploadProgress = p
        },
        phaseUpdate: { phase in
          self.uploadPhase = phase
        },
        completion: { result in
          self.isUploading = false
          self.uploadProgress = 1.0
          self.catchStore.refresh()
          self.farmedStore.refresh()
          self.uploadResultMessage = result.summary
          self.showUploadAlert = true
        }
      )
    }
  }
}
