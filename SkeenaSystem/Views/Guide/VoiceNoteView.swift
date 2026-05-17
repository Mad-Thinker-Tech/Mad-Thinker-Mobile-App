// Bend Fly Shop

import AVFoundation
import Combine
import CoreLocation
import Speech
import SwiftUI

// =====================================================
// MARK: - Debug (OFF by default)

// =====================================================
nonisolated private let DEBUG_NOTES_LOGGING = false
@inline(__always) private nonisolated func VLog(_ msg: @autoclosure () -> String) {
  if DEBUG_NOTES_LOGGING { print("🧭 VoiceNote | \(msg())") }
}

// =====================================================
// MARK: - Model

// =====================================================
enum VoiceNoteStatus: String, Codable { case savedPendingUpload, uploaded }

nonisolated struct LocalVoiceNote: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  var createdAt: Date
  var durationSec: Double?
  var language: String
  var onDevice: Bool
  var sampleRate: Double
  var format: String // "m4a" or "caf"
  var transcript: String
  var lat: Double?
  var lon: Double?
  var horizontalAccuracy: Double?
  var status: VoiceNoteStatus

  var audioFilename: String { "note_\(id.uuidString).m4a" }
  var jsonFilename: String { "note_\(id.uuidString).json" }
}

// =====================================================
// MARK: - Storage

