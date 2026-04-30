// Bend Fly Shop

import CoreLocation
import MapboxMaps
import SwiftUI
import UIKit
import CoreData
import Foundation

// MARK: - Catch Report Upload API (URL composition matches TripRosterAPI pattern)

enum CatchReportUploadAPI {
  // Composable base + path URLs from Info.plist keys, with safe normalization and logging

  private static let rawBaseURLString: String = {
    (Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }()

  private static let baseURLString: String = {
    var s = rawBaseURLString
    if !s.isEmpty, URL(string: s)?.scheme == nil {
      s = "https://" + s
    }
    return s
  }()

  private static let rawUploadString: String = {
    (Bundle.main.object(forInfoDictionaryKey: "UPLOAD_CATCH_URL") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      ?? "/functions/v1/upload-catch-reports-v5"
  }()

  private static let supabaseAnonKey: String = {
    (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }()

  private static func logConfig(normalizedPath: String) {
    AppLogging.log("CatchReportUploadAPI config — API_BASE_URL (raw): '\(rawBaseURLString)'", level: .debug, category: .catch)
    AppLogging.log("CatchReportUploadAPI config — API_BASE_URL (normalized): '\(baseURLString)'", level: .debug, category: .catch)
    AppLogging.log("CatchReportUploadAPI config — UPLOAD_CATCH_URL (raw): '\(rawUploadString)'", level: .debug, category: .catch)
    AppLogging.log("CatchReportUploadAPI config — upload path (normalized): '\(normalizedPath)'", level: .debug, category: .catch)
    AppLogging.log("CatchReportUploadAPI config — SUPABASE_ANON_KEY prefix: \(supabaseAnonKey.prefix(8))…", level: .debug, category: .catch)
  }

  /// Convert whatever is in UPLOAD_CATCH_URL into a *path-only* string (e.g. "/functions/v1/upload-catch-reports-v5")
  /// Handles:
  /// - "/functions/v1/..."
  /// - "functions/v1/..."
  /// - "https://host/functions/v1/..."
  /// - "https://$(API_BASE_URL)/functions/v1/..."
  private static func normalizePath(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    // If someone stored a tokenized full URL like https://$(API_BASE_URL)/functions/...
    // replace the "https://$(API_BASE_URL)" prefix with the actual normalized baseURLString.
    // Also handle http:// variant.
    s = s.replacingOccurrences(of: "https://$(API_BASE_URL)", with: baseURLString)
    s = s.replacingOccurrences(of: "http://$(API_BASE_URL)", with: baseURLString)

    // If someone stored only "$(API_BASE_URL)/functions/..." (no scheme),
    // replace token with the *host-only* form so we can still parse if needed.
    if s.contains("$(API_BASE_URL)") {
      let hostOnly = baseURLString
        .replacingOccurrences(of: "https://", with: "")
        .replacingOccurrences(of: "http://", with: "")
      s = s.replacingOccurrences(of: "$(API_BASE_URL)", with: hostOnly)
    }

    // If it's an absolute URL now, extract its path (+ query) as the "relative" portion
    if let abs = URL(string: s), abs.scheme != nil, abs.host != nil {
      var path = abs.path
      if path.isEmpty { path = "/" }
      if let comps = URLComponents(url: abs, resolvingAgainstBaseURL: false),
         let q = comps.percentEncodedQuery, !q.isEmpty {
        path += "?\(q)"
      }
      return path
    }

    // Otherwise treat as a relative path
    if s.isEmpty { return "/functions/v1/upload-catch-reports-v5" }
    return s.hasPrefix("/") ? s : ("/" + s)
  }

  /// Builds URL by combining baseURLString with a normalized path.
  /// Preserves any query string that was embedded in the path (rare, but safe).
  private static func makeURL(pathWithOptionalQuery: String) throws -> URL {
    guard let base = URL(string: baseURLString), let scheme = base.scheme, let host = base.host else {
      AppLogging.log("CatchReportUploadAPI invalid API_BASE_URL — raw: '\(rawBaseURLString)', normalized: '\(baseURLString)'", level: .debug, category: .catch)
      throw NSError(domain: "CatchReportUpload", code: -1000, userInfo: [
        NSLocalizedDescriptionKey: "Invalid API_BASE_URL (raw: '\(rawBaseURLString)', normalized: '\(baseURLString)')"
      ])
    }

    // Split embedded query off the path if present
    let parts = pathWithOptionalQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    let rawPath = String(parts.first ?? "")
    let rawQuery = (parts.count == 2) ? String(parts[1]) : nil

    var comps = URLComponents()
    comps.scheme = scheme
    comps.host = host
    comps.port = base.port

    let basePath = base.path
    let normalizedBasePath = basePath == "/" ? "" : (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath)
    let normalizedPath = rawPath.hasPrefix("/") ? rawPath : "/" + rawPath
    comps.path = normalizedBasePath + normalizedPath

    // Preserve any query already on the base URL (rare) plus query from the path.
    let existing = base.query != nil ? (URLComponents(string: base.absoluteString)?.queryItems ?? []) : []
    var merged: [URLQueryItem] = existing

    if let rawQuery, !rawQuery.isEmpty {
      // Parse query into items by constructing temporary URLComponents
      var tmp = URLComponents()
      tmp.percentEncodedQuery = rawQuery
      merged.append(contentsOf: tmp.queryItems ?? [])
    }

    comps.queryItems = merged.isEmpty ? nil : merged

    guard let url = comps.url else {
      throw NSError(domain: "CatchReportUpload", code: -1001, userInfo: [
        NSLocalizedDescriptionKey: "Failed to build URL for path: \(pathWithOptionalQuery)"
      ])
    }
    return url
  }

  static func endpointURL() -> URL? {
    let normalizedPath = normalizePath(rawUploadString)
    logConfig(normalizedPath: normalizedPath)

    do {
      let url = try makeURL(pathWithOptionalQuery: normalizedPath)
      AppLogging.log("CatchReportUploadAPI endpoint URL: \(url.absoluteString)", level: .debug, category: .catch)
      return url
    } catch {
      AppLogging.log("CatchReportUploadAPI failed to build endpoint — \(error.localizedDescription)", level: .debug, category: .catch)
      return nil
    }
  }

  static func apiKey() -> String { supabaseAnonKey }
}

// MARK: - View

struct ReportsListView: View {
  /// When true the view is hosted inside `ActivitiesView` and skips its own
  /// `DarkPageTemplate` wrapper, navigation title, and back button. The
  /// parent provides those instead. All state, upload logic, sheets, and
  /// navigation destinations remain functional.
  let embedded: Bool

  init(embedded: Bool = false) {
    self.embedded = embedded
  }

  @Environment(\.dismiss) private var dismiss
  @StateObject private var store = CatchReportStore.shared

  // Upload state
  @State private var isUploading = false
  @State private var uploadProgress: Double = 0.0
  @State private var uploadErrorMessage: String?
  @State private var showErrorAlert = false
  @State private var lastUploadResult: String?

  @State private var reportToDelete: CatchReport?
  @State private var showDeleteConfirm: Bool = false

  // Map navigation
  @State private var showMap = false

  // Archive navigation
  @State private var showArchived = false

  // Farmed navigation (removed — now in Observations tab)

    private var uploader: UploadCatchReport {
      // Read from Info.plist (ProcessInfo.environment is typically empty on iOS)
      let rawBase = ((Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      let baseWithScheme: String = {
        guard !rawBase.isEmpty else { return "" }
        if rawBase.hasPrefix("http://") || rawBase.hasPrefix("https://") {
          return rawBase
        } else {
          return "https://" + rawBase
        }
      }()

      let rawPath = ((Bundle.main.object(forInfoDictionaryKey: "UPLOAD_CATCH_URL") as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      let apiKey = ((Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      // Helper: join base + relative path safely (handles leading "/")
      func join(base: String, path: String) -> URL? {
        guard !base.isEmpty, let baseURL = URL(string: base) else { return nil }
        guard !path.isEmpty else { return baseURL }

        // If relative path begins with "/", drop it for appendingPathComponent
        if path.hasPrefix("/") {
          return baseURL.appendingPathComponent(String(path.dropFirst()))
        } else {
          return baseURL.appendingPathComponent(path)
        }
      }

      // Expand tokenized forms like "https://$(API_BASE_URL)/functions/..."
      // and also handle "$(API_BASE_URL)/functions/..." (no scheme)
      let expandedPath: String = {
        var s = rawPath

        // Replace full tokenized absolute prefixes
        s = s.replacingOccurrences(of: "https://$(API_BASE_URL)", with: baseWithScheme)
        s = s.replacingOccurrences(of: "http://$(API_BASE_URL)", with: baseWithScheme)

        // Replace bare token "$(API_BASE_URL)" with host-only if present
        if s.contains("$(API_BASE_URL)") {
          let hostOnly = baseWithScheme
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
          s = s.replacingOccurrences(of: "$(API_BASE_URL)", with: hostOnly)
        }

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
      }()

      let endpointURL: URL? = {
        // If UPLOAD_CATCH_URL is an absolute URL (after expansion), use it as-is
        if let u = URL(string: expandedPath), u.scheme != nil, u.host != nil {
          return u
        }

        // Otherwise treat it as relative (your updated config should be this case)
        return join(base: baseWithScheme, path: expandedPath)
      }()

      // Logging (matches your style)
      AppLogging.log("CatchReport uploader config — API_BASE_URL (raw): '\(rawBase)'", level: .debug, category: .catch)
      AppLogging.log("CatchReport uploader config — API_BASE_URL (normalized): '\(baseWithScheme)'", level: .debug, category: .catch)
      AppLogging.log("CatchReport uploader config — UPLOAD_CATCH_URL (raw): '\(rawPath)'", level: .debug, category: .catch)
      AppLogging.log("CatchReport uploader config — UPLOAD_CATCH_URL (expanded): '\(expandedPath)'", level: .debug, category: .catch)

      if let endpointURL {
        AppLogging.log("CatchReport uploader endpoint resolved: \(endpointURL.absoluteString)", level: .debug, category: .catch)
      } else {
        AppLogging.log(
          "CatchReport uploader endpoint is invalid. base='\(baseWithScheme)' path='\(rawPath)'. Falling back to https://invalid.local",
          level: .debug,
          category: .catch
        )
      }

      if apiKey.isEmpty {
        AppLogging.log("SUPABASE_ANON_KEY is empty or not set. Uploads may fail.", level: .debug, category: .catch)
      } else {
        AppLogging.log("CatchReport uploader apikey prefix: \(apiKey.prefix(8))…", level: .debug, category: .catch)
      }

      return UploadCatchReport(
        config: .init(
          endpoint: endpointURL ?? URL(string: "https://invalid.local")!,
          appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
          apiKey: apiKey
        )
      )
    }

  // MARK: - Archiving

  private func isArchived(_ report: CatchReport) -> Bool {
    guard report.status == .uploaded else { return false }
    let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date.distantPast
    return report.createdAt < twoWeeksAgo
  }

  private var activeReports: [CatchReport] {
    store.reports.filter { !isArchived($0) }
  }

  private var archivedReports: [CatchReport] {
    store.reports.filter { isArchived($0) }
  }

  // MARK: - Derived collections (active only)

  private var pendingReports: [CatchReport] {
    activeReports.filter { $0.status == .savedLocally }
  }

  private var uploadedReports: [CatchReport] {
    activeReports.filter { $0.status == .uploaded }
  }

  private var groupedPending: [(date: String, reports: [CatchReport])] {
    groupedByDay(pendingReports)
  }

  private var groupedUploaded: [(date: String, reports: [CatchReport])] {
    groupedByDay(uploadedReports)
  }

  private func groupedByDay(_ list: [CatchReport])
    -> [(date: String, reports: [CatchReport])] {
    let grouped = Dictionary(grouping: list) { report -> String in
      Self.dayFormatter.string(from: report.createdAt)
    }

    return grouped
      .map { (
        date: $0.key,
        reports: $0.value.sorted { $0.createdAt > $1.createdAt }
      ) 
      }
      .sorted { lhs, rhs in
        guard let ld = Self.dayFormatter.date(from: lhs.date),
              let rd = Self.dayFormatter.date(from: rhs.date)
        else { return lhs.date > rhs.date }
        return ld > rd
      }
  }

  static let dayFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateStyle = .long
    df.timeStyle = .none
    return df
  }()

  // MARK: - Map annotation data

  private var mapAnnotations: [CatchReportAnnotation] {
    store.reports.compactMap { r in
      guard
        let lat = r.lat,
        let lon = r.lon,
        lat.isFinite, lon.isFinite,
        lat >= -90, lat <= 90,
        lon >= -180, lon <= 180,
        !(lat == 0 && lon == 0)
      else {
        return nil
      }

      let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)

      return CatchReportAnnotation(
        id: r.id,
        coordinate: coord,
        title: r.species ?? "Catch",
        subtitle: r.river,
        lifecycleStage: r.lifecycleStage,
        lengthInches: r.lengthInches,
        memberId: r.memberId,
        createdAt: r.createdAt
      )
    }
  }

  // MARK: - Body

  var body: some View {
    let inner = reportsContent

    if embedded {
      // Hosted inside ActivitiesView — no DarkPageTemplate, no nav chrome.
      inner
    } else {
      // Standalone — full page with toolbar and nav title.
      DarkPageTemplate(bottomToolbar: {
        RoleAwareToolbar(activeTab: "activities")
      }) {
        inner
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
      }
    }
  }

  // MARK: - Reports content (shared between standalone and embedded modes)

  @ViewBuilder
  private var reportsContent: some View {
    VStack(spacing: 0) {
        // Content fills remaining space
        ZStack(alignment: .bottom) {
          if store.reports.isEmpty {
            VStack {
              Text("No catch reports yet.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding()
              Spacer()
            }
          } else if activeReports.isEmpty {
            VStack {
              VStack(spacing: 12) {
                Image(systemName: "archivebox")
                  .font(.largeTitle)
                  .foregroundColor(.secondary)
                Text("All catch reports have been archived.")
                  .font(.headline)
                  .foregroundColor(.white)
                  .multilineTextAlignment(.center)
                Text("Tap the archive icon in the toolbar to view previous catch reports.")
                  .font(.subheadline)
                  .foregroundColor(.secondary)
                  .multilineTextAlignment(.center)
              }
              .padding()
              Spacer()
            }
          } else {
              List {
                if !groupedPending.isEmpty {
                  Section(header: Text("Pending Upload").foregroundColor(.white)) {
                    ForEach(groupedPending, id: \.date) { section in
                      Text(section.date)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .listRowBackground(Color.black)

                      ForEach(section.reports) { report in
                        NavigationLink {
                          CatchReportDetailView(report: report)
                        } label: {
                          CatchReportRow(report: report)
                        }
                        .listRowBackground(Color.black)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                          Button(role: .destructive) {
                            self.reportToDelete = report
                            self.showDeleteConfirm = true
                          } label: {
                            Label("Delete", systemImage: "trash")
                          }
                          .tint(.red)
                        }
                      }
                    }
                  }
                }

                if !groupedUploaded.isEmpty {
                  Section(header: Text("Uploaded").foregroundColor(.white)) {
                    ForEach(groupedUploaded, id: \.date) { section in
                      Text(section.date)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .listRowBackground(Color.black)

                      ForEach(section.reports) { report in
                        NavigationLink {
                          CatchReportDetailView(report: report)
                        } label: {
                          CatchReportRow(report: report)
                        }
                        .listRowBackground(Color.black)
                      }
                    }
                  }
                }
              }
              .listStyle(.plain)
              .background(Color.black)
              .modifier(HideListBackgroundIfAvailable())
              .alert("Delete Catch Report?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {
                  reportToDelete = nil
                }
                Button("Delete", role: .destructive) {
                  if let r = reportToDelete {
                    // Only allow deletion of locally saved reports
                    if r.status == .savedLocally {
                      CatchReportStore.shared.delete(r)
                      store.refresh()
                    }
                    reportToDelete = nil
                  }
                }
              } message: {
                Text("This will remove the catch report from this device. This action cannot be undone.")
              }
            }

          // Upload progress overlay
          if isUploading {
            VStack(spacing: 8) {
              ProgressView(value: uploadProgress, total: 1.0)
                .progressViewStyle(LinearProgressViewStyle())
                .padding(.horizontal)
              Text("Uploading catch reports… \(Int(uploadProgress * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding()
            .background(.ultraThinMaterial)
          }
        }
        .frame(maxHeight: .infinity)
      }
    .onAppear {
      store.refresh()
    }
    .navigationDestination(isPresented: $showArchived) {
      CatchReportArchiveListView(reports: archivedReports)
    }
    // No Catch (farmed) navigation removed — now in Observations tab
    .alert("Upload Error", isPresented: $showErrorAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(uploadErrorMessage ?? "Unknown error")
    }
  }

  // MARK: - Upload / Delete

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
          self.uploadProgress = 0
          self.uploadErrorMessage = "You must be signed in to upload catch reports."
          self.showErrorAlert = true
        }
        return
      }

      _ = jwt

      let uploader = self.uploader
      let reportsToUpload = self.pendingReports

      uploader.upload(
        reports: reportsToUpload,
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
              CatchReportStore.shared.markUploaded(uploadedIDs)
              self.store.refresh()
              self.lastUploadResult = "Uploaded \(uploadedIDs.count) catch reports."
            case let .failure(error):
              self.uploadErrorMessage = error.localizedDescription
              self.showErrorAlert = true
            }
          }
        }
      )
    }
  }

  private func deleteReports(offsets: IndexSet, in sectionReports: [CatchReport]) {
    let toDelete = offsets.map { sectionReports[$0] }
    let local = toDelete.filter { $0.status == .savedLocally }
    local.forEach { store.delete($0) }
  }
}

// MARK: - List background helper

private struct HideListBackgroundIfAvailable: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 16.0, *) {
      content.scrollContentBackground(.hidden)
    } else {
      content
    }
  }
}

