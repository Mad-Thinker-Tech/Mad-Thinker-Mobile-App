// Bend Fly Shop

import Foundation

// MARK: - Response DTOs (nonisolated to avoid actor isolation issues in Swift 6)

private struct UploadResponseDTO: Sendable {
  let processed: Int
  let successful: Int
  let skipped: Int
  let failed: Int
  let results: [UploadResultDTO]
  let errors: [String]?
}

extension UploadResponseDTO: Decodable {
  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    processed = try container.decode(Int.self, forKey: .processed)
    successful = try container.decode(Int.self, forKey: .successful)
    skipped = try container.decode(Int.self, forKey: .skipped)
    failed = try container.decode(Int.self, forKey: .failed)
    results = try container.decode([UploadResultDTO].self, forKey: .results)
    errors = try container.decodeIfPresent([String].self, forKey: .errors)
  }

  private enum CodingKeys: String, CodingKey {
    case processed, successful, skipped, failed, results, errors
  }
}

private struct UploadResultDTO: Sendable {
  let clientId: String
  let id: String?
  let status: String
}

extension UploadResultDTO: Decodable {
  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    clientId = try container.decode(String.self, forKey: .clientId)
    id = try container.decodeIfPresent(String.self, forKey: .id)
    status = try container.decode(String.self, forKey: .status)
  }

  private enum CodingKeys: String, CodingKey {
    case clientId, id, status
  }
}

// MARK: - Upload service for standalone observations
//
// Explicitly `nonisolated`: the project sets SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor,
// which would otherwise make this class `@MainActor`. That routes its deinit through
// `swift_task_deinitOnExecutorMainActorBackDeploy`, which hits a TaskLocal scope
// double-free in iOS 26.2 simruntime when the enclosing SwiftUI View is destroyed.
// The class has no stored properties and no main-thread-only resources, so nonisolated
// is also the semantically correct choice.