// =====================================================
/// Persistent store for local `LocalVoiceNote` records.
///
/// Storage is scoped by `(memberId, communityId)` so that signing out, signing
/// in as a different user, or switching the active community produces a
/// completely isolated voice-note history. Mirrors `CatchReportStore`.
///
/// On-disk layout:
///
///     Documents/VoiceNotes/<memberId>/<communityId>/note_<uuid>.{json,m4a}
///
/// When either identity signal is missing the store is *unbound*: `notes` is
/// empty and writes become logged no-ops. The store auto-rebinds whenever
/// `AuthService.currentMemberId` or `CommunityService.activeCommunityId`
/// changes via Combine subscription.
///
/// `nonisolated` so the upload pipeline can read voice-note metadata
/// synchronously. All mutations write through `setNotesOnMain`. See
/// `CatchReportStore` for the full pattern rationale.
nonisolated final class VoiceNoteStore: ObservableObject, @unchecked Sendable {
  static let shared = VoiceNoteStore()

  // See `CatchReportStore` for why we drive the publisher manually instead
  // of using `@Published` (property wrappers don't combine with `nonisolated`).
  private let _notes = CurrentValueSubject<[LocalVoiceNote], Never>([])
  private(set) var notes: [LocalVoiceNote] {
    get { _notes.value }
    set {
      objectWillChange.send()
      _notes.send(newValue)
    }
  }
  var notesPublisher: AnyPublisher<[LocalVoiceNote], Never> { _notes.eraseToAnyPublisher() }

  // FileManager isn't formally Sendable but `.default` is safe to share.
  nonisolated(unsafe) private let fm = FileManager.default
  private let rootDirectoryURL: URL

  /// Directory for the currently bound scope, or `nil` when unbound.
  /// All reads/writes go through this — never fall back to `rootDirectoryURL`
  /// directly for note I/O, or data will leak across users again.
  private var boundDirectoryURL: URL?
  private var boundMemberId: String?
  private var boundCommunityId: String?

  private var cancellables = Set<AnyCancellable>()

  /// UserDefaults flag set once the one-time legacy migration has run for this install.
  private static let migrationFlagKey = "VoiceNoteStore.migratedToScoped_v1"

  /// Production initialiser — anchors under `Documents/VoiceNotes/` and
  /// auto-rebinds on `AuthService` / `CommunityService` identity changes.
  private convenience init() {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let root = docs.appendingPathComponent("VoiceNotes", isDirectory: true)
    self.init(rootDirectory: root, autoRebind: true)
  }

  /// Designated initialiser.
  ///
  /// - Parameters:
  ///   - rootDirectory: Parent directory containing `<memberId>/<communityId>/`
  ///     subfolders. Tests inject a temp dir here.
  ///   - autoRebind: When `true`, subscribes to identity changes and rebinds
  ///     automatically. Tests pass `false` and call `rebind(...)` directly.
  internal init(rootDirectory: URL, autoRebind: Bool) {
    self.rootDirectoryURL = rootDirectory
    ensureDir(at: rootDirectoryURL)
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

  /// Whether the store is currently bound to a valid (memberId, communityId) scope.
  var isBound: Bool { boundDirectoryURL != nil }

  // MARK: - Scope binding (internal for tests)

  /// Rebind to the given `(memberId, communityId)` pair. Either id `nil`/empty
  /// moves the store to the unbound state (empty `notes`, writes become no-ops).
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
      ensureDir(at: dir)
      AppLogging.log("[VoiceNoteStore] rebind -> scoped path member=\(m) community=\(c)", level: .info, category: .audio)
      loadAll()
    } else {
      boundDirectoryURL = nil
      AppLogging.log("[VoiceNoteStore] rebind -> unbound (member=\(normalizedMember ?? "nil") community=\(normalizedCommunity ?? "nil"))", level: .info, category: .audio)
      setNotesOnMain([])
    }
  }

  private func ensureDir(at url: URL) {
    if !fm.fileExists(atPath: url.path) {
      try? fm.createDirectory(at: url, withIntermediateDirectories: true)
      VLog("Created notes directory at \(url.path)")
    }
  }

  func loadAll() {
    guard let dir = boundDirectoryURL else {
      setNotesOnMain([])
      return
    }
    ensureDir(at: dir)
    do {
      let urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
      let jsons = urls.filter { $0.lastPathComponent.hasSuffix(".json") }
      var loaded: [LocalVoiceNote] = []
      let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
      for url in jsons {
        do {
          let data = try Data(contentsOf: url)
          let note = try dec.decode(LocalVoiceNote.self, from: data)
          loaded.append(note)
        } catch {
          VLog("ERROR decoding \(url.lastPathComponent): \(error.localizedDescription)")
          // quarantine corrupt json so it doesn't keep breaking loads
          let bad = url.deletingPathExtension().appendingPathExtension("badjson")
          try? fm.removeItem(at: bad)
          try? fm.moveItem(at: url, to: bad)
        }
      }
      setNotesOnMain(loaded.sorted(by: { $0.createdAt > $1.createdAt }))
      VLog("Loaded \(notes.count) notes from disk")
    } catch {
      VLog("ERROR listing notes dir: \(error.localizedDescription)")
    }
  }

  /// Set `notes` on the main thread. Mirrors `CatchReportStore.setReportsOnMain`
  /// — runs synchronously when already on main to avoid async ordering races.
  private func setNotesOnMain(_ newValue: [LocalVoiceNote]) {
    if Thread.isMainThread {
      self.notes = newValue
    } else {
      DispatchQueue.main.async { self.notes = newValue }
    }
  }

  @discardableResult
  func save(_ note: LocalVoiceNote) -> Bool {
    guard let dir = boundDirectoryURL else {
      AppLogging.log("[VoiceNoteStore] save() called while unbound — dropping note \(note.id)", level: .warn, category: .audio)
      return false
    }
    ensureDir(at: dir)
    let url = dir.appendingPathComponent(note.jsonFilename)
    do {
      let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]; enc
        .dateEncodingStrategy = .iso8601
      let data = try enc.encode(note)
      try data.write(to: url, options: [.atomic])
      loadAll()
      return true
    } catch {
      VLog("ERROR writing \(note.jsonFilename): \(error.localizedDescription)")
      return false
    }
  }

  /// Resolve a note's audio/JSON URL within the bound scope. Falls back to the
  /// root only when unbound — reads then simply miss, which is harmless.
  func audioURL(for note: LocalVoiceNote) -> URL {
    (boundDirectoryURL ?? rootDirectoryURL).appendingPathComponent(note.audioFilename)
  }

  func jsonURL(for note: LocalVoiceNote) -> URL {
    (boundDirectoryURL ?? rootDirectoryURL).appendingPathComponent(note.jsonFilename)
  }

  @discardableResult
  func addNew(
    audioTempURL: URL,
    transcript: String,
    language: String,
    onDevice: Bool,
    sampleRate: Double,
    location: CLLocation?,
    duration: Double?
  ) -> LocalVoiceNote {
    let note = LocalVoiceNote(
      id: UUID(), createdAt: Date(), durationSec: duration,
      language: language, onDevice: onDevice, sampleRate: sampleRate,
      format: "m4a", transcript: transcript,
      lat: location?.coordinate.latitude, lon: location?.coordinate.longitude,
      horizontalAccuracy: location?.horizontalAccuracy, status: .savedPendingUpload
    )
    guard boundDirectoryURL != nil else {
      AppLogging.log("[VoiceNoteStore] addNew() called while unbound — dropping note \(note.id)", level: .warn, category: .audio)
      return note
    }
    let dest = audioURL(for: note)
    try? FileManager.default.removeItem(at: dest)
    try? FileManager.default.moveItem(at: audioTempURL, to: dest)
    _ = save(note)
    return note
  }

  func delete(_ note: LocalVoiceNote) {
    guard boundDirectoryURL != nil else {
      AppLogging.log("[VoiceNoteStore] delete() called while unbound — ignoring \(note.id)", level: .warn, category: .audio)
      return
    }
    try? fm.removeItem(at: audioURL(for: note))
    try? fm.removeItem(at: jsonURL(for: note))
    loadAll()
  }

  func markUploaded(_ note: LocalVoiceNote) {
    var n = note; n.status = .uploaded; _ = save(n)
  }

  func lastTwo() -> [LocalVoiceNote] { Array(notes.prefix(2)) }

  // MARK: - Legacy migration

  /// One-time migration away from the legacy flat layout
  /// (`VoiceNotes/note_<uuid>.{json,m4a}`).
  ///
  /// `LocalVoiceNote` carries no `memberId`/`communityId`, so legacy flat files
  /// cannot be attributed to any user. Per the `CatchReportStore` product
  /// decision, unattributable local data is **dropped** rather than leaked —
  /// every regular file directly under the root is deleted. Per-scope
  /// subdirectories are left untouched.
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
      AppLogging.log("[VoiceNoteStore] migration: listing root failed: \(error.localizedDescription)", level: .error, category: .audio)
      return
    }

    var dropped = 0
    for file in files {
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { continue }
      try? fm.removeItem(at: file)
      dropped += 1
    }

    if dropped > 0 {
      AppLogging.log("[VoiceNoteStore] migration complete — dropped \(dropped) legacy unscoped voice-note file(s)", level: .info, category: .audio)
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

// =====================================================
// MARK: - Location

// =====================================================
final class LocationHelper: NSObject, CLLocationManagerDelegate {
  static let shared = LocationHelper()
  private let manager = CLLocationManager()
  private(set) var latestLocation: CLLocation?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
  }

  func request() {
    let status: CLAuthorizationStatus
    if #available(iOS 14.0, *) {
      status = manager.authorizationStatus
    } else {
      status = CLLocationManager.authorizationStatus()
    }
    if status == .notDetermined {
      manager.requestWhenInUseAuthorization()
    }
  }

  func captureOnce() {
    let s: CLAuthorizationStatus
    if #available(iOS 14.0, *) {
      s = manager.authorizationStatus
    } else {
      s = CLLocationManager.authorizationStatus()
    }
    if s == .authorizedWhenInUse || s == .authorizedAlways { manager.requestLocation() } else { request() }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    latestLocation = locations.last
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    VLog("Location error: \(error.localizedDescription)")
  }
}

