// Bend Fly Shop

import Foundation
import UIKit

// Explicitly `nonisolated`: the project sets SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor,
// which would otherwise route this class's deinit through the broken
// `swift_task_deinitOnExecutorMainActorBackDeploy` path on iOS 26.2 sim.
// The class has no stored properties that require main-thread access.

nonisolated final class UploadCatchReport: Sendable {

  // Reusable encoder/decoder — avoids re-creating per upload call.
  private static let sharedEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.withoutEscapingSlashes]
    #if DEBUG
    e.outputFormatting.insert(.prettyPrinted)
    #endif
    return e
  }()
  private static let sharedDecoder = JSONDecoder()

  // MARK: - Config

  struct Config {
    let endpoint: URL
    let appVersion: String
    let deviceDescription: String
    let platform: String
    let timeout: TimeInterval
    let apiKey: String

    /// Default `deviceDescription` snapshot. Reads `UIDevice.current` once via
    /// `MainActor.assumeIsolated` (Apple keeps `UIDevice.current` MainActor-isolated)
    /// and caches the string for the rest of the process lifetime. Callers can
    /// still override per-construction. (`String` is Sendable, so the `static let`
    /// itself doesn't need an isolation annotation.)
    static let defaultDeviceDescription: String = MainActor.assumeIsolated {
      "\(UIDevice.current.model) \(UIDevice.current.systemVersion)"
    }

    init(
      endpoint: URL,
      appVersion: String,
      deviceDescription: String = Config.defaultDeviceDescription,
      platform: String = "iOS",
      timeout: TimeInterval = 30,
      apiKey: String
    ) {
      self.endpoint = endpoint
      self.appVersion = appVersion
      self.deviceDescription = deviceDescription
      self.platform = platform
      self.timeout = timeout
      self.apiKey = apiKey
    }
  }

  enum UploadError: LocalizedError {
    case unauthenticated
    case noReportsToUpload
    case localValidationFailed([String])
    case encodingFailed(String)
    case network(Error)
    case http(Int, String)

    var errorDescription: String? {
      switch self {
      case .unauthenticated:
        "You must be signed in to upload catch reports"
      case .noReportsToUpload:
        "There are no pending catch reports to upload."
      case let .localValidationFailed(messages):
        "Some catch reports failed validation:\n" + messages.joined(separator: "\n")
      case let .encodingFailed(message):
        "Failed to encode catch report upload payload: \(message)"
      case let .network(error):
        "Network error while uploading catch reports: \(error.localizedDescription)"
      case let .http(status, body):
        "Server returned HTTP \(status) for catch upload: \(body)"
      }
    }
  }

  // MARK: - DTOs

  private struct UploadCatchReportDTO: Codable {
    let reportId: String
    let createdAt: Date
    let uploadedAt: Date
    /// Required by v5 — we synthesize a fresh UUID in `makeDTO` when the
    /// CatchReport has no tripId (researcher or solo-guide catch). The
    /// backend auto-creates a "Solo Fishing Trip" for unknown UUIDs.
    let tripId: String
    let communityId: String?
    let tripName: String?
    let catchInfo: CatchDTO
    let initialAnalysis: InitialAnalysisDTO?
    let weightEstimation: WeightEstimationDTO?
    let status: String
    let meta: MetaDTO

    enum CodingKeys: String, CodingKey {
      case reportId, createdAt, uploadedAt, tripId, communityId, tripName
      case catchInfo = "catch"
      case initialAnalysis, weightEstimation, status, meta
    }
  }

  private struct CatchDTO: Codable {
    let memberId: String
    let species: String?
    let sex: String?
    let lengthInches: Int
    let lifecycleStage: String?
    let river: String?
    let girthInches: Double?
    let weightLbs: Double?
    // v5 additions (all optional, all nested under `catch` per v5 spec).
    // Reference: docs/api-reference.md — "Upload Catch Reports v5".
    let initialGirthInches: Double?
    let initialWeightLbs: Double?
    let floyId: String?
    let pitId: String?
    let scaleEnvelopeId: String?
    let finEnvelopeId: String?
    let conservationOptIn: Bool?
    let mlTrainingOptOut: Bool?
    let location: Location?
    let photo: Photo?
    /// Close-up back-of-head shot. Same wire shape as `photo`. Populated by
    /// the researcher/conservation flow. Stored server-side but not displayed
    /// in public catch galleries.
    let headPhoto: Photo?
    let voiceMemo: VoiceMemo?

    struct Location: Codable {
      let lat: Double
      let lon: Double
    }

    struct Photo: Codable {
      let filename: String
      let mimeType: String
      let data_base64: String
    }

    struct VoiceMemo: Codable {
      let filename: String
      let mimeType: String
      let data_base64: String
      let transcript: String
      let language: String
      let onDevice: Bool
      let sampleRate: Int
      let format: String
    }
  }

  private struct InitialAnalysisDTO: Codable {
    let riverName: String?
    let species: String?
    let lifecycleStage: String?
    let sex: String?
    let lengthInches: Int?
    let mlFeatures: [String: Double]?
    let lengthSource: String?
    let modelVersion: String?
  }

  private struct WeightEstimationDTO: Codable {
    // Final confirmed values
    let girthInches: Double?
    let weightLbs: Double?
    let divisor: Int?
    let divisorSource: String?
    let girthRatio: Double?
    let girthRatioSource: String?

    // Initial measurement estimates (calculated with confirmed species, before user edits)
    let initialLengthInches: Double?
    let initialGirthInches: Double?
    let initialWeightLbs: Double?
    let initialDivisor: Int?
    let initialDivisorSource: String?
    let initialGirthRatio: Double?
    let initialGirthRatioSource: String?
  }

  private struct MetaDTO: Codable {
    let appVersion: String
    let device: String
    let platform: String
  }

  nonisolated private struct ResponseDTO: Codable {
    // V3 fields
    let version: String?
    let processed: Int
    let successful: Int
    let skipped: Int?
    let failed: Int
    let results: [ResponseResultDTO]?
    let errors: [String]?

    // V2 compatibility
    let success: Bool?
  }

  nonisolated private struct ResponseResultDTO: Codable {
    let reportId: String
    let status: String
    // V3 fields
    let id: String?
    let tripId: String?
    let originalTripId: String?
    let tripReconciled: Bool?
    let anglerId: String?
    // V2 compatibility
    let catchReportId: String?
  }

  // MARK: - Validation (testable without instantiation)

  /// Filters reports to only those with `.savedLocally` status.
  static func filterPending(_ reports: [CatchReport]) -> [CatchReport] {
    reports.filter { $0.status == .savedLocally }
  }

  /// Validates a single report's fields. Returns error messages, or empty array if valid.
  static func validateReport(_ report: CatchReport) -> [String] {
    var errors: [String] = []
    let memberId = MemberNumber.normalize(report.memberId.trimmingCharacters(in: .whitespacesAndNewlines))
    if memberId.isEmpty {
      errors.append("• \(report.id.uuidString): memberId is required")
    }
    if report.lengthInches < 1 {
      errors.append("• \(report.id.uuidString): lengthInches must be at least 1")
    }
    return errors
  }

  /// Runs the full pre-upload validation pipeline and returns the first error encountered, or nil if valid.
  /// Mirrors the guard/validation sequence in `upload()` without requiring an instance or network call.
  static func validateForUpload(reports: [CatchReport], jwt: String?) -> UploadError? {
    let pending = filterPending(reports)
    guard !pending.isEmpty else { return .noReportsToUpload }
    guard let jwt, !jwt.isEmpty else { return .unauthenticated }
    var allErrors: [String] = []
    for report in pending {
      allErrors.append(contentsOf: validateReport(report))
    }
    if !allErrors.isEmpty { return .localValidationFailed(allErrors) }
    return nil
  }

  // MARK: - Properties

  private let config: Config
  private let session: URLSession

  init(config: Config, session: URLSession? = nil) {
    self.config = config

    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = config.timeout
      configuration.timeoutIntervalForResource = config.timeout * 4
      self.session = URLSession(configuration: configuration)
    }
  }

  // MARK: - Public API

  func upload(
    reports: [CatchReport],
    progress: @escaping (Double) -> Void,
    completion: @escaping (Result<[UUID], Error>) -> Void
  ) {
    let pending = reports.filter { $0.status == .savedLocally }

    guard !pending.isEmpty else {
      completion(.failure(UploadError.noReportsToUpload))
      return
    }

    guard let jwt = AuthStore.shared.jwt, !jwt.isEmpty else {
      completion(.failure(UploadError.unauthenticated))
      return
    }

    // v5 expects ONE catch per POST — the top level of the request body is
    // the catch report object itself ({reportId, createdAt, tripId, catch,
    // meta}), not a batched array. v4 accepted arrays; v5 rejects them with
    // "Missing required fields: reportId, createdAt, tripId, catch, meta"
    // because it tries to read those keys off whatever is at the root.
    //
    // We upload pending reports sequentially, accumulate successful IDs, and
    // return success at the end if at least one report uploaded. Per-report
    // failures are logged but don't abort the batch — the caller re-marks
    // only the successful ones as .uploaded via CatchReportStore.markUploaded.
    progress(0.0)
    uploadSequentially(
      pending: pending,
      index: 0,
      jwt: jwt,
      accumulated: [],
      lastError: nil,
      progress: progress,
      completion: completion
    )
  }

  /// Uploads a single catch report at `pending[index]`, then recurses to the
  /// next one. Accumulates successful IDs across iterations. On the final
  /// recursion (`index >= pending.count`) reports the aggregated result on
  /// the main queue.
  ///
  /// Error handling: per-report failures are collected in `lastError` but do
  /// not short-circuit. The caller sees `.success(accumulated)` if any report
  /// succeeded, `.failure(lastError)` only if every report failed.
  private func uploadSequentially(
    pending: [CatchReport],
    index: Int,
    jwt: String,
    accumulated: [UUID],
    lastError: Error?,
    progress: @escaping (Double) -> Void,
    completion: @escaping (Result<[UUID], Error>) -> Void
  ) {
    // Terminal case — all reports processed.
    guard index < pending.count else {
      DispatchQueue.main.async {
        progress(1.0)
        if !accumulated.isEmpty {
          completion(.success(accumulated))
        } else if let err = lastError {
          completion(.failure(err))
        } else {
          completion(.failure(UploadError.noReportsToUpload))
        }
      }
      return
    }

    let report = pending[index]
    let now = Date()

    // Build the DTO for this single report.
    let dto: UploadCatchReportDTO
    do {
      dto = try makeDTO(from: report, now: now)
    } catch let error {
      AppLogging.log("[UploadCatchReport] Build failed for \(report.id): \(error.localizedDescription)", level: .warn, category: .network)
      uploadSequentially(
        pending: pending,
        index: index + 1,
        jwt: jwt,
        accumulated: accumulated,
        lastError: error,
        progress: progress,
        completion: completion
      )
      return
    }

    // Encode as a bare object (NOT an array). This is the core v5 fix.
    let bodyData: Data
    do {
      bodyData = try Self.sharedEncoder.encode(dto)
      #if DEBUG
      if let jsonString = String(data: bodyData, encoding: .utf8) {
        let preview = jsonString.count > 4000
          ? String(jsonString.prefix(4000)) + "\n…(truncated)…"
          : jsonString
        AppLogging.log({ "================ V5 UPLOAD REQUEST PAYLOAD (\(index + 1)/\(pending.count)) ================" }, level: .debug, category: .network)
        AppLogging.log({ "Size: \(bodyData.count) bytes, chars: \(jsonString.count)" }, level: .debug, category: .network)
        AppLogging.log({ preview }, level: .debug, category: .network)
        AppLogging.log({ "=============================================================" }, level: .debug, category: .network)
      }
      #endif
    } catch {
      AppLogging.log("[UploadCatchReport] Encode failed for \(report.id): \(error.localizedDescription)", level: .warn, category: .network)
      uploadSequentially(
        pending: pending,
        index: index + 1,
        jwt: jwt,
        accumulated: accumulated,
        lastError: UploadError.encodingFailed(error.localizedDescription),
        progress: progress,
        completion: completion
      )
      return
    }

    var request = URLRequest(url: config.endpoint)
    request.httpMethod = "POST"
    request.httpBody = bodyData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(config.apiKey, forHTTPHeaderField: "apikey")
    request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

    #if DEBUG
    AppLogging.log({ "[UploadCatchReport] POST \(self.config.endpoint.absoluteString) (\(index + 1)/\(pending.count))" }, level: .debug, category: .network)
    #endif

    // Report coarse progress as we start this request.
    progress(Double(index) / Double(pending.count))

    // Delegate to the existing retry/response-parsing path, but pass just
    // THIS report in the pending array so the response matcher works. Swallow
    // the inner progress callback — sequential progress is reported here at
    // a per-report granularity instead of per-byte within a request.
    //
    // IMPORTANT: strong `self` capture is deliberate. The URLSession dataTask
    // inside performUpload dispatches its success to main.async and then its
    // own closure returns — at that moment the dataTask releases the only
    // strong ref keeping this UploadCatchReport alive (the caller's local
    // `uploader` variable already went out of scope when `upload(reports:)`
    // returned). Main queue then runs the dispatched block and invokes this
    // closure; if we used [weak self] here, self would be nil and we'd
    // silently bail before firing the terminal completion — leaving the UI
    // stuck at 0% progress and the catch never marked uploaded. No retain
    // cycle because this closure is released once `uploadSequentially` hits
    // its terminal case and the outer completion fires.
    performUpload(
      request: request,
      attempt: 1,
      pending: [report],
      progress: { _ in },
      completion: { result in
        var nextAccumulated = accumulated
        var nextError = lastError
        switch result {
        case let .success(ids):
          nextAccumulated.append(contentsOf: ids)
        case let .failure(error):
          nextError = error
          AppLogging.log("[UploadCatchReport] Failed report \(report.id): \(error.localizedDescription)", level: .warn, category: .network)
        }
        self.uploadSequentially(
          pending: pending,
          index: index + 1,
          jwt: jwt,
          accumulated: nextAccumulated,
          lastError: nextError,
          progress: progress,
          completion: completion
        )
      }
    )
  }

  // MARK: - Retry logic

  /// Maximum number of upload attempts before surfacing the error.
  private static let maxRetries = 3

  /// Base delay in seconds for exponential backoff (1s, 2s, 4s).
  private static let baseRetryDelay: TimeInterval = 1.0

  /// Returns true for errors that are transient and worth retrying.
  private static func isRetryableError(_ error: Error) -> Bool {
    let nsError = error as NSError
    let retryableCodes: Set<Int> = [
      NSURLErrorNetworkConnectionLost,       // -1005
      NSURLErrorTimedOut,                     // -1001
      NSURLErrorNotConnectedToInternet,       // -1009
      NSURLErrorCannotConnectToHost,          // -1004
      NSURLErrorCannotFindHost,              // -1003
      NSURLErrorDNSLookupFailed,             // -1006
      NSURLErrorSecureConnectionFailed,      // -1200
    ]
    return nsError.domain == NSURLErrorDomain && retryableCodes.contains(nsError.code)
  }

  /// Returns true for HTTP status codes that are transient and worth retrying.
  private static func isRetryableStatus(_ code: Int) -> Bool {
    code == 408 || code == 429 || code == 502 || code == 503 || code == 504
  }

  private func performUpload(
    request: URLRequest,
    attempt: Int,
    pending: [CatchReport],
    progress: @escaping (Double) -> Void,
    completion: @escaping (Result<[UUID], Error>) -> Void
  ) {
    let task = session.dataTask(with: request) { data, response, error in

      // --- Network error ---
      if let error {
        if Self.isRetryableError(error), attempt < Self.maxRetries {
          let delay = Self.baseRetryDelay * pow(2.0, Double(attempt - 1))
          AppLogging.log("[UploadCatchReport] Retryable network error (attempt \(attempt)/\(Self.maxRetries)): \(error.localizedDescription). Retrying in \(delay)s…", level: .warn, category: .network)
          DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            self.performUpload(request: request, attempt: attempt + 1, pending: pending, progress: progress, completion: completion)
          }
          return
        }
        DispatchQueue.main.async {
          completion(.failure(UploadError.network(error)))
        }
        return
      }

      guard let httpResponse = response as? HTTPURLResponse else {
        DispatchQueue.main.async {
          completion(.failure(UploadError.http(-1, "No HTTP response")))
        }
        return
      }

      let statusCode = httpResponse.statusCode
      let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""

      #if DEBUG
      AppLogging.log({ "[UploadCatchReport] Response \(statusCode)" }, level: .debug, category: .network)
      AppLogging.log({ "[UploadCatchReport] Body:\n\(responseBody)" }, level: .debug, category: .network)
      #endif

      // --- Retryable HTTP status ---
      if !((200 ... 299).contains(statusCode)) {
        if Self.isRetryableStatus(statusCode), attempt < Self.maxRetries {
          let delay = Self.baseRetryDelay * pow(2.0, Double(attempt - 1))
          AppLogging.log("[UploadCatchReport] Retryable HTTP \(statusCode) (attempt \(attempt)/\(Self.maxRetries)). Retrying in \(delay)s…", level: .warn, category: .network)
          DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            self.performUpload(request: request, attempt: attempt + 1, pending: pending, progress: progress, completion: completion)
          }
          return
        }
        DispatchQueue.main.async {
          completion(.failure(UploadError.http(statusCode, responseBody)))
        }
        return
      }

      var uploadedIDs: [UUID] = []

      // Always log the raw response body (truncated) so we can diagnose
      // mismatches between local "Uploaded" status and what the server
      // actually persisted. Stored server-side IDs (`result.id`) differ
      // from local report UUIDs (`result.reportId`).
      let bodyPreview: String = {
        guard let data, let s = String(data: data, encoding: .utf8) else { return "<no body>" }
        return s.count > 4096 ? String(s.prefix(4096)) + "…<truncated>" : s
      }()
      AppLogging.log("[UploadCatchReport] HTTP \(statusCode) body: \(bodyPreview)", level: .info, category: .network)

      if let data {
        do {
          let resp = try Self.sharedDecoder.decode(ResponseDTO.self, from: data)
          let v = resp.version ?? "unknown"
          AppLogging.log("[UploadCatchReport] Parsed response: version=\(v), processed=\(resp.processed), successful=\(resp.successful), failed=\(resp.failed), results=\(resp.results?.count ?? 0) sent=\(pending.count)", level: .info, category: .network)
          resp.results?.enumerated().forEach { idx, result in
            AppLogging.log("[UploadCatchReport]   results[\(idx)] reportId=\(result.reportId) status=\(result.status) serverId=\(result.id ?? "nil")", level: .info, category: .network)
          }
          if let errors = resp.errors, !errors.isEmpty {
            AppLogging.log("[UploadCatchReport] errors[]: \(errors)", level: .warn, category: .network)
          }
          if let reconciled = resp.results?.filter({ $0.tripReconciled == true }), !reconciled.isEmpty {
            AppLogging.log({ "[UploadCatchReport] Trip reconciled for \(reconciled.count) report(s)" }, level: .debug, category: .network)
          }

          let idsByString = Dictionary(uniqueKeysWithValues: pending.map { ($0.id.uuidString, $0.id) })
          resp.results?.forEach { result in
            if result.status == "success", let localId = idsByString[result.reportId] {
              uploadedIDs.append(localId)
            }
          }

          // Fallback: if we couldn't match individual results but the overall response was successful
          let isSuccess = resp.success ?? (resp.successful > 0 && resp.failed == 0)
          if uploadedIDs.isEmpty, isSuccess {
            AppLogging.log("[UploadCatchReport] ⚠️ No results matched local IDs but isSuccess=true — falling back to marking all \(pending.count) as Uploaded", level: .warn, category: .network)
            uploadedIDs = pending.map(\.id)
          }
          let unmatched = pending.filter { !uploadedIDs.contains($0.id) }
          if !unmatched.isEmpty {
            AppLogging.log("[UploadCatchReport] \(unmatched.count) of \(pending.count) report(s) NOT marked uploaded: \(unmatched.map(\.id.uuidString))", level: .warn, category: .network)
          }
        } catch {
          AppLogging.log("[UploadCatchReport] ⚠️ Failed to decode response JSON: \(error.localizedDescription) — falling back to marking all \(pending.count) as Uploaded", level: .warn, category: .network)
          uploadedIDs = pending.map(\.id)
        }
      } else {
        AppLogging.log("[UploadCatchReport] ⚠️ HTTP \(statusCode) with empty body — falling back to marking all \(pending.count) as Uploaded", level: .warn, category: .network)
        uploadedIDs = pending.map(\.id)
      }

      if attempt > 1 {
        AppLogging.log("[UploadCatchReport] Upload succeeded on attempt \(attempt)/\(Self.maxRetries)", level: .info, category: .network)
      }

      DispatchQueue.main.async {
        progress(1.0)
        completion(.success(uploadedIDs))
      }
    }

    task.resume()
  }

  // MARK: - Mapping

  /// Debug helper: build a single-report DTO via `makeDTO` and return its
  /// encoded JSON string. Used by tests to verify the top-level payload shape
  /// against the v5 API spec without needing to run an actual network request.
  /// Returns `nil` if the report can't be built (validation error, missing
  /// photo, etc.) — the thrown error is swallowed intentionally because
  /// callers just want to eyeball the payload shape.
  internal func debugEncodePayload(for report: CatchReport, now: Date = Date()) -> String? {
    guard let dto = try? makeDTO(from: report, now: now),
          let data = try? Self.sharedEncoder.encode(dto) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  private func makeDTO(from r: CatchReport, now: Date) throws -> UploadCatchReportDTO {
    var localErrors: [String] = []

    let memberId = MemberNumber.normalize(r.memberId.trimmingCharacters(in: .whitespacesAndNewlines))
    if memberId.isEmpty {
      localErrors.append("memberId is required")
    }

    if r.lengthInches < 1 {
      localErrors.append("lengthInches must be at least 1")
    }

    if !localErrors.isEmpty {
      throw UploadError.localValidationFailed(
        localErrors.map { "• \(r.id.uuidString): \($0)" }
      )
    }

    let createdAt = r.catchDate ?? r.createdAt
    let uploadedAt = r.uploadedAt ?? now

    // Location
    var location: CatchDTO.Location?
    if let lat = r.lat, let lon = r.lon, abs(lat) <= 90, abs(lon) <= 180 {
      location = .init(lat: lat, lon: lon)
    }

    // Photo (primary fish photo)
    let photo = try loadPhoto(from: r)

    // Head photo (close-up back of head, captured in conservation flow)
    let headPhoto = try loadHeadPhoto(from: r)

    // Voice memo (with real transcript + metadata)
    let voiceMemo = try loadVoiceMemo(from: r)

    // Initial analysis + ML features
    let mlFeatures: [String: Double]? = r.mlFeatureVector.flatMap { data in
      guard let fv = try? Self.sharedDecoder.decode(CatchPhotoAnalyzer.LengthFeatureVector.self, from: data) else {
        return nil
      }
      // Zip feature names with values to create a keyed dictionary
      return Dictionary(uniqueKeysWithValues: zip(CatchPhotoAnalyzer.featureCols, fv.asArray))
    }

    let initial = InitialAnalysisDTO(
      riverName: r.initialRiverName,
      species: r.initialSpecies,
      lifecycleStage: r.initialLifecycleStage,
      sex: r.initialSex,
      lengthInches: r.initialLengthInches,
      mlFeatures: mlFeatures,
      lengthSource: r.lengthSource,
      modelVersion: r.modelVersion
    )

    #if DEBUG
    let tripIdDebug = r.tripId ?? "(nil)"
    let tripNameDebug = r.tripName ?? "(nil)"
    AppLogging.log({ "[UploadCatchReport] Mapping for report=\(r.id): tripId=\(tripIdDebug), tripName=\(tripNameDebug)" }, level: .debug, category: .network)
    #endif

    // v5 REQUIRES tripId on the top-level body. When a catch has no
    // associated trip (researcher records, guide solo mode without a
    // pre-existing trip row) we generate a fresh UUID and let the backend
    // auto-create a "Solo Fishing Trip" server-side. The spec explicitly
    // documents this fallback — see docs/api-reference.md "Upload Catch
    // Reports v5" → "If tripId doesn't exist, a 'Solo Fishing Trip' is
    // auto-created." Omitting the key entirely (which is what JSONEncoder
    // does for nil optionals) causes a 400 with "Missing required fields:
    // reportId, createdAt, tripId, catch, meta".
    let tripIdToSend: String = {
      if let existing = r.tripId?.trimmingCharacters(in: .whitespacesAndNewlines),
         !existing.isEmpty {
        return existing
      }
      return UUID().uuidString
    }()
    let tripNameToSend = r.tripName

    let meta = MetaDTO(
      appVersion: r.appVersion ?? config.appVersion,
      device: r.deviceDescription ?? config.deviceDescription,
      platform: r.platform ?? config.platform
    )

    let catchDTO = CatchDTO(
      memberId: memberId,
      species: r.species,
      sex: r.sex,
      lengthInches: max(1, r.lengthInches),
      lifecycleStage: r.lifecycleStage,
      river: r.river,
      girthInches: r.girthInches,
      weightLbs: r.weightLbs,
      initialGirthInches: r.initialGirthInches,
      initialWeightLbs: r.initialWeightLbs,
      floyId: r.floyId,
      pitId: r.pitId,
      // 1:1 pass-through to the backend's `catch.scaleEnvelopeId` +
      // `catch.finEnvelopeId` fields. iOS-side names match the wire
      // exactly so the only thing happening here is the JSON encode.
      scaleEnvelopeId: r.scaleEnvelopeId,
      finEnvelopeId: r.finEnvelopeId,
      conservationOptIn: r.conservationOptIn,
      mlTrainingOptOut: r.mlTrainingOptOut,
      location: location,
      photo: photo,
      headPhoto: headPhoto,
      voiceMemo: voiceMemo
    )

    // Weight estimation metadata (researcher flow only)
    let weightEstimation: WeightEstimationDTO?
    if r.girthInches != nil || r.weightLbs != nil {
      weightEstimation = WeightEstimationDTO(
        girthInches: r.girthInches,
        weightLbs: r.weightLbs,
        divisor: r.weightDivisor,
        divisorSource: r.weightDivisorSource,
        girthRatio: r.girthRatio,
        girthRatioSource: r.girthRatioSource,
        initialLengthInches: r.initialLengthForMeasurements,
        initialGirthInches: r.initialGirthInches,
        initialWeightLbs: r.initialWeightLbs,
        initialDivisor: r.initialWeightDivisor,
        initialDivisorSource: r.initialWeightDivisorSource,
        initialGirthRatio: r.initialGirthRatio,
        initialGirthRatioSource: r.initialGirthRatioSource
      )
    } else {
      weightEstimation = nil
    }

    return UploadCatchReportDTO(
      reportId: r.id.uuidString,
      createdAt: createdAt,
      uploadedAt: uploadedAt,
      tripId: tripIdToSend,
      communityId: r.communityId,
      tripName: tripNameToSend,
      catchInfo: catchDTO,
      initialAnalysis: initial,
      weightEstimation: weightEstimation,
      status: r.status == .uploaded ? "Uploaded" : "Saved locally",
      meta: meta
    )
  }

  private func loadPhoto(from report: CatchReport) throws -> CatchDTO.Photo? {
    guard let filename = report.photoFilename, !filename.isEmpty else {
      return nil
    }

    let fm = FileManager.default
    guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
      return nil
    }

    let photosDir = docs.appendingPathComponent("CatchPhotos", isDirectory: true)
    let url = photosDir.appendingPathComponent(filename)

    guard fm.fileExists(atPath: url.path) else {
      #if DEBUG
      AppLogging.log({ "[UploadCatchReport] Photo not found at \(url.path)" }, level: .warn, category: .network)
      #endif
      return nil
    }

    let data = try Data(contentsOf: url)
    let base64 = data.base64EncodedString()
    return CatchDTO.Photo(
      filename: filename,
      mimeType: "image/jpeg",
      data_base64: base64
    )
  }

  /// Loads the optional back-of-head close-up photo. Same shape + directory as
  /// the primary photo — just a different field on the catch record.
  /// Returns nil when the catch didn't capture a head photo (e.g. guide flow
  /// with Conservation OFF, or researcher flow pre-Phase-3.5).
  private func loadHeadPhoto(from report: CatchReport) throws -> CatchDTO.Photo? {
    guard let filename = report.headPhotoFilename, !filename.isEmpty else {
      return nil
    }

    let fm = FileManager.default
    guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
      return nil
    }

    let photosDir = docs.appendingPathComponent("CatchPhotos", isDirectory: true)
    let url = photosDir.appendingPathComponent(filename)

    guard fm.fileExists(atPath: url.path) else {
      #if DEBUG
      AppLogging.log({ "[UploadCatchReport] Head photo not found at \(url.path)" }, level: .warn, category: .network)
      #endif
      return nil
    }

    let data = try Data(contentsOf: url)
    let base64 = data.base64EncodedString()
    return CatchDTO.Photo(
      filename: filename,
      mimeType: "image/jpeg",
      data_base64: base64
    )
  }

  // MARK: - Voice memo loading (REAL transcript + metadata)

  private func loadVoiceMemo(from report: CatchReport) throws -> CatchDTO.VoiceMemo? {
    guard let noteId = report.voiceNoteId else {
      AppLogging.log("[UploadCatchReport] No voiceNoteId for report \(report.id)", level: .debug, category: .audio)
      return nil
    }

    let fm = FileManager.default
    guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
      AppLogging.log("[UploadCatchReport] Could not resolve documents directory", level: .warn, category: .audio)
      return nil
    }

    let notesDir = docs.appendingPathComponent("VoiceNotes", isDirectory: true)

    #if DEBUG
    AppLogging.log({ "[UploadCatchReport] Looking for voice memo for id=\(noteId.uuidString)" }, level: .debug, category: .audio)
    AppLogging.log({ "[UploadCatchReport] Expected directory: \(notesDir.path)" }, level: .debug, category: .audio)
    #endif

    // Try to find the LocalVoiceNote so we can use *its* metadata + transcript.
    let note = VoiceNoteStore.shared.notes.first(where: { $0.id == noteId })

    var candidateURLs: [(URL, String)] = [] // (url, mime)

    if let note {
      let url = VoiceNoteStore.shared.audioURL(for: note)
      let ext = url.pathExtension.lowercased()
      let mime = (ext == "caf") ? "audio/x-caf" : "audio/m4a"

      #if DEBUG
      AppLogging.log({ "[UploadCatchReport] Using VoiceNoteStore URL: \(url.path)" }, level: .debug, category: .audio)
      #endif
      candidateURLs.append((url, mime))
    }

    // Fallback: derive from pattern note_<UUID>.m4a / .caf
    let fallbackM4A = notesDir.appendingPathComponent("note_\(noteId.uuidString).m4a")
    let fallbackCAF = notesDir.appendingPathComponent("note_\(noteId.uuidString).caf")
    candidateURLs.append((fallbackM4A, "audio/m4a"))
    candidateURLs.append((fallbackCAF, "audio/x-caf"))

    var finalURL: URL?
    var finalMime = "audio/m4a"

    for (url, mime) in candidateURLs {
      #if DEBUG
      AppLogging.log({ "[UploadCatchReport] Checking \(url.path)" }, level: .debug, category: .audio)
      #endif
      if fm.fileExists(atPath: url.path) {
        finalURL = url
        finalMime = mime
        break
      }
    }

    guard let url = finalURL else {
      AppLogging.log("[UploadCatchReport] No voice memo file found for id=\(noteId.uuidString) in \(notesDir.path)", level: .error, category: .audio)
      return nil
    }

    let data = try Data(contentsOf: url)
    guard !data.isEmpty else {
      AppLogging.log("[UploadCatchReport] Voice memo file is empty at \(url.path)", level: .error, category: .audio)
      return nil
    }

    let base64 = data.base64EncodedString()
    let ext = url.pathExtension.lowercased()
    let inferredFormat = (ext == "caf") ? "caf" : "m4a"

    // === REAL transcript & metadata ===

    // Prefer the transcript from LocalVoiceNote
    var transcript: String? = note?.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if let t = transcript, t.isEmpty { transcript = nil }

    // If not present, fall back to any transcript stored on the report itself
    if transcript == nil,
       let t = report.voiceTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
       !t.isEmpty {
      transcript = t
    }

    // As a last resort, keep a short generic line (should be rare)
    let finalTranscript = transcript ?? "Spoken catch notes for report \(report.id.uuidString)."

    let language = note?.language ?? report.voiceLanguage ?? "en-US"
    let onDevice = note?.onDevice ?? report.voiceOnDevice ?? true
    let sampleRate = Int(note?.sampleRate ?? Double(report.voiceSampleRate ?? 24000))
    let format = report.voiceFormat ?? inferredFormat

    AppLogging.log("[UploadCatchReport] Loaded voice memo \(url.lastPathComponent) (\(data.count) bytes)", level: .info, category: .audio)
    AppLogging.log({ "[UploadCatchReport]   transcript: \(finalTranscript.prefix(80))\(finalTranscript.count > 80 ? "…" : "")" }, level: .debug, category: .audio)
    AppLogging.log({ "[UploadCatchReport]   language: \(language), onDevice: \(onDevice), sampleRate: \(sampleRate), format: \(format)" },
      level: .debug, category: .audio
    )

    return CatchDTO.VoiceMemo(
      filename: url.lastPathComponent,
      mimeType: finalMime,
      data_base64: base64,
      transcript: finalTranscript,
      language: language,
      onDevice: onDevice,
      sampleRate: sampleRate,
      format: format
    )
  }
}
