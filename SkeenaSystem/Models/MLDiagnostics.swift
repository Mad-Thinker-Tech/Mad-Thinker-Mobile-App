// Bend Fly Shop
//
// MLDiagnostics.swift — on-device ML provenance captured at photo-analysis
// time and shipped to the backend under `initialAnalysis.mlDiagnostics`.
// Persisted on `CatchReport` as JSON-encoded `Data` so the disk format stays
// stable while this struct evolves; the field is non-load-bearing for the UI
// so decode failures are silent.
//
// All fields are optional. Backend stores the whole blob as JSONB, so adding
// new optional keys here is forward-compatible with v5 without a contract bump.
// Anything we lose mid-pipeline (e.g. EXIF when the user picked from a fast
// PHPicker path without raw Data) simply renders as `null` server-side.
//
// `nonisolated` + `Sendable` because the upload path runs off-MainActor and
// reads these structs from a Data blob persisted on `CatchReport`.

import Foundation

public nonisolated struct MLDiagnostics: Codable, Equatable, Sendable {

  // MARK: - Confidences (top-1 softmax probabilities)

  /// ViT-species winner softmax probability after lifecycle variants of the
  /// same root species (e.g. holding + traveler) are summed. 0..1.
  public var speciesConfidence: Float?

  /// Conditional probability of the predicted lifecycle stage given the root
  /// species. Nil for species without a lifecycle dimension. 0..1.
  public var lifecycleStageConfidence: Float?

  /// ViT-sex winner softmax probability. Nil when sex model didn't run. 0..1.
  public var sexConfidence: Float?

  // MARK: - Flags

  /// True when the regressor's raw output sat outside the species'
  /// biological envelope (`speciesLengthRanges`) and got clamped. High-
  /// signal for retraining — flags cases the regressor wants to overshoot.
  public var lengthAtSpeciesCap: Bool?

  /// True when this species is in `regressorBypassSpecies` and the
  /// heuristic was used instead of the regressor. Derivable from
  /// `lengthSource == "heuristic"` but stored explicitly so retraining
  /// pipelines can grep without remembering the encoding rule.
  public var regressorBypassed: Bool?

  // MARK: - Species runner-ups (top-N + their probabilities)

  /// ViT-species top-N candidates as label → probability. Includes the
  /// winner plus any runner-ups above the visibility floor. Pre-existing
  /// `speciesAlternatives` surfaces these to the UI as capsules; this map
  /// is the same data, serialized for the backend.
  public var speciesAlternatives: [SpeciesAlternative]?

  public struct SpeciesAlternative: Codable, Equatable, Sendable {
    public var label: String
    public var confidence: Float
    public var isPrimary: Bool

    public init(label: String, confidence: Float, isPrimary: Bool) {
      self.label = label
      self.confidence = confidence
      self.isPrimary = isPrimary
    }
  }

  // MARK: - Raw model outputs (Tier 1b, populated in a follow-up commit)

  /// Full ViT-species softmax distribution: label → probability over the
  /// 13-class space. Currently nil; populated once the analyzer surfaces it.
  public var speciesSoftmax: [String: Float]?

  /// Sex classifier raw output before argmax. Currently nil; populated once
  /// the analyzer surfaces it.
  public var sexSoftmax: [String: Float]?

  /// Length regressor's raw output BEFORE species-range clamping, in inches.
  /// The delta vs the persisted length tells us how often the regressor
  /// wants to overshoot the biological envelope.
  public var regressorRawInches: Double?

  /// YOLOv8 detection confidences (best fish, best person).
  public var yoloFishConfidence: Float?
  public var yoloPersonConfidence: Float?

  // MARK: - Derived geometry

  /// Fish bounding-box aspect ratio (W / H) in YOLO 640×640 space. > 1 means
  /// horizontal hold; < 1 means vertical. Proxy for fish orientation.
  public var fishBoxAspectRatio: Double?

  /// Fraction of the fish box that overlaps the person box. 0 = no overlap,
  /// 1 = fish fully inside person box. Proxy for grip occlusion.
  public var personFishOverlapRatio: Double?

  // MARK: - Hand landmarks (Tier 1c, populated in a follow-up commit)

  /// Full MediaPipe `HandLandmarkerResult` flattened across hands and the 21
  /// landmarks per hand. Currently nil; populated once the analyzer surfaces it.
  public var handLandmarks: [HandLandmark]?

  public struct HandLandmark: Codable, Equatable, Sendable {
    public var handIndex: Int       // 0..1 (one or two hands detected)
    public var landmarkIndex: Int   // 0..20 (MediaPipe's 21-point hand skeleton)
    public var x: Float
    public var y: Float
    public var z: Float
    public var visibility: Float?
    public var presence: Float?

    public init(
      handIndex: Int, landmarkIndex: Int,
      x: Float, y: Float, z: Float,
      visibility: Float? = nil, presence: Float? = nil
    ) {
      self.handIndex = handIndex
      self.landmarkIndex = landmarkIndex
      self.x = x; self.y = y; self.z = z
      self.visibility = visibility
      self.presence = presence
    }
  }

  // MARK: - Model versions (multi)

  public var modelVersions: ModelVersions?

  public struct ModelVersions: Codable, Equatable, Sendable {
    public var yolo: String?
    public var vitSpecies: String?
    public var vitSex: String?
    public var lengthRegressor: String?

    public init(yolo: String? = nil, vitSpecies: String? = nil, vitSex: String? = nil, lengthRegressor: String? = nil) {
      self.yolo = yolo
      self.vitSpecies = vitSpecies
      self.vitSex = vitSex
      self.lengthRegressor = lengthRegressor
    }
  }

  // MARK: - Stage timings (Tier 1b)

  /// Wall-clock milliseconds per pipeline stage. Stage names match
  /// CatchPhotoAnalyzer's internal labels (`yolo`, `vitSpecies`, `vitSex`,
  /// `handLandmarker`, `featureVector`, `lengthRegressor`, `total`).
  public var stageTimingsMs: [StageTiming]?

  public struct StageTiming: Codable, Equatable, Sendable {
    public var stage: String
    public var ms: Double

    public init(stage: String, ms: Double) {
      self.stage = stage
      self.ms = ms
    }
  }

  // MARK: - EXIF / camera (Tier 1c, populated in a follow-up commit)

  public var exifFlashFired: Bool?
  public var exifIso: Int?
  public var exifExposureSeconds: Double?
  public var exifFNumber: Double?
  public var exifFocalLengthMm: Double?
  public var exifFocalLength35mm: Double?
  public var exifLensModel: String?

  /// Approximate scene illuminance derived from EXIF via the Sunny-16 inverse:
  /// `lux ≈ (250 × N²) / (t × ISO)`. Returns nil when any of N, t, ISO is absent.
  public var computedLuxApprox: Double?

  // MARK: - Init

  public init(
    speciesConfidence: Float? = nil,
    lifecycleStageConfidence: Float? = nil,
    sexConfidence: Float? = nil,
    lengthAtSpeciesCap: Bool? = nil,
    regressorBypassed: Bool? = nil,
    speciesAlternatives: [SpeciesAlternative]? = nil,
    speciesSoftmax: [String: Float]? = nil,
    sexSoftmax: [String: Float]? = nil,
    regressorRawInches: Double? = nil,
    yoloFishConfidence: Float? = nil,
    yoloPersonConfidence: Float? = nil,
    fishBoxAspectRatio: Double? = nil,
    personFishOverlapRatio: Double? = nil,
    handLandmarks: [HandLandmark]? = nil,
    modelVersions: ModelVersions? = nil,
    stageTimingsMs: [StageTiming]? = nil,
    exifFlashFired: Bool? = nil,
    exifIso: Int? = nil,
    exifExposureSeconds: Double? = nil,
    exifFNumber: Double? = nil,
    exifFocalLengthMm: Double? = nil,
    exifFocalLength35mm: Double? = nil,
    exifLensModel: String? = nil,
    computedLuxApprox: Double? = nil
  ) {
    self.speciesConfidence = speciesConfidence
    self.lifecycleStageConfidence = lifecycleStageConfidence
    self.sexConfidence = sexConfidence
    self.lengthAtSpeciesCap = lengthAtSpeciesCap
    self.regressorBypassed = regressorBypassed
    self.speciesAlternatives = speciesAlternatives
    self.speciesSoftmax = speciesSoftmax
    self.sexSoftmax = sexSoftmax
    self.regressorRawInches = regressorRawInches
    self.yoloFishConfidence = yoloFishConfidence
    self.yoloPersonConfidence = yoloPersonConfidence
    self.fishBoxAspectRatio = fishBoxAspectRatio
    self.personFishOverlapRatio = personFishOverlapRatio
    self.handLandmarks = handLandmarks
    self.modelVersions = modelVersions
    self.stageTimingsMs = stageTimingsMs
    self.exifFlashFired = exifFlashFired
    self.exifIso = exifIso
    self.exifExposureSeconds = exifExposureSeconds
    self.exifFNumber = exifFNumber
    self.exifFocalLengthMm = exifFocalLengthMm
    self.exifFocalLength35mm = exifFocalLength35mm
    self.exifLensModel = exifLensModel
    self.computedLuxApprox = computedLuxApprox
  }
}