// =====================================================
// MARK: - Speech Recorder (with meter for mic animation)

// =====================================================
final class SpeechRecorder: NSObject, ObservableObject {
  @Published var partialTranscript: String = ""
  @Published var isRecording: Bool = false
  @Published var isPaused: Bool = false
  @Published var onDeviceRecognition: Bool = false
  @Published var meterLevel: CGFloat = 0.0 // 0…1
  @Published var didHitTimeLimit: Bool = false

  private let audioEngine = AVAudioEngine()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var speechRecognizer: SFSpeechRecognizer?

  private var audioRecorder: AVAudioRecorder?
  private var audioTempURL: URL?
  private var accumulatedDuration: TimeInterval = 0
  private var segmentStartTime: CFAbsoluteTime?
  private var levelTimer: Timer?

  /// Text from prior recognition sessions that have already finalized. The
  /// engine periodically emits `isFinal == true` mid-recording (especially
  /// on-device, and most often after a brief speech pause). Per Apple, no
  /// further results are delivered on a finalized task — so we lock that
  /// text in here, start a fresh task, and concatenate the new session's
  /// rolling partial onto this prefix. Previously the recorder only kept
  /// the current task's partial, so any auto-finalize caused the visible
  /// transcript to "reset" back to whatever the next sentence said.
  ///
  /// Also written by `pause()` (snapshots `partialTranscript`) so a
  /// resumed session has the pre-pause text to concatenate onto, even when
  /// iOS hadn't silence-finalized yet.
  private var finalizedTranscript: String = ""

  /// Monotonically incremented every time a recognition session is started
  /// or torn down. Each task's result closure captures the generation in
  /// effect at task creation; a mismatch on the next callback means the
  /// task has been superseded (by `startNewRecognitionSession()`, `pause()`,
  /// or `stop()`) and any late results should be dropped. Prevents a
  /// cancelled task from delivering one last `bestTranscription` and
  /// double-appending or overwriting the accumulator after pause.
  private var sessionGeneration: Int = 0

  /// Longest `bestTranscription.formattedString` we've observed in the
  /// active recognition session, across partials AND the final result.
  ///
  /// On iOS 26 on real device hardware (observed iPhone 16, iOS 26.4.2),
  /// SFSpeechRecognizer can deliver an `isFinal == true` result whose
  /// `bestTranscription.formattedString` is *empty* (or a heavily-revised,
  /// much shorter string) after a brief natural speech pause. Appending
  /// that final string straight into `finalizedTranscript` would drop
  /// everything the user just said because the longer text only ever
  /// lived in the preceding partials.
  ///
  /// Tracking the running maximum lets the commit path accumulate the
  /// user's actual words regardless of what iOS decides to put in the
  /// final result. Reset to "" at the start of every session.
  private var currentSessionLongestPartial: String = ""

  /// Wall-clock timestamp of the most recent meter sample that registered
  /// above `silencePeakThresholdDb`. `nil` means the meter has been silent
  /// since the last reset (or has never sampled yet).
  ///
  /// Used by the meter timer to detect sustained silence and recover from
  /// iOS 26's *silent* SFSpeechRecognizer auto-finalize: on iPhone 16 /
  /// iOS 26.4.2 we've observed the recognition task stop emitting
  /// callbacks after ~1s of speech silence without firing `isFinal` or
  /// an error. The user then keeps speaking and nothing is transcribed.
  /// When silence has lasted longer than `silenceRestartThresholdSec` we
  /// proactively commit `currentSessionLongestPartial` into
  /// `finalizedTranscript` and start a new recognition session.
  private var silenceStartedAt: CFAbsoluteTime?

  /// dB FS threshold below which a meter sample counts as "silent". The
  /// recorder reports 0 dB at full scale and ~-160 dB at the noise floor;
  /// natural speech runs roughly -10 to -25 dB. -35 dB catches normal
  /// pauses while leaving room for quiet talkers and ambient noise.
  private let silencePeakThresholdDb: Float = -35.0

  /// Seconds of continuous silence (per `silencePeakThresholdDb`) before
  /// we suspect iOS has silently killed the recognition task and rotate
  /// to a new session. Calibrated against the user-observed iOS 26
  /// auto-finalize timing of ~1–2 seconds.
  private let silenceRestartThresholdSec: TimeInterval = 1.5

  /// Wall-clock timestamp of the most recent successful recognition
  /// callback (result OR error) for the current session generation. Used
  /// by the meter timer to detect "audio is happening but callbacks have
  /// stopped" — the canonical fingerprint of iOS 26's silent task kill
  /// when the user pauses briefly (under `silenceRestartThresholdSec`)
  /// and then resumes speaking. In that case the silence-based trigger
  /// can't help because audio is active again, but no recognition is
  /// happening. We rotate to a new session as soon as the gap exceeds
  /// `callbackInactivityRestartThresholdSec`.
  ///
  /// Reset to "now" whenever a new recognition session starts (so the
  /// new task has a grace period) and to nil when not recording.
  private var lastResultCallbackAt: CFAbsoluteTime?

  /// Seconds without any callback (with audio active) before we assume
  /// iOS killed the task silently. 1.0s is short enough to recover
  /// quickly after a brief speech pause; long enough that a natural
  /// gap between partial deliveries during continuous speech does not
  /// false-positive.
  private let callbackInactivityRestartThresholdSec: TimeInterval = 1.0

  private let maxDuration: TimeInterval?

  let sampleRate: Double = 16000
  let languageCode: String = Locale.preferredLanguages.first ?? "en-US"