// MARK: - Row

private struct CatchReportRow: View {
  let report: CatchReport
  var isArchived: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(speciesText)
          .font(.headline)
          .foregroundColor(.white)
          .lineLimit(1)
          .truncationMode(.tail)

        if let lengthText {
          Text("• \(lengthText)")
            .font(.subheadline)
            .foregroundColor(.secondary)
        }

        if let riverText {
          Text("• \(riverText)")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }

        Spacer()
        CatchReportStatusChip(status: report.status, isArchived: isArchived)
      }

      Text("\(authorRoleLabel): \(guideText)")
        .font(.footnote)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)

      Text("Member Number: \(report.memberId)")
        .font(.footnote)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .listRowBackground(Color.black)
  }

  private var speciesText: String {
    (report.species?.isEmpty == false ? report.species : "Unknown Species") ?? "Unknown Species"
  }

  private var lengthText: String? {
    report.lengthInches > 0 ? "\(report.lengthInches)\"" : nil
  }

  private var riverText: String? {
    let name = (report.river?.isEmpty == false ? report.river : "Unknown River") ?? "Unknown River"
    return name
  }

  private var guideText: String {
    let name = report.guideName ?? ""
    return name.isEmpty ? "—" : name
  }

  private var authorRoleLabel: String {
    switch AuthService.shared.currentUserType {
    case .researcher: return "Researcher"
    case .`public`: return "Member"
    default: return "Guide"
    }
  }
}

