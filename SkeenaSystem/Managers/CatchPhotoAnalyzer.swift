// Bend Fly Shop

import CoreLocation
import CoreML
#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
#endif
import UIKit
import Vision

/// How the length estimate was produced.
enum LengthEstimateSource: String, Codable {
  case regressor  // ML model prediction
  case heuristic  // pixel-based heuristic
  case manual     // user correction
}

/// A species candidate surfaced to the chat UI when the ML top-1 confidence is
/// below the "pick-from-capsules" trigger threshold. The first candidate is
/// always the ML top-1 (rendered as primary/green); subsequent candidates are
/// runner-ups above the visibility floor (rendered yellow).
struct SpeciesCandidate: Equatable {
  /// Raw model label, e.g. `"chinook_salmon"` or `"steelhead_holding"`.
  let label: String
  /// Softmax probability from ViT, 0.0–1.0.
  let confidence: Float
  /// True for the ML top-1; false for runner-ups. Drives capsule coloring.
  let isPrimary: Bool
}

struct CatchPhotoAnalysis {
  let riverName: String?
  let species: String?
  let sex: String?
  let estimatedLength: String?
  let lifecycleStage: String?
  let featureVector: CatchPhotoAnalyzer.LengthFeatureVector?
  let lengthSource: LengthEstimateSource?
  /// True when the heuristic clamped at the species' max length range —
  /// i.e. raw input exceeded the global heuristic envelope ceiling.
  /// Carried through to the chat flow so `formatLength` can render "+".
  let lengthAtSpeciesCap: Bool
  let modelVersion: String?
  /// Alternative species candidates when the ML top-1 confidence is ambiguous.
  /// Empty when the model was confident enough to commit directly.
  let speciesAlternatives: [SpeciesCandidate]
  /// Top-1 ViT species softmax probability summed across lifecycle variants of
  /// the same root species (e.g. `steelhead_holding + steelhead_traveler`). Nil
  /// when the model returned no prediction or fell below the detection
  /// threshold. Surfaced in the chat capsule as a `%` next to the species name.
  let speciesConfidence: Float?
  /// Conditional probability of the predicted lifecycle stage given the root
  /// species — `probs[predicted] / (probs[<root>_holding] + probs[<root>_traveler])`.
  /// Nil for species without a lifecycle dimension or when no prediction was made.
  let lifecycleStageConfidence: Float?
  /// Top-1 softmax probability from the ViTFishSex classifier. Nil when the sex
  /// model returned no prediction.
  let sexConfidence: Float?

  init(
    riverName: String?,
    species: String?,
    sex: String?,
    estimatedLength: String?,
    lifecycleStage: String? = nil,
    featureVector: CatchPhotoAnalyzer.LengthFeatureVector? = nil,
    lengthSource: LengthEstimateSource? = nil,
    lengthAtSpeciesCap: Bool = false,
    modelVersion: String? = nil,
    speciesAlternatives: [SpeciesCandidate] = [],
    speciesConfidence: Float? = nil,
    lifecycleStageConfidence: Float? = nil,
    sexConfidence: Float? = nil
  ) {
    self.riverName = riverName
    self.species = species
    self.sex = sex
    self.estimatedLength = estimatedLength
    self.lifecycleStage = lifecycleStage
    self.featureVector = featureVector
    self.lengthSource = lengthSource
    self.lengthAtSpeciesCap = lengthAtSpeciesCap
    self.modelVersion = modelVersion
    self.speciesAlternatives = speciesAlternatives
    self.speciesConfidence = speciesConfidence
    self.lifecycleStageConfidence = lifecycleStageConfidence
    self.sexConfidence = sexConfidence
  }
}

final class CatchPhotoAnalyzer {
  // private let communityID: String
  private let riverLocator: RiverLocator
  private let waterBodyLocator: WaterBodyLocator

  // ViT species model (raw MLModel) — nil if bundle or compilation fails
  private let coreMLModel: MLModel?

  // YOLOv8 detector from best.mlpackage — nil if bundle or compilation fails
  private let detectorModel: best?

  // Cached on-demand models (avoid re-loading on every call)
  private static var _sexModel: ViTFishSex?
  #if canImport(MediaPipeTasksVision)
  private static var _handLandmarker: HandLandmarker?
  #endif

  // Species labels for ViT — alphabetical order MUST match the Python ImageFolder
  // training set order (see `docs/new-species-onboarding.md`). Reordering silently
  // breaks the LengthRegressor, which consumes `species_index` as a feature.
  static let speciesLabels: [String] = [
      "atlantic_salmon_holding",
      "atlantic_salmon_traveler",
      "brook_trout",
      "brown_trout",
      "chinook_salmon",
      "lingcod",
      "musky",
      "other",
      "rainbow_trout",
      "sea_run_trout",
      "steelhead_holding",
      "steelhead_traveler",
      "striped_bass"
  ]

  // Species that aren't calibrated with the regressor — fall back to heuristic.
  // Single source of truth: previously declared inline at two call sites, which
  // diverged easily. Keep this in lockstep with `speciesLabels` when adding a
  // species (see `/new-species` slash command).
  static let regressorBypassSpecies: Set<String> = [
      "sea_run_trout",
      "other",
      "brook_trout",
      "brown_trout",
      "lingcod",
      "musky",
      "rainbow_trout",
      "striped_bass"
  ]


  // MARK: - Init

  init(riverLocator: RiverLocator = .shared, waterBodyLocator: WaterBodyLocator = .shared) {
    self.riverLocator = riverLocator
    self.waterBodyLocator = waterBodyLocator

    let config = MLModelConfiguration()

    // Species model (ViTFishSpecies.mlpackage)
    if let speciesURL = Bundle.main.url(forResource: "ViTFishSpecies", withExtension: "mlmodelc"),
       let model = try? MLModel(contentsOf: speciesURL, configuration: config) {
      self.coreMLModel = model
    } else {
      AppLogging.log("CatchPhotoAnalyzer: failed to load ViTFishSpecies model", level: .error, category: .ml)
      self.coreMLModel = nil
    }

    // YOLOv8 detector (best.mlpackage)
    if let detector = try? best(configuration: config) {
      self.detectorModel = detector
    } else {
      AppLogging.log("CatchPhotoAnalyzer: failed to load YOLOv8 detector model", level: .error, category: .ml)
      self.detectorModel = nil
    }
  }

  // MARK: - Main analysis entry point

  func analyze(
    image: UIImage,
    location: CLLocation?
  ) async -> CatchPhotoAnalysis {
    // 1. Location detection: check both river spines and water body polygons,
    //    pick whichever is closer when both match.
    var riverDisplay: String?

    let riverResult = riverLocator.riverMatch(near: location)
    let waterBodyResult = waterBodyLocator.waterBodyMatch(at: location)
    AppLogging.log("[Analyzer] Location (\(location?.coordinate.latitude ?? 0), \(location?.coordinate.longitude ?? 0)) — river: \(riverResult?.name ?? "none") @ \(String(format: "%.2f", riverResult?.distanceKm ?? -1)) km, waterBody: \(waterBodyResult?.name ?? "none") @ \(String(format: "%.2f", waterBodyResult?.distanceKm ?? -1)) km", level: .debug, category: .ml)

    if let river = riverResult, let waterBody = waterBodyResult {
      // Both matched — pick whichever is closer
      if river.distanceKm <= waterBody.distanceKm {
        riverDisplay = river.name
        AppLogging.log("[Analyzer] River '\(river.name)' wins (closer)", level: .debug, category: .ml)
      } else {
        riverDisplay = waterBody.name
        AppLogging.log("[Analyzer] Water body '\(waterBody.name)' wins (closer)", level: .debug, category: .ml)
      }
    } else if let river = riverResult {
      riverDisplay = river.name
    } else if let waterBody = waterBodyResult {
      riverDisplay = waterBody.name
    } else {
      riverDisplay = nil
      AppLogging.log("[Analyzer] No location matched", level: .debug, category: .ml)
    }

    // 2. YOLO detection (run first so we can crop for species/sex)
    let detection = runDetector(on: image)

    // 3. Species via ViT (on full image)
    let vitResult = runViT(on: image)

    let speciesText: String?
    var detectedSpeciesLabel: String? = nil
    var speciesAlternatives: [SpeciesCandidate] = []
    var speciesRootConfidence: Float? = nil
    var lifecycleStageConfidence: Float? = nil
    let lowConfidenceThreshold = AppEnvironment.shared.speciesDetectionThreshold
    if let vit = vitResult,
       vit.index >= 0,
       vit.index < Self.speciesLabels.count {
      let rawLabel = Self.speciesLabels[vit.index]
      let prettyLabel = rawLabel.replacingOccurrences(of: "_", with: " ")

      if vit.confidence >= lowConfidenceThreshold {
        speciesText = "Species (model): \(prettyLabel)"
        detectedSpeciesLabel = rawLabel
        AppLogging.log({ "ViT species: \(prettyLabel), confidence: \(vit.confidence)" }, level: .info, category: .ml)

        // Cumulative confidence across lifecycle variants of the same root
        // (e.g. steelhead_holding + steelhead_traveler), and conditional
        // lifecycle probability within that root. Surfaces in the chat
        // capsules so the user sees what the model actually believed.
        let stats = Self.confidenceStats(distribution: vit.distribution, predictedIndex: vit.index)
        speciesRootConfidence = stats.rootConfidence
        lifecycleStageConfidence = stats.lifecycleConditional

        // Runner-up capsule logic: when top-1 is below the trigger, surface up to
        // 2 candidates (primary + best runner-up above the visibility floor) so
        // the user can correct an ambiguous classification with one tap instead
        // of having to type the right species name.
        //
        // Also applies when top-1 is "other" (Bi-catch) — a strong salmonid
        // runner-up (e.g. steelhead_holding 0.41 when top-1 is other 0.44)
        // should still be offered. The capsule step renders
        // [Bi-catch (green)] [Steelhead (yellow)]; user picks the real species
        // with one tap, or confirms Bi-catch to stay in the name-it-yourself
        // flow.
        let env = AppEnvironment.shared
        if vit.confidence < env.speciesRunnerUpTrigger {
          speciesAlternatives = computeSpeciesAlternatives(
            distribution: vit.distribution,
            winnerIndex: vit.index,
            minProb: env.speciesRunnerUpMinProb
          )
          AppLogging.log({
            let names = speciesAlternatives.map {
              String(format: "%@=%.2f%@", $0.label, $0.confidence, $0.isPrimary ? "★" : "")
            }.joined(separator: ", ")
            return "Runner-up capsules triggered (top1=\(String(format: "%.2f", vit.confidence)) < \(env.speciesRunnerUpTrigger)): [\(names)]"
          }, level: .info, category: .ml)
        }
      } else {
        AppLogging.log({ "ViT species below threshold: best=\(prettyLabel), confidence=\(vit.confidence) (min \(lowConfidenceThreshold))" }, level: .debug, category: .ml)
        speciesText = "Species: Unable to confidently detect"
      }
    } else {
      AppLogging.log("ViT species: no prediction returned", level: .debug, category: .ml)
      speciesText = "Species: Unable to confidently detect"
    }

    // 4. Sex via ViTFishSex (on full image)
    let sexResult: (label: String, confidence: Float)? = if #available(iOS 16.0, *) {
      runSexClassifier(on: image)
    } else {
      nil
    }
    let sexText: String? = if let s = sexResult { "Sex (model): \(s.label)" } else { "Unknown" }
    let sexConfidence: Float? = sexResult?.confidence