  init(maxDuration: TimeInterval? = nil) {
    self.maxDuration = maxDuration
    super.init()
  }

  func start() async throws {
    guard !isRecording else { return }
    didHitTimeLimit = false

    let micOK = try await Self.requestMic(); guard micOK else { throw NSError(
      domain: "Voice",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]
    ) }
    let sttOK = try await Self.requestSpeech(); guard sttOK else { throw NSError(
      domain: "Voice",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "Speech permission denied"]
    ) }

    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
    try session.setActive(true, options: .notifyOthersOnDeactivation)

    let locale = Locale(identifier: languageCode)
    let recognizer = SFSpeechRecognizer(locale: locale)
    speechRecognizer = recognizer
    onDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false

    // Reset the cross-session accumulator so a new recording starts with a
    // clean slate. partialTranscript is reset for the same reason — older
    // sheets clear it themselves on save/cancel, but resetting here makes
    // the recorder safe to re-use without that ceremony.
    finalizedTranscript = ""
    partialTranscript = ""
    currentSessionLongestPartial = ""
    silenceStartedAt = nil
    lastResultCallbackAt = nil

    try configureEngineTapAndStart()
    startNewRecognitionSession()

    // File recorder
    audioTempURL = FileManager.default.temporaryDirectory.appendingPathComponent("note_tmp_\(UUID().uuidString).m4a")
    let recordSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVNumberOfChannelsKey: 1,
      AVSampleRateKey: sampleRate,
      AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
    ]
    audioRecorder = try AVAudioRecorder(url: audioTempURL!, settings: recordSettings)
    audioRecorder?.isMeteringEnabled = true
    audioRecorder?.record()
    segmentStartTime = CFAbsoluteTimeGetCurrent()
    startMeterTimer()

    isRecording = true
    isPaused = false
  }

  private func configureEngineTapAndStart() throws {
    let input = audioEngine.inputNode
    let format = input.inputFormat(forBus: 0)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      // The tap dereferences `self.recognitionRequest` lazily on every
      // append, so when `startNewRecognitionSession()` swaps in a fresh
      // request mid-recording, subsequent buffers route to the new task
      // automatically. No need to reinstall the tap on each restart.
      self?.recognitionRequest?.append(buffer)
    }
    audioEngine.prepare()
    try audioEngine.start()
  }

  /// Tear down any in-flight recognition task/request and start a new one
  /// so the recorder can keep transcribing across the engine's automatic
  /// segmentation boundaries. Called from `start()` for the first session
  /// and from the callback when the engine finalizes a task mid-recording.
  ///
  /// Result handling:
  /// - In-flight partial → display = finalizedTranscript + " " + current
  /// - `isFinal == true` → append current to `finalizedTranscript`, then
  ///   spin up a new session (if still actively recording) so audio keeps
  ///   flowing into a live recognizer.
  /// - Error → if still recording, attempt one restart. Errors thrown by
  ///   `cancel()` on the prior task during teardown reach the callback as
  ///   noise — the `isRecording`/`isPaused` guards skip those.
  private func startNewRecognitionSession() {
    // Tear down any prior task/request before starting a new one. Safe to
    // call after the prior task already finalized — `cancel()` on a
    // finished task is a no-op.
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionTask = nil

    sessionGeneration += 1
    let myGeneration = sessionGeneration
    currentSessionLongestPartial = ""
    // Treat the session start as a "callback" for the inactivity timer
    // so it gets a full `callbackInactivityRestartThresholdSec` grace
    // period before triggering — otherwise a freshly-rotated session
    // would instantly rotate again.
    lastResultCallbackAt = CFAbsoluteTimeGetCurrent()

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    #if targetEnvironment(simulator)
    request.requiresOnDeviceRecognition = false
    #else
    request.requiresOnDeviceRecognition = onDeviceRecognition
    #endif
    request.taskHint = .dictation
    recognitionRequest = request

    recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
      DispatchQueue.main.async {
        guard let self, self.sessionGeneration == myGeneration else { return }
        // Any callback for the active generation — partial result, final
        // result, or error — counts as "recognition is alive." Stamp the
        // inactivity clock so the meter timer's callback-inactivity
        // detector doesn't rotate while the task is still talking to us.
        self.lastResultCallbackAt = CFAbsoluteTimeGetCurrent()
        if let result {
          let current = result.bestTranscription.formattedString

          // Track the longest text we've seen in this session. iOS 26 on
          // physical device can emit `isFinal == true` with an empty
          // `bestTranscription.formattedString` after a brief speech
          // pause, while the preceding partials held the actual words. By
          // accumulating into a running max here and using it for both
          // the display and the final commit, we no longer depend on the
          // final result being the longest — partials are authoritative.
          if current.count > self.currentSessionLongestPartial.count {
            self.currentSessionLongestPartial = current
          }
          let sessionText = self.currentSessionLongestPartial

          let display = self.finalizedTranscript.isEmpty
            ? sessionText
            : self.finalizedTranscript + " " + sessionText
          self.partialTranscript = display

          if result.isFinal {
            // Commit the running maximum (NOT `current` — which iOS 26 may
            // deliver as ""), then start a new task so we keep transcribing
            // the user's next sentences.
            if !sessionText.isEmpty {
              if !self.finalizedTranscript.isEmpty {
                self.finalizedTranscript += " "
              }
              self.finalizedTranscript += sessionText
            }
            if self.isRecording, !self.isPaused {
              self.startNewRecognitionSession()
            }
          }
        }
        if let error {
          VLog("Recognition error: \(error.localizedDescription)")
          // Errors during normal stop()/cancel() teardown also arrive
          // here — the recording-state guard skips them. If we're still
          // recording, attempt one restart to keep the session alive.
          if self.isRecording, !self.isPaused {
            self.startNewRecognitionSession()
          }
        }
      }
    }
  }

  /// Commit the current session's longest-seen transcription into the
  /// cross-session accumulator and rotate to a fresh recognition session.
  /// Used both by the `isFinal` branch of the recognition callback and by
  /// the meter timer's silence-based recovery path when iOS has silently
  /// killed the task without firing a callback.
  private func commitCurrentSessionAndRestart() {
    let sessionText = currentSessionLongestPartial
    if !sessionText.isEmpty {
      if !finalizedTranscript.isEmpty {
        finalizedTranscript += " "
      }
      finalizedTranscript += sessionText
    }
    startNewRecognitionSession()
  }

  private func startMeterTimer() {
    levelTimer?.invalidate()
    levelTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.audioRecorder?.updateMeters()
      let peak = self.audioRecorder?.peakPower(forChannel: 0) ?? -160
      let clamped = max(-60, min(0, peak))
      let linear = pow(10, clamped / 20)
      DispatchQueue.main.async { self.meterLevel = CGFloat(linear) }

      // Silent-finalize recovery, trigger 1 (audio level):
      // SFSpeechRecognizer can stop emitting callbacks after ~1s of speech
      // silence without firing `isFinal` or an error — the task is alive
      // but mute, so anything the user says after the pause is dropped.
      // Track silence via the meter and once it has run past
      // `silenceRestartThresholdSec` with a non-empty session, commit
      // what we've captured and rotate to a new recognition task. The
      // `!currentSessionLongestPartial.isEmpty` guard prevents both (a)
      // restarting before the user has said anything and (b) repeatedly
      // restarting while silence continues after we already rotated.
      let isSilent = peak < self.silencePeakThresholdDb
      if isSilent {
        if self.silenceStartedAt == nil {
          self.silenceStartedAt = CFAbsoluteTimeGetCurrent()
        }
        if
          let silenceStart = self.silenceStartedAt,
          CFAbsoluteTimeGetCurrent() - silenceStart >= self.silenceRestartThresholdSec,
          self.isRecording,
          !self.isPaused,
          !self.currentSessionLongestPartial.isEmpty
        {
          self.silenceStartedAt = nil
          DispatchQueue.main.async { self.commitCurrentSessionAndRestart() }
        }
      } else {
        self.silenceStartedAt = nil
      }

      // Silent-finalize recovery, trigger 2 (task state):
      // If iOS DOES update the task state when it kills the recognition
      // (vs. leaving it stuck at `.running`), this catches it more
      // directly than the silence-level heuristic. Same guard set as
      // above to avoid restarting empty sessions or sessions we just
      // rotated.
      if
        let task = self.recognitionTask,
        task.state != .running, task.state != .starting,
        self.isRecording,
        !self.isPaused,
        !self.currentSessionLongestPartial.isEmpty
      {
        DispatchQueue.main.async { self.commitCurrentSessionAndRestart() }
      }

      // Silent-finalize recovery, trigger 3 (callback inactivity):
      // The canonical iOS-26 failure mode: user pauses briefly, iOS
      // kills the task silently (no isFinal, no error, state stuck at
      // .running), user resumes speaking, but no callbacks ever fire.
      // The other two triggers can't catch this: silence reset when
      // audio came back, task state is still .running. The fingerprint
      // is "audio is happening NOW but the recognition callbacks have
      // gone quiet." Detect that directly: if peak is above the silence
      // threshold (audio active) and the last callback for this
      // generation was longer than the inactivity threshold ago, rotate.
      if
        let last = self.lastResultCallbackAt,
        peak >= self.silencePeakThresholdDb,
        CFAbsoluteTimeGetCurrent() - last >= self.callbackInactivityRestartThresholdSec,
        self.isRecording,
        !self.isPaused,
        !self.currentSessionLongestPartial.isEmpty
      {
        // Zero the inactivity clock so we don't trigger again before
        // commitCurrentSessionAndRestart can reset it via the new
        // session's session-start stamp.
        self.lastResultCallbackAt = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async { self.commitCurrentSessionAndRestart() }
      }

      // NEW: enforce maxDuration if set
      if
        let limit = self.maxDuration,
        let elapsed = self.totalDurationSec(),
        elapsed >= limit
      {
        DispatchQueue.main.async { self.didHitTimeLimit = true }
        self.stop()
      }
    }
    RunLoop.current.add(levelTimer!, forMode: .common)
  }

  private func stopMeterTimer() { levelTimer?.invalidate(); levelTimer = nil }

  func pause() {
    guard isRecording, !isPaused else { return }

    // Lock the visible transcript into the accumulator BEFORE tearing down
    // recognition. Without this, a fast resume spins up a fresh session
    // whose first partial recomputes `partialTranscript` as
    // `finalizedTranscript + " " + currentNewAudio`. If iOS hadn't yet
    // silence-finalized the prior task, `finalizedTranscript` would still
    // be empty and the pre-pause text would vanish from the display.
    finalizedTranscript = partialTranscript

    // Cleanly end the in-flight recognition session and bump the generation
    // so any late callback the cancelled task may still deliver (cancel() +
    // endAudio() can race a final result onto the main queue) is dropped —
    // otherwise it would re-append the current-session text we just rolled
    // into the accumulator.
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionTask = nil
    sessionGeneration += 1
    silenceStartedAt = nil
    lastResultCallbackAt = nil

    if let start = segmentStartTime { accumulatedDuration += CFAbsoluteTimeGetCurrent() - start }
    segmentStartTime = nil
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    audioRecorder?.pause()
    stopMeterTimer()
    isPaused = true
  }

  func resume() {
    guard isRecording, isPaused else { return }
    do {
      try configureEngineTapAndStart()
      _ = audioRecorder?.record()
      segmentStartTime = CFAbsoluteTimeGetCurrent()
      silenceStartedAt = nil
      lastResultCallbackAt = CFAbsoluteTimeGetCurrent()
      startMeterTimer()
      isPaused = false
      // Spin up a fresh recognition session so the resumed audio engine's
      // buffers route into a live recognizer. The prior task was torn down
      // in pause(); without this, the tap would append to a nil / finalized
      // request and no further transcription would happen.
      startNewRecognitionSession()
    } catch { VLog("Resume error: \(error.localizedDescription)") }
  }

  func stop() {
    guard isRecording else { return }
    if !isPaused, let start = segmentStartTime { accumulatedDuration += CFAbsoluteTimeGetCurrent() - start }
    segmentStartTime = nil
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionTask = nil
    sessionGeneration += 1
    audioRecorder?.stop()
    stopMeterTimer()
    isRecording = false
    isPaused = false
  }

  func currentTempURL() -> URL? { audioTempURL }
  func totalDurationSec() -> Double? { audioRecorder?.currentTime ?? accumulatedDuration }

  static func requestMic() async throws -> Bool {
    try await withCheckedThrowingContinuation { cont in
      AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
    }
  }

  static func requestSpeech() async throws -> Bool {
    try await withCheckedThrowingContinuation { cont in
      SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
    }
  }
}

