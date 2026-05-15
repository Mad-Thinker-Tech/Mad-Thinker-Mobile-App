import UIKit
import CoreLocation
import ImageIO
import CoreServices

/// A photo plus any EXIF-derived metadata we care about.
struct PickedPhoto {
  let image: UIImage
  let exifDate: Date?
  let exifLocation: CLLocation?
  /// Camera capture settings parsed from the source file's EXIF when
  /// available. Best-effort: nil on the PHPicker fast path (no source Data)
  /// or when the user picked a photo that doesn't carry EXIF (synthesized
  /// images, third-party screenshots, etc.). The analyzer copies these into
  /// `MLDiagnostics.exif*` slots for retraining provenance.
  let cameraMetadata: CapturedCameraMetadata?

  init(
    image: UIImage,
    exifDate: Date? = nil,
    exifLocation: CLLocation? = nil,
    cameraMetadata: CapturedCameraMetadata? = nil
  ) {
    self.image = image
    self.exifDate = exifDate
    self.exifLocation = exifLocation
    self.cameraMetadata = cameraMetadata
  }
}

/// Photo capture settings extracted from an image source's EXIF metadata.
/// Lives alongside `PickedPhoto` so the photo intake layer doesn't need to
/// pull in the ML model. `CatchPhotoAnalyzer.analyze` copies these into
/// `MLDiagnostics` at the end of the pipeline.
struct CapturedCameraMetadata: Equatable {
  /// EXIF `Flash` tag bit 0 — true when the flash actually fired.
  var flashFired: Bool?
  /// EXIF `ISOSpeedRatings` (or `PhotographicSensitivity`).
  var iso: Int?
  /// EXIF `ExposureTime` in seconds (e.g. 1/250 → 0.004).
  var exposureSeconds: Double?
  /// EXIF `FNumber` (aperture).
  var fNumber: Double?
  /// EXIF `FocalLength` in mm.
  var focalLengthMm: Double?
  /// EXIF `FocalLenIn35mmFilm` — 35mm-equivalent focal length.
  var focalLength35mm: Double?
  /// EXIF `LensModel` (string identifier of the lens used).
  var lensModel: String?

  /// All fields nil → considered absent; callers should check this before
  /// attaching the struct (or pass nil instead). Avoids shipping
  /// `cameraMetadata: { ... all-null ... }` blobs server-side.
  var isEmpty: Bool {
    flashFired == nil && iso == nil && exposureSeconds == nil &&
      fNumber == nil && focalLengthMm == nil &&
      focalLength35mm == nil && lensModel == nil
  }

  // MARK: - Parsing

  /// Parse from raw image `Data` (HEIC / JPEG / etc). Uses `CGImageSource`
  /// to read the EXIF dictionary without decoding the pixel buffer — cheap.
  /// Returns nil when the source has no EXIF or fails to open.
  static func parse(from data: Data) -> CapturedCameraMetadata? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return nil
    }
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
      return nil
    }
    return parseProperties(props)
  }

  /// Parse from `UIImagePickerController.InfoKey.mediaMetadata` (the camera
  /// capture path delivers this as a plain `[String: Any]`). Top-level keys
  /// are stringified `kCGImagePropertyExif*` constants; converts to the
  /// `[CFString: Any]` shape `parseProperties` expects.
  static func parse(from mediaMetadata: [String: Any]) -> CapturedCameraMetadata? {
    // The camera info dict uses CFString keys bridged to NSString — Swift
    // exposes them as String keys. Re-key into the CFString shape we share
    // with the CGImageSource path so the property reader is single-source.
    let bridged = mediaMetadata.reduce(into: [CFString: Any]()) { result, pair in
      result[pair.key as CFString] = pair.value
    }
    return parseProperties(bridged)
  }

  // MARK: - Internals

  /// Reads EXIF + image properties out of a CGImageSource-style property
  /// dictionary. Top-level holds `kCGImagePropertyExifDictionary` plus a
  /// few orientation/density keys; the EXIF dict holds the per-shot
  /// settings we care about. Unknown keys are ignored.
  private static func parseProperties(_ props: [CFString: Any]) -> CapturedCameraMetadata? {
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

    let iso: Int? = {
      // Newer files use PhotographicSensitivity; legacy uses ISOSpeedRatings (array).
      if let v = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = v.first {
        return first
      }
      if let v = exif["PhotographicSensitivity" as CFString] as? Int {
        return v
      }
      return nil
    }()

    let flashFired: Bool? = {
      guard let raw = exif[kCGImagePropertyExifFlash] as? Int else { return nil }
      // EXIF Flash tag is a bitfield; bit 0 is "Flash fired" (1 = yes).
      return (raw & 0x1) == 0x1
    }()

    let lensModel: String? = (aux[kCGImagePropertyExifAuxLensModel] as? String)
      ?? (exif["LensModel" as CFString] as? String)

    let metadata = CapturedCameraMetadata(
      flashFired: flashFired,
      iso: iso,
      exposureSeconds: exif[kCGImagePropertyExifExposureTime] as? Double,
      fNumber: exif[kCGImagePropertyExifFNumber] as? Double,
      focalLengthMm: exif[kCGImagePropertyExifFocalLength] as? Double,
      focalLength35mm: exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double,
      lensModel: lensModel
    )
    return metadata.isEmpty ? nil : metadata
  }

  /// Sunny-16 inverse: `lux ≈ (250 × N²) / (t × ISO)`. Returns nil when any
  /// of N, t, or ISO is missing — partial EXIF can't yield a meaningful
  /// scene illuminance.
  var computedLuxApprox: Double? {
    guard let n = fNumber, let t = exposureSeconds, let iso, iso > 0, t > 0 else {
      return nil
    }
    return (250.0 * n * n) / (t * Double(iso))
  }
}
