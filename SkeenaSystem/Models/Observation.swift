// Bend Fly Shop

import Foundation

// MARK: - Status

public enum ObservationStatus: String, Codable, CaseIterable {
  case savedLocally = "Saved locally"
  case uploaded = "Uploaded"
}

// MARK: - Model

public nonisolated struct Observation: Identifiable, Codable, Equatable, Sendable {
  // Identity
  public let id: UUID          // Local SwiftUI / filename ID
  public let clientId: UUID    // Server idempotency key
  public var createdAt: Date
  public var uploadedAt: Date?

  // Status
  public var status: ObservationStatus

  // Voice memo reference (points to LocalVoiceNote in VoiceNoteStore)
  public var voiceNoteId: UUID?

  // Transcript (editable copy — canonical after save)
  public var transcript: String

  // Voice metadata (for upload DTO)
  public var voiceLanguage: String?
  public var voiceOnDevice: Bool?
  public var voiceSampleRate: Int?
  public var voiceFormat: String?

  // Location
  public var lat: Double?
  public var lon: Double?
  public var horizontalAccuracy: Double?

  // Convenience
  public var isUploaded: Bool { status == .uploaded }

  public var coordinate: CLLocationCoordinate2D? {
    guard let lat, let lon else { return nil }
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
  }
}

import CoreLocation