// =====================================================
// MARK: - Uploader (Supabase Edge Function)

// =====================================================
enum NoteUploader {
  private static var endpoint: URL { AppEnvironment.shared.notesUploadURL }
  private static var apiKey: String { AppEnvironment.shared.anonKey }

  struct UploadResponse: Decodable { let noteId: String; let status: String }
  private struct MetaGPS: Codable {
    let lat: Double?
    let lon: Double?
    let hAcc: Double?
  }

  private struct MetaPayload: Codable {
    let id: UUID
    let createdAt: Date
    let language: String
    let onDevice: Bool
    let sampleRate: Double
    let format: String
    let transcript: String
    let gps: MetaGPS?
    let status: String
  }

  static func upload(note: LocalVoiceNote, store: VoiceNoteStore, jwtToken: String) async throws {
    let boundary = "Boundary-\(UUID().uuidString)"
    var req = URLRequest(url: endpoint)
    req.httpMethod = "POST"
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    req.setValue(note.id.uuidString, forHTTPHeaderField: "Idempotency-Key")
    req.setValue("Bearer \(jwtToken)", forHTTPHeaderField: "Authorization")
    req.setValue(apiKey, forHTTPHeaderField: "apikey")

    // meta body from existing JSON on disk (keeps createdAt, gps, etc.)
    var body = Data()
    // --- BUILD META JSON WITH NESTED gps ---
    let metaPayload = MetaPayload(
      id: note.id,
      createdAt: note.createdAt,
      language: note.language,
      onDevice: note.onDevice,
      sampleRate: note.sampleRate,
      format: note.format, // "m4a" or "caf"
      transcript: note.transcript,
      gps: MetaGPS(
        lat: note.lat,
        lon: note.lon,
        hAcc: note.horizontalAccuracy
      ),
      status: note.status.rawValue // "savedPendingUpload" or "uploaded"
    )

    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    let metaData = try enc.encode(metaPayload)

    // multipart: meta
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body
      .append("Content-Disposition: form-data; name=\"meta\"; filename=\"\(note.jsonFilename)\"\r\n"
        .data(using: .utf8)!)
    body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
    body.append(metaData)
    body.append("\r\n".data(using: .utf8)!)

    // audio part
    let audioURL = store.audioURL(for: note)
    let audio = try Data(contentsOf: audioURL)
    let contentType = (note.format.lowercased() == "caf") ? "audio/x-caf" : "audio/m4a"
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body
      .append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(note.audioFilename)\"\r\n"
        .data(using: .utf8)!)
    body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
    body.append(audio)
    body.append("\r\n".data(using: .utf8)!)
    body.append("--\(boundary)--\r\n".data(using: .utf8)!)

