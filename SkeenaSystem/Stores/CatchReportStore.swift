// Bend Fly Shop

import Combine
import Foundation

/// Persistent store for local `CatchReport` records.
///
/// Storage is scoped by `(memberId, communityId)` so that signing out, signing in
/// as a different user, or switching the active community produces a completely
/// isolated catch history. See `/Users/geoffsipperly/.claude/plans/kind-spinning-duckling.md`.
///
/// On-disk layout:
///
///     Documents/CatchReportsPicMemo/<memberId>/<communityId>/report_<uuid>.json
///
/// When either identity signal is missing (signed out, not yet fetched, etc.) the
/// store is in an *unbound* state: `reports` is empty and writes become logged
/// no-ops. The store automatically rebinds whenever `AuthService.currentMemberId`
/// or `CommunityService.activeCommunityId` changes via Combine subscription.
///
/// Explicitly `nonisolated`: the project sets `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor`, which would otherwise make this class `@MainActor`. That routes
/// its deinit through `swift_task_deinitOnExecutorMainActorBackDeploy`, which
/// hits a TaskLocal scope double-free in the iOS 26.2 simruntime. All mutations
/// of `@Published var reports` already dispatch onto the main queue explicitly,
/// so nonisolated is the semantically correct choice too. See
/// `SkeenaSystem/Managers/UploadObservations.swift` for the same pattern.
nonisolated final class CatchReportStore: ObservableObject, @unchecked Sendable {
  static let shared = CatchReportStore()

  // `@Published` is incompatible with the class-level `nonisolated` (which is
  // load-bearing for the iOS 26.2 deinit-crash mitigation above), so we drive
  // the publisher manually. SwiftUI consumers observe via `objectWillChange`;
  // non-SwiftUI consumers (e.g. `PendingUploadSummary`) subscribe to
  // `reportsPublisher`.
  private let _reports = CurrentValueSubject<[CatchReport], Never>([])
  private(set) var reports: [CatchReport] {
    get { _reports.value }
    set {
      objectWillChange.send()
      _reports.send(newValue)
    }
  }
  var reportsPublisher: AnyPublisher<[CatchReport], Never> { _reports.eraseToAnyPublisher() }

  /// Count of catch reports still waiting to be uploaded.
  var pendingCount: Int {
    reports.filter { $0.status == .savedLocally }.count
  }

  private let fm = FileManager.default
  private let rootDirectoryURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  /// Directory for the currently bound scope, or `nil` when unbound.
  /// All reads/writes go through this — never fall back to `rootDirectoryURL`
  /// directly for report I/O, or data will leak across users again.
  private var boundDirectoryURL: URL?
  private var boundMemberId: String?
  private var boundCommunityId: String?

  private var cancellables = Set<AnyCancellable>()

  /// UserDefaults flag set once the one-time legacy migration has run for this install.
  private static let migrationFlagKey = "CatchReportStore.migratedToScoped_v1"

  // MARK: - Initialisation

  /// Production initialiser — anchors under `Documents/CatchReportsPicMemo/`
  /// and auto-rebinds on `AuthService` / `CommunityService` identity changes.
  private convenience init() {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    // Historical on-disk directory name — kept as "CatchReportsPicMemo" for
    // backward compatibility with catches saved by earlier versions of the
    // app. Renaming this literal would orphan every existing user's local
    // records; leave it unless we ship a migration.
    let root = docs.appendingPathComponent("CatchReportsPicMemo", isDirectory: true)
    self.init(rootDirectory: root, autoRebind: true)
  }

  /// Designated initialiser.
  ///
  /// - Parameters:
  ///   - rootDirectory: The parent directory that contains `<memberId>/<communityId>/`
  ///     subfolders. Tests inject a temp dir here.
  ///   - autoRebind: When `true`, subscribes to `AuthService.currentMemberId` and
  ///     `CommunityService.activeCommunityId` and rebinds automatically. Tests pass
  ///     `false` and drive rebinding explicitly via `rebind(memberId:communityId:)`.
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
      // Combine `@Published` identity signals. First emission fires synchronously
      // with the current cached values, so a signed-in user's scope is bound
      // before any view reads `reports`.
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

  // MARK: - Debug

  /// Whether the store is currently bound to a valid (memberId, communityId) scope.
  var isBound: Bool { boundDirectoryURL != nil }

  /// Debug description of the current binding state.
  var bindingDebugDescription: String {
    "bound=\(isBound) member='\(boundMemberId ?? "nil")' community='\(boundCommunityId ?? "nil")' dir=\(boundDirectoryURL?.lastPathComponent ?? "nil")"
  }

  // MARK: - Public API

  /// Re-scan the currently bound scope from disk. No-op when unbound.
  func refresh() {
    loadAll()
  }

  func add(_ report: CatchReport) {
    guard boundDirectoryURL != nil else {
      AppLogging.log("[CatchReportStore] add() called while unbound — dropping report \(report.id)", level: .warn, category: .catch)
      return
    }
    var new = report
    new.status = .savedLocally
    save(report: new)
    upsertInMemory(new)
  }

  func update(_ report: CatchReport) {
    guard boundDirectoryURL != nil else {
      AppLogging.log("[CatchReportStore] update() called while unbound — dropping report \(report.id)", level: .warn, category: .catch)
      return
    }
    save(report: report)
    upsertInMemory(report)
  }

  func delete(_ report: CatchReport) {
    guard let url = jsonURL(for: report.id) else {
      AppLogging.log("[CatchReportStore] delete() called while unbound — ignoring \(report.id)", level: .warn, category: .catch)
      return
    }
    try? fm.removeItem(at: url)
    removeInMemory(report.id)
  }

  func markUploaded(_ reportIDs: [UUID]) {
    guard boundDirectoryURL != nil else {
      AppLogging.log("[CatchReportStore] markUploaded() called while unbound — ignoring \(reportIDs.count) ids", level: .warn, category: .catch)
      return
    }
    let now = Date()
    var current = reports

    for idx in current.indices {
      if reportIDs.contains(current[idx].id) {
        current[idx].status = .uploaded
        current[idx].uploadedAt = now
        save(report: current[idx])
      }
    }

    // Apply to in-memory array in one shot
    current.sort { $0.createdAt > $1.createdAt }
    setReportsOnMain(current)
  }

  // MARK: - Convenience creation for chat flow

  /// Create and persist a new catch report from the chat-based capture flow.
  /// This is the preferred entry point to ensure voice memos, photo, trip & analysis
  /// are all captured in one place.
  func createFromChat(
    memberId: String,
    species: String?,
    sex: String?,
    lengthInches: Int,
    lifecycleStage: String?,
    river: String?,
    classifiedWatersLicenseNumber: String?,
    lat: Double?,
    lon: Double?,
    photoFilename: String?,
    headPhotoFilename: String? = nil,
    voiceNoteId: UUID?,
    tripId: String?,
    tripName: String?,
    tripStartDate: Date?,
    tripEndDate: Date?,
    guideName: String?,
    community: String?,
    communityId: String?,
    lodge: String?,
    initialRiverName: String?,
    initialSpecies: String?,
    initialLifecycleStage: String?,
    initialSex: String?,
    initialLengthInches: Int?,
    mlFeatureVector: Data? = nil,
    lengthSource: String? = nil,
    modelVersion: String? = nil,
    mlDiagnostics: Data? = nil,
    girthInches: Double? = nil,
    weightLbs: Double? = nil,
    weightDivisor: Int? = nil,
    weightDivisorSource: String? = nil,
    girthRatio: Double? = nil,
    girthRatioSource: String? = nil,
    initialLengthForMeasurements: Double? = nil,
    initialGirthInches: Double? = nil,
    initialWeightLbs: Double? = nil,
    initialWeightDivisor: Int? = nil,
    initialWeightDivisorSource: String? = nil,
    initialGirthRatio: Double? = nil,
    initialGirthRatioSource: String? = nil,
    conservationOptIn: Bool? = nil,
    mlTrainingOptOut: Bool? = nil,
    floyId: String? = nil,
    pitId: String? = nil,
    scaleEnvelopeId: String? = nil,
    finEnvelopeId: String? = nil,
    appVersion: String?,
    deviceDescription: String?,
    platform: String?,
    catchDate: Date? = nil
  ) {
    guard let dir = boundDirectoryURL else {
      AppLogging.log("[CatchReportStore] createFromChat() called while unbound — dropping new report for member=\(memberId) community=\(communityId ?? "nil")", level: .error, category: .catch)
      return
    }
    AppLogging.log("[CatchReportStore] createFromChat() proceeding — dir=\(dir.lastPathComponent) member=\(memberId) community=\(communityId ?? "nil")", level: .debug, category: .catch)
    let report = CatchReport(
      id: UUID(),
      createdAt: Date(),
      catchDate: catchDate,
      uploadedAt: nil,
      status: .savedLocally,
      memberId: memberId,
      species: species,
      sex: sex,
      lengthInches: lengthInches,
      lifecycleStage: lifecycleStage,
      river: river,
      classifiedWatersLicenseNumber: classifiedWatersLicenseNumber,
      lat: lat,
      lon: lon,
      photoFilename: photoFilename,
      headPhotoFilename: headPhotoFilename,
      voiceNoteId: voiceNoteId,
      tripId: tripId,
      tripName: tripName,
      tripStartDate: tripStartDate,
      tripEndDate: tripEndDate,
      guideName: guideName,
      community: community,
      communityId: communityId,
      lodge: lodge,
      initialRiverName: initialRiverName,
      initialSpecies: initialSpecies,
      initialLifecycleStage: initialLifecycleStage,
      initialSex: initialSex,
      initialLengthInches: initialLengthInches,
      mlFeatureVector: mlFeatureVector,
      lengthSource: lengthSource,
      modelVersion: modelVersion,
      mlDiagnostics: mlDiagnostics,
      girthInches: girthInches,
      weightLbs: weightLbs,
      weightDivisor: weightDivisor,
      weightDivisorSource: weightDivisorSource,
      girthRatio: girthRatio,
      girthRatioSource: girthRatioSource,
      initialLengthForMeasurements: initialLengthForMeasurements,
      initialGirthInches: initialGirthInches,
      initialWeightLbs: initialWeightLbs,
      initialWeightDivisor: initialWeightDivisor,
      initialWeightDivisorSource: initialWeightDivisorSource,
      initialGirthRatio: initialGirthRatio,
      initialGirthRatioSource: initialGirthRatioSource,
      conservationOptIn: conservationOptIn,
      mlTrainingOptOut: mlTrainingOptOut,
      floyId: floyId,
      pitId: pitId,
      scaleEnvelopeId: scaleEnvelopeId,
      finEnvelopeId: finEnvelopeId,
      appVersion: appVersion,
      deviceDescription: deviceDescription,
      platform: platform
    )

    save(report: report)
    upsertInMemory(report)
    AppLogging.log("[CatchReportStore] createFromChat() complete — id=\(report.id) total reports now=\(reports.count)", level: .debug, category: .catch)
  }

  /// Optionally attach or change the voice note ID for an existing report.
  func updateVoiceNote(for reportId: UUID, voiceNoteId: UUID?) {
    guard boundDirectoryURL != nil else {
      AppLogging.log("[CatchReportStore] updateVoiceNote() called while unbound — ignoring \(reportId)", level: .warn, category: .catch)
      return
    }
    var current = reports

    for idx in current.indices {
      if current[idx].id == reportId {
        current[idx].voiceNoteId = voiceNoteId
        save(report: current[idx])
        upsertInMemory(current[idx])
        return
      }
    }
  }

  // MARK: - Scope binding (internal for tests)

  /// Rebind the store to the given `(memberId, communityId)` pair.
  ///
  /// - If either id is `nil` or empty, the store moves to the **unbound** state:
  ///   `reports` is emptied and subsequent writes become logged no-ops.
  /// - If the new binding matches the current one, this is a no-op.
  /// - Otherwise the in-memory list is cleared and the new scope is loaded from disk.
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
      AppLogging.log("[CatchReportStore] rebind -> scoped path member=\(m) community=\(c)", level: .info, category: .catch)
      loadAll()
    } else {
      boundDirectoryURL = nil
      AppLogging.log("[CatchReportStore] rebind -> unbound (member=\(normalizedMember ?? "nil") community=\(normalizedCommunity ?? "nil"))", level: .info, category: .catch)
      setReportsOnMain([])
    }
  }

  // MARK: - In-memory helpers (avoid full disk reload)

  /// Set `reports` on the main thread. Runs synchronously when already on
  /// main to avoid async ordering races (e.g. loadAll vs. upsertInMemory).
  private func setReportsOnMain(_ newValue: [CatchReport]) {
    if Thread.isMainThread {
      self.reports = newValue
    } else {
      DispatchQueue.main.async { self.reports = newValue }
    }
  }

  /// Insert or replace a report in the in-memory array, keeping newest-first sort.
  private func upsertInMemory(_ report: CatchReport) {
    var current = reports
    if let idx = current.firstIndex(where: { $0.id == report.id }) {
      current[idx] = report
    } else {
      current.append(report)
    }
    current.sort { $0.createdAt > $1.createdAt }
    setReportsOnMain(current)
  }

  /// Remove a report from the in-memory array by ID.
  private func removeInMemory(_ id: UUID) {
    let current = reports.filter { $0.id != id }
    setReportsOnMain(current)
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
    return dir.appendingPathComponent("report_\(id.uuidString).json")
  }

  private func save(report: CatchReport) {
    guard let url = jsonURL(for: report.id) else {
      AppLogging.log("[CatchReportStore] save() called while unbound — dropping \(report.id)", level: .warn, category: .catch)
      return
    }
    ensureDirectory(at: url.deletingLastPathComponent())
    do {
      let data = try encoder.encode(report)
      try data.write(to: url, options: [.atomic])
    } catch {
      AppLogging.log("[CatchReportStore] Failed to save report \(report.id): \(error.localizedDescription)", level: .error, category: .catch)
    }
  }

  private func loadAll() {
    guard let dir = boundDirectoryURL else {
      setReportsOnMain([])
      return
    }
    ensureDirectory(at: dir)
    guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
      setReportsOnMain([])
      return
    }

    var loaded: [CatchReport] = []

    for file in files where file.pathExtension.lowercased() == "json" {
      do {
        let data = try Data(contentsOf: file)
        let report = try decoder.decode(CatchReport.self, from: data)

        // No defensive memberId-equality check here. `report.memberId` is the
        // ANGLER who caught the fish — for guide-with-clients trips that's
        // legitimately different from the store's bound (guide) scope. The
        // `<memberId>/<communityId>/` directory layout itself partitions the
        // data per guide, so any file under this directory belongs to this
        // guide's local activity stream regardless of which angler is stamped.
        loaded.append(report)
      } catch {
        AppLogging.log("[CatchReportStore] Failed to decode \(file.lastPathComponent): \(error.localizedDescription)", level: .error, category: .catch)
      }
    }

    // Sort newest first
    loaded.sort { $0.createdAt > $1.createdAt }
    AppLogging.log("[CatchReportStore] loaded \(loaded.count) reports from scope member=\(self.boundMemberId ?? "nil") community=\(self.boundCommunityId ?? "nil")", level: .debug, category: .catch)
    for r in loaded {
      let uploadedAt = r.uploadedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
      AppLogging.log("[CatchReportStore]   • id=\(r.id.uuidString) status=\(r.status.rawValue) createdAt=\(ISO8601DateFormatter().string(from: r.createdAt)) uploadedAt=\(uploadedAt) river=\(r.river ?? "nil")", level: .debug, category: .catch)
    }
    setReportsOnMain(loaded)
  }

  // MARK: - Legacy migration

  /// One-time migration from the legacy flat layout
  /// (`CatchReportsPicMemo/report_<uuid>.json`) into the scoped layout
  /// (`CatchReportsPicMemo/<memberId>/<communityId>/report_<uuid>.json`).
  ///
  /// Behavior:
  /// - Reports with non-empty `memberId` AND `communityId` are moved into the
  ///   matching scoped subdirectory.
  /// - Reports with missing or empty `communityId` / `memberId` are **deleted**
  ///   (per product decision — legacy unscoped data is dropped rather than
  ///   leaked to the current user).
  /// - Files that fail to decode are quarantined to `_corrupt/` with a `.bad`
  ///   suffix and logged.
  ///
  /// Guarded by `migratedToScoped_v1` in UserDefaults so it runs exactly once.
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
      AppLogging.log("[CatchReportStore] migration: listing root failed: \(error.localizedDescription)", level: .error, category: .catch)
      return
    }

    var migrated = 0
    var dropped = 0
    var quarantined = 0

    for file in files {
      // Skip directories (per-scope subfolders from a previous run)
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { continue }
      guard file.pathExtension.lowercased() == "json" else { continue }
      guard file.lastPathComponent.hasPrefix("report_") else { continue }

      do {
        let data = try Data(contentsOf: file)
        let report = try decoder.decode(CatchReport.self, from: data)
        let member = report.memberId.trimmingCharacters(in: .whitespacesAndNewlines)
        let community = (report.communityId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !member.isEmpty && !community.isEmpty {
          let destDir = rootDirectoryURL
            .appendingPathComponent(member, isDirectory: true)
            .appendingPathComponent(community, isDirectory: true)
          ensureDirectory(at: destDir)
          let destURL = destDir.appendingPathComponent(file.lastPathComponent)
          // If something already exists at the destination, prefer the existing
          // file (rename conflict shouldn't happen for UUID-named files).
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
        // Decoding failed — quarantine for support recovery
        let quarantineDir = rootDirectoryURL.appendingPathComponent("_corrupt", isDirectory: true)
        ensureDirectory(at: quarantineDir)
        let destURL = quarantineDir.appendingPathComponent("\(file.lastPathComponent).bad")
        if fm.fileExists(atPath: destURL.path) {
          try? fm.removeItem(at: file)
        } else {
          try? fm.moveItem(at: file, to: destURL)
        }
        quarantined += 1
        AppLogging.log("[CatchReportStore] migration: quarantined \(file.lastPathComponent): \(error.localizedDescription)", level: .warn, category: .catch)
      }
    }

    if migrated + dropped + quarantined > 0 {
      AppLogging.log("[CatchReportStore] migration complete — migrated=\(migrated) dropped=\(dropped) quarantined=\(quarantined)", level: .info, category: .catch)
    }
  }

  // MARK: - Test hooks

  #if DEBUG
  /// Reset the migration flag so tests can exercise `migrateLegacyLayoutIfNeeded`
  /// repeatedly. Never call from app code.
  internal static func resetMigrationFlagForTesting() {
    UserDefaults.standard.removeObject(forKey: migrationFlagKey)
  }

  /// Expose the currently bound directory for assertion in tests.
  internal var currentBoundDirectoryURL: URL? { boundDirectoryURL }
  #endif
}
