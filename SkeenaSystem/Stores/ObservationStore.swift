// Bend Fly Shop

import Combine
import Foundation

final class ObservationStore: ObservableObject {
  nonisolated static let shared = ObservationStore()

  @Published private(set) var observations: [Observation] = []

  /// Count of observations still waiting to be uploaded.
  var pendingCount: Int {
    observations.filter { $0.status == .savedLocally }.count
  }

  private let fm = FileManager.default
  private let directoryURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  private init() {
    let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
    self.directoryURL = docs.appendingPathComponent("Observations", isDirectory: true)

    self.encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601

    self.decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    ensureDirectory()
    loadAll()
  }

  // MARK: - Public API

  func refresh() {
    loadAll()
  }

  func add(_ observation: Observation) {
    var new = observation
    new.status = .savedLocally
    save(observation: new)
    loadAll()
  }

  func update(_ observation: Observation) {
    save(observation: observation)
    loadAll()
  }

  func delete(_ observation: Observation) {
    let url = jsonURL(for: observation.id)
    try? fm.removeItem(at: url)
    loadAll()
  }

  /// Mark observations as uploaded by their server-facing `clientId`.
  func markUploaded(_ clientIds: [UUID]) {
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

  // MARK: - Internals

  private func ensureDirectory() {
    if !fm.fileExists(atPath: directoryURL.path) {
      try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
    }
  }

  private func jsonURL(for id: UUID) -> URL {
    directoryURL.appendingPathComponent("observation_\(id.uuidString).json")
  }

  private func save(observation: Observation) {
    ensureDirectory()
    let url = jsonURL(for: observation.id)
    do {
      let data = try encoder.encode(observation)
      try data.write(to: url, options: [.atomic])
    } catch {
      AppLogging.log("[ObservationStore] Failed to save observation \(observation.id): \(error.localizedDescription)", level: .error, category: .observation)
    }
  }

  private func loadAll() {
    ensureDirectory()
    guard let files = try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
      DispatchQueue.main.async { self.observations = [] }
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

    DispatchQueue.main.async {
      self.observations = loaded
    }
  }
}
