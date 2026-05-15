// Bend Fly Shop

import CoreLocation
import MapboxMaps
import SwiftUI

// MARK: - Annotation model

struct GuideLandingAnnotation: Identifiable {
  enum ReportType: String {
    case catch_ = "catch"
    case active = "active"
    case farmed = "farmed"
    case promising = "promising"
    case passed = "passed"

    var pinColor: UIColor {
      switch self {
      case .catch_:    return .systemBlue
      case .active:    return .systemGreen
      case .farmed:    return .systemOrange
      case .promising: return .systemYellow
      case .passed:    return .systemGray
      }
    }

    var pinName: String { "guide-pin-\(rawValue)" }
  }

  let id: String
  let coordinate: CLLocationCoordinate2D
  let reportType: ReportType
  let species: String?
  let lengthInches: Int?
  let date: Date
  /// True for pins synthesized from on-device `savedLocally` reports.
  /// Drives the hollow pin variant so users can see what they've recorded
  /// today before it has been uploaded.
  let isPendingUpload: Bool
  /// Screen-pixel offset applied to the icon at render time. Non-zero only
  /// when this annotation shares a coordinate (within ~5m) with one or more
  /// other annotations — `GuideLandingMapView.applyOverlapOffsets` fans
  /// collided pins around a small circle so every pin is visible. The
  /// underlying `coordinate` is untouched; this only shifts the icon's
  /// display position, not the data tied to it.
  var iconOffset: CGSize = .zero
}

// MARK: - Map View

struct GuideLandingMapView: View {
  let reports: [MapReportDTO]
  /// Optional user GPS coordinate — used as a viewport fallback when no reports exist.
  var userLocation: CLLocationCoordinate2D? = nil
  /// When set, the map flies to this coordinate. Caller drives the value; map does not reset it.
  var focusCoordinate: CLLocationCoordinate2D? = nil

  @State private var selectedAnnotation: GuideLandingAnnotation? = nil

  // MARK: - Derived annotations

  private var annotations: [GuideLandingAnnotation] {
    let base: [GuideLandingAnnotation] = reports.compactMap { r in
      guard let lat = r.latitude, let lon = r.longitude,
            lat.isFinite, lon.isFinite,
            abs(lat) <= 90, abs(lon) <= 180,
            !(lat == 0 && lon == 0) else { return nil }
      let type = GuideLandingAnnotation.ReportType(rawValue: r.type) ?? .passed
      return GuideLandingAnnotation(
        id: r.id,
        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
        reportType: type,
        species: r.species,
        lengthInches: r.lengthInches,
        date: Self.parseISO(r.date) ?? Date(),
        isPendingUpload: r.isPendingUpload
      )
    }
    return Self.applyOverlapOffsets(base)
  }

  /// Quantize a coordinate to a coarse key so pins from the same fishing
  /// hole (or repeat catches on the same drift / boat seat) cluster
  /// together. 5e-5 deg ≈ 5.5m at the equator — well inside consumer-phone
  /// GPS noise so we don't fracture genuinely-co-located reports across
  /// adjacent buckets.
  private static func clusterKey(_ coord: CLLocationCoordinate2D) -> String {
    let q: Double = 5e-5
    let lat = (coord.latitude / q).rounded() * q
    let lon = (coord.longitude / q).rounded() * q
    return String(format: "%.6f,%.6f", lat, lon)
  }

  /// For any group of annotations whose coordinates collide (within the
  /// `clusterKey` tolerance), fan them around a small circle in screen-pixel
  /// space so each pin is individually visible. `coordinate` is unchanged —
  /// only the icon offset shifts, so taps and callouts still reference the
  /// real GPS. Singletons receive a zero offset. Order within a cluster is
  /// stable (input order) so re-renders don't shuffle the fan.
  private static func applyOverlapOffsets(_ list: [GuideLandingAnnotation]) -> [GuideLandingAnnotation] {
    var clusters: [String: [Int]] = [:]
    for (idx, ann) in list.enumerated() {
      clusters[clusterKey(ann.coordinate), default: []].append(idx)
    }
    guard clusters.values.contains(where: { $0.count > 1 }) else { return list }

    var result = list
    let baseRadius: Double = 14
    for indices in clusters.values where indices.count > 1 {
      let n = indices.count
      // Ring radius grows gently with cluster size so 6+ pins don't crush
      // into each other. Most real clusters are 2–4, where this just gives
      // baseRadius. Cap so the fan stays inside reasonable visual bounds.
      let radius = min(baseRadius * (1 + Double(max(0, n - 4)) * 0.15), 28)
      for (i, listIdx) in indices.enumerated() {
        // Start at -π/2 (top) and walk clockwise so the first pin sits
        // above the GPS dot — easier to mentally associate "where I tapped"
        // with "where the data is".
        let angle = (2 * .pi * Double(i)) / Double(n) - .pi / 2
        result[listIdx].iconOffset = CGSize(
          width: radius * cos(angle),
          height: radius * sin(angle)
        )
      }
    }
    return result
  }

