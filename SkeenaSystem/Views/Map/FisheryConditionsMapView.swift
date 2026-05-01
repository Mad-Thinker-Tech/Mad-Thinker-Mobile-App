// Bend Fly Shop
//
// FisheryConditionsMapView.swift — Mapbox map used by the conditions-recall
// fishery drill-down. Differs from GuideLandingMapView only in that every
// pin type is tappable (not just .catch_) — under similar conditions, a
// "passed" or "promising" pin is just as informative as a catch. The
// callout is provided by the caller via a builder closure so this view
// stays UI-agnostic about what's compared.

import CoreLocation
import MapboxMaps
import SwiftUI

/// Annotation backing a pin on `FisheryConditionsMapView`. Carries the raw
/// `MapReportDTO` so the caller's callout builder can read whatever fields
/// it needs (water temp, water level, etc.) without us threading them.
struct FisheryConditionsAnnotation: Identifiable {
  let id: String
  let coordinate: CLLocationCoordinate2D
  let reportType: GuideLandingAnnotation.ReportType
  let report: MapReportDTO
}

struct FisheryConditionsMapView<Callout: View>: View {
  let reports: [MapReportDTO]
  /// Rendered when any pin is tapped. Receives the tapped annotation +
  /// dismiss callback.
  let calloutBuilder: (FisheryConditionsAnnotation, @escaping () -> Void) -> Callout
  /// Coordinate to focus the camera on when no pins exist. Caller is
  /// expected to supply the fishery's GPS center (river spine midpoint /
  /// water-body polygon centroid). Nil → falls back to the community
  /// default in `initialViewport`.
  var fallbackCenter: CLLocationCoordinate2D? = nil

  @State private var selectedAnnotation: FisheryConditionsAnnotation? = nil

  // MARK: - Annotation derivation

  private var annotations: [FisheryConditionsAnnotation] {
    reports.compactMap { r in
      guard let lat = r.latitude, let lon = r.longitude,
            lat.isFinite, lon.isFinite,
            abs(lat) <= 90, abs(lon) <= 180,
            !(lat == 0 && lon == 0) else { return nil }
      let type = GuideLandingAnnotation.ReportType(rawValue: r.type) ?? .passed
      return FisheryConditionsAnnotation(
        id: r.id,
        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
        reportType: type,
        report: r
      )
    }
  }

  private func annotationsFor(_ type: GuideLandingAnnotation.ReportType) -> [FisheryConditionsAnnotation] {
    annotations.filter { $0.reportType == type }
  }

  // MARK: - Initial viewport

  /// Center on the most recent annotation; if there are none, fall back to
  /// the caller-supplied fishery center, then the community default. The
  /// user's own GPS is intentionally NOT consulted — the guide is recalling
  /// conditions at *this fishery*, not where they happen to be standing.
  private var initialViewport: Viewport {
    let recent = annotations.sorted {
      ($0.report.date) > ($1.report.date)
    }.first
    if let r = recent {
      return .camera(center: r.coordinate, zoom: 9, bearing: 0, pitch: 0)
    }
    if let center = fallbackCenter {
      return .camera(center: center, zoom: 10, bearing: 0, pitch: 0)
    }
    let config = CommunityService.shared.activeCommunityConfig
    if let lat = config.resolvedDefaultMapLatitude,
       let lon = config.resolvedDefaultMapLongitude {
      return .camera(
        center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
        zoom: 8, bearing: 0, pitch: 0
      )
    }
    return .camera(
      center: CLLocationCoordinate2D(
        latitude: AppEnvironment.shared.defaultMapLatitude,
        longitude: AppEnvironment.shared.defaultMapLongitude
      ),
      zoom: 8, bearing: 0, pitch: 0
    )
  }

  // MARK: - Body

  var body: some View {
    Map(initialViewport: initialViewport) {
      // Unrolled rather than ForEach'd because @MapContentBuilder doesn't
      // accept Swift ForEach over arbitrary Identifiable sequences.
      annotationGroup(for: annotationsFor(.catch_),    type: .catch_)
      annotationGroup(for: annotationsFor(.active),    type: .active)
      annotationGroup(for: annotationsFor(.farmed),    type: .farmed)
      annotationGroup(for: annotationsFor(.promising), type: .promising)
      annotationGroup(for: annotationsFor(.passed),    type: .passed)

      if let selected = selectedAnnotation {
        MapViewAnnotation(coordinate: selected.coordinate) {
          calloutBuilder(selected) { selectedAnnotation = nil }
        }
        .allowOverlap(true)
        .variableAnchors([ViewAnnotationAnchorConfig(anchor: .bottom, offsetY: 44)])
      }
    }
    .mapStyle(.satelliteStreets)
  }

  @MapContentBuilder
  private func annotationGroup(
    for group: [FisheryConditionsAnnotation],
    type: GuideLandingAnnotation.ReportType
  ) -> some MapContent {
    PointAnnotationGroup(group) { annotation in
      PointAnnotation(coordinate: annotation.coordinate)
        .image(.init(image: MapPinImage.pin(color: type.pinColor), name: type.pinName))
        .iconAnchor(.bottom)
        .onTapGesture { _ in
          selectedAnnotation = annotation
          return true
        }
    }
  }
}