    let (respData, resp) = try await URLSession.shared.upload(for: req, from: body)
    guard let http = resp as? HTTPURLResponse else {
      throw NSError(domain: "Upload", code: -1, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
    }

    switch http.statusCode {
    case 201, 409:
      // success (new or idempotent)
      _ = try? JSONDecoder().decode(UploadResponse.self, from: respData)
    default:
      let bodyStr = String(data: respData, encoding: .utf8) ?? ""
      throw NSError(
        domain: "Upload",
        code: http.statusCode,
        userInfo: [NSLocalizedDescriptionKey: "Upload failed (\(http.statusCode)) \(bodyStr)"]
      )
    }
  }
}

// =====================================================
// MARK: - Audio Player

// =====================================================
final class NoteAudioPlayer: ObservableObject {
  private var player: AVAudioPlayer?
  func play(url: URL) {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
      try AVAudioSession.sharedInstance().setActive(true)
      player = try AVAudioPlayer(contentsOf: url)
      player?.prepareToPlay(); player?.play()
    } catch { VLog("Play error: \(error.localizedDescription)") }
  }
}

// =====================================================
// MARK: - Mic Animation

// =====================================================
struct MicRippleView: View {
  var level: CGFloat // 0…1
  var body: some View {
    ZStack {
      Circle()
        .strokeBorder(Color.brandTextPrimary.opacity(0.25), lineWidth: 2)
        .scaleEffect(0.9 + 0.25 * max(0, min(1, level)))
        .opacity(0.4 + 0.3 * Double(level))

      Circle()
        .fill(Color.brandTextPrimary.opacity(0.10))
        .frame(width: 110, height: 110)

      Image(systemName: "mic.fill")
        .font(.system(size: 40, weight: .bold))
    }
    .frame(width: 140, height: 140)
    .animation(.easeOut(duration: 0.12), value: level)
  }
}