  // MARK: - Group by type for PointAnnotationGroup (one group per pin style)

  private var catchAnnotations: [GuideLandingAnnotation]     { annotations.filter { $0.reportType == .catch_ } }
  private var activeAnnotations: [GuideLandingAnnotation]    { annotations.filter { $0.reportType == .active } }
  private var farmedAnnotations: [GuideLandingAnnotation]    { annotations.filter { $0.reportType == .farmed } }
  private var promisingAnnotations: [GuideLandingAnnotation] { annotations.filter { $0.reportType == .promising } }
  private var passedAnnotations: [GuideLandingAnnotation]    { annotations.filter { $0.reportType == .passed } }

  // MARK: - Initial viewport

  private var initialViewport: Viewport {
    // Center on user's GPS location (matches weather conditions location)
    if let loc = userLocation {
      return .camera(center: loc, zoom: 9, bearing: 0, pitch: 0)
    }
    // Fallback to most recent report
    if let latest = annotations.sorted(by: { $0.date > $1.date }).first {
      return .camera(center: latest.coordinate, zoom: 9, bearing: 0, pitch: 0)
    }
    // Fallback to community geography
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
    MapReader { proxy in
      Map(initialViewport: initialViewport) {
        annotationGroup(for: catchAnnotations,     type: .catch_)
        annotationGroup(for: activeAnnotations,    type: .active)
        annotationGroup(for: farmedAnnotations,    type: .farmed)
        annotationGroup(for: promisingAnnotations, type: .promising)
        annotationGroup(for: passedAnnotations,    type: .passed)

        // Callout for selected catch pin
        if let selected = selectedAnnotation, selected.reportType == .catch_ {
          MapViewAnnotation(coordinate: selected.coordinate) {
            GuideMapCalloutView(
              species: selected.species,
              lengthInches: selected.lengthInches,
              date: selected.date,
              onDismiss: { selectedAnnotation = nil }
            )
          }
          .allowOverlap(true)
          .variableAnchors([ViewAnnotationAnchorConfig(anchor: .bottom, offsetY: 44)])
        }
      }
      .mapStyle(.satelliteStreets)
      .onChange(of: focusCoordinate) { coord in
        guard let coord else { return }
        proxy.camera?.fly(to: CameraOptions(center: coord, zoom: 12), duration: 0.8)
      }
    }
  }

  // MARK: - Helpers

  @MapContentBuilder
  private func annotationGroup(
    for group: [GuideLandingAnnotation],
    type: GuideLandingAnnotation.ReportType
  ) -> some MapContent {
    PointAnnotationGroup(group) { annotation in
      // Hollow variant for `savedLocally` pins so the user can see at a
      // glance what they've recorded today that hasn't synced yet. Each
      // (type, pending-state) pair registers its own Mapbox image name so
      // the texture cache doesn't dedupe the filled and hollow versions
      // into one glyph.
      let pinImage = annotation.isPendingUpload
        ? MapPinImage.hollowPin(color: type.pinColor)
        : MapPinImage.pin(color: type.pinColor)
      let pinName = annotation.isPendingUpload
        ? "\(type.pinName)-pending"
        : type.pinName
      // Mapbox iconOffset is a `[Double]?` property (NOT a chain method)
      // expressed as [x, y] in pixels with positive-y = DOWN (screen-space).
      // Our `iconOffset.height` is computed in standard math coords
      // (positive-y = up), so we flip the sign so a pin at angle -π/2
      // (which our fan-out helper places at the top of the ring) actually
      // renders above the GPS dot. Skip the property assignment entirely
      // for non-collided pins so Mapbox stays on its default rendering
      // path for the common case.
      var pa = PointAnnotation(coordinate: annotation.coordinate)
      if annotation.iconOffset != .zero {
        pa.iconOffset = [Double(annotation.iconOffset.width), -Double(annotation.iconOffset.height)]
      }
      return pa
        .image(.init(image: pinImage, name: pinName))
        .iconAnchor(.bottom)
        .onTapGesture { _ in
          if annotation.reportType == .catch_ {
            selectedAnnotation = annotation
          }
          return true
        }
    }
  }

  private static func parseISO(_ iso: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
  }
}

// MARK: - Legend

/// Compact colour legend shown below the map
struct GuideLandingMapLegend: View {
  private let items: [(String, UIColor)] = [
    ("Catch",     .systemBlue),
    ("Active",    .systemGreen),
    ("Farmed",    .systemOrange),
    ("Promising", .systemYellow),
    ("Passed",    .systemGray),
  ]

  var body: some View {
    HStack(spacing: 12) {
      ForEach(items, id: \.0) { label, uiColor in
        HStack(spacing: 4) {
          Circle()
            .fill(Color(uiColor))
            .frame(width: 8, height: 8)
          Text(label)
            .font(.system(size: 10))
            .foregroundColor(.brandTextPrimary.opacity(0.7))
        }
      }
    }
  }
}
