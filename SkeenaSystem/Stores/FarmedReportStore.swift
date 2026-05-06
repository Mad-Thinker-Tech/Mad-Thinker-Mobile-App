// Bend Fly Shop

import Combine
import Foundation

/// Persistent store for local `FarmedReport` records (no-catch events like
/// "active", "farmed", "promising", "passed").
///
/// Mirrors `CatchReportStore`'s `(memberId, communityId)` scoping so that
/// guides switching users or communities on the same device don't see each
/// other's pending submissions. See the per-scope on-disk layout below.
///
/// On-disk layout:
///
///     Documents/FarmedReports/<memberId>/<communityId>/farmed_<uuid>.json
///
/// The store rebinds automatically via Combine on `AuthService.currentMemberId`
/// / `CommunityService.activeCommunityId` changes. See the plan at
/// `/Users/geoffsipperly/.claude/plans/kind-spinning-duckling.md`.
///
/// Explicitly `nonisolated` for the same reason as `CatchReportStore` —
/// avoiding the iOS 26.2 simruntime `swift_task_deinitOnExecutorMainActorBackDeploy`
/// double-free when deinit hops to MainActor. See `UploadObservations.swift`.
nonisolated final class FarmedReportStore: ObservableObject, @unchecked Sendable {
  static let shared = FarmedReportStore()

  // See `CatchReportStore` for why we drive the publisher manually instead
  // of using `@Published` (property wrappers don't combine with the
  // class-level `nonisolated` in Swift 6).
  private let _reports = CurrentValueSubject<[FarmedReport], Never>([])
  private(set) var reports: [FarmedReport] {
    get { _reports.value }
    set {
      objectWillChange.send()
      _reports.send(newValue)
    }
  }
  var reportsPublisher: AnyPublisher<[FarmedReport], Never> { _reports.eraseToAnyPublisher() }

  /// Count of farmed reports still waiting to be uploaded.
  var pendingCount: Int {
    reports.filter { $0.status == .savedLocally }.count
  }

  private let fm = FileManager.default
  private let rootDirectoryURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  private var boundDirectoryURL: URL?
  private var boundMemberId: String?
  private var boundCommunityId: String?

  private var cancellables = Set<AnyCancellable>()

  private static let migrationFlagKey = "FarmedReportStore.migratedToScoped_v1"

  // MARK: - Initialisation

  private convenience init() {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let root = docs.appendingPathComponent("FarmedReports", isDirectory: true)
    self.init(rootDirectory: root, autoRebind: true)
  }

  internal init(rootDirectory: URL, autoRebind: Bool) {
    self.rootDirectoryURL = rootDirectory

    self.encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601

    self.decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    ensureRootDirectory()
    migrateLegacyLayoutIfNeeded()

    if autoRebind {
      Publishers.CombineLatest(
        AuthService.shared.currentMemberIdPublisher,
        CommunityService.shared.activeCommunityIdPublisher
      )
      .receive(on: DispatchQueue.main)
      .sink { [weak self] member, community in
        self?.rebind(memberId: member, communityId: community)
      }
      .store(in: &cancellables)
    }
  }

  // MARK: - Public API

  func refresh() {
    loadAll()
  }

  func add(_ report: FarmedReport) {
    guard boundDirectoryURL != nil else {
      AppLogging.log("[FarmedReportStore] add() called while unbound — dropping report \(report.id)", level: .warn, category: .catch)
      return
    }
    var new = report
    new.status = .savedLocally
    save(report: new)
    loadAll()
  }

  func update(_ report: FarmedReport) {
    guard boundDirectoryURL != nil else {
      AppLogging.log("[FarmedReportStore] update() called while unbound — dropping report \(report.id)", level: .warn, category: .catch)
      return
    }
    save(report: report)
    loadAll()
  }

  func delete(_ report: FarmedReport) {
    guard let url = jsonURL(for: report.id) else {
      AppLogging.log("[FarmedReportStore] delete() called while unbound — ignoring \(report.id)", level: .warn, category: .catch)
      return
    }
    try? fm.removeItem(at: url)
    loadAll()
  }

  /// Deletes uploaded reports whose `createdAt` is older than the given number of days.
  func purgeOldUploaded(olderThanDays days: Int = 14) {
    guard boundDirectoryURL != nil else { return }
    let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    var purged = 0

    for report in reports where report.status == .uploaded && report.createdAt < cutoff {
      if let url = jsonURL(for: report.id) {
        try? fm.removeItem(at: url)
        purged += 1
      }
    }

    if purged > 0 {
      AppLogging.log("[FarmedReportStore] Purged \(purged) uploaded report(s) older than \(days) days", level: .info, category: .catch)
      loadAll()
    }
  }

  func markUploaded(_ reportIDs: [UUID]) {
    guard boundDirectoryURL != nil else {
      AppLogging.log("[FarmedReportStore] markUploaded() called while unbound — ignoring \(reportIDs.count) ids", level: .warn, category: .catch)
      return
    }
    var changed = false
    var current = reports

    for idx in current.indices {
      if reportIDs.contains(current[idx].id) {
        current[idx].status = .uploaded
        save(report: current[idx])
        changed = true
      }
    }

    if changed {
      loadAll()
    }
  }

  // MARK: - Scope binding

  internal func rebind(memberId: String?, communityId: String?) {
    let cleanMember = memberId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanCommunity = communityId?.trimmingCharacters(in: .whitespacesAndNewlines)

    let normalizedMember = (cleanMember?.isEmpty == false) ? cleanMember : nil
    let normalizedCommunity = (cleanCommunity?.isEmpty == false) ? cleanCommunity : nil

    if normalizedMember == boundMemberId && normalizedCommunity == boundCommunityId {
      return
    }

    boundMemberId = normalizedMember
    boundCommunityId = normalizedCommunity

    if let m = normalizedMember, let c = normalizedCommunity {
      let dir = rootDirectoryURL
        .appendingPathComponent(m, isDirectory: true)
        .appendingPathComponent(c, isDirectory: true)
      boundDirectoryURL = dir
      ensureDirectory(at: dir)
      AppLogging.log("[FarmedReportStore] rebind -> scoped path member=\(m) community=\(c)", level: .info, category: .catch)
      loadAll()
    } else {
      boundDirectoryURL = nil
      AppLogging.log("[FarmedReportStore] rebind -> unbound (member=\(normalizedMember ?? "nil") community=\(normalizedCommunity ?? "nil"))", level: .info, category: .catch)
      DispatchQueue.main.async { self.reports = [] }
    }
  }

  // MARK: - Filesystem internals

  private func ensureRootDirectory() {
    ensureDirectory(at: rootDirectoryURL)
  }

  private func ensureDirectory(at url: URL) {
    if !fm.fileExists(atPath: url.path) {
      try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }
  }

  private func jsonURL(for id: UUID) -> URL? {
    guard let dir = boundDirectoryURL else { return nil }
    return dir.appendingPathComponent("farmed_\(id.uuidString).json")
  }

  private func save(report: FarmedReport) {
    guard let url = jsonURL(for: report.id) else {
      AppLogging.log("[FarmedReportStore] save() called while unbound — dropping \(report.id)", level: .warn, category: .catch)
      return
    }
    ensureDirectory(at: url.deletingLastPathComponent())
    do {
      let data = try encoder.encode(report)
      try data.write(to: url, options: [.atomic])
    } catch {
      AppLogging.log("[FarmedReportStore] Failed to save report \(report.id): \(error.localizedDescription)", level: .error, category: .catch)
    }
  }

  private func loadAll() {
    guard let dir = boundDirectoryURL else {
      DispatchQueue.main.async { self.reports = [] }
      return
    }
    ensureDirectory(at: dir)
    guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
      DispatchQueue.main.async { self.reports = [] }
      return
    }

    var loaded: [FarmedReport] = []
    var skippedCrossMember = 0

    for file in files where file.pathExtension.lowercased() == "json" {
      do {
        let data = try Data(contentsOf: file)
        let report = try decoder.decode(FarmedReport.self, from: data)

        // Defense in depth: refuse to surface reports whose stamped memberId
        // doesn't match the bound scope. See CatchReportStore.loadAll for
        // the matching rationale.
        let stamped = (report.memberId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let bound = boundMemberId, !stamped.isEmpty, stamped != bound {
          skippedCrossMember += 1
          AppLogging.log("[FarmedReportStore] SKIPPING cross-member report \(file.lastPathComponent) — stamped='\(stamped)' bound='\(bound)'", level: .warn, category: .catch)
          continue
        }

        loaded.append(report)
      } catch {
        AppLogging.log("[FarmedReportStore] Failed to decode \(file.lastPathComponent): \(error.localizedDescription)", level: .error, category: .catch)
      }
    }

    if skippedCrossMember > 0 {
      AppLogging.log("[FarmedReportStore] loadAll: skipped \(skippedCrossMember) cross-member orphan(s) in scope member=\(self.boundMemberId ?? "nil")", level: .warn, category: .catch)
    }

    loaded.sort { $0.createdAt > $1.createdAt }

    DispatchQueue.main.async {
      self.reports = loaded
    }
  }

  // MARK: - Legacy migration

  /// One-time migration from the flat `FarmedReports/farmed_<uuid>.json` layout
  /// to the scoped `<memberId>/<communityId>/` layout. Records missing either
  /// id are deleted; decode failures are quarantined to `_corrupt/*.bad`.
  internal func migrateLegacyLayoutIfNeeded() {
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: Self.migrationFlagKey) {
      return
    }
    defer { defaults.set(true, forKey: Self.migrationFlagKey) }

    guard fm.fileExists(atPath: rootDirectoryURL.path) else {
      return
    }

    let files: [URL]
    do {
      files = try fm.contentsOfDirectory(
        at: rootDirectoryURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      AppLogging.log("[FarmedReportStore] migration: listing root failed: \(error.localizedDescription)", level: .error, category: .catch)
      return
    }

    var migrated = 0
    var dropped = 0
    var quarantined = 0

    for file in files {
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { continue }
      guard file.pathExtension.lowercased() == "json" else { continue }
      guard file.lastPathComponent.hasPrefix("farmed_") else { continue }

      do {
        let data = try Data(contentsOf: file)
        let report = try decoder.decode(FarmedReport.self, from: data)
        let member = (report.memberId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let community = (report.communityId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !member.isEmpty && !community.isEmpty {
          let destDir = rootDirectoryURL
            .appendingPathComponent(member, isDirectory: true)
            .appendingPathComponent(community, isDirectory: true)
          ensureDirectory(at: destDir)
          let destURL = destDir.appendingPathComponent(file.lastPathComponent)
          if fm.fileExists(atPath: destURL.path) {
            try? fm.removeItem(at: file)
          } else {
            try fm.moveItem(at: file, to: destURL)
          }
          migrated += 1
        } else {
          try? fm.removeItem(at: file)
          dropped += 1
        }
      } catch {
        let quarantineDir = rootDirectoryURL.appendingPathComponent("_corrupt", isDirectory: true)
        ensureDirectory(at: quarantineDir)
        let destURL = quarantineDir.appendingPathComponent("\(file.lastPathComponent).bad")
        if fm.fileExists(atPath: destURL.path) {
          try? fm.removeItem(at: file)
        } else {
          try? fm.moveItem(at: file, to: destURL)
        }
        quarantined += 1
        AppLogging.log("[FarmedReportStore] migration: quarantined \(file.lastPathComponent): \(error.localizedDescription)", level: .warn, category: .catch)
      }
    }

    if migrated + dropped + quarantined > 0 {
      AppLogging.log("[FarmedReportStore] migration complete — migrated=\(migrated) dropped=\(dropped) quarantined=\(quarantined)", level: .info, category: .catch)
    }
  }

  // MARK: - Test hooks

  #if DEBUG
  internal static func resetMigrationFlagForTesting() {
    UserDefaults.standard.removeObject(forKey: migrationFlagKey)
  }

  internal var currentBoundDirectoryURL: URL? { boundDirectoryURL }
  #endif
}