    // 5. Hand pose detection via MediaPipe
    let handMeasurement = detectHand(on: image)

    // 6. Length estimation
    var lengthText: String? = "Length estimate not available (photo estimate failed)"
    var featureVector: LengthFeatureVector?
    var lengthSource: LengthEstimateSource?
    var lengthAtSpeciesCap: Bool = false

    if let fishBox = detection.fishBox {
      // Gate the person box on confidence — low-confidence person detections
      // (square boxes, partial-body false positives) silently corrupt the
      // fish/person ratios used by both the heuristic and the regressor's
      // feature vector. Below the threshold we treat the person as undetected.
      let personConfThreshold = AppEnvironment.shared.personDetectMinConfidence
      let qualifiedPersonBox: NormalizedBox? = {
        guard let p = detection.personBox else { return nil }
        if p.confidence >= personConfThreshold {
          AppLogging.log({ "Detector found person box with conf \(p.confidence)" }, level: .info, category: .ml)
          return p
        }
        AppLogging.log({
          "Person box rejected: conf \(String(format: "%.2f", p.confidence)) < threshold \(String(format: "%.2f", personConfThreshold)) — treating as no person reference"
        }, level: .info, category: .ml)
        return nil
      }()

      // Build feature vector from all detection results
      let speciesIdx = vitResult?.index ?? 0
      let speciesConf = vitResult?.confidence ?? 0.0

      let fv = buildFeatureVector(
        fishBox: fishBox,
        personBox: qualifiedPersonBox,
        speciesIndex: speciesIdx,
        speciesConfidence: speciesConf,
        hand: handMeasurement,
        imageSize: image.size
      )
      featureVector = fv
      AppLogging.log({ "Built feature vector: personDetected=\(fv.personBoxHeight > 0), handDetected=\(fv.handDetected > 0), species=\(Int(fv.speciesIndex))" }, level: .debug, category: .ml)

      // Log feature breakdown grouped by signal source
      AppLogging.log({
        var lines = ["── Feature Vector Breakdown ──"]

        // Fish detection
        lines.append("  Fish: \(String(format: "%.0f", fv.fishBoxWidth))×\(String(format: "%.0f", fv.fishBoxHeight))px, " +
                      "area=\(String(format: "%.0f", fv.fishBoxArea)), " +
                      "aspect=\(String(format: "%.2f", fv.fishAspectRatio)), " +
                      "conf=\(String(format: "%.2f", fv.fishConfidence)), " +
                      "pixelLen=\(String(format: "%.0f", fv.fishPixelLength))")

        // Person reference (primary scale signal)
        if fv.personBoxHeight > 0 {
          lines.append("  Person: \(String(format: "%.0f", fv.personBoxWidth))×\(String(format: "%.0f", fv.personBoxHeight))px, " +
                        "fish/person=\(String(format: "%.3f", fv.fishToPersonRatio))")
          lines.append("  Person ratios: w/h=\(String(format: "%.3f", fv.fishWToPersonH)), " +
                        "h/h=\(String(format: "%.3f", fv.fishHToPersonH)), " +
                        "w/w=\(String(format: "%.3f", fv.fishWToPersonW)), " +
                        "area/h²=\(String(format: "%.3f", fv.fishAreaToPersonHSq))")
        } else {
          lines.append("  Person: NOT DETECTED (ratios zeroed)")
        }

        // Hand/finger reference (secondary scale signal)
        if fv.handDetected > 0 {
          lines.append("  Hand: fingerW=\(String(format: "%.1f", fv.fingerWidthPx))px, " +
                        "fingerL=\(String(format: "%.1f", fv.fingerLengthPx))px, " +
                        "ppi=\(String(format: "%.1f", fv.ppiFromFinger))")
          lines.append("  Hand ratios: fish/fingerW=\(String(format: "%.1f", fv.fishToFingerWidth)), " +
                        "fish/fingerL=\(String(format: "%.1f", fv.fishToFingerLength)), " +
                        "inches_from_finger=\(String(format: "%.1f", fv.fishInchesFromFinger))")
        } else {
          lines.append("  Hand: NOT DETECTED (finger features zeroed)")
        }

        // Species + image context
        lines.append("  Species: idx=\(Int(fv.speciesIndex)), conf=\(String(format: "%.2f", fv.speciesConfidence)), " +
                      "diagFrac=\(String(format: "%.3f", fv.diagonalFraction))")

        return lines.joined(separator: "\n")
      }, level: .debug, category: .ml)

      let useRegressorForSpecies = !Self.regressorBypassSpecies.contains(detectedSpeciesLabel ?? "")

      // Always log regressor prediction for future training data
      if AppEnvironment.shared.useLengthRegressor, let predicted = predictLength(from: fv) {
        let clamped = max(
          AppEnvironment.shared.fishMinLengthInches,
          min(predicted, AppEnvironment.shared.fishMaxLengthInches)
        )
        AppLogging.log({ "Length regressor: raw=\(String(format: "%.1f", predicted)), clamped=\(String(format: "%.1f", clamped))" }, level: .debug, category: .ml)

        let confidence = Self.estimateConfidence(from: fv)
        AppLogging.log({
          "Length estimate confidence: \(confidence.label) (\(String(format: "%.0f", confidence.score * 100))%) — \(confidence.reasoning)"
        }, level: .info, category: .ml)

        // Also log heuristic for comparison
        let heuristicResult = estimateLength(from: fishBox, imageSize: image.size, speciesLabel: detectedSpeciesLabel)
        AppLogging.log({
          "Length heuristic (for comparison): \(heuristicResult.display) vs regressor: \(String(format: "%.0f inches", clamped.rounded()))"
        }, level: .info, category: .ml)

        if useRegressorForSpecies {
          lengthText = String(format: "%.0f inches (%@ confidence)", clamped.rounded(), confidence.label)
          lengthSource = .regressor
        } else {
          // Use species-scaled heuristic for uncalibrated species
          let scaledResult = estimateLength(from: fishBox, imageSize: image.size, speciesLabel: detectedSpeciesLabel)
          lengthText = scaledResult.display
          lengthSource = .heuristic
          lengthAtSpeciesCap = scaledResult.atSpeciesCap
          AppLogging.log({ "Using species-scaled heuristic for \(detectedSpeciesLabel ?? "unknown") (regressor not yet calibrated)" }, level: .info, category: .ml)
        }
      } else {
        let result = estimateLength(from: fishBox, imageSize: image.size)
        lengthText = result.display
        lengthSource = .heuristic
        lengthAtSpeciesCap = result.atSpeciesCap
        AppLogging.log({ "Length heuristic fallback: \(result.display) (regressor \(AppEnvironment.shared.useLengthRegressor ? "failed" : "disabled"))" }, level: .debug, category: .ml)
      }
    } else {
      AppLogging.log("Detector did not return any fish box above confidence/shape thresholds.", level: .warn, category: .ml)
    }