// MARK: - Status chip

private struct CatchReportStatusChip: View {
  let status: CatchReportStatus
  var isArchived: Bool = false

  var body: some View {
    Text(displayText)
      .font(.caption2)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(background)
      .foregroundColor(foreground)
      .clipShape(Capsule())
  }

  private var displayText: String {
    isArchived ? "Archived" : status.rawValue
  }

  private var background: Color {
    if isArchived { return Color.gray.opacity(0.15) }
    switch status {
    case .savedLocally: return Color.blue.opacity(0.12)
    case .uploaded: return Color.green.opacity(0.12)
    }
  }

  private var foreground: Color {
    if isArchived { return .gray }
    switch status {
    case .savedLocally: return .blue
    case .uploaded: return .green
    }
  }
}

// MARK: - Map support

private struct CatchReportAnnotation: Identifiable {
  let id: UUID
  let coordinate: CLLocationCoordinate2D
  let title: String
  let subtitle: String?
  let lifecycleStage: String?
  let lengthInches: Int
  let memberId: String
  let createdAt: Date
}

// MARK: - SwiftUI Mapbox map wrapper with navigation

private struct CatchReportMapView: View {
  let annotations: [CatchReportAnnotation]

  @State private var selectedAnnotation: CatchReportAnnotation?
  @State private var selectedReportID: UUID?

