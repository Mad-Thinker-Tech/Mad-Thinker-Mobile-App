// Bend Fly Shop

import Combine
import Foundation

/// Persistent store for local `Observation` records.
///
/// Storage is scoped by `(memberId, communityId)` so that signing out, signing in
/// as a different user, or switching the active community produces a completely
/// isolated observation history. Mirrors `CatchReportStore`.
///
/// On-disk layout:
///
///     Documents/Observations/<memberId>/<communityId>/observation_<uuid>.json
///
/// When either identity signal is missing (signed out, not yet fetched, etc.) the
/// store is in an *unbound* state: `observations` is empty and writes become logged
/// no-ops. The store automatically rebinds whenever `AuthService.currentMemberId`
/// or `CommunityService.activeCommunityId` changes via Combine subscription.
///
/// `nonisolated` so the upload coordinator (which runs off MainActor for the
/// iOS 26.2 deinit-crash mitigation) can call `markUploaded` synchronously.
/// All mutations route through `setObservationsOnMain`, which dispatches to
/// the main thread before touching `objectWillChange` / the subject.
nonisolated final class ObservationStore: ObservableObject, @unchecked Sendable {
  static let shared = ObservationStore()

  // See `CatchReportStore` for the rationale — `@Published` doesn't compose
  // with the class-level `nonisolated`. Drive the publisher manually instead.
  private let _observations = CurrentValueSubject<[Observation], Never>([])
  private(set) var observations: [Observation] {
    get { _observations.value }
    set {
      objectWillChange.send()
      _observations.send(newValue)
    }
  }
  var observationsPublisher: AnyPublisher<[Observation], Never> { _observations.eraseToAnyPublisher() }

  /// Count of observations still waiting to be uploaded.
  var pendingCount: Int {
    observations.filter { $0.status == .savedLocally }.count
  }

  private let fm = FileManager.default
  private let rootDirectoryURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  /// Directory for the currently bound scope, or `nil` when unbound.
  /// All reads/writes go through this — never fall back to `rootDirectoryURL`
  /// directly for observation I/O, or data will leak across users again.
  private var boundDirectoryURL: URL?
  private var boundMemberId: String?
  private var boundCommunityId: String?

  private var cancellables = Set<AnyCancellable>()

  /// UserDefaults flag set once the one-time legacy migration has run for this install.
  private static let migrationFlagKey = "ObservationStore.migratedToScoped_v1"

  // MARK: - Initialisation

  /// Production initialiser — anchors under `Documents/Observations/` and
  /// auto-rebinds on `AuthService` / `CommunityService` identity changes.
  private convenience init() {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let root = docs.appendingPathComponent("Observations", isDirectory: true)
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

    ensureDirectory(at: rootDirectoryURL)
    migrateLegacyLayoutIfNeeded()

    if autoRebind {
      // First emission fires synchronously with current cached values, so a
      // signed-in user's scope is bound before any view reads `observations`.
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

  // MARK: - Public API

  /// Re-scan the currently bound scope from disk. No-op when unbound.
  func refresh() {
    loadAll()
  }

  func add(_ observation: Observation) {
    guard boundDirectoryURL != nil else {
      AppLogging.log("[ObservationStore] add() called while unbound — dropping observation \(observation.id)", level: .warn, category: .observation)
      return
    }
    var new = observation
    new.status = .savedLocally
    save(observation: new)
    loadAll()
  }

  func update(_ observation: Observation) {
    guard boundDirectoryURL != nil else {
      AppLogging.log("[ObservationStore] update() called while unbound — dropping observation \(observation.id)", level: .warn, category: .observation)
      return
    }
    save(observation: observation)
    loadAll()
  }

  func delete(_ observation: Observation) {
    guard let url = jsonURL(for: observation.id) else {
      AppLogging.log("[ObservationStore] delete() called while unbound — ignoring \(observation.id)", level: .warn, category: .observation)
      return
    }
    try? fm.removeItem(at: url)
    loadAll()
  }

  /// Mark observations as uploaded by their server-facing `clientId`.
  func markUploaded(_ clientIds: [UUID]) {
    guard boundDirectoryURL != nil else {
      AppLogging.log("[ObservationStore] markUploaded() called while unbound — ignoring \(clientIds.count) ids", level: .warn, category: .observation)
      return
    }
    var changed = false
    var current = observations
    let now = Date()

    for idx in current.indices {
      if clientIds.contains(current[idx].clientId) {
        current[idx].status = .uploaded
        current[idx].uploadedAt = now
        save(observation: current[idx])
        changed = true
      }
    }

    if changed {
      loadAll()
    }
  }

  // MARK: - Scope binding (internal for tests)

  /// Rebind the store to the given `(memberId, communityId)` pair.
  ///
  /// - If either id is `nil` or empty, the store moves to the **unbound** state:
  ///   `observations` is emptied and subsequent writes become logged no-ops.
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
      AppLogging.log("[ObservationStore] rebind -> scoped path member=\(m) community=\(c)", level: .info, category: .observation)
      loadAll()
    } else {
      boundDirectoryURL = nil
      AppLogging.log("[ObservationStore] rebind -> unbound (member=\(normalizedMember ?? "nil") community=\(normalizedCommunity ?? "nil"))", level: .info, category: .observation)
      setObservationsOnMain([])
    }
  }

  // MARK: - Internals

  private func ensureDirectory(at url: URL) {
    if !fm.fileExists(atPath: url.path) {
      try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }
  }

  private func jsonURL(for id: UUID) -> URL? {
    guard let dir = boundDirectoryURL else { return nil }
    return dir.appendingPathComponent("observation_\(id.uuidString).json")
  }

  private func save(observation: Observation) {
    guard let url = jsonURL(for: observation.id) else {
      AppLogging.log("[ObservationStore] save() called while unbound — dropping \(observation.id)", level: .warn, category: .observation)
      return
    }
    ensureDirectory(at: url.deletingLastPathComponent())
    do {
      let data = try encoder.encode(observation)
      try data.write(to: url, options: [.atomic])
    } catch {
      AppLogging.log("[ObservationStore] Failed to save observation \(observation.id): \(error.localizedDescription)", level: .error, category: .observation)
    }
  }

  private func loadAll() {
    guard let dir = boundDirectoryURL else {
      setObservationsOnMain([])
      return
    }
    ensureDirectory(at: dir)
    guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
      setObservationsOnMain([])
      return
    }

    var loaded: [Observation] = []

    for file in files where file.pathExtension.lowercased() == "json" {
      do {
        let data = try Data(contentsOf: file)
        let observation = try decoder.decode(Observation.self, from: data)
        loaded.append(observation)
      } catch {
        AppLogging.log("[ObservationStore] Failed to decode \(file.lastPathComponent): \(error.localizedDescription)", level: .error, category: .observation)
      }
    }

    loaded.sort { $0.createdAt > $1.createdAt }

    setObservationsOnMain(loaded)
  }

  /// Set `observations` on the main thread. Runs synchronously when already
  /// on main to avoid async ordering races; mirrors `CatchReportStore`.
  private func setObservationsOnMain(_ newValue: [Observation]) {
    if Thread.isMainThread {
      self.observations = newValue
    } else {
      DispatchQueue.main.async { self.observations = newValue }
    }
  }

  // MARK: - Legacy migration

  /// One-time migration away from the legacy flat layout
  /// (`Observations/observation_<uuid>.json`).
  ///
  /// `Observation` carries no `memberId`/`communityId`, so legacy flat files
  /// cannot be attributed to any user. Per the `CatchReportStore` product
  /// decision, unattributable local data is **dropped** rather than leaked to
  /// the current user — so every regular file directly under the root is
  /// deleted. Per-scope subdirectories are left untouched.
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
      AppLogging.log("[ObservationStore] migration: listing root failed: \(error.localizedDescription)", level: .error, category: .observation)
      return
    }

    var dropped = 0
    for file in files {
      // Skip directories (per-scope subfolders from a previous run)
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { continue }
      try? fm.removeItem(at: file)
      dropped += 1
    }

    if dropped > 0 {
      AppLogging.log("[ObservationStore] migration complete — dropped \(dropped) legacy unscoped observation file(s)", level: .info, category: .observation)
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