// =====================================================
// MARK: - Main View

// =====================================================
struct VoiceNoteView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var store = VoiceNoteStore.shared
  @StateObject private var recorder = SpeechRecorder()
  @StateObject private var player = NoteAudioPlayer()

  @State private var isUploading = false
  @State private var showAllNotes = false
  @State private var errorMessage: String?
  @State private var uploadSummary: String?

  var body: some View {
    ZStack {
      Color.brandBackground.ignoresSafeArea()
      VStack(spacing: 14) {
        topBar
        Spacer(minLength: 8)
        header
        Spacer(minLength: 16)

        if recorder.isRecording { recordingPane } else { idlePane }

        Spacer(minLength: 12)
        if recorder.isRecording { actionBar }

        if let msg = errorMessage {
          Text(msg).font(.brandFootnote).foregroundColor(.brandError).multilineTextAlignment(.center).padding(.top, 4)
        } else if let summary = uploadSummary {
          Text(summary).font(.brandFootnote).foregroundColor(.brandSuccess).multilineTextAlignment(.center).padding(.top, 4)
        }

        Spacer(minLength: 10)
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .foregroundColor(.brandTextPrimary)
      .disabled(isUploading)
      .overlay {
        if isUploading {
          ProgressView("Uploading…")
            .progressViewStyle(.circular)
            .padding(14)
            .background(Color.brandScrim.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
      }
    }
    .navigationBarBackButtonHidden(true)
    .onAppear { store.loadAll(); LocationHelper.shared.captureOnce() }
  }

  // Top bar with Back + Upload (matches your reports pattern)
  private var topBar: some View {
    HStack {
      // Back
      Button {
        dismiss()
      } label: {
        Image(systemName: "chevron.left").font(.brandHeadline.weight(.bold))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.brandStroke)
        .clipShape(Capsule())
      }

      Spacer()

      // Upload icon (uploads all pending)
      Button(action: startUploadAll) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.brandTitle2)
      }
      .accessibilityIdentifier("uploadAllNotesButton")
    }
  }

  private var header: some View {
    VStack(spacing: 8) {
      CommunityLogoView(config: CommunityService.shared.activeCommunityConfig, size: 160)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 8).padding(.bottom, 6)

      Text(CommunityService.shared.activeCommunityName)
        .font(.brandLargeTitle)
        .fontWeight(.bold)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
        .foregroundColor(.brandTextPrimary)

      Text("Steelhead Paradise")
        .font(.brandTitle3)
        .fontWeight(.medium)
        .foregroundColor(.brandTextSecondary)
        .multilineTextAlignment(.center)
    }
  }

  // --- Idle Pane (start + history; upload icon is in the top bar) ---
  private var idlePane: some View {
    VStack(spacing: 16) {
      // Start recording
      Button(action: startRecordingTapped) {
        ZStack {
          Circle().fill(Color.brandTextPrimary.opacity(0.10)).frame(width: 96, height: 96)
          Image(systemName: "mic.fill").font(.system(size: 34, weight: .bold))
        }
      }
      .accessibilityIdentifier("micStartButton")

      // Recent notes (last two)
      if store.lastTwo().isEmpty {
        Text("No notes yet").foregroundColor(.brandTextSecondary)
      } else {
        VStack(spacing: 8) {
          ForEach(store.lastTwo()) { note in
            noteRow(note).onTapGesture { player.play(url: store.audioURL(for: note)) }
          }
        }
      }

      if store.notes.count > 2 {
        Button {
          showAllNotes = true
        } label: {
          Text("Show more").font(.brandFootnote.weight(.semibold))
            .foregroundColor(.brandTextPrimary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.brandStroke).clipShape(Capsule())
        }
        .sheet(isPresented: $showAllNotes) { NoteListView() }
      }
    }
  }

  private var recordingPane: some View {
    VStack(spacing: 14) {
      MicRippleView(level: recorder.meterLevel)
      ScrollView {
        Text(recorder.partialTranscript.isEmpty ? "Listening…" : recorder.partialTranscript)
          .font(.brandBody).foregroundColor(.brandTextPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding().background(Color.brandStrokeSubtle)
          .clipShape(RoundedRectangle(cornerRadius: 12))
      }
      .frame(maxHeight: 240)

      if recorder.isPaused {
        Button(action: resumeTapped) {
          HStack(spacing: 8) { Image(systemName: "play.fill"); Text("Resume") }
            .font(.brandHeadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.brandStroke).clipShape(Capsule())
        }
      } else {
        Button(action: pauseTapped) {
          HStack(spacing: 8) { Image(systemName: "pause.fill"); Text("Pause") }
            .font(.brandHeadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.brandStroke).clipShape(Capsule())
        }
      }
    }
  }

  private var actionBar: some View {
    HStack(spacing: 12) {
      Button(role: .destructive) { discardTapped() } label: {
        Text("Discard")
          .font(.brandHeadline.weight(.semibold))
          .frame(maxWidth: .infinity).padding(.vertical, 12)
          .background(Color.brandStrokeSubtle).clipShape(RoundedRectangle(cornerRadius: 12))
      }
      Button { saveTapped() } label: {
        Text("Save")
          .font(.brandHeadline.weight(.semibold))
          .frame(maxWidth: .infinity).padding(.vertical, 12)
          .background(Color.brandTextPrimary.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 12))
      }
      .accessibilityIdentifier("saveNoteButton")
    }
  }

  @ViewBuilder
  private func noteRow(_ note: LocalVoiceNote) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "waveform")
        .font(.brandTitle3.weight(.semibold))
        .frame(width: 28, height: 28)
        .padding(10)
        .background(Color.brandStroke)
        .clipShape(RoundedRectangle(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 4) {
        Text(note.createdAt, style: .date).font(.brandSubheadline.weight(.semibold))
        Text(note.transcript.isEmpty ? "(no transcript)" : note.transcript)
          .font(.brandFootnote).lineLimit(1).foregroundColor(.brandTextPrimary.opacity(0.9))
      }
      Spacer()
      Text(note.status == .uploaded ? "uploaded" : "saved locally")
        .font(.brandCaption2.weight(.bold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(note.status == .uploaded ? Color.brandSuccess.opacity(0.22) : Color.brandStroke)
        .clipShape(Capsule())
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .background(Color.brandStrokeSubtle)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brandTextPrimary.opacity(0.10), lineWidth: 1))
    .contextMenu {
      if note.status == .savedPendingUpload {
        Button {
          Task { await uploadSingle(note) }
        } label: { Label("Upload", systemImage: "arrow.up.circle") 
        }
      }
    }
  }

  // MARK: - Actions (recording)

  private func startRecordingTapped() {
    Task {
      do {
        LocationHelper.shared.captureOnce()
        try await recorder.start()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func pauseTapped() { recorder.pause() }
  private func resumeTapped() { recorder.resume() }

  private func discardTapped() {
    recorder.stop()
    recorder.partialTranscript = ""
    errorMessage = nil
  }

  private func saveTapped() {
    recorder.stop()
    guard let tempURL = recorder.currentTempURL() else { errorMessage = "No audio to save."; return }
    _ = store.addNew(
      audioTempURL: tempURL,
      transcript: recorder.partialTranscript,
      language: recorder.languageCode,
      onDevice: recorder.onDeviceRecognition,
      sampleRate: recorder.sampleRate,
      location: LocationHelper.shared.latestLocation,
      duration: recorder.totalDurationSec()
    )
    recorder.partialTranscript = ""
    errorMessage = nil
    store.loadAll()
    #if os(iOS)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    #endif
  }

  // MARK: - Upload (mirrors Catch Reports pattern)

  // Top-right button: upload ALL pending
  private func startUploadAll() {
    Task {
      // 1) Ensure we have a fresh user JWT cached (same pattern as ReportListView)
      await AuthStore.shared.refreshFromSupabase()
      guard let jwt = AuthStore.shared.jwt else {
        withAnimation { errorMessage = "Sign in required to upload." }
        return
      }

      // 2) Proceed uploading only pending notes
      let pending = store.notes.filter { $0.status == .savedPendingUpload }
      guard !pending.isEmpty else {
        uploadSummary = "No pending notes."
        return
      }

      isUploading = true
      uploadSummary = nil
      errorMessage = nil

      var success = 0
      for n in pending {
        do {
          try await NoteUploader.upload(note: n, store: store, jwtToken: jwt)
          store.markUploaded(n)
          success += 1
        } catch {
          errorMessage = "Upload failed: \(error.localizedDescription)"
          break
        }
      }

      isUploading = false
      store.loadAll()
      if errorMessage == nil {
        uploadSummary = "Uploaded \(success) note\(success == 1 ? "" : "s")."
      }
    }
  }

  // Context-menu: upload ONE pending note
  private func uploadSingle(_ note: LocalVoiceNote) async {
    await AuthStore.shared.refreshFromSupabase()
    guard let jwt = AuthStore.shared.jwt, note.status == .savedPendingUpload else {
      errorMessage = "Sign in required to upload."
      return
    }
    isUploading = true; uploadSummary = nil; errorMessage = nil
    defer { isUploading = false; store.loadAll() }
    do {
      try await NoteUploader.upload(note: note, store: store, jwtToken: jwt)
      store.markUploaded(note)
      uploadSummary = "Uploaded 1 note."
    } catch {
      errorMessage = "Upload failed: \(error.localizedDescription)"
    }
  }
}

// =====================================================
// MARK: - Note History Sheet

// =====================================================
struct NoteListView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var store = VoiceNoteStore.shared
  @StateObject private var player = NoteAudioPlayer()

  var body: some View {
    NavigationView {
      ZStack {
        Color.brandBackground.ignoresSafeArea()
        listContent()
      }
      .navigationTitle("Note History")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "chevron.left").font(.brandHeadline.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.brandStroke)
            .foregroundColor(.brandTextPrimary)
            .clipShape(Capsule())
          }
        }
      }
    }
    .onAppear { store.loadAll() }
  }

  @ViewBuilder
  private func listContent() -> some View {
    if #available(iOS 16.0, *) {
      baseList.scrollContentBackground(.hidden)
    } else { baseList }
  }

  private var baseList: some View {
    List {
      ForEach(store.notes) { note in
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(note.createdAt, style: .date)
              .font(.brandSubheadline.weight(.semibold))
              .foregroundColor(.brandTextPrimary)
            Text(note.transcript.isEmpty ? "(no transcript)" : note.transcript)
              .font(.brandFootnote)
              .foregroundColor(.brandTextPrimary.opacity(0.9))
              .lineLimit(2)
          }
          Spacer()
          Text(note.status == .uploaded ? "uploaded" : "saved locally")
            .font(.brandCaption2.weight(.bold))
            .foregroundColor(.brandTextPrimary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(note.status == .uploaded ? Color.brandSuccess.opacity(0.25) : Color.brandStrokeStrong)
            .clipShape(Capsule())
        }
        .contentShape(Rectangle())
        .listRowBackground(Color.clear)
        .onTapGesture { player.play(url: store.audioURL(for: note)) }
      }
    }
    .listStyle(.plain)
    .background(Color.clear)
  }
}