    return CatchPhotoAnalysis(
      riverName: riverDisplay,
      species: speciesText,
      sex: sexText,
      estimatedLength: lengthText,
      featureVector: featureVector,
      lengthSource: lengthSource,
      lengthAtSpeciesCap: lengthAtSpeciesCap,
      modelVersion: CatchPhotoAnalyzer._lengthRegressorVersion,
      speciesAlternatives: speciesAlternatives,
      speciesConfidence: speciesRootConfidence,
      lifecycleStageConfidence: lifecycleStageConfidence,
      sexConfidence: sexConfidence
    )
  }

  /// Splits a ViT label like `"steelhead_holding"` into `(root: "steelhead",
  /// stage: "holding")`. Only the trailing words `holding` / `traveler` are
  /// recognized as lifecycle stages — matches `splitSpecies()` in
  /// `CatchChatViewModel`. For labels without a lifecycle suffix, returns
  /// `(root: <label>, stage: nil)`.
  static func splitLabel(_ raw: String) -> (root: String, stage: String?) {
    let lifecycleSuffixes: Set<String> = ["holding", "traveler"]
    if let underscoreIdx = raw.lastIndex(of: "_") {
      let suffix = String(raw[raw.index(after: underscoreIdx)...]).lowercased()
      if lifecycleSuffixes.contains(suffix) {
        return (root: String(raw[..<underscoreIdx]), stage: suffix)
      }
    }
    return (root: raw, stage: nil)
  }

  /// Cumulative species root probability + conditional lifecycle probability
  /// derived from the ViT softmax distribution. Used by the chat capsules so
  /// the user sees the model's actual confidence next to each prediction.
  ///
  /// - rootConfidence: sum of probabilities across all labels that share the
  ///   predicted label's root (e.g. `steelhead_holding + steelhead_traveler`).
  /// - lifecycleConditional: `probs[predicted] / rootConfidence` when the
  ///   predicted label has a lifecycle suffix; nil otherwise.
  private static func confidenceStats(
    distribution probs: [Float],
    predictedIndex: Int
  ) -> (rootConfidence: Float, lifecycleConditional: Float?) {
    guard predictedIndex >= 0,
          predictedIndex < speciesLabels.count,
          predictedIndex < probs.count else {
      return (0, nil)
    }
    let predictedLabel = speciesLabels[predictedIndex]
    let predictedRoot = splitLabel(predictedLabel).root

    var rootSum: Float = 0
    for (i, label) in speciesLabels.enumerated() where i < probs.count {
      if splitLabel(label).root == predictedRoot {
        rootSum += probs[i]
      }
    }

    let predictedStage = splitLabel(predictedLabel).stage
    let conditional: Float?
    if predictedStage != nil, rootSum > 0 {
      conditional = probs[predictedIndex] / rootSum
    } else {
      conditional = nil
    }
    return (rootConfidence: rootSum, lifecycleConditional: conditional)
  }

  /// Build up to 3 species candidates (primary + up to 2 runners-up) from the
  /// full ViT softmax distribution. Each runner-up must clear `minProb`
  /// independently. Returns an empty array if no runner-up clears the floor,
  /// signalling that capsule UX should be skipped.
  private func computeSpeciesAlternatives(
    distribution probs: [Float],
    winnerIndex: Int,
    minProb: Float
  ) -> [SpeciesCandidate] {
    guard winnerIndex >= 0, winnerIndex < Self.speciesLabels.count else { return [] }

    // Take the top 2 non-winner indices that clear the visibility floor,
    // sorted by descending probability.
    let runnersUp = (0 ..< probs.count)
      .filter { $0 != winnerIndex && $0 < Self.speciesLabels.count && probs[$0] >= minProb }
      .sorted { probs[$0] > probs[$1] }
      .prefix(2)

    // If no runner-up clears the visibility floor, skip capsules entirely —
    // the model strongly prefers the winner, so there's no ambiguity worth
    // surfacing to the user.
    guard !runnersUp.isEmpty else { return [] }

    var result: [SpeciesCandidate] = [
      SpeciesCandidate(label: Self.speciesLabels[winnerIndex], confidence: probs[winnerIndex], isPrimary: true)
    ]
    for idx in runnersUp {
      result.append(SpeciesCandidate(label: Self.speciesLabels[idx], confidence: probs[idx], isPrimary: false))
    }
    return result
  }

  // MARK: - ViT inference (species)

  /// Runs the ViT species model on a UIImage and returns the best species index,
  /// the winner's softmax confidence, and the full probability distribution
  /// (used downstream to surface runner-up candidates to the user).
  ///
  /// Uses Inception-style normalization (mean/std 0.5) — timm's default for
  /// `vit_tiny_patch16_224`, which is what the species model was trained with.
  /// Matching the training preprocessing is load-bearing: the previous
  /// ImageNet-norm default silently produced wrong-distribution inputs.
  ///
  /// Emits a diagnostic log with the full softmax distribution, runner-up margin,
  /// and entropy at the `.info` level so misclassifications can be debugged
  /// without re-running with extra instrumentation.
  private func runViT(on image: UIImage) -> (index: Int, confidence: Float, distribution: [Float])? {
    guard let inputArray = try? makeInputArray(from: image, mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5]) else {
      return nil
    }

    // Wrap the MLMultiArray in an MLFeatureProvider
    let provider = ViTInputFeatureProvider(imageArray: inputArray)

    guard let output = try? coreMLModel?.prediction(from: provider) else {
      return nil
    }

    // Grab the first output feature that is a multiArray
    guard
      let outputName = output.featureNames.first,
      let logits = output.featureValue(for: outputName)?.multiArrayValue
    else {
      return nil
    }

    // Compute the full softmax distribution once — reused for the returned
    // winner confidence, the diagnostic log, and the runner-up capsule logic.
    let probs = softmaxDistribution(logits)
    guard let bestIdx = probs.indices.max(by: { probs[$0] < probs[$1] }) else { return nil }
    let confidence = probs[bestIdx]

    logViTBreakdown(probs: probs, logits: logits, bestIdx: bestIdx)

    return (index: bestIdx, confidence: confidence, distribution: probs)
  }

  /// Computes the full softmax probability distribution from a logits array.
  /// Numerically stable (subtracts max before exp).
  private func softmaxDistribution(_ logits: MLMultiArray) -> [Float] {
    guard logits.count > 0 else { return [] }  // swiftlint:disable:this empty_count

    var maxVal: Float = -.greatestFiniteMagnitude
    for i in 0 ..< logits.count {
      maxVal = max(maxVal, logits[i].floatValue)
    }

    var exps = [Float](repeating: 0, count: logits.count)
    var sumExp: Float = 0
    for i in 0 ..< logits.count {
      let e = exp(logits[i].floatValue - maxVal)
      exps[i] = e
      sumExp += e
    }

    guard sumExp > 0 else { return exps }
    for i in 0 ..< exps.count {
      exps[i] /= sumExp
    }
    return exps
  }

  /// Emits a structured diagnostic log showing the full ViT species distribution,
  /// runner-up margin, and entropy — everything you need to understand why a
  /// given class was picked. Flags close calls (small margin / high entropy) so
  /// they stand out when scanning logs.
  private func logViTBreakdown(probs: [Float], logits: MLMultiArray, bestIdx: Int) {
    // Sorted (probability, originalIndex) pairs, descending.
    let ranked = probs.enumerated()
      .map { (idx: $0.offset, prob: $0.element) }
      .sorted { $0.prob > $1.prob }

    // Top-1 vs Top-2 margin (0 if only one class).
    let margin: Float = ranked.count >= 2 ? ranked[0].prob - ranked[1].prob : ranked.first?.prob ?? 0

    // Shannon entropy in nats. Uniform over N classes = ln(N). Peaky ≈ 0.
    // Max possible entropy for sanity framing: ln(numClasses).
    var entropy: Float = 0
    for p in probs where p > 0 {
      entropy -= p * log(p)
    }
    let maxEntropy = log(Float(max(probs.count, 1)))
    let normalizedEntropy = maxEntropy > 0 ? entropy / maxEntropy : 0

    // Heuristic close-call flag — surfaces the cases worth eyeballing.
    let closeCall = margin < 0.15 || normalizedEntropy > 0.7

    AppLogging.log({
      var lines = ["── ViT species breakdown ──"]
      for (rank, item) in ranked.enumerated() {
        let label = item.idx < Self.speciesLabels.count ? Self.speciesLabels[item.idx] : "idx\(item.idx)"
        let logitValue = item.idx < logits.count ? logits[item.idx].floatValue : 0
        let marker = (item.idx == bestIdx) ? "★" : " "
        lines.append(String(
          format: "  %@ %d. %-22@ %.3f (logit %.3f)",
          marker, rank + 1, label as NSString, item.prob, logitValue
        ))
      }
      lines.append(String(
        format: "  margin (top1-top2): %.3f  |  entropy: %.3f nats (%.0f%% of max)%@",
        margin,
        entropy,
        normalizedEntropy * 100,
        closeCall ? "  ⚠️ CLOSE CALL" : ""
      ))
      return lines.joined(separator: "\n")
    }, level: .info, category: .ml)
  }

  /// Computes the softmax probability for a specific index in a logits array.
  /// Kept for any callers still using it directly; new code should prefer
  /// `softmaxDistribution(_:)` which returns the full vector in one pass.
  private func softmaxConfidence(_ logits: MLMultiArray, at index: Int) -> Float {
    let probs = softmaxDistribution(logits)
    guard index >= 0, index < probs.count else { return 0 }
    return probs[index]
  }

  /// Returns the index of the largest value in the MLMultiArray (assumed 1-D or flattenable).
  private func argmax(_ array: MLMultiArray) -> Int? {
    guard array.count > 0 else { return nil }  // swiftlint:disable:this empty_count

    var bestIndex = 0
    var bestValue = Float(array[0].floatValue)

    for i in 1 ..< array.count {
      let v = array[i].floatValue
      if v > bestValue {
        bestValue = v
        bestIndex = i
      }
    }
    return bestIndex
  }

  // MARK: - ViT sex classifier (iOS 16+)

  /// Runs the ViTFishSex model on a UIImage and returns the predicted label
  /// ("male" / "female") together with its softmax probability. Nil when the
  /// model fails to load or run.
  @available(iOS 16.0, *)
  private func runSexClassifier(on image: UIImage) -> (label: String, confidence: Float)? {
    guard let inputArray = try? makeInputArray(from: image, mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5]) else {
      AppLogging.log("runSexClassifier: failed to create input array", level: .error, category: .ml)
      return nil
    }

    // Lazy-cache the sex model so it's only loaded once.
    if Self._sexModel == nil {
      Self._sexModel = try? ViTFishSex(configuration: MLModelConfiguration())
    }
    guard let model = Self._sexModel else {
      AppLogging.log("runSexClassifier: failed to create ViTFishSex model", level: .error, category: .ml)
      return nil
    }

    // ViTFishSex was exported with a single Tensor input (ct.TensorType),
    // so the generated API should look like `prediction(input: MLMultiArray)`.
    guard let output = try? model.prediction(input: inputArray) else {
      AppLogging.log("runSexClassifier: model prediction failed", level: .error, category: .ml)
      return nil
    }

    let label = output.classLabel.lowercased() // "female" or "male"

    // The ViTFishSex CoreML package exposes a `classLabel_probs` dictionary
    // alongside the raw label. Pull the values for each class via the
    // MLFeatureProvider API so we don't depend on the auto-generated Swift
    // property name (which can vary across Xcode versions).
    //
    // The exported model pipes the linear classifier head straight into
    // CoreML's `classify` op without a softmax in between, so the dict
    // values are raw logits, not probabilities — without normalization the
    // chat capsule renders things like 520% for the predicted sex. We
    // detect the logits case (out-of-range or sum != 1) and softmax before
    // reading the winner's probability, while leaving already-normalized
    // outputs alone in case a future retrain bakes softmax into the model.
    var confidence: Float = 0
    if let dict = output.featureValue(for: "classLabel_probs")?.dictionaryValue {
      var values: [(label: String, value: Float)] = []
      for (k, v) in dict {
        if let key = k as? String {
          values.append((label: key.lowercased(), value: v.floatValue))
        }
      }

      let sum = values.reduce(Float(0)) { $0 + $1.value }
      let outOfRange = values.contains { $0.value < 0 || $0.value > 1 }
      if !values.isEmpty, outOfRange || abs(sum - 1) > 0.01 {
        let maxVal = values.map { $0.value }.max() ?? 0
        var expSum: Float = 0
        let exps: [(label: String, value: Float)] = values.map { entry in
          let e = exp(entry.value - maxVal)
          expSum += e
          return (label: entry.label, value: e)
        }
        if expSum > 0 {
          values = exps.map { ($0.label, $0.value / expSum) }
        }
      }

      if let entry = values.first(where: { $0.label == label }) {
        confidence = entry.value
      }
    }

    AppLogging.log({ "runSexClassifier: label=\(label), confidence=\(confidence)" }, level: .info, category: .ml)
    return (label: label, confidence: confidence)
  }

  // MARK: - Hand pose detection (MediaPipe)

  /// Finger measurements from MediaPipe hand detection, in original image pixel space.
  struct HandMeasurement {
    let fingerWidthPx: Float   // index-to-middle knuckle distance
    let fingerLengthPx: Float  // index MCP to tip distance
    let confidence: Float      // handedness confidence
  }

  /// Detects hand landmarks via MediaPipe and returns finger measurements for the best hand.
  /// Applies same sanity filters as the Python training pipeline.
  private func detectHand(on image: UIImage) -> HandMeasurement? {
    #if canImport(MediaPipeTasksVision)
    guard image.cgImage != nil else { return nil }

    // Lazy-cache the HandLandmarker so the .task model is only loaded once.
    if Self._handLandmarker == nil {
      guard let modelPath = Bundle.main.path(forResource: "hand_landmarker", ofType: "task") else {
        AppLogging.log("detectHand: hand_landmarker.task not found in bundle", level: .error, category: .ml)
        return nil
      }
      let options = HandLandmarkerOptions()
      options.baseOptions.modelAssetPath = modelPath
      options.numHands = 2
      options.minHandDetectionConfidence = 0.3
      options.minHandPresenceConfidence = 0.3
      options.runningMode = .image
      Self._handLandmarker = try? HandLandmarker(options: options)
    }
    guard let landmarker = Self._handLandmarker else {
      AppLogging.log("detectHand: failed to create HandLandmarker", level: .error, category: .ml)
      return nil
    }

    let mpImage = try? MPImage(uiImage: image)
    guard let mpImage else {
      AppLogging.log("detectHand: failed to create MPImage", level: .error, category: .ml)
      return nil
    }

    guard let result = try? landmarker.detect(image: mpImage) else {
      AppLogging.log("detectHand: detection failed", level: .error, category: .ml)
      return nil
    }

    guard !result.landmarks.isEmpty else {
      AppLogging.log("detectHand: no hands detected", level: .debug, category: .ml)
      return nil
    }

    let imgW = Float(image.size.width)
    let imgH = Float(image.size.height)

    var bestMeasurement: HandMeasurement?
    var bestConf: Float = 0.0

    for (i, hand) in result.landmarks.enumerated() {
      guard hand.count > 9 else { continue }

      // Key landmarks (same indices as Python)
      let idxMCP = hand[5]  // Index finger knuckle
      let idxTip = hand[8]  // Index fingertip
      let midMCP = hand[9]  // Middle finger knuckle

      // Finger width: index-to-middle knuckle distance (pixels)
      let fingerWidthPx = sqrtf(
        powf((idxMCP.x - midMCP.x) * imgW, 2) +
        powf((idxMCP.y - midMCP.y) * imgH, 2)
      )

      // Index finger length: knuckle to tip (pixels)
      let fingerLengthPx = sqrtf(
        powf((idxMCP.x - idxTip.x) * imgW, 2) +
        powf((idxMCP.y - idxTip.y) * imgH, 2)
      )

      // Handedness confidence
      let conf: Float = if i < result.handedness.count, !result.handedness[i].isEmpty {
        result.handedness[i][0].score
      } else {
        0.5
      }

      // ── Sanity filters (matching Python pipeline) ──

      // Min pixel size
      if fingerWidthPx < 10 || fingerLengthPx < 15 { continue }

      // Length-to-width ratio must be plausible (1.5-10x)
      let lengthToWidth = fingerLengthPx / max(fingerWidthPx, 1)
      if lengthToWidth < 1.5 || lengthToWidth > 10.0 { continue }

      // PPI sanity: finger width ~0.85" real-world
      let ppi = fingerWidthPx / 0.85
      if ppi < 10 || ppi > 500 { continue }

      // Implied max fish length sanity
      let imgDiag = sqrtf(imgW * imgW + imgH * imgH)
      let maxFishInches = imgDiag / ppi
      if maxFishInches < 5 || maxFishInches > 300 { continue }

      if conf > bestConf {
        bestConf = conf
        bestMeasurement = HandMeasurement(
          fingerWidthPx: fingerWidthPx,
          fingerLengthPx: fingerLengthPx,
          confidence: conf
        )
      }
    }

    if let m = bestMeasurement {
      AppLogging.log({ "detectHand: fingerWidth=\(m.fingerWidthPx)px, fingerLength=\(m.fingerLengthPx)px, conf=\(m.confidence)" }, level: .info, category: .ml)
    } else {
      AppLogging.log("detectHand: all hands failed sanity filters", level: .debug, category: .ml)
    }

    return bestMeasurement
    #else
    AppLogging.log("detectHand: MediaPipeTasksVision not available, skipping hand detection", level: .info, category: .ml)
    return nil
    #endif
  }

  // MARK: - Fish crop from YOLO box

  /// Crops a UIImage to the YOLO fish bounding box (640×640 coords → original image coords).
  /// Adds 10% padding on each side for context.
  private func cropToBox(image: UIImage, box: NormalizedBox) -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }

    let imgW = CGFloat(cgImage.width)
    let imgH = CGFloat(cgImage.height)
    let yoloSize: CGFloat = 640.0

    // Convert from YOLO 640×640 center coords to original image pixel coords
    let scaleX = imgW / yoloSize
    let scaleY = imgH / yoloSize

    let centerX = box.xCenter * scaleX
    let centerY = box.yCenter * scaleY
    let w = box.width * scaleX
    let h = box.height * scaleY

    // Add 10% padding for context
    let padX = w * 0.1
    let padY = h * 0.1

    let cropRect = CGRect(
      x: max(0, centerX - w / 2 - padX),
      y: max(0, centerY - h / 2 - padY),
      width: min(w + 2 * padX, imgW),
      height: min(h + 2 * padY, imgH)
    ).integral

    guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
    return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
  }

  // MARK: - Image preprocessing for ViT / ViTFishSex

  /// Converts a UIImage into a 1×3×224×224 Float32 MLMultiArray with configurable normalization.
  /// Default uses ImageNet normalization (species model). Sex model passes mean/std of 0.5.
  private func makeInputArray(
    from image: UIImage,
    mean: [Float] = [0.485, 0.456, 0.406],
    std: [Float] = [0.229, 0.224, 0.225]
  ) throws -> MLMultiArray {
    guard let srcCGImage = image.cgImage else {
      throw PreprocessError.cannotResize
    }

    let width = 224
    let height = 224
    let bytesPerPixel = 4
    let bytesPerRow = bytesPerPixel * width

    // 1) Draw the original image directly into a 224×224 RGBA8 buffer (single resize pass)
    var rawData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    guard
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: &rawData,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw PreprocessError.cannotCreateContext
    }

    context.draw(srcCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    // 2) Create MLMultiArray of shape [1, 3, 224, 224]
    let shape: [NSNumber] = [1, 3, NSNumber(value: height), NSNumber(value: width)]
    let array = try MLMultiArray(shape: shape, dataType: .float32)

    // 3) Fill using a raw pointer — avoids ~150K NSNumber allocations per image
    let channelStride = height * width
    let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * channelStride)

    for y in 0 ..< height {
      for x in 0 ..< width {
        let pixelIndex = y * bytesPerRow + x * bytesPerPixel
        let hwIndex = y * width + x

        ptr[0 * channelStride + hwIndex] = (Float(rawData[pixelIndex + 0]) / 255.0 - mean[0]) / std[0]
        ptr[1 * channelStride + hwIndex] = (Float(rawData[pixelIndex + 1]) / 255.0 - mean[1]) / std[1]
        ptr[2 * channelStride + hwIndex] = (Float(rawData[pixelIndex + 2]) / 255.0 - mean[2]) / std[2]
      }
    }

    return array
  }

  private enum PreprocessError: Error {
    case cannotResize
    case cannotCreateContext
  }

  // MARK: - Feature vector & length regressor

  /// The 26 features in exact order matching the Python FEATURE_COLS.
  /// This order is critical — a mismatch produces silently wrong predictions.
  nonisolated static let featureCols: [String] = [
    // Base features (19)
    "fish_box_width",
    "fish_box_height",
    "fish_box_area",
    "fish_aspect_ratio",
    "fish_confidence",
    "person_box_height",
    "person_box_width",
    "person_aspect_ratio",
    "fish_to_person_ratio",
    "species_index",
    "species_confidence",
    "diagonal_fraction",
    "hand_detected",
    "finger_width_px",
    "finger_length_px",
    "ppi_from_finger",
    "fish_to_finger_width",
    "fish_to_finger_length",
    "fish_inches_from_finger",
    // Engineered features (7)
    "fish_pixel_length",
    "pixel_length_to_person",
    "fish_w_to_person_h",
    "fish_h_to_person_h",
    "fish_area_to_person_h_sq",
    "fish_w_to_person_w",
    "fish_area_to_person_w_sq",
  ]

  /// All 26 features for the length regressor, in FEATURE_COLS order. Codable for upload to Supabase.
  nonisolated struct LengthFeatureVector: Codable {
    // Base features
    let fishBoxWidth: Double
    let fishBoxHeight: Double
    let fishBoxArea: Double
    let fishAspectRatio: Double
    let fishConfidence: Double
    let personBoxHeight: Double
    let personBoxWidth: Double
    let personAspectRatio: Double
    let fishToPersonRatio: Double
    var speciesIndex: Double
    let speciesConfidence: Double
    let diagonalFraction: Double
    let handDetected: Double
    let fingerWidthPx: Double
    let fingerLengthPx: Double
    let ppiFromFinger: Double
    let fishToFingerWidth: Double
    let fishToFingerLength: Double
    let fishInchesFromFinger: Double
    // Engineered features
    let fishPixelLength: Double
    let pixelLengthToPerson: Double
    let fishWToPersonH: Double
    let fishHToPersonH: Double
    let fishAreaToPersonHSq: Double
    let fishWToPersonW: Double
    let fishAreaToPersonWSq: Double

    /// Returns values as a Double array in FEATURE_COLS order.
    var asArray: [Double] {
      [
        fishBoxWidth, fishBoxHeight, fishBoxArea, fishAspectRatio, fishConfidence,
        personBoxHeight, personBoxWidth, personAspectRatio, fishToPersonRatio,
        speciesIndex, speciesConfidence, diagonalFraction,
        handDetected, fingerWidthPx, fingerLengthPx, ppiFromFinger,
        fishToFingerWidth, fishToFingerLength, fishInchesFromFinger,
        fishPixelLength, pixelLengthToPerson,
        fishWToPersonH, fishHToPersonH, fishAreaToPersonHSq,
        fishWToPersonW, fishAreaToPersonWSq,
      ]
    }
  }

  /// Builds the 26-feature vector from detection results.
  /// Matches Python `compute_features()` + `add_engineered_features()` exactly.
  private func buildFeatureVector(
    fishBox: NormalizedBox,
    personBox: NormalizedBox?,
    speciesIndex: Int,
    speciesConfidence: Float,
    hand: HandMeasurement?,
    imageSize: CGSize
  ) -> LengthFeatureVector {
    let imgSize: Double = 640.0 // YOLO model input size

    let fw = Double(fishBox.width)
    let fh = Double(fishBox.height)
    let fishArea = fw * fh

    // Person features (zero if no person detected)
    let pH = personBox.map { Double($0.height) } ?? 0.0
    let pW = personBox.map { Double($0.width) } ?? 0.0
    let personAR = pW / max(pH, 1.0)
    let fishToPersonR = personBox != nil ? max(fw, fh) / pH : 0.0

    // Diagonal fraction
    let diagonal = sqrt(fw * fw + fh * fh)
    let frameDiagonal = sqrt(imgSize * imgSize + imgSize * imgSize)
    let diagFraction = diagonal / frameDiagonal

    // Hand features (zero if no hand detected)
    let handDet: Double = hand != nil ? 1.0 : 0.0
    let fwPx = Double(hand?.fingerWidthPx ?? 0)
    let flPx = Double(hand?.fingerLengthPx ?? 0)
    let ppi = fwPx > 0 ? fwPx / 0.85 : 0.0

    // Fish pixel length in original image space (for finger-based ratios)
    let origW = Double(imageSize.width)
    let origH = Double(imageSize.height)
    let fishPixelOrig = max(fw / (imgSize / origW), fh / (imgSize / origH))
    let fishToFingerW = fwPx > 0 ? fishPixelOrig / fwPx : 0.0
    let fishToFingerL = flPx > 0 ? fishPixelOrig / flPx : 0.0
    let fishInchesFromF = ppi > 0 ? fishPixelOrig / ppi : 0.0

    // Engineered features
    let fishPixelLength = max(fw, fh)
    let clampedPH = max(pH, 1.0)
    let clampedPW = max(pW, 1.0)

    return LengthFeatureVector(
      fishBoxWidth: fw,
      fishBoxHeight: fh,
      fishBoxArea: fishArea,
      fishAspectRatio: fw / max(fh, 1.0),
      fishConfidence: Double(fishBox.confidence),
      personBoxHeight: pH,
      personBoxWidth: pW,
      personAspectRatio: personAR,
      fishToPersonRatio: fishToPersonR,
      speciesIndex: Double(speciesIndex),
      speciesConfidence: Double(speciesConfidence),
      diagonalFraction: diagFraction,
      handDetected: handDet,
      fingerWidthPx: fwPx,
      fingerLengthPx: flPx,
      ppiFromFinger: ppi,
      fishToFingerWidth: fishToFingerW,
      fishToFingerLength: fishToFingerL,
      fishInchesFromFinger: fishInchesFromF,
      fishPixelLength: fishPixelLength,
      pixelLengthToPerson: fishPixelLength / clampedPH,
      fishWToPersonH: fw / clampedPH,
      fishHToPersonH: fh / clampedPH,
      fishAreaToPersonHSq: fishArea / (clampedPH * clampedPH),
      fishWToPersonW: fw / clampedPW,
      fishAreaToPersonWSq: fishArea / (clampedPW * clampedPW)
    )
  }

  /// Cached length regressor model
  private static var _lengthRegressor: MLModel?
  /// Cached model version string read from CoreML metadata
  private static var _lengthRegressorVersion: String?

  /// Runs the LengthRegressor CoreML model on a feature vector.
  /// Returns predicted length in inches, or nil on failure.
  private func predictLength(from features: LengthFeatureVector) -> Double? {
    // Lazy-load the model
    if CatchPhotoAnalyzer._lengthRegressor == nil {
      guard let url = Bundle.main.url(forResource: "LengthRegressor", withExtension: "mlmodelc") else {
        AppLogging.log("predictLength: LengthRegressor.mlmodelc not found in bundle", level: .error, category: .ml)
        return nil
      }
      let model = try? MLModel(contentsOf: url)
      CatchPhotoAnalyzer._lengthRegressor = model
      // Extract version from model metadata (set during training via coremltools)
      let metadata = model?.modelDescription.metadata
      let version = (metadata?[.versionString] as? String)
        ?? (metadata?[.description] as? String)
        ?? "unknown"
      CatchPhotoAnalyzer._lengthRegressorVersion = version
      AppLogging.log("LengthRegressor loaded, model version: \(version)", level: .info, category: .ml)
    }

    guard let model = CatchPhotoAnalyzer._lengthRegressor else {
      AppLogging.log("predictLength: failed to load LengthRegressor model", level: .error, category: .ml)
      return nil
    }

    // Build MLDictionaryFeatureProvider with named Double inputs
    let values = features.asArray
    var featureDict: [String: MLFeatureValue] = [:]
    for (i, name) in Self.featureCols.enumerated() {
      featureDict[name] = MLFeatureValue(double: values[i])
    }

    guard let provider = try? MLDictionaryFeatureProvider(dictionary: featureDict) else {
      AppLogging.log("predictLength: failed to create feature provider", level: .error, category: .ml)
      return nil
    }

    guard let output = try? model.prediction(from: provider) else {
      AppLogging.log("predictLength: model prediction failed", level: .error, category: .ml)
      return nil
    }

    guard let lengthValue = output.featureValue(for: "length_inches") else {
      AppLogging.log("predictLength: output missing 'length_inches' feature", level: .error, category: .ml)
      return nil
    }

    let predicted = lengthValue.doubleValue
    let ver = CatchPhotoAnalyzer._lengthRegressorVersion ?? "unknown"
    AppLogging.log({ "predictLength: predicted \(predicted) inches (model version: \(ver))" }, level: .info, category: .ml)
    return predicted
  }

  // MARK: - Confidence estimation

  struct ConfidenceEstimate {
    let score: Double   // 0.0–1.0
    let label: String   // "High", "Medium", "Low"
    let reasoning: String
  }

  /// Heuristic confidence score based on which scale signals the model had available.
  /// This doesn't reflect the model's internal certainty — it scores input quality.
  static func estimateConfidence(from fv: LengthFeatureVector) -> ConfidenceEstimate {
    var score: Double = 0.0
    var factors: [String] = []

    // Fish detection quality (0–25 pts)
    let fishConf = Double(fv.fishConfidence)
    if fishConf >= 0.7 {
      score += 0.25
      factors.append("strong fish detection (\(String(format: "%.0f", fishConf * 100))%)")
    } else if fishConf >= 0.4 {
      score += 0.15
      factors.append("moderate fish detection (\(String(format: "%.0f", fishConf * 100))%)")
    } else {
      score += 0.05
      factors.append("weak fish detection (\(String(format: "%.0f", fishConf * 100))%)")
    }

    // Person reference — primary scale signal (0–35 pts)
    if fv.personBoxHeight > 0 {
      // Person detected: score based on fish-to-person ratio plausibility
      let ratio = fv.fishToPersonRatio
      if ratio > 0.1 && ratio < 1.5 {
        score += 0.35
        factors.append("person reference (ratio \(String(format: "%.2f", ratio)))")
      } else {
        score += 0.15
        factors.append("person detected but unusual ratio (\(String(format: "%.2f", ratio)))")
      }
    } else {
      factors.append("no person reference")
    }

    // Hand/finger reference — secondary scale signal (0–25 pts)
    if fv.handDetected > 0 {
      let ppi = fv.ppiFromFinger
      if ppi > 20 && ppi < 200 {
        score += 0.25
        factors.append("hand calibration (ppi=\(String(format: "%.0f", ppi)))")
      } else {
        score += 0.10
        factors.append("hand detected but unusual ppi (\(String(format: "%.0f", ppi)))")
      }
    } else {
      factors.append("no hand reference")
    }

    // Species confidence (0–10 pts)
    let specConf = Double(fv.speciesConfidence)
    if specConf >= 0.7 {
      score += 0.10
      factors.append("confident species ID")
    } else if specConf >= 0.4 {
      score += 0.05
      factors.append("uncertain species ID")
    }

    // Image composition (0–5 pts)
    if fv.diagonalFraction > 0.15 && fv.diagonalFraction < 0.7 {
      score += 0.05
      factors.append("good framing")
    }

    let label: String
    switch score {
    case 0.70...: label = "High"
    case 0.45...: label = "Medium"
    default:      label = "Low"
    }

    return ConfidenceEstimate(
      score: min(score, 1.0),
      label: label,
      reasoning: factors.joined(separator: ", ")
    )
  }

  // MARK: - Detector helpers (YOLOv8 → length)

  private struct NormalizedBox {
    let xCenter: CGFloat // pixels in 640×640 coordinate space
    let yCenter: CGFloat // pixels in 640×640 coordinate space
    let width: CGFloat   // pixels in 640×640 coordinate space
    let height: CGFloat  // pixels in 640×640 coordinate space
    let confidence: Float
  }

  /// Result from YOLO detector containing the best fish and person boxes.
  private struct DetectionResult {
    let fishBox: NormalizedBox?
    let personBox: NormalizedBox?
  }
    
    /// Runs the YOLOv8 detector and returns the highest-confidence fish and person boxes.
    /// Handles both [1, C, A] and [1, A, C] output layouts (C = 4 + numClasses, A = anchors).
    private func runDetector(on image: UIImage) -> DetectionResult {
      guard let cgImage = image.cgImage else {
        AppLogging.log("runDetector: could not get CGImage from UIImage", level: .error, category: .ml)
        return DetectionResult(fishBox: nil, personBox: nil)
      }

      // YOLOv8 CoreML export expects 640×640
      let inputSize = CGSize(width: 640, height: 640)

      guard let pixelBuffer = cgImage.toPixelBuffer(targetSize: inputSize) else {
        AppLogging.log("runDetector: failed to create pixel buffer", level: .error, category: .ml)
        return DetectionResult(fishBox: nil, personBox: nil)
      }

      guard let output = try? detectorModel?.prediction(image: pixelBuffer) else {
        AppLogging.log("runDetector: model prediction failed", level: .error, category: .ml)
        return DetectionResult(fishBox: nil, personBox: nil)
      }

      let arr = output.var_913

      guard arr.shape.count == 3,
            arr.shape[0].intValue == 1 else {
        AppLogging.log({ "runDetector: unexpected output shape \(arr.shape)" }, level: .error, category: .ml)
        return DetectionResult(fishBox: nil, personBox: nil)
      }

      let dim1 = arr.shape[1].intValue
      let dim2 = arr.shape[2].intValue

      // Decide which axis is channels (small) vs anchors (large, ~8400)
      let channels: Int
      let numAnchors: Int
      let channelsOnSecondAxis: Bool

      if dim1 <= dim2 {
        // Layout: [1, C, A]
        channels = dim1
        numAnchors = dim2
        channelsOnSecondAxis = true
      } else {
        // Layout: [1, A, C]
        channels = dim2
        numAnchors = dim1
        channelsOnSecondAxis = false
      }

      guard channels > 4 else {
        AppLogging.log({ "runDetector: not enough channels (\(channels)) for xywh+classes" }, level: .error, category: .ml)
        return DetectionResult(fishBox: nil, personBox: nil)
      }

      let numClasses = channels - 4

      // Helper closure to read arr[0, channel, anchor] or arr[0, anchor, channel]
      // Uses direct index math instead of allocating [NSNumber] arrays (~16K times).
      let read: (_ channelIndex: Int, _ anchorIndex: Int) -> Double
      let rawPtr = arr.dataPointer
      if arr.dataType == .float32 {
        let fp32 = rawPtr.bindMemory(to: Float32.self, capacity: channels * numAnchors)
        read = { ch, an in
          let i = channelsOnSecondAxis ? ch * numAnchors + an : an * channels + ch
          return Double(fp32[i])
        }
      } else {
        let fp64 = rawPtr.bindMemory(to: Float64.self, capacity: channels * numAnchors)
        read = { ch, an in
          let i = channelsOnSecondAxis ? ch * numAnchors + an : an * channels + ch
          return fp64[i]
        }
      }

      AppLogging.log({ "runDetector: output shape=\(arr.shape), channels=\(channels), anchors=\(numAnchors), channelsOnSecondAxis=\(channelsOnSecondAxis)" }, level: .debug, category: .ml)

      // data.yaml: names: ['fish', 'person'] → fish = class 0, person = class 1
      let fishClassIndex = 0
      let personClassIndex = 1

      // Threshold for our "good" candidate (geometry-filtered)
      let minPrimaryConfidence: Float = AppEnvironment.shared.fishDetectMinConfidence

      // Geometry thresholds
      let imgW: CGFloat = 640.0
      let imgH: CGFloat = 640.0
      let minAspect: CGFloat = 1.0        // width / height; allow closer to square
      let maxHeightFraction: CGFloat = 0.9 // allow tall boxes
      let maxAreaFraction: CGFloat = 0.8   // allow large area

      // Best fish box that passes geometry filters + primary threshold
      var bestBox: NormalizedBox?
      var bestConf: Float = 0.0

      // Best raw fish candidate (ignores geometry filters and threshold)
      var bestRawFishBox: NormalizedBox?
      var bestRawFishConf: Float = 0.0

      // Best person box (highest confidence, no geometry filters needed)
      var bestPersonBox: NormalizedBox?
      var bestPersonConf: Float = 0.0

      for i in 0 ..< numAnchors {
        // 1) Find best class & score for this anchor
        var bestClassIdx = -1
        var bestClassScore: Float = 0.0

        for c in 0 ..< numClasses {
          let score = Float(read(4 + c, i))
          if score > bestClassScore {
            bestClassScore = score
            bestClassIdx = c
          }
        }

        // Track person box (class 1) — highest confidence, no geometry filters
        if bestClassIdx == personClassIndex, bestClassScore > bestPersonConf {
          let xRaw = CGFloat(read(0, i))
          let yRaw = CGFloat(read(1, i))
          let wRaw = CGFloat(read(2, i))
          let hRaw = CGFloat(read(3, i))

          bestPersonConf = bestClassScore
          bestPersonBox = NormalizedBox(
            xCenter: xRaw,
            yCenter: yRaw,
            width: wRaw,
            height: hRaw,
            confidence: bestClassScore
          )
        }

        // If this anchor's best class is fish, ALWAYS consider it for the raw fallback
        if bestClassIdx == fishClassIndex {
          if bestClassScore > bestRawFishConf {
            bestRawFishConf = bestClassScore

            let xRaw = CGFloat(read(0, i))
            let yRaw = CGFloat(read(1, i))
            let wRaw = CGFloat(read(2, i))
            let hRaw = CGFloat(read(3, i))

            bestRawFishBox = NormalizedBox(
              xCenter: xRaw,
              yCenter: yRaw,
              width: wRaw,
              height: hRaw,
              confidence: bestClassScore
            )
          }
        } else {
          // Best class not fish or person → skip primary fish candidate path
          continue
        }

        // For the primary (filtered) candidate, also require a minimum confidence
        guard bestClassScore >= minPrimaryConfidence else { continue }

        // 3) Read box geometry for filtered path
        let x = CGFloat(read(0, i))
        let y = CGFloat(read(1, i))
        let w = CGFloat(read(2, i))
        let h = CGFloat(read(3, i))

        // 4) Geometry filters
        let aspect = w / max(h, 1.0)
        let hFrac = h / imgH
        let areaFrac = (w * h) / (imgW * imgH)

        if aspect < minAspect { continue }
        if hFrac > maxHeightFraction { continue }
        if areaFrac > maxAreaFraction { continue }

        let box = NormalizedBox(
          xCenter: x,
          yCenter: y,
          width: w,
          height: h,
          confidence: bestClassScore
        )

        if bestClassScore > bestConf {
          bestConf = bestClassScore
          bestBox = box
        }
      }

      // Log person detection result
      if let person = bestPersonBox {
        AppLogging.log({ "runDetector: best person conf = \(person.confidence), x=\(person.xCenter), y=\(person.yCenter), w=\(person.width), h=\(person.height)" }, level: .info, category: .ml)
      }

      // Resolve fish box: prefer geometry-filtered, then raw fallback
      let resolvedFishBox: NormalizedBox?

      if let best = bestBox {
        AppLogging.log({ "runDetector: best fish (filtered) conf = \(best.confidence), x=\(best.xCenter), y=\(best.yCenter), w = \(best.width), h = \(best.height)" }, level: .info, category: .ml)
        resolvedFishBox = best
      } else if let fallback = bestRawFishBox, fallback.confidence >= 0.01 {
        AppLogging.log({ "runDetector: using raw fish box without geometry filters, conf = \(fallback.confidence), w = \(fallback.width), h = \(fallback.height)" }, level: .warn, category: .ml)
        resolvedFishBox = fallback
      } else {
        if let fallback = bestRawFishBox {
          AppLogging.log({ "runDetector: best fish candidate too low-confidence (conf=\(fallback.confidence)); treating as no detection." }, level: .warn, category: .ml)
        } else {
          AppLogging.log("runDetector: no fish boxes at all (model never preferred fish for any anchor).", level: .warn, category: .ml)
        }
        resolvedFishBox = nil
      }

      return DetectionResult(fishBox: resolvedFishBox, personBox: bestPersonBox)
    }

  // MARK: - Species length ranges (min/max in inches)

  /// Known length ranges per species for heuristic rescaling.
  /// Add new species here as they are calibrated.
  static let speciesLengthRanges: [String: (min: Double, max: Double)] = [
    "brown_trout":         (min: 8,  max: 30),
    "lingcod":             (min: 18, max: 60),
    "musky":               (min: 24, max: 60),
    "rainbow_trout":       (min: 8,  max: 30),
    "sea_run_trout":       (min: 8,  max: 30),
    "steelhead_holding":   (min: 24, max: 42),
    "steelhead_traveler":  (min: 24, max: 42),
  ]

  /// Turn the best detected box into a rough length estimate.
  /// When `speciesLabel` is provided and the species has a known range,
  /// the raw heuristic output is rescaled into that range. `atSpeciesCap`
  /// is true when the raw input exceeded the global heuristic envelope and
  /// the value clamped to the species' max — surfaced as "+" in the display.
  private func estimateLength(
    from box: NormalizedBox,
    imageSize: CGSize,
    speciesLabel: String? = nil
  ) -> (inches: Double, display: String, atSpeciesCap: Bool) {
    // YOLOv8 export is giving us pixel coordinates in 640×640 space.
    // Use the *long side* of the box as a proxy for fish length.
    var pixelLength = max(box.width, box.height)

    // Diagonal-fraction correction: a tight close-up (high diagFrac) means the
    // photographer was close, so the pixel-length over-represents the fish's
    // real size; a wide shot (low diagFrac) means the opposite. Compute in the
    // YOLO 640×640 space so it matches buildFeatureVector's diagonalFraction.
    // Strength 0 disables the correction (env-tunable).
    let env = AppEnvironment.shared
    let frameDiagonal: CGFloat = sqrt(640 * 640 + 640 * 640)
    let fishDiagonal = sqrt(box.width * box.width + box.height * box.height)
    let diagFrac = fishDiagonal / frameDiagonal
    let strength = CGFloat(env.heuristicDiagFracStrength)
    let diagAdjustment = 1.0 + strength * (0.5 - diagFrac)
    pixelLength *= diagAdjustment

    // Scale down boxes (training data has boxes around person+fish, not just fish)
    pixelLength *= env.fishBoxScaleFactor

    // Heuristic: pixels per inch in the 640×640 model space
    let pixelsPerInch: CGFloat = env.fishPixelsPerInch
    let rawInches = Double(pixelLength / pixelsPerInch)

    AppLogging.log({
      "estimateLength: w=\(box.width), h=\(box.height), diagFrac=\(String(format: "%.3f", diagFrac)), " +
      "diagAdj=\(String(format: "%.3f", diagAdjustment)), pixelLength=\(pixelLength), rawInches=\(rawInches)"
    }, level: .debug, category: .ml)

    // If species has a known range, rescale the raw heuristic into that range
    if let species = speciesLabel,
       let range = Self.speciesLengthRanges[species] {

      // Steelhead heuristic range (what the raw heuristic was calibrated for)
      let heuristicMin = env.fishMinLengthInches
      let heuristicMax = env.fishMaxLengthInches

      // Normalize raw inches to 0..1 within the steelhead heuristic range
      let unclamped = (rawInches - heuristicMin) / (heuristicMax - heuristicMin)
      let fraction = min(1.0, max(0.0, unclamped))

      // Map into the species-specific range
      let scaled = range.min + fraction * (range.max - range.min)
      let atCap = unclamped >= 1.0

      AppLogging.log({
        "estimateLength (species-scaled): raw=\(String(format: "%.1f", rawInches))\" " +
        "-> fraction=\(String(format: "%.2f", fraction)) " +
        "-> \(species) range [\(Int(range.min))-\(Int(range.max))] " +
        "-> scaled=\(String(format: "%.1f", scaled))\"" +
        (atCap ? " [AT SPECIES CAP]" : "")
      }, level: .debug, category: .ml)

      // At-cap fish exceed the model's representable upper bound — surface
      // as "<max>+ inches" rather than a misleading low–high range that would
      // imply both sides are bounded.
      let display: String
      if atCap {
        display = String(format: "%.0f+ inches (photo estimate)", range.max)
      } else {
        let low = (scaled * env.fishEstimateLowFactor).rounded()
        let high = (scaled * env.fishEstimateHighFactor).rounded()
        display = String(format: "%.0f–%.0f inches (photo estimate)", low, high)
      }
      return (inches: scaled, display: display, atSpeciesCap: atCap)
    }

    // Default: clamp to steelhead range (original behavior)
    let clamped = max(env.fishMinLengthInches, min(rawInches, env.fishMaxLengthInches))

    let low = clamped * env.fishEstimateLowFactor
    let high = clamped * env.fishEstimateHighFactor

    let display = String(
      format: "%.0f–%.0f inches (photo estimate)",
      low.rounded(),
      high.rounded()
    )

    return (inches: clamped, display: display, atSpeciesCap: false)
  }

  // MARK: - Species-corrected length re-estimation

  /// Result of re-estimating length after species correction.
  struct LengthReEstimate {
    let lengthInches: Double?
    let source: LengthEstimateSource
    /// True when the species-scaled heuristic clamped at the species' max
    /// length range (raw input was >= the global heuristic envelope ceiling).
    /// Surfaced as a "+" suffix in the formatted length to signal that the
    /// fish may exceed the model's representable upper bound.
    let atSpeciesCap: Bool
  }

  /// Maps user-facing species names (+ optional lifecycle stage) to model labels.
  /// Used when re-estimating length after the researcher corrects species.
  ///
  /// Every value MUST exist in `speciesLabels`. Keys MUST cover every entry in
  /// `CatchChatViewModel.speciesDisplayNames` — otherwise a corrected species
  /// silently falls through to `speciesIdx=0` and the regressor runs with the
  /// wrong species feature. Keep all three (`speciesLabels`,
  /// `speciesDisplayNames`, this map) in lockstep — see `/new-species`.
  static let speciesDisplayToLabel: [String: String] = [
    // Lifecycle-split species — default to _holding; reEstimateLength will
    // upgrade to _traveler when the stage parameter is supplied.
    "steelhead":       "steelhead_holding",
    "atlantic salmon": "atlantic_salmon_holding",
    // Single-label species
    "rainbow trout":   "rainbow_trout",
    "brown trout":     "brown_trout",
    "chinook salmon":  "chinook_salmon",
    "sea-run trout":   "sea_run_trout",
    "sea run trout":   "sea_run_trout",
    "lingcod":         "lingcod",
    "musky":           "musky",
    "bi-catch":        "other",
  ]

  /// Maps model labels to their species index in the `speciesLabels` array.
  private func speciesLabelToIndex(_ label: String) -> Int? {
    Self.speciesLabels.firstIndex(of: label)
  }

  /// Re-estimate length using the original feature vector but with a corrected species.
  /// Called when the researcher changes species during the identification step,
  /// because the regressor uses species index as an input feature, and some species
  /// bypass the regressor entirely (e.g. sea_run_trout uses heuristic only).
  ///
  /// - Parameters:
  ///   - originalFV: The feature vector from the initial ML analysis
  ///   - correctedSpecies: The user-confirmed species display name (e.g. "Steelhead")
  ///   - correctedLifecycleStage: Optional lifecycle stage (e.g. "Holding", "Traveler")
  /// - Returns: Re-estimated length and source, or nil length if estimation fails
  func reEstimateLength(
    originalFV: LengthFeatureVector,
    correctedSpecies: String?,
    correctedLifecycleStage: String?
  ) -> LengthReEstimate {
    guard let species = correctedSpecies else {
      return LengthReEstimate(lengthInches: nil, source: .heuristic, atSpeciesCap: false)
    }

    // Build the model label from species + lifecycle stage
    let lowerSpecies = species.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    let lowerStage = correctedLifecycleStage?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

    // Try direct lookup first (e.g. "steelhead" -> "steelhead_holding")
    var modelLabel = Self.speciesDisplayToLabel[lowerSpecies]

    // If we have a lifecycle stage, try species_stage combination
    if let stage = lowerStage, !stage.isEmpty {
      let combined = "\(lowerSpecies.replacingOccurrences(of: " ", with: "_"))_\(stage)"
      if Self.speciesLabels.contains(combined) {
        modelLabel = combined
      }
    }

    // Resolve species index
    let speciesIdx: Int
    let labelResolved: Bool
    if let label = modelLabel, let idx = speciesLabelToIndex(label) {
      speciesIdx = idx
      labelResolved = true
    } else {
      // Couldn't map the corrected species to a known model label.
      // Force-skip the regressor — running it with speciesIdx=0 silently
      // produces a wrong-distribution prediction. Heuristic falls through
      // to the default clamp when resolvedLabel isn't in speciesLengthRanges.
      speciesIdx = 0
      labelResolved = false
      AppLogging.log({
        "reEstimateLength: could not resolve '\(species)' to a known model label — using heuristic"
      }, level: .warn, category: .ml)
    }

    let resolvedLabel = modelLabel ?? "unknown"
    AppLogging.log({
      "reEstimateLength: corrected species=\(species), stage=\(correctedLifecycleStage ?? "nil"), " +
      "resolved label=\(resolvedLabel), index=\(speciesIdx)"
    }, level: .info, category: .ml)

    let useRegressor = labelResolved && !Self.regressorBypassSpecies.contains(resolvedLabel)

    // Build updated feature vector with corrected species index
    var updatedFV = originalFV
    updatedFV.speciesIndex = Double(speciesIdx)

    if useRegressor, AppEnvironment.shared.useLengthRegressor,
       let predicted = predictLength(from: updatedFV) {
      let clamped = max(
        AppEnvironment.shared.fishMinLengthInches,
        min(predicted, AppEnvironment.shared.fishMaxLengthInches)
      )
      AppLogging.log({
        "reEstimateLength: regressor predicted=\(String(format: "%.1f", predicted)), " +
        "clamped=\(String(format: "%.1f", clamped)) for \(resolvedLabel)"
      }, level: .info, category: .ml)
      return LengthReEstimate(lengthInches: clamped, source: .regressor, atSpeciesCap: false)
    }

    // Fallback to species-scaled heuristic
    // Reconstruct fish box dimensions from feature vector (in 640x640 model space)
    let fw = originalFV.fishBoxWidth
    let fh = originalFV.fishBoxHeight
    var pixelLength = max(fw, fh)

    let env = AppEnvironment.shared

    // Apply the same diagFrac correction the initial heuristic uses, so post-
    // correction estimates don't diverge from the initial estimate for the
    // same photo. diagonalFraction was computed in buildFeatureVector.
    let strength = Double(env.heuristicDiagFracStrength)
    let diagAdjustment = 1.0 + strength * (0.5 - originalFV.diagonalFraction)
    pixelLength *= diagAdjustment

    let scaledPixelLength = pixelLength * env.fishBoxScaleFactor
    let rawInches = scaledPixelLength / env.fishPixelsPerInch

    // Check for species-specific range
    if let range = Self.speciesLengthRanges[resolvedLabel] {
      let heuristicMin = env.fishMinLengthInches
      let heuristicMax = env.fishMaxLengthInches
      let unclamped = (rawInches - heuristicMin) / (heuristicMax - heuristicMin)
      let fraction = min(1.0, max(0.0, unclamped))
      let scaled = range.min + fraction * (range.max - range.min)
      let atCap = unclamped >= 1.0

      AppLogging.log({
        "reEstimateLength: heuristic species-scaled for \(resolvedLabel), " +
        "raw=\(String(format: "%.1f", rawInches)), scaled=\(String(format: "%.1f", scaled))" +
        (atCap ? " [AT SPECIES CAP]" : "")
      }, level: .info, category: .ml)
      return LengthReEstimate(lengthInches: scaled, source: .heuristic, atSpeciesCap: atCap)
    }

    // Default heuristic (steelhead range)
    let clamped = max(env.fishMinLengthInches, min(rawInches, env.fishMaxLengthInches))
    AppLogging.log({
      "reEstimateLength: heuristic default, raw=\(String(format: "%.1f", rawInches)), " +
      "clamped=\(String(format: "%.1f", clamped))"
    }, level: .info, category: .ml)
    return LengthReEstimate(lengthInches: clamped, source: .heuristic, atSpeciesCap: false)
  }
}

