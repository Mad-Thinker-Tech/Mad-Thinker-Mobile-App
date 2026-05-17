import XCTest
@testable import SkeenaSystem

/// Verifies that `VoiceNoteStore` is strictly scoped by
/// `(memberId, communityId)` so signing out / switching identity does NOT
/// leak voice-note history across users. Also exercises the one-time
/// migration that drops the legacy flat layout.
///
/// These tests build a non-singleton `VoiceNoteStore` anchored in a temp
/// directory with `autoRebind: false`.
@MainActor
final class VoiceNoteStoreIsolationTests: XCTestCase {

  // MARK: - Fixtures

  private var tempRoot: URL!

  override func setUp() {
    super.setUp()
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("VoiceNoteStoreIsolationTests-\(UUID().uuidString)", isDirectory: true)
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

  private func makeStore() -> VoiceNoteStore {
    VoiceNoteStore.resetMigrationFlagForTesting()
    return VoiceNoteStore(rootDirectory: tempRoot, autoRebind: false)
  }

  private func waitForStoreUpdate(_ description: String = "store update") {
    let expectation = expectation(description: description)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2.0)
  }

  private func makeNote(id: UUID = UUID()) -> LocalVoiceNote {
    LocalVoiceNote(
      id: id,
      createdAt: Date(),
      durationSec: 3.0,
      language: "en-US",
      onDevice: true,
      sampleRate: 16000,
      format: "m4a",
      transcript: "test memo",
      lat: nil,
      lon: nil,
      horizontalAccuracy: nil,
      status: .savedPendingUpload
    )
  }

  /// Drop a note JSON into the legacy flat layout for migration tests.
  private func seedLegacyNote(_ note: LocalVoiceNote) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(note)
    try data.write(to: tempRoot.appendingPathComponent(note.jsonFilename), options: [.atomic])
    // also a fake audio sibling
    try Data("fake-audio".utf8).write(to: tempRoot.appendingPathComponent(note.audioFilename), options: [.atomic])
  }

  // MARK: - Cross-user / cross-community isolation

  func testRebind_crossUserIsolation() {
    let store = makeStore()

    store.rebind(memberId: "memberA", communityId: "communityX")
    let noteA = makeNote()
    XCTAssertTrue(store.save(noteA))
    waitForStoreUpdate()
    XCTAssertEqual(store.notes.map(\.id), [noteA.id], "Scope (A, X) should see its own note")

    store.rebind(memberId: "memberB", communityId: "communityY")
    waitForStoreUpdate()
    XCTAssertTrue(store.notes.isEmpty, "Scope (B, Y) must not see (A, X)'s notes")

    store.rebind(memberId: "memberA", communityId: "communityX")
    waitForStoreUpdate()
    XCTAssertEqual(store.notes.map(\.id), [noteA.id], "Rebinding to the original scope should surface the original note")
  }

  func testRebind_crossCommunityIsolation_sameMember() {
    let store = makeStore()

    store.rebind(memberId: "memberA", communityId: "communityX")
    let noteX = makeNote()
    _ = store.save(noteX)
    waitForStoreUpdate()
    XCTAssertEqual(store.notes.count, 1)

    store.rebind(memberId: "memberA", communityId: "communityY")
    waitForStoreUpdate()
    XCTAssertTrue(store.notes.isEmpty, "Same member in a different community should see a disjoint list")
  }

  // MARK: - Unbound state

  func testUnboundState_writesAreDroppedAndNotesEmpty() {
    let store = makeStore()

    store.rebind(memberId: nil, communityId: nil)
    waitForStoreUpdate()
    XCTAssertTrue(store.notes.isEmpty)

    XCTAssertFalse(store.save(makeNote()), "save() while unbound should fail and be a no-op")
    waitForStoreUpdate()
    XCTAssertTrue(store.notes.isEmpty)

    let contents = (try? FileManager.default.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)) ?? []
    let jsonFiles = contents.filter { $0.pathExtension == "json" }
    XCTAssertTrue(jsonFiles.isEmpty, "Unbound save() must not touch disk")
  }

  func testUnboundState_partialIdentityTreatedAsUnbound() {
    let store = makeStore()

    store.rebind(memberId: "memberA", communityId: nil)
    XCTAssertNil(store.currentBoundDirectoryURL)

    store.rebind(memberId: nil, communityId: "communityX")
    XCTAssertNil(store.currentBoundDirectoryURL)
  }

  // MARK: - addNew moves the audio file into the bound scope

  func testAddNew_storesAudioInBoundScope() throws {
    let store = makeStore()
    store.rebind(memberId: "memberA", communityId: "communityX")

    let tempAudio = FileManager.default.temporaryDirectory
      .appendingPathComponent("note_tmp_\(UUID().uuidString).m4a")
    try Data("fake-audio".utf8).write(to: tempAudio, options: [.atomic])

    let note = store.addNew(
      audioTempURL: tempAudio,
      transcript: "memo",
      language: "en-US",
      onDevice: true,
      sampleRate: 16000,
      location: nil,
      duration: 2.0
    )
    waitForStoreUpdate()

    XCTAssertEqual(store.notes.map(\.id), [note.id])
    let scopedAudio = tempRoot
      .appendingPathComponent("memberA", isDirectory: true)
      .appendingPathComponent("communityX", isDirectory: true)
      .appendingPathComponent(note.audioFilename)
    XCTAssertTrue(FileManager.default.fileExists(atPath: scopedAudio.path), "Audio file should land in the scoped directory")
  }

  // MARK: - Migration

  func testMigration_legacyFlatFilesDropped() throws {
    let legacy = makeNote()
    try seedLegacyNote(legacy)

    let flatJSON = tempRoot.appendingPathComponent(legacy.jsonFilename)
    let flatAudio = tempRoot.appendingPathComponent(legacy.audioFilename)
    XCTAssertTrue(FileManager.default.fileExists(atPath: flatJSON.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: flatAudio.path))

    let store = makeStore()

    XCTAssertFalse(FileManager.default.fileExists(atPath: flatJSON.path), "Legacy flat JSON should be dropped on migration")
    XCTAssertFalse(FileManager.default.fileExists(atPath: flatAudio.path), "Legacy flat audio should be dropped on migration")

    store.rebind(memberId: "memberA", communityId: "communityX")
    waitForStoreUpdate()
    XCTAssertTrue(store.notes.isEmpty, "Dropped legacy notes must not leak to any scope")
  }

  func testMigration_idempotent_flagPreventsRescan() throws {
    _ = makeStore()

    let legacy = makeNote()
    try seedLegacyNote(legacy)
    let flatJSON = tempRoot.appendingPathComponent(legacy.jsonFilename)

    _ = VoiceNoteStore(rootDirectory: tempRoot, autoRebind: false)

    XCTAssertTrue(FileManager.default.fileExists(atPath: flatJSON.path), "Second migration pass should be skipped by the UserDefaults flag")
  }
}
