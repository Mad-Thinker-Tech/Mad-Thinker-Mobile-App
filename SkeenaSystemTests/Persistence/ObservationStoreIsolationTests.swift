import XCTest
@testable import SkeenaSystem

/// Verifies that `ObservationStore` is strictly scoped by
/// `(memberId, communityId)` so that signing out, signing in as a different
/// user (including a deleted-and-recreated account, which gets a new
/// `memberId`), or switching communities does NOT leak observation history
/// across identities. Also exercises the one-time migration that drops the
/// legacy flat layout.
///
/// These tests build a non-singleton `ObservationStore` anchored in a temp
/// directory with `autoRebind: false`, so they don't touch the real Documents
/// folder and don't depend on `AuthService`/`CommunityService` state.
@MainActor
final class ObservationStoreIsolationTests: XCTestCase {

  // MARK: - Fixtures

  private var tempRoot: URL!

  override func setUp() {
    super.setUp()
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ObservationStoreIsolationTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDown() {
    if let tempRoot {
      try? FileManager.default.removeItem(at: tempRoot)
    }
    tempRoot = nil
    super.tearDown()
  }

  // MARK: - Helpers

  private func makeStore() -> ObservationStore {
    ObservationStore.resetMigrationFlagForTesting()
    return ObservationStore(rootDirectory: tempRoot, autoRebind: false)
  }

  private func waitForStoreUpdate(_ description: String = "store update") {
    let expectation = expectation(description: description)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2.0)
  }

  private func makeObservation(
    id: UUID = UUID(),
    clientId: UUID = UUID(),
    transcript: String = "spotted a steelhead"
  ) -> Observation {
    Observation(
      id: id,
      clientId: clientId,
      createdAt: Date(),
      uploadedAt: nil,
      status: .savedLocally,
      voiceNoteId: nil,
      transcript: transcript,
      voiceLanguage: nil,
      voiceOnDevice: nil,
      voiceSampleRate: nil,
      voiceFormat: nil,
      lat: nil,
      lon: nil,
      horizontalAccuracy: nil
    )
  }

