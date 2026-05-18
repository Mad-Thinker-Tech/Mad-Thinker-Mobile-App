// Bend Fly Shop

import SwiftUI

// MARK: - View

struct FarmedReportsListView: View {
  /// Prefix for the row line that names who logged the report.
  /// Renamed from "Guide" so the same row can be reused across roles.
  static let activityRowMemberLabel = "Member"

  @Environment(\.dismiss) private var dismiss
  @StateObject private var store = FarmedReportStore.shared

  // Upload state
  @State private var isUploading = false
  @State private var uploadProgress: Double = 0.0
  @State private var uploadErrorMessage: String?
  @State private var showErrorAlert = false

  private let uploader = UploadFarmedReports()

  private var pendingReports: [FarmedReport] {
    store.reports.filter { $0.status == .savedLocally }
  }

  var body: some View {
    ZStack {
      Color.brandBackground.ignoresSafeArea()

      VStack(spacing: 0) {
        // Content
        ZStack(alignment: .bottom) {
          if store.reports.isEmpty {
            VStack {
              Text("No no-catch reports yet.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding()
              Spacer()
            }
          } else {
            List {
              ForEach(store.reports) { report in
                FarmedReportRow(report: report)
                  .listRowBackground(Color.brandBackground)
              }
              .onDelete { offsets in
                deleteReports(at: offsets)
              }
            }
            .listStyle(.plain)
            .background(Color.brandBackground)
            .modifier(FarmedHideListBackground())
            .padding(.top, 12)
          }

          // Upload progress overlay
          if isUploading {
            VStack(spacing: 8) {
              ProgressView(value: uploadProgress, total: 1.0)
                .progressViewStyle(LinearProgressViewStyle())
                .padding(.horizontal)
              Text("Uploading no-catch reports… \(Int(uploadProgress * 100))%")
                .font(.brandCaption)
                .foregroundColor(.secondary)
            }
            .padding()
            .background(.ultraThinMaterial)
          }
        }
        .frame(maxHeight: .infinity)
      }
    }
    .navigationTitle("No Catch Reports")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button {
          dismiss()
        } label: {
          Image(systemName: "chevron.left")
        }
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: startUpload) {
          Label("Upload", systemImage: "arrow.up.circle")
        }
        .disabled(isUploading || pendingReports.isEmpty)
      }
    }
    .environment(\.colorScheme, .dark)
    .onAppear {
      store.purgeOldUploaded()
      store.refresh()
    }
    .alert("Upload Error", isPresented: $showErrorAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(uploadErrorMessage ?? "Unknown error")
    }
  }

  // MARK: - Delete

  private func deleteReports(at offsets: IndexSet) {
    for index in offsets {
      let report = store.reports[index]
      // Only allow deleting reports that are saved locally (not yet uploaded)
      if report.status == .savedLocally {
        store.delete(report)
      }
    }
  }

  // MARK: - Upload

  private func startUpload() {
    guard !pendingReports.isEmpty else { return }

    isUploading = true
    uploadProgress = 0
    uploadErrorMessage = nil

    Task {
      await AuthStore.shared.refreshFromSupabase()

      guard let jwt = AuthStore.shared.jwt, !jwt.isEmpty else {
        await MainActor.run {
          self.isUploading = false
          self.uploadErrorMessage = "You must be signed in to upload no-catch reports."
          self.showErrorAlert = true
        }
        return
      }

      _ = jwt

      uploader.upload(
        reports: pendingReports,
        progress: { progress in
          DispatchQueue.main.async {
            self.uploadProgress = progress
          }
        },
        completion: { result in
          DispatchQueue.main.async {
            self.isUploading = false

            switch result {
            case let .success(uploadedIDs):
              FarmedReportStore.shared.markUploaded(uploadedIDs)
              self.store.refresh()
            case let .failure(error):
              self.uploadErrorMessage = error.localizedDescription
              self.showErrorAlert = true
            }
          }
        }
      )
    }
  }
}

// MARK: - Row

private struct FarmedReportRow: View {
  let report: FarmedReport

  private static let timestampFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateStyle = .medium
    df.timeStyle = .short
    return df
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(Self.timestampFormatter.string(from: report.createdAt))
          .font(.brandHeadline)
          .foregroundColor(.brandTextPrimary)
          .lineLimit(1)

        Spacer()
        NoCatchEventTypeChip(eventType: report.eventType)
        FarmedStatusChip(status: report.status)
      }

      if let lat = report.lat, let lon = report.lon {
        Text("GPS: \(String(format: "%.5f", lat)), \(String(format: "%.5f", lon))")
          .font(.brandFootnote)
          .foregroundColor(.secondary)
          .lineLimit(1)
      } else {
        Text("GPS: —")
          .font(.brandFootnote)
          .foregroundColor(.secondary)
      }

      Text("\(FarmedReportsListView.activityRowMemberLabel): \(report.guideName)")
        .font(.brandFootnote)
        .foregroundColor(.secondary)
        .lineLimit(1)

      if let angler = report.memberId, !angler.isEmpty {
        Text("Member Number: \(angler)")
          .font(.brandFootnote)
          .foregroundColor(.secondary)
          .lineLimit(1)
      }
    }
    .listRowBackground(Color.brandBackground)
    .deleteDisabled(report.status != .savedLocally)
  }
}

// MARK: - Status chip

private struct FarmedStatusChip: View {
  let status: FarmedReportStatus

  var body: some View {
    Text(status.rawValue)
      .font(.brandCaption2)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(background)
      .foregroundColor(foreground)
      .clipShape(Capsule())
  }

  private var background: Color {
    switch status {
    case .savedLocally: return Color.brandAccent.opacity(0.12)
    case .uploaded: return Color.brandSuccess.opacity(0.12)
    }
  }

  private var foreground: Color {
    switch status {
    case .savedLocally: return .brandAccent
    case .uploaded: return .brandSuccess
    }
  }
}

// MARK: - Event type chip

private struct NoCatchEventTypeChip: View {
  let eventType: NoCatchEventType

  var body: some View {
    Text(eventType.displayName)
      .font(.brandCaption2)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(background)
      .foregroundColor(foreground)
      .clipShape(Capsule())
  }

  private var background: Color { Color.brandTextSecondary.opacity(0.15) }

  private var foreground: Color { .gray }
}

// MARK: - List background helper

private struct FarmedHideListBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 16.0, *) {
      content.scrollContentBackground(.hidden)
    } else {
      content
    }
  }
}