  private var showDetail: Binding<Bool> {
    Binding(
      get: { selectedReportID != nil },
      set: { if !$0 { selectedReportID = nil } }
    )
  }

  private var selectedReport: CatchReport? {
    guard let id = selectedReportID else { return nil }
    return CatchReportStore.shared.reports.first { $0.id == id }
  }

  private var initialViewport: Viewport {
    if let latest = annotations.sorted(by: { $0.createdAt > $1.createdAt }).first {
      return .camera(center: latest.coordinate, zoom: 10, bearing: 0, pitch: 0)
    }
    // Fallback: Skeena region
    return .camera(
      center: CLLocationCoordinate2D(latitude: 54.5, longitude: -128.6),
      zoom: 8, bearing: 0, pitch: 0
    )
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      Map(initialViewport: initialViewport) {
        PointAnnotationGroup(annotations) { annotation in
          PointAnnotation(coordinate: annotation.coordinate)
            .image(.init(image: MapPinImage.pin(), name: "catch-pin"))
            .iconAnchor(IconAnchor.bottom)
            .onTapGesture { _ in
              selectedAnnotation = annotation
              return true
            }
        }

        if let selected = selectedAnnotation {
          MapViewAnnotation(coordinate: selected.coordinate) {
            CatchReportCalloutView(
              title: selected.title,
              lifecycleStage: selected.lifecycleStage,
              lengthInches: selected.lengthInches,
              memberId: selected.memberId,
              createdAt: selected.createdAt,
              onDismiss: { selectedAnnotation = nil }
            )
          }
          .allowOverlap(true)
          .variableAnchors([
            ViewAnnotationAnchorConfig(anchor: .bottom, offsetY: 40),
          ])
        }
      }
      .mapStyle(.outdoors)
      .ignoresSafeArea(edges: .bottom)
    }
    .navigationTitle("Catch Map")
    .environment(\.colorScheme, .dark)
    .navigationDestination(isPresented: showDetail) {
      if let report = selectedReport {
        CatchReportDetailView(report: report)
      }
    }
  }
}

