// Bend Fly Shop

import PhotosUI
import SwiftUI
import CoreLocation
import UIKit
import Photos

struct ImagePicker: UIViewControllerRepresentable {
  enum Source { case camera, library }
  let source: Source
  var onPickedPhoto: (PickedPhoto) -> Void
  /// Called on the main queue when both the fast `loadObject` path and the
  /// `PHImageManager` iCloud-download fallback fail. Lets the host view
  /// surface a toast or alert.
  var onLoadFailed: (() -> Void)? = nil

  func makeUIViewController(context: Context) -> UIViewController {
    switch source {
    case .camera:
      AppLogging.log("UIImagePickerController (camera) created", level: .debug, category: .angler)
      let vc = UIImagePickerController()
      vc.sourceType = .camera
      vc.delegate = context.coordinator
      return vc
    case .library:
      AppLogging.log("PHPickerViewController (library) created", level: .debug, category: .angler)
      var config = PHPickerConfiguration(photoLibrary: .shared())
      config.filter = .images
      let picker = PHPickerViewController(configuration: config)
      picker.delegate = context.coordinator
      return picker
    }
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate,
    PHPickerViewControllerDelegate {
    let parent: ImagePicker
    init(_ parent: ImagePicker) { self.parent = parent }

      func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
      ) {
        AppLogging.log("UIImagePicker didFinishPickingMediaWithInfo called", level: .debug, category: .angler)
        guard let image = info[.originalImage] as? UIImage else {
          AppLogging.log("UIImagePicker no original image in info; dismissing", level: .warn, category: .angler)
          picker.dismiss(animated: true)
          return
        }

        var exifDate: Date?
        var exifLocation: CLLocation?

        // If the picker gives us a PHAsset (e.g. when choosing from library), use its metadata
        if let asset = info[.phAsset] as? PHAsset {
          exifDate = asset.creationDate
          exifLocation = asset.location
        }

        // Camera-captured photos carry their EXIF settings under .mediaMetadata
        // (a NSDictionary of kCGImagePropertyExif* keys bridged to String).
        // Library picks via this controller usually don't, so this is best-
        // effort; ML diagnostics tolerate nil camera metadata cleanly.
        let cameraMetadata: CapturedCameraMetadata? = {
          guard let md = info[.mediaMetadata] as? [String: Any] else { return nil }
          return CapturedCameraMetadata.parse(from: md)
        }()

        let picked = PickedPhoto(
          image: image,
          exifDate: exifDate,
          exifLocation: exifLocation,
          cameraMetadata: cameraMetadata
        )
        AppLogging.log("UIImagePicker picked image: size=\(Int(image.size.width))x\(Int(image.size.height)), exifDate=\(exifDate != nil), exifLocation=\(exifLocation != nil), cameraMetadata=\(cameraMetadata != nil)", level: .info, category: .angler)
        parent.onPickedPhoto(picked)
        AppLogging.log("UIImagePicker calling onPickedPhoto and dismissing", level: .debug, category: .angler)
        picker.dismiss(animated: true)
      }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      AppLogging.log("UIImagePicker cancel tapped; dismissing", level: .debug, category: .angler)
      picker.dismiss(animated: true)
    }

      func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        AppLogging.log("PHPicker didFinishPicking called with results count=\(results.count)", level: .debug, category: .angler)
        guard let result = results.first else {
          AppLogging.log("PHPicker no results; dismissing", level: .debug, category: .angler)
          picker.dismiss(animated: true)
          return
        }

        let provider = result.itemProvider
        AppLogging.log("PHPicker provider registered types: \(provider.registeredTypeIdentifiers)", level: .debug, category: .angler)
        guard provider.canLoadObject(ofClass: UIImage.self) else {
          AppLogging.log("PHPicker provider cannot load UIImage; dismissing", level: .warn, category: .angler)
          picker.dismiss(animated: true)
          return
        }

        // Try to resolve the PHAsset so we can read EXIF date/location
        var asset: PHAsset?
        if let id = result.assetIdentifier {
          let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
          asset = fetchResult.firstObject
        }
        AppLogging.log("PHPicker resolved asset: \(asset != nil)", level: .debug, category: .angler)