// MARK: - MLFeatureProvider wrapper for ViT input (species)

private final class ViTInputFeatureProvider: MLFeatureProvider {
  private let imageArray: MLMultiArray

  init(imageArray: MLMultiArray) {
    self.imageArray = imageArray
  }

  var featureNames: Set<String> {
    ["image"]
  }

  func featureValue(for featureName: String) -> MLFeatureValue? {
    if featureName == "image" {
      return MLFeatureValue(multiArray: imageArray)
    }
    return nil
  }
}

// MARK: - Helpers at file scope

private extension MLMultiArray {
  subscript(_ i: Int, _ j: Int, _ k: Int) -> Double {
    let idx: [NSNumber] = [
      NSNumber(value: i),
      NSNumber(value: j),
      NSNumber(value: k)
    ]
    return self[idx].doubleValue
  }
}

private extension CGImage {
  func toPixelBuffer(targetSize: CGSize) -> CVPixelBuffer? {
    let attrs: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]

    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      Int(targetSize.width),
      Int(targetSize.height),
      kCVPixelFormatType_32BGRA,
      attrs as CFDictionary,
      &pixelBuffer
    )

    guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(pb, [])
    guard let context = CGContext(
      data: CVPixelBufferGetBaseAddress(pb),
      width: Int(targetSize.width),
      height: Int(targetSize.height),
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    ) else {
      CVPixelBufferUnlockBaseAddress(pb, [])
      return nil
    }

    context.draw(self, in: CGRect(origin: .zero, size: targetSize))
    CVPixelBufferUnlockBaseAddress(pb, [])

    return pb
  }
}
