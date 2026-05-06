// Bend Fly Shop

import CoreLocation
import Foundation

// MARK: - Local status

public enum CatchReportStatus: String, Codable, CaseIterable {
  case savedLocally = "Saved locally"
  case uploaded = "Uploaded"
}

// MARK: - Main model

public nonisolated struct CatchReport: Identifiable, Codable, Equatable, Sendable {
  // Local identity
  public let id: UUID // local ID (for JSON filename, SwiftUI IDs)
  public var createdAt: Date
  public var catchDate: Date?
  public var uploadedAt: Date?

  // Upload status
  public var status: CatchReportStatus

  // Catch info (FINAL, after any editing)
  public var memberId: String
  public var species: String?
  public var sex: String?
  public var lengthInches: Int
  public var lifecycleStage: String?
  public var river: String?
  public var classifiedWatersLicenseNumber: String?

  // Location
  public var lat: Double?
  public var lon: Double?

  // Local media references
  /// Filename of the photo under Documents/CatchPhotos (same as existing PhotoStore convention).
  public var photoFilename: String?
  /// Filename of the close-up head shot under Documents/CatchPhotos. Captured in
  /// the conservation/research flow (required when the guide has toggled
  /// Conservation on). Maps to the v5 upload field `catch.headPhoto`.
  public var headPhotoFilename: String?
  /// ID of the voice note (LocalVoiceNote.id) if there is an attached memo.
  public var voiceNoteId: UUID?

  // 🔊 Voice memo metadata (for v2 voiceMemo object)
  /// Transcribed text from the voice memo (used by AI catch story gen).
  public var voiceTranscript: String?
  /// Language code, e.g. "en-US".
  public var voiceLanguage: String?
  /// Whether transcription was done on-device.
  public var voiceOnDevice: Bool?
  /// Audio sample rate in Hz (e.g. 24000).
  public var voiceSampleRate: Int?
  /// Audio format string: "m4a" or "caf".
  public var voiceFormat: String?

  // Trip info (minimal for now, can be extended later)
  public var tripId: String?
  public var tripName: String?
  public var tripStartDate: Date?
  public var tripEndDate: Date?
  public var guideName: String?
  public var community: String?
  public var communityId: String?
  public var lodge: String?

  // Initial AI analysis (for v2 initialAnalysis section)
  public var initialRiverName: String?
  public var initialSpecies: String?
  public var initialLifecycleStage: String?
  public var initialSex: String?
  public var initialLengthInches: Int?

  // ML features (Phase 2 length regressor)
  /// JSON-encoded 26-feature vector from initial ML analysis, for retraining.
  public var mlFeatureVector: Data?
  /// How the length was estimated: "regressor", "heuristic", or "manual".
  public var lengthSource: String?
  /// Version of the LengthRegressor model that produced the estimate.
  public var modelVersion: String?

  // Girth & weight estimation (researcher flow) — final confirmed values.
  // The "estimated vs measured" distinction lives only on the live flow state
  // (ResearcherCatchFlowManager.girthIsEstimated) for chat UI purposes; it's
  // not persisted because the backend doesn't use it and the detail view
  // doesn't display it.
  public var girthInches: Double?
  public var weightLbs: Double?
  public var weightDivisor: Int?
  public var weightDivisorSource: String?
  public var girthRatio: Double?
  public var girthRatioSource: String?

  // Initial measurement estimates (calculated with confirmed species, before user edits length/girth)
  public var initialLengthForMeasurements: Double?
  public var initialGirthInches: Double?
  public var initialWeightLbs: Double?
  public var initialWeightDivisor: Int?
  public var initialWeightDivisorSource: String?
  public var initialGirthRatio: Double?
  public var initialGirthRatioSource: String?

  /// Whether this catch participated in the conservation (research-grade) flow.
  /// True for researchers and for guides who toggled the Conservation opt-in on
  /// GuideLandingView. Maps to the v5 upload field `catch.conservationOptIn`.
  /// Optional so existing locally-stored JSON records decode cleanly (absent → nil → treated as false).
  public var conservationOptIn: Bool?

  /// Whether the user opted this catch OUT of being used to train ML models.
  /// Only ever `true` for public users who disabled the toggle in
  /// ManageProfileView → Privacy. Lodge-provisioned users (guide/angler) and
  /// conservation-agency researchers always send `false`. Maps to the upload
  /// field `catch.mlTrainingOptOut` (default false server-side).
  /// Optional for backward-compatible JSON decode.
  public var mlTrainingOptOut: Bool?

  // Research tag & sample IDs (captured in the researcher/conservation flow).
  // All optional — only populated when the researcher chose the corresponding
  // study type or sample type. Map to the v5 upload fields of the same name.

  /// Floy tag ID — set when the researcher selected study type "Floy".
  public var floyId: String?
  /// PIT tag ID — set when the researcher selected study type "Pit".
  public var pitId: String?
  /// Scale envelope barcode. Set whenever sampling was taken (scales are
  /// always collected when sampling). Maps to `catch.scaleEnvelopeId` on
  /// the v5 upload endpoint.
  public var scaleEnvelopeId: String?
  /// Fin clip envelope barcode. Set only when the researcher answered Yes
  /// to the fin-clip prompt and scanned the second envelope. Maps to
  /// `catch.finEnvelopeId` on the v5 upload endpoint.
  public var finEnvelopeId: String?

  // Meta
  public var appVersion: String?
  public var deviceDescription: String?
  public var platform: String?

  public init(
    id: UUID = UUID(),
    createdAt: Date = Date(),
    catchDate: Date? = nil,
    uploadedAt: Date? = nil,
    status: CatchReportStatus = .savedLocally,
    memberId: String,
    species: String? = nil,
    sex: String? = nil,
    lengthInches: Int,
    lifecycleStage: String? = nil,
    river: String? = nil,
    classifiedWatersLicenseNumber: String? = nil,
    lat: Double? = nil,
    lon: Double? = nil,
    photoFilename: String? = nil,
    headPhotoFilename: String? = nil,
    voiceNoteId: UUID? = nil,
    voiceTranscript: String? = nil,
    voiceLanguage: String? = nil,
    voiceOnDevice: Bool? = nil,
    voiceSampleRate: Int? = nil,
    voiceFormat: String? = nil,
    tripId: String? = nil,
    tripName: String? = nil,
    tripStartDate: Date? = nil,
    tripEndDate: Date? = nil,
    guideName: String? = nil,
    community: String? = nil,
    communityId: String? = nil,
    lodge: String? = nil,
    initialRiverName: String? = nil,
    initialSpecies: String? = nil,
    initialLifecycleStage: String? = nil,
    initialSex: String? = nil,
    initialLengthInches: Int? = nil,
    mlFeatureVector: Data? = nil,
    lengthSource: String? = nil,
    modelVersion: String? = nil,
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
    appVersion: String? = nil,
    deviceDescription: String? = nil,
    platform: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.catchDate = catchDate
    self.uploadedAt = uploadedAt
    self.status = status
    self.memberId = memberId
    self.species = species
    self.sex = sex
    self.lengthInches = lengthInches
    self.lifecycleStage = lifecycleStage
    self.river = river
    self.classifiedWatersLicenseNumber = classifiedWatersLicenseNumber
    self.lat = lat
    self.lon = lon
    self.photoFilename = photoFilename
    self.headPhotoFilename = headPhotoFilename
    self.voiceNoteId = voiceNoteId
    self.voiceTranscript = voiceTranscript
    self.voiceLanguage = voiceLanguage
    self.voiceOnDevice = voiceOnDevice
    self.voiceSampleRate = voiceSampleRate
    self.voiceFormat = voiceFormat
    self.tripId = tripId
    self.tripName = tripName
    self.tripStartDate = tripStartDate
    self.tripEndDate = tripEndDate
    self.guideName = guideName
    self.community = community
    self.communityId = communityId
    self.lodge = lodge
    self.initialRiverName = initialRiverName
    self.initialSpecies = initialSpecies
    self.initialLifecycleStage = initialLifecycleStage
    self.initialSex = initialSex
    self.initialLengthInches = initialLengthInches
    self.mlFeatureVector = mlFeatureVector
    self.lengthSource = lengthSource
    self.modelVersion = modelVersion
    self.girthInches = girthInches
    self.weightLbs = weightLbs
    self.weightDivisor = weightDivisor
    self.weightDivisorSource = weightDivisorSource
    self.girthRatio = girthRatio
    self.girthRatioSource = girthRatioSource
    self.initialLengthForMeasurements = initialLengthForMeasurements
    self.initialGirthInches = initialGirthInches
    self.initialWeightLbs = initialWeightLbs
    self.initialWeightDivisor = initialWeightDivisor
    self.initialWeightDivisorSource = initialWeightDivisorSource
    self.initialGirthRatio = initialGirthRatio
    self.initialGirthRatioSource = initialGirthRatioSource
    self.conservationOptIn = conservationOptIn
    self.mlTrainingOptOut = mlTrainingOptOut
    self.floyId = floyId
    self.pitId = pitId
    self.scaleEnvelopeId = scaleEnvelopeId
    self.finEnvelopeId = finEnvelopeId
    self.appVersion = appVersion
    self.deviceDescription = deviceDescription
    self.platform = platform
  }

  // Convenience
  public var hasPhoto: Bool { photoFilename != nil }
  public var hasVoiceNote: Bool { voiceNoteId != nil }

  public var coordinate: CLLocationCoordinate2D? {
    guard let lat, let lon else { return nil }
    guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
  }

  public var isUploaded: Bool { status == .uploaded }
}