        AppLogging.log("PHPicker starting loadObject UIImage", level: .debug, category: .angler)
        let loadStart = Date()
        provider.loadObject(ofClass: UIImage.self) { object, error in
          let elapsed = Date().timeIntervalSince(loadStart)
          if let error = error {
            AppLogging.log("PHPicker loadObject ERROR after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription) (\((error as NSError).domain) code=\((error as NSError).code))", level: .warn, category: .angler)
          }
          guard let img = object as? UIImage else {
            AppLogging.log("PHPicker loadObject returned non-UIImage after \(String(format: "%.2f", elapsed))s (object=\(object.map { String(describing: type(of: $0)) } ?? "nil")); attempting PHImageManager fallback", level: .warn, category: .angler)
            self.loadFromAssetWithICloudDownload(asset: asset)
            return
          }
          // Surface degenerate UIImage cases that would render blank: zero-size,
          // missing CGImage backing (often happens with iCloud transcode hiccups
          // or HEIC decode failures), or huge images near the memory ceiling.
          let hasCG = img.cgImage != nil
          let hasCI = img.ciImage != nil
          let pixelW = Int(img.size.width * img.scale)
          let pixelH = Int(img.size.height * img.scale)
          AppLogging.log("PHPicker loadObject succeeded after \(String(format: "%.2f", elapsed))s: size=\(Int(img.size.width))x\(Int(img.size.height)) scale=\(img.scale) pixels=\(pixelW)x\(pixelH) orient=\(img.imageOrientation.rawValue) cgImage=\(hasCG) ciImage=\(hasCI)", level: .info, category: .angler)
          if img.size.width == 0 || img.size.height == 0 {
            AppLogging.log("PHPicker WARNING: zero-size UIImage from loadObject — will render blank", level: .warn, category: .angler)
          }
          if !hasCG && !hasCI {
            AppLogging.log("PHPicker WARNING: UIImage has neither CGImage nor CIImage backing — likely render-fail", level: .warn, category: .angler)
          }

          DispatchQueue.main.async {
            AppLogging.log("PHPicker delivering picked photo to parent", level: .debug, category: .angler)
            let picked = PickedPhoto(
              image: img,
              exifDate: asset?.creationDate,
              exifLocation: asset?.location
            )
            self.parent.onPickedPhoto(picked)
          }
        }

        AppLogging.log("PHPicker dismissing picker", level: .debug, category: .angler)
        picker.dismiss(animated: true)
      }

    /// Fallback for the common "photo is in iCloud and wasn't downloaded"
    /// failure mode that surfaces as `NSItemProviderErrorDomain code=-1000`
    /// from `loadObject(ofClass: UIImage.self)`. `PHImageManager` with
    /// `isNetworkAccessAllowed = true` explicitly asks the system to fetch
    /// the original from iCloud — `NSItemProvider` does not. If we have no
    /// asset (rare — should only happen for synthesised picker results) or
    /// the request still fails (offline, asset truly broken), surface the
    /// failure via `onLoadFailed` so the host view can toast.
    private func loadFromAssetWithICloudDownload(asset: PHAsset?) {
      guard let asset = asset else {
        AppLogging.log("PHImageManager fallback unavailable: no PHAsset resolved; signalling failure", level: .warn, category: .angler)
        DispatchQueue.main.async { self.parent.onLoadFailed?() }
        return
      }

      AppLogging.log("PHImageManager fallback starting: asset=\(asset.localIdentifier) iCloudDownload=true", level: .info, category: .angler)
      let options = PHImageRequestOptions()
      options.isNetworkAccessAllowed = true
      options.deliveryMode = .highQualityFormat
      options.resizeMode = .none
      options.isSynchronous = false

      let fallbackStart = Date()
      PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
        let elapsed = Date().timeIntervalSince(fallbackStart)

        // Skip degraded intermediate results — wait for the final high-quality
        // delivery. PHImageManager may invoke the handler multiple times when
        // it has a thumbnail available before the full asset finishes downloading.
        if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded {
          AppLogging.log("PHImageManager fallback delivered degraded intermediate; waiting for final", level: .debug, category: .angler)
          return
        }

        if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
          AppLogging.log("PHImageManager fallback cancelled after \(String(format: "%.2f", elapsed))s", level: .warn, category: .angler)
          DispatchQueue.main.async { self.parent.onLoadFailed?() }
          return
        }

        if let icloudError = info?[PHImageErrorKey] as? Error {
          AppLogging.log("PHImageManager fallback ERROR after \(String(format: "%.2f", elapsed))s: \(icloudError.localizedDescription) (\((icloudError as NSError).domain) code=\((icloudError as NSError).code))", level: .warn, category: .angler)
          DispatchQueue.main.async { self.parent.onLoadFailed?() }
          return
        }

        guard let data = data, let img = UIImage(data: data) else {
          AppLogging.log("PHImageManager fallback returned no usable data after \(String(format: "%.2f", elapsed))s (dataBytes=\(data?.count ?? 0))", level: .warn, category: .angler)
          DispatchQueue.main.async { self.parent.onLoadFailed?() }
          return
        }

        // Parse EXIF camera metadata off the raw bytes BEFORE handing the
        // image to the host view — this is the only intake path with native
        // Data access, so it's our best chance to capture flash/ISO/focal
        // length / lens model for ML diagnostics. Cheap (no pixel decode).
        let cameraMetadata = CapturedCameraMetadata.parse(from: data)

        AppLogging.log("PHImageManager fallback SUCCESS after \(String(format: "%.2f", elapsed))s: size=\(Int(img.size.width))x\(Int(img.size.height)) bytes=\(data.count) cgImage=\(img.cgImage != nil) cameraMetadata=\(cameraMetadata != nil)", level: .info, category: .angler)
        DispatchQueue.main.async {
          let picked = PickedPhoto(
            image: img,
            exifDate: asset.creationDate,
            exifLocation: asset.location,
            cameraMetadata: cameraMetadata
          )
          self.parent.onPickedPhoto(picked)
        }
      }
    }

  }
}