// MARK: - Detail View

private struct CatchReportDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.managedObjectContext) private var context

  @State private var report: CatchReport
  @ObservedObject private var voiceStore = VoiceNoteStore.shared
  @StateObject private var audioPlayer = NoteAudioPlayer()
  @State private var isEditing: Bool = false

  // Drive navigation to voice recorder (ChatVoiceNoteSheet)
  @State private var showVoiceNoteRecorder = false

  init(report: CatchReport) {
    _report = State(initialValue: report)
  }

  private var canEdit: Bool {
    report.status == .savedLocally && isEditing
  }

  var body: some View {
    ZStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if report.conservationOptIn == true {
            conservationBadge
          }
          photoSection
          if report.headPhotoFilename != nil {
            headPhotoSection
          }
          catchInfoSection
          // Length is always present; girth/weight rows inside the section
          // stay conditional for historical records that pre-date Phase 3.
          measurementsSection
          if hasResearchTagData {
            researchTagsSection
          }
          tripInfoSection
          locationSection
          voiceMemoSection
        }
        .padding()
      }

    }
    .background(Color.black.ignoresSafeArea())
    .navigationTitle("Catch Details")
    .navigationDestination(isPresented: $showVoiceNoteRecorder) {
      ChatVoiceNoteSheet { note in
        // Attach note metadata to this catch
        report.voiceNoteId = note.id
        if !note.transcript.isEmpty {
          report.voiceTranscript = note.transcript
        }

        // Persist immediately so it's saved even if the user
        // backs out without tapping "Save Changes".
        CatchReportStore.shared.update(report)

        // Pop back to the detail view
        showVoiceNoteRecorder = false
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Group {
          if report.status == .savedLocally {
            Button {
              if isEditing {
                saveEdits()
              } else {
                isEditing = true
              }
            } label: {
              if isEditing {
                Text("Save")
                  .font(.subheadline.weight(.semibold))
                  .foregroundColor(.white)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .background(Color.blue)
                  .clipShape(Capsule())
              } else {
                Text("Edit")
              }
            }
          }
        }
      }
    }
    .environment(\.colorScheme, .dark)
  }

  // MARK: Sections

  private var photoSection: some View {
    Group {
      if let filename = report.photoFilename,
         let image = loadCatchImage(filename: filename) {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .cornerRadius(12)
      } else {
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.gray.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4]))
          .frame(height: 200)
          .overlay(
            Text("No photo available")
              .foregroundColor(.secondary)
          )
      }
    }
  }

  private var catchInfoSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Catch Info")
        .font(.headline)
        .foregroundColor(.white)

      editableTextField(title: "Species", text: Binding(
        get: { report.species ?? "" },
        set: { report.species = $0 }
      ))

      editableTextField(title: "Lifecycle Stage", text: Binding(
        get: { report.lifecycleStage ?? "" },
        set: { report.lifecycleStage = $0 }
      ))

      editableTextField(title: "Sex", text: Binding(
        get: { report.sex ?? "" },
        set: { report.sex = $0 }
      ))

      editableTextField(title: "River", text: Binding(
        get: { report.river ?? "" },
        set: { report.river = $0 }
      ))
    }
    .padding()
    .background(Color.white.opacity(0.06))
    .cornerRadius(12)
  }

  // MARK: Conservation badge & research-grade sections

  /// Shown at the top of the detail view when this catch participated in the
  /// conservation/research flow. Mirrors the landing-view banner.
  private var conservationBadge: some View {
    HStack(spacing: 6) {
      Image(systemName: "leaf.fill")
        .font(.caption)
        .foregroundColor(.green)
      Text("Conservation Mode")
        .font(.caption.weight(.semibold))
        .foregroundColor(.green)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    .background(Color.green.opacity(0.12))
    .cornerRadius(10)
    .accessibilityIdentifier("conservationBadge")
  }

  /// Close-up head shot displayed below the primary catch photo when present.
  /// Populated by the research/conservation flow in Phase 3.5.
  private var headPhotoSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Head Photo")
        .font(.headline)
        .foregroundColor(.white)

      if let filename = report.headPhotoFilename,
         let image = loadCatchImage(filename: filename) {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .cornerRadius(12)
      }
    }
    .padding()
    .background(Color.white.opacity(0.06))
    .cornerRadius(12)
  }

  /// Length, girth, and weight rows. Length is always present on a catch;
  /// girth/weight are only populated by the unified research flow (Phase 3+)
  /// and are omitted from display on older historical records. The `~` prefix
  /// marks estimated values, matching the convention in FishWeightEstimator.
  private var measurementsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Measurements")
        .font(.headline)
        .foregroundColor(.white)

      HStack {
        Text("Length (in)")
          .font(.subheadline)
          .foregroundColor(.blue)
        Spacer()
        TextField(
          canEdit ? "Length" : "",
          text: Binding(
            get: { report.lengthInches > 0 ? "\(report.lengthInches)" : "" },
            set: { value in
              if let intVal = Int(value) {
                report.lengthInches = intVal
              } else {
                report.lengthInches = 0
              }
            }
          )
        )
        .keyboardType(.numberPad)
        .multilineTextAlignment(.trailing)
        .foregroundColor(.white)
        .disabled(!canEdit)
      }

      if let girth = report.girthInches {
        infoRow(label: "Girth (in)", value: String(format: "%.1f", girth))
      }
      if let weight = report.weightLbs {
        infoRow(label: "Weight (lbs)", value: String(format: "%.1f", weight))
      }
    }
    .padding()
    .background(Color.white.opacity(0.06))
    .cornerRadius(12)
  }

  /// True when any research-tag or sample field is populated on the report.
  private var hasResearchTagData: Bool {
    report.floyId?.isEmpty == false
      || report.pitId?.isEmpty == false
      || report.sampleEnvelopeId?.isEmpty == false
  }

  /// Research tag IDs and sample envelope. Only rendered when at least one
  /// field is populated (guarded by `hasResearchTagData` at the call site).
  private var researchTagsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Research Tags & Samples")
        .font(.headline)
        .foregroundColor(.white)

      if let floy = report.floyId, !floy.isEmpty {
        infoRow(label: "Floy Tag", value: floy)
      }
      if let pit = report.pitId, !pit.isEmpty {
        infoRow(label: "PIT Tag", value: pit)
      }
      if let envelope = report.sampleEnvelopeId, !envelope.isEmpty {
        infoRow(label: "Sample Envelope", value: envelope)
        if let contents = report.sampleContents, !contents.isEmpty {
          infoRow(label: "Contents", value: formattedSampleContents(contents))
        }
      }
    }
    .padding()
    .background(Color.white.opacity(0.06))
    .cornerRadius(12)
  }

  /// Map the wire-format contents array (`["scale", "fin_clip"]`) to a
  /// human-readable label ("Scale + Fin clip"). Reserved future values
  /// (`"otolith"`, `"tissue"`, `"gut"`) get title-cased so they display
  /// reasonably even before we add explicit labels.
  private func formattedSampleContents(_ contents: [String]) -> String {
    contents.map { value in
      switch value {
      case "scale": return "Scale"
      case "fin_clip": return "Fin clip"
      default: return value.replacingOccurrences(of: "_", with: " ").capitalized
      }
    }.joined(separator: " + ")
  }

  private var tripInfoSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Trip / Angler")
        .font(.headline)
        .foregroundColor(.white)

      HStack {
        Text("Trip Name")
          .font(.subheadline)
          .foregroundColor(.blue)
        Spacer()
        Text(resolvedTripName())
          .font(.body)
          .foregroundColor(.white)
      }

      editableTextField(title: "Guide", text: Binding(
        get: { report.guideName ?? "" },
        set: { report.guideName = $0 }
      ))

      editableTextField(title: "Member Number", text: Binding(
        get: { report.memberId },
        set: { report.memberId = MemberNumber.normalize($0) }
      ))

      if CommunityService.shared.activeCommunityConfig.flag("E_MANAGE_LICENSES") {
        editableTextField(title: "Classified Waters License", text: Binding(
          get: { report.classifiedWatersLicenseNumber ?? "" },
          set: { report.classifiedWatersLicenseNumber = $0 }
        ))
      }

      infoRow(
        label: "Created",
        value: DateFormatter.localizedString(from: report.createdAt, dateStyle: .medium, timeStyle: .short)
      )
      if let uploadedAt = report.uploadedAt {
        infoRow(
          label: "Uploaded",
          value: DateFormatter.localizedString(from: uploadedAt, dateStyle: .medium, timeStyle: .short)
        )
      }
    }
    .padding()
    .background(Color.white.opacity(0.06))
    .cornerRadius(12)
  }

  private var locationSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Location")
        .font(.headline)
        .foregroundColor(.white)

      editableDoubleField(
        title: "Latitude",
        value: Binding(
          get: { report.lat },
          set: { report.lat = $0 }
        )
      )

      editableDoubleField(
        title: "Longitude",
        value: Binding(
          get: { report.lon },
          set: { report.lon = $0 }
        )
      )
    }
    .padding()
    .background(Color.white.opacity(0.06))
    .cornerRadius(12)
  }

  private var voiceMemoSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Voice Memo")
        .font(.headline)
        .foregroundColor(.white)

      if let voiceId = report.voiceNoteId,
         let note = voiceStore.notes.first(where: { $0.id == voiceId }) {
        // We *have* a voice memo attached
        let transcript = (report.voiceTranscript?.isEmpty == false)
          ? report.voiceTranscript!
          : note.transcript

        if !transcript.isEmpty {
          Text(transcript)
            .font(.subheadline)
            .foregroundColor(.white)
        } else {
          Text("No transcript available")
            .font(.subheadline)
            .foregroundColor(.secondary)
        }

        HStack(spacing: 12) {
          Button {
            audioPlayer.play(url: voiceStore.audioURL(for: note))
          } label: {
            HStack {
              Image(systemName: "play.circle.fill")
              Text("Play")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white)
            .foregroundColor(.black)
            .cornerRadius(8)
          }

          if canEdit {
            Button {
              // Re-record existing memo → same UX as CatchChatView
              showVoiceNoteRecorder = true
            } label: {
              HStack {
                Image(systemName: "mic.fill")
                Text("Re-record")
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(Color.white.opacity(0.1))
              .foregroundColor(.white)
              .cornerRadius(8)
            }
          }
        }

      } else {
        // No voice memo attached
        Text("No voice memo attached")
          .font(.subheadline)
          .foregroundColor(.secondary)

        if canEdit {
          Button {
            // Record new memo → same UX as CatchChatView
            showVoiceNoteRecorder = true
          } label: {
            HStack {
              Image(systemName: "mic.fill")
              Text("Record")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.1))
            .foregroundColor(.white)
            .cornerRadius(8)
          }
        }
      }
    }
    .padding()
    .background(Color.white.opacity(0.06))
    .cornerRadius(12)
  }

  // MARK: Helpers

  private func editableTextField(title: String, text: Binding<String>) -> some View {
    HStack {
      Text(title)
        .font(.subheadline)
        .foregroundColor(.blue)
      Spacer()
      TextField(
        canEdit ? title : "",
        text: text
      )
      .multilineTextAlignment(.trailing)
      .foregroundColor(.white)
      .disabled(!canEdit)
    }
  }

  private func editableDoubleField(title: String, value: Binding<Double?>) -> some View {
    HStack {
      Text(title)
        .font(.subheadline)
        .foregroundColor(.blue)
      Spacer()
      TextField(
        canEdit ? title : "",
        text: Binding(
          get: {
            if let v = value.wrappedValue {
              String(format: "%.5f", v)
            } else {
              ""
            }
          },
          set: { str in
            if let v = Double(str) {
              value.wrappedValue = v
            } else {
              value.wrappedValue = nil
            }
          }
        )
      )
      .keyboardType(.decimalPad)
      .multilineTextAlignment(.trailing)
      .foregroundColor(.white)
      .disabled(!canEdit)
    }
  }

  private func infoRow(label: String, value: String) -> some View {
    HStack {
      Text(label)
        .font(.subheadline)
        .foregroundColor(.blue)
      Spacer()
      Text(value)
        .font(.subheadline)
        .foregroundColor(.white)
    }
  }

  private func loadCatchImage(filename: String) -> UIImage? {
    let fm = FileManager.default
    guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
    let dir = docs.appendingPathComponent("CatchPhotos", isDirectory: true)
    let url = dir.appendingPathComponent(filename)
    return UIImage(contentsOfFile: url.path)
  }

  private func saveEdits() {
    CatchReportStore.shared.update(report)
    isEditing = false
    dismiss()
  }

  private func resolvedTripName() -> String {
    // First check if the catch report has a tripName stored directly
    if let storedName = report.tripName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !storedName.isEmpty {
      return storedName
    }

    // Fall back to Core Data Trip lookup using the stored tripId
    let dash = "-"

    // Guard that CatchReport has a tripId property; if not, bail
    guard let any = Mirror(reflecting: report).children.first(where: { $0.label == "tripId" })?.value else {
      return dash
    }

    // Extract tripId as String if possible
    let tripIdString: String
    if let s = any as? String { tripIdString = s } else if let sOpt = any as? String? { tripIdString = sOpt ?? "" } else { return dash }

    let trimmed = tripIdString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return dash }

    // Build fetch request for Trip by tripId, supporting UUID or String storage
    let request: NSFetchRequest<Trip> = Trip.fetchRequest()

    if let uuid = UUID(uuidString: trimmed) {
      request.predicate = NSPredicate(format: "tripId == %@", uuid as CVarArg)
    } else {
      request.predicate = NSPredicate(format: "tripId == %@", trimmed)
    }

    request.fetchLimit = 1

    do {
      if let trip = try context.fetch(request).first {
        // Prefer Trip.name if present and non-empty
        if let nameAttr = trip.entity.attributesByName["name"], nameAttr.attributeType == .stringAttributeType {
          if let name = trip.value(forKey: "name") as? String {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
          }
        }
      }
    } catch {
      // Silent fallback
    }

    return dash
  }
}

