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
  private let notesDirName = "VoiceNotes"
  private var notesDirURL: URL {
    fm.urls(for: .documentDirectory, in: .userDomainMask).first!
      .appendingPathComponent(notesDirName, isDirectory: true)
  }

  private init() { ensureDir(); loadAll() }

  func ensureDir() {
    if !fm.fileExists(atPath: notesDirURL.path) {
      try? fm.createDirectory(at: notesDirURL, withIntermediateDirectories: true)
      VLog("Created notes directory at \(notesDirURL.path)")
    }
  }

  func loadAll() {
    ensureDir()
    do {
      let urls = try fm.contentsOfDirectory(at: notesDirURL, includingPropertiesForKeys: nil)
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
    ensureDir()
    let url = notesDirURL.appendingPathComponent(note.jsonFilename)
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

  func audioURL(for note: LocalVoiceNote) -> URL { notesDirURL.appendingPathComponent(note.audioFilename) }
  func jsonURL(for note: LocalVoiceNote) -> URL { notesDirURL.appendingPathComponent(note.jsonFilename) }

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
    let dest = audioURL(for: note)
    try? FileManager.default.removeItem(at: dest)
    try? FileManager.default.moveItem(at: audioTempURL, to: dest)
    _ = save(note)
    return note
  }

  // ✅ Add this:
  func delete(_ note: LocalVoiceNote) {
    let audio = audioURL(for: note)
    let json = jsonURL(for: note)
    try? fm.removeItem(at: audio)
    try? fm.removeItem(at: json)
    loadAll()
  }

  func markUploaded(_ note: LocalVoiceNote) {
    var n = note; n.status = .uploaded; _ = save(n)
  }

  func lastTwo() -> [LocalVoiceNote] { Array(notes.prefix(2)) }
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

    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    recognitionRequest?.shouldReportPartialResults = true

    let locale = Locale(identifier: languageCode)
    let recognizer = SFSpeechRecognizer(locale: locale)
    speechRecognizer = recognizer

    let supportsOnDevice = recognizer?.supportsOnDeviceRecognition ?? false
    onDeviceRecognition = supportsOnDevice
    #if targetEnvironment(simulator)
    recognitionRequest?.requiresOnDeviceRecognition = false
    #else
    recognitionRequest?.requiresOnDeviceRecognition = supportsOnDevice
    #endif
    recognitionRequest?.taskHint = .dictation

    try configureEngineTapAndStart()

    recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest!) { [weak self] result, error in
      guard let self else { return }
      if let result {
        DispatchQueue.main.async {
          self.partialTranscript = result.bestTranscription.formattedString
        }
      }
      if let error { VLog("Recognition error: \(error.localizedDescription)") }
    }

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
      self?.recognitionRequest?.append(buffer)
    }
    audioEngine.prepare()
    try audioEngine.start()
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
      startMeterTimer()
      isPaused = false
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