nonisolated final class UploadObservations {

  private static let sharedEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes]
    return e
  }()

  // MARK: - Error types

  enum UploadError: LocalizedError {
    case unauthenticated
    case missingMemberNumber
    case noObservationsToUpload
    case encodingFailed(String)
    case network(Error)
    case http(Int, String)

    var errorDescription: String? {
      switch self {
      case .unauthenticated:
        return "Not authenticated. Please log in and try again."
      case .missingMemberNumber:
        return "No member number on file. Re-link your member account and try again."
      case .noObservationsToUpload:
        return "No pending observations to upload."
      case .encodingFailed(let detail):
        return "Failed to prepare upload: \(detail)"
      case .network(let error):
        return "Network error: \(error.localizedDescription)"
      case .http(let code, let body):
        return "Server error (\(code)): \(body)"
      }
    }
  }

  // MARK: - DTOs (match API contract)

  private struct UploadObservationDTO: Codable {
    let clientId: String
    let memberId: String
    let createdAt: String
    let language: String
    let onDevice: Bool
    let sampleRate: Int
    let format: String
    let transcript: String
    let communityId: String?
    let location: LocationDTO?
    let audio: AudioDTO

    // v5: `memberId` carries the human-readable member_number string and is
    // emitted camelCase on the wire to match the catch-upload v5 convention
    // (catch.memberId). The legacy snake_case `community_id` is preserved for
    // backwards compatibility with the existing observations endpoint.
    enum CodingKeys: String, CodingKey {
      case clientId, memberId, createdAt, language, onDevice, sampleRate, format, transcript
      case communityId = "community_id"
      case location, audio
    }

    struct LocationDTO: Codable {
      let lat: Double
      let lon: Double
      let horizontalAccuracy: Double
    }

    struct AudioDTO: Codable {
      let filename: String
      let mimeType: String
      let data_base64: String
    }
  }

  // MARK: - Upload

  func upload(
    observations: [Observation],
    memberId: String,
    progress: @escaping (Double) -> Void,
    completion: @escaping (Result<[UUID], UploadError>) -> Void
  ) {
    let pending = observations.filter { $0.status == .savedLocally }
    AppLogging.log("[UploadObservations] upload() called — total=\(observations.count) pending=\(pending.count) memberId=\(memberId)", level: .info, category: .network)
    guard !pending.isEmpty else {
      AppLogging.log("[UploadObservations] No pending observations — aborting", level: .warn, category: .network)
      completion(.failure(.noObservationsToUpload))
      return
    }

    guard let jwt = AuthStore.shared.jwt, !jwt.isEmpty else {
      AppLogging.log("[UploadObservations] No JWT — aborting", level: .error, category: .network)
      completion(.failure(.unauthenticated))
      return
    }

    // v5: every observation row must carry the uploader's member_number.
    // Sourced at the call site (MainActor) from AuthService.shared.currentMemberId
    // and threaded through here so this nonisolated method does not have to
    // touch the MainActor-isolated AuthService.
    let normalizedMemberId = MemberNumber.normalize(memberId.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !normalizedMemberId.isEmpty else {
      AppLogging.log("[UploadObservations] Empty memberId after normalize — aborting", level: .error, category: .network)
      completion(.failure(.missingMemberNumber))
      return
    }

    // Build DTOs
    var dtos: [UploadObservationDTO] = []
    let isoFormatter = DateFormatting.iso8601

    for (index, obs) in pending.enumerated() {
      progress(Double(index) / Double(pending.count) * 0.5) // 0–50% for prep

      guard let audioDTO = loadAudio(for: obs) else {
        AppLogging.log("[UploadObservations] Skipping observation \(obs.id) — no audio file found", level: .warn, category: .upload)
        continue
      }

      let locationDTO: UploadObservationDTO.LocationDTO?
      if let lat = obs.lat, let lon = obs.lon {
        locationDTO = .init(
          lat: lat,
          lon: lon,
          horizontalAccuracy: obs.horizontalAccuracy ?? 0
        )
      } else {
        locationDTO = nil
      }

      let dto = UploadObservationDTO(
        clientId: obs.clientId.uuidString,
        memberId: normalizedMemberId,
        createdAt: isoFormatter.string(from: obs.createdAt),
        language: obs.voiceLanguage ?? "en-US",
        onDevice: obs.voiceOnDevice ?? true,
        sampleRate: obs.voiceSampleRate ?? 16000,
        format: obs.voiceFormat ?? "m4a",
        transcript: obs.transcript,
        communityId: CommunityService.shared.activeCommunityIdSnapshot,
        location: locationDTO,
        audio: audioDTO
      )
      dtos.append(dto)
    }

    guard !dtos.isEmpty else {
      completion(.failure(.encodingFailed("No observations could be prepared (missing audio files)")))
      return
    }

    // Encode (reuse static instance)
    let encoder = Self.sharedEncoder

    let bodyData: Data
    do {
      bodyData = try encoder.encode(dtos)
    } catch {
      completion(.failure(.encodingFailed(error.localizedDescription)))
      return
    }

    // ── DEBUG: log the outgoing payload so we can diagnose upload failures ──
    let endpoint = AppEnvironment.shared.observationsURL
    let apiKey = AppEnvironment.shared.anonKey

    AppLogging.log("[UploadObservations] Endpoint: \(endpoint.absoluteString)", level: .info, category: .network)
    AppLogging.log("[UploadObservations] DTOs count: \(dtos.count), memberId: \(normalizedMemberId), communityId: \(CommunityService.shared.activeCommunityIdSnapshot ?? "nil")", level: .info, category: .network)

    if let jsonString = String(data: bodyData, encoding: .utf8) {
      // Truncate audio base64 to keep logs readable — replace data_base64
      // values longer than 80 chars with a placeholder showing byte count.
      let redacted = jsonString.replacingOccurrences(
        of: #""data_base64"\s*:\s*"[A-Za-z0-9+/=]{80,}""#,
        with: "\"data_base64\":\"<\(bodyData.count) bytes total payload>\"",
        options: .regularExpression
      )
      AppLogging.log("[UploadObservations] Request body (audio redacted):\n\(redacted)", level: .debug, category: .network)
    }
    // ── end DEBUG ──

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
    request.setValue(apiKey, forHTTPHeaderField: "apikey")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = bodyData
    request.timeoutInterval = 60

    AppLogging.log("[UploadObservations] Sending \(bodyData.count) bytes to \(endpoint.absoluteString)", level: .info, category: .network)

    progress(0.5) // 50% — sending

    // Send
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        AppLogging.log("[UploadObservations] Network error: \(error.localizedDescription)", level: .error, category: .network)
        DispatchQueue.main.async { completion(.failure(.network(error))) }
        return
      }

      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""

      AppLogging.log({ "[UploadObservations] Response \(statusCode): \(body.prefix(2000))" }, level: .info, category: .network)

      guard statusCode == 200 else {
        AppLogging.log("[UploadObservations] FAILED \(statusCode): \(body)", level: .error, category: .network)
        DispatchQueue.main.async { completion(.failure(.http(statusCode, body))) }
        return
      }

      // Parse response
      var uploadedClientIds: [UUID] = []
      if let data, let resp = try? JSONDecoder().decode(UploadResponseDTO.self, from: data) {
        for result in resp.results where result.status == "success" || result.status == "skipped" {
          if let uuid = UUID(uuidString: result.clientId) {
            uploadedClientIds.append(uuid)
          }
        }
      }

      DispatchQueue.main.async {
        progress(1.0)
        completion(.success(uploadedClientIds))
      }
    }
    .resume()
  }

  // MARK: - Audio loading

  private func loadAudio(for observation: Observation) -> UploadObservationDTO.AudioDTO? {
    guard let voiceNoteId = observation.voiceNoteId else { return nil }

    // Find the audio file via VoiceNoteStore
    let store = VoiceNoteStore.shared
    let audioURL = store.audioURL(for: LocalVoiceNote(
      id: voiceNoteId,
      createdAt: Date(),
      durationSec: nil,
      language: "en-US",
      onDevice: true,
      sampleRate: 16000,
      format: "m4a",
      transcript: "",
      lat: nil,
      lon: nil,
      horizontalAccuracy: nil,
      status: .savedPendingUpload
    ))

    guard FileManager.default.fileExists(atPath: audioURL.path) else {
      // Fallback: try pattern-based lookup
      let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
      let fallback = docs
        .appendingPathComponent("VoiceNotes", isDirectory: true)
        .appendingPathComponent("note_\(voiceNoteId.uuidString).m4a")

      guard FileManager.default.fileExists(atPath: fallback.path),
            let data = try? Data(contentsOf: fallback) else {
        return nil
      }

      return UploadObservationDTO.AudioDTO(
        filename: fallback.lastPathComponent,
        mimeType: "audio/m4a",
        data_base64: data.base64EncodedString()
      )
    }

    guard let data = try? Data(contentsOf: audioURL) else { return nil }

    let ext = audioURL.pathExtension.lowercased()
    let mimeType = ext == "caf" ? "audio/x-caf" : "audio/m4a"

    return UploadObservationDTO.AudioDTO(
      filename: audioURL.lastPathComponent,
      mimeType: mimeType,
      data_base64: data.base64EncodedString()
    )
  }
}