// MARK: - CatchReportVoiceNoteSheet

private struct CatchReportVoiceNoteSheet: View {
  @Binding var isPresented: Bool
  let onSaved: (LocalVoiceNote) -> Void

  @StateObject private var recorder = SpeechRecorder()
  @State private var isStarting = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationView {
      VStack(spacing: 16) {
        Text("Record a quick voice memo for this catch.")
          .font(.headline)
          .foregroundColor(.white)
          .multilineTextAlignment(.center)
          .padding(.top, 8)

        ZStack {
          Circle()
            .strokeBorder(Color.white.opacity(0.35), lineWidth: 2)
            .frame(width: 120, height: 120)

          Circle()
            .fill(recorder.isRecording ? Color.red.opacity(0.7) : Color.white.opacity(0.15))
            .frame(width: 100, height: 100)

          Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
            .font(.system(size: 36, weight: .bold))
            .foregroundColor(.white)
        }
        .padding(.vertical, 8)
        .onTapGesture { toggleRecording() }

        ScrollView {
          Text(
            recorder.partialTranscript.isEmpty
              ? "Transcript will appear here as you speak…"
              : recorder.partialTranscript
          )
          .font(.body)
          .foregroundColor(.white.opacity(0.9))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
          .background(Color.white.opacity(0.08))
          .cornerRadius(12)
        }
        .frame(maxHeight: 260)

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
            recorder.stop()
            isPresented = false
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

  private func toggleRecording() {
    if recorder.isRecording {
      recorder.stop()
    } else {
      isStarting = true
      Task {
        do {
          try await recorder.start()
        } catch {
          errorMessage = error.localizedDescription
        }
        isStarting = false
      }
    }
  }

  private func saveNote() {
    recorder.stop()

    guard let tempURL = recorder.currentTempURL() else {
      errorMessage = "No audio recorded."
      return
    }

    let duration = recorder.totalDurationSec()
    let note = VoiceNoteStore.shared.addNew(
      audioTempURL: tempURL,
      transcript: recorder.partialTranscript,
      language: recorder.languageCode,
      onDevice: recorder.onDeviceRecognition,
      sampleRate: recorder.sampleRate,
      location: nil,
      duration: duration
    )

    onSaved(note)
    isPresented = false
  }
}

// MARK: - Archived List

struct CatchReportArchiveListView: View {
  let reports: [CatchReport]

  private var groupedArchived: [(date: String, reports: [CatchReport])] {
    let grouped = Dictionary(grouping: reports) { report -> String in
      ReportsListView.dayFormatter.string(from: report.createdAt)
    }
    return grouped
      .map { (
        date: $0.key,
        reports: $0.value.sorted { $0.createdAt > $1.createdAt }
      ) 
      }
      .sorted { lhs, rhs in
        guard let ld = ReportsListView.dayFormatter.date(from: lhs.date),
              let rd = ReportsListView.dayFormatter.date(from: rhs.date)
        else { return lhs.date > rhs.date }
        return ld > rd
      }
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      if reports.isEmpty {
        Text("No archived catches.")
          .foregroundColor(.secondary)
      } else {
        List {
          ForEach(groupedArchived, id: \.date) { section in
            Text(section.date)
              .font(.subheadline)
              .foregroundColor(.secondary)
              .listRowBackground(Color.black)

            ForEach(section.reports) { report in
              NavigationLink {
                CatchReportDetailView(report: report)
              } label: {
                CatchReportRow(report: report, isArchived: true)
              }
              .listRowBackground(Color.black)
            }
          }
        }
        .listStyle(.plain)
        .background(Color.black)
        .modifier(HideListBackgroundIfAvailable())
      }
    }
    .navigationTitle("Archived Catches")
    .environment(\.colorScheme, .dark)
  }
}