  /// Drop an observation JSON into the legacy flat layout for migration tests.
  private func seedLegacyObservation(_ observation: Observation) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(observation)
    let url = tempRoot.appendingPathComponent("observation_\(observation.id.uuidString).json")
    try data.write(to: url, options: [.atomic])
  }

  // MARK: - Cross-user / cross-community isolation

  func testRebind_crossUserIsolation() {
    let store = makeStore()

    store.rebind(memberId: "memberA", communityId: "communityX")
    let obsA = makeObservation()
    store.add(obsA)
    waitForStoreUpdate()
    XCTAssertEqual(store.observations.count, 1, "Scope (A, X) should see its own observation")
    XCTAssertEqual(store.observations.first?.id, obsA.id)

    // Rebind to a different user (e.g. a recreated account = a new memberId)
    store.rebind(memberId: "memberB", communityId: "communityY")
    waitForStoreUpdate()
    XCTAssertTrue(store.observations.isEmpty, "Scope (B, Y) must not see (A, X)'s observations")

    store.rebind(memberId: "memberA", communityId: "communityX")
    waitForStoreUpdate()
    XCTAssertEqual(store.observations.count, 1)
    XCTAssertEqual(store.observations.first?.id, obsA.id, "Rebinding to the original scope should surface the original observation")
  }

  func testRebind_crossCommunityIsolation_sameMember() {
    let store = makeStore()

    store.rebind(memberId: "memberA", communityId: "communityX")
    let obsX = makeObservation()
    store.add(obsX)
    waitForStoreUpdate()
    XCTAssertEqual(store.observations.count, 1)

    store.rebind(memberId: "memberA", communityId: "communityY")
    waitForStoreUpdate()
    XCTAssertTrue(store.observations.isEmpty, "Same member in a different community should see a disjoint list")

    let obsY = makeObservation()
    store.add(obsY)
    waitForStoreUpdate()
    XCTAssertEqual(store.observations.map(\.id), [obsY.id])

    store.rebind(memberId: "memberA", communityId: "communityX")
    waitForStoreUpdate()
    XCTAssertEqual(store.observations.map(\.id), [obsX.id])
  }

  // MARK: - Unbound state

  func testUnboundState_writesAreDroppedAndObservationsEmpty() {
    let store = makeStore()

    store.rebind(memberId: nil, communityId: nil)
    waitForStoreUpdate()
    XCTAssertTrue(store.observations.isEmpty)

    store.add(makeObservation())
    waitForStoreUpdate()
    XCTAssertTrue(store.observations.isEmpty, "add() while unbound should be a no-op")

    let contents = (try? FileManager.default.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)) ?? []
    let jsonFiles = contents.filter { $0.pathExtension == "json" }
    XCTAssertTrue(jsonFiles.isEmpty, "Unbound add() must not touch disk")
  }

  func testUnboundState_partialIdentityTreatedAsUnbound() {
    let store = makeStore()

    store.rebind(memberId: "memberA", communityId: nil)
    XCTAssertNil(store.currentBoundDirectoryURL)

    store.rebind(memberId: nil, communityId: "communityX")
    XCTAssertNil(store.currentBoundDirectoryURL)

    store.rebind(memberId: "", communityId: "communityX")
    XCTAssertNil(store.currentBoundDirectoryURL)
  }

  // MARK: - Upload semantics

  func testMarkUploaded_noOpWhenUnbound() {
    let store = makeStore()

    store.rebind(memberId: "memberA", communityId: "communityX")
    let obs = makeObservation()
    store.add(obs)
    waitForStoreUpdate()
    XCTAssertEqual(store.observations.first?.status, .savedLocally)

    store.rebind(memberId: nil, communityId: nil)
    waitForStoreUpdate()
    store.markUploaded([obs.clientId])
    waitForStoreUpdate()

    store.rebind(memberId: "memberA", communityId: "communityX")
    waitForStoreUpdate()
    XCTAssertEqual(store.observations.count, 1)
    XCTAssertEqual(store.observations.first?.status, .savedLocally, "markUploaded() while unbound must be a no-op")
  }

  func testMarkUploaded_byClientId() {
    let store = makeStore()
    store.rebind(memberId: "memberA", communityId: "communityX")
    let obs = makeObservation()
    store.add(obs)
    waitForStoreUpdate()

    store.markUploaded([obs.clientId])
    waitForStoreUpdate()
    XCTAssertEqual(store.observations.first?.status, .uploaded)
    XCTAssertNotNil(store.observations.first?.uploadedAt)
  }

  // MARK: - Migration

  func testMigration_legacyFlatFilesDropped() throws {
    let legacy = makeObservation()
    try seedLegacyObservation(legacy)

    let flatURL = tempRoot.appendingPathComponent("observation_\(legacy.id.uuidString).json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: flatURL.path))

    // Migration runs inside init.
    let store = makeStore()

    XCTAssertFalse(FileManager.default.fileExists(atPath: flatURL.path), "Legacy flat file should be dropped on migration")

    // It must not surface for any user — legacy data is unattributable.
    store.rebind(memberId: "memberA", communityId: "communityX")
    waitForStoreUpdate()
    XCTAssertTrue(store.observations.isEmpty, "Dropped legacy observations must not leak to any scope")
  }

  func testMigration_idempotent_flagPreventsRescan() throws {
    _ = makeStore()

    // Drop another legacy file AFTER the flag is set — it must NOT be removed
    // on the next store creation because the flag short-circuits the scan.
    let legacy = makeObservation()
    try seedLegacyObservation(legacy)
    let flatURL = tempRoot.appendingPathComponent("observation_\(legacy.id.uuidString).json")

    _ = ObservationStore(rootDirectory: tempRoot, autoRebind: false)

    XCTAssertTrue(FileManager.default.fileExists(atPath: flatURL.path), "Second migration pass should be skipped by the UserDefaults flag")
  }
}
