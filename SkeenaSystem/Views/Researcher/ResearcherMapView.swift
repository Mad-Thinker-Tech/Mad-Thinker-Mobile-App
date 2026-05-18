// Bend Fly Shop
//
// ResearcherMapView.swift — Full-page map of the *current researcher's* catch
// reports. Reached from the Researcher bottom toolbar's "Maps" tab. Mirrors the
// Guide landing-page map but server-filters by member_id and drops every
// non-catch report type, so the map only shows pins this researcher logged.
//
// Off-line behavior (mirrors GuideLandingView + GuideFisheryMapView):
//   - Successful pin fetch → persisted to `MapRecallCache` scoped by
//     `memberId` so the researcher's slice doesn't collide with any
//     community-wide cache.
//   - Failed pin fetch → falls back to the last cached snapshot and surfaces
//     a "Cached N ago" pill over the map.
//   - Successful fetch also kicks off `OfflineTileManager.preCacheLanding`
//     so the community-wide satellite basemap is available off-line. A
//     spinner over the map (top-leading) shows download progress.

import CoreLocation
import SwiftUI

struct ResearcherMapView: View {
  @StateObject private var loc = LocationManager()

  @State private var mapReports: [MapReportDTO] = []
  @State private var fetchDone = false
  @State private var focusCatchCoordinate: CLLocationCoordinate2D? = nil

  /// Timestamp on the disk snapshot when pins were populated from the
  /// `MapRecallCache` fallback (live fetch failed). nil when the current
  /// pin list came from a successful network fetch.
  @State private var cachedAt: Date?

  /// 0…1 while the offline-tile pre-cache is downloading the community-
  /// wide basemap, nil when idle. Drives the spinner overlay below.
  @State private var tileCacheProgress: Double?

  var body: some View {
    DarkPageTemplate(backgroundColor: .researcherBackground, navBarColor: .researcherBackground, bottomToolbar: {
      RoleAwareToolbar(activeTab: "maps")
    }) {
      content
    }
    .navigationTitle("Member Catch Map")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      loc.request()
      loc.start()
    }
    .task {
      await fetchMapReports()
    }
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if !fetchDone {
      ZStack {
        Color.researcherBackground
        ProgressView().tint(.researcherTextPrimary)
      }
    } else {
      ZStack(alignment: .top) {
        GuideLandingMapView(
          reports: mapReports,
          userLocation: loc.lastLocation?.coordinate,
          focusCoordinate: focusCatchCoordinate
        )

        if mapReports.isEmpty {
          Text("No catches recorded yet")
            .font(.brandSubheadline.weight(.semibold))
            .foregroundColor(.researcherTextPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.brandScrim.opacity(0.6), in: Capsule())
            .accessibilityIdentifier("researcherMapEmptyState")
        } else if let nearest = nearestCatch {
          Button {
            focusCatchCoordinate = nearest.coordinate
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "location.fill")
                .font(.system(size: 10))
              Text(nearest.label)
                .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.researcherTextPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.brandScrim.opacity(0.6), in: Capsule())
          }
          .buttonStyle(.plain)
          .padding(.top, 12)
          .accessibilityIdentifier("nearestCatchLabel")
        }

        // Tile pre-cache spinner — top-leading while the off-line basemap
        // is downloading. Disappears on success/failure; the cached pin
        // pill below shares the same anchor but is mutually exclusive
        // (tile cache fires after a successful fetch; pin cache fallback
        // only after a failed fetch).
        if let p = tileCacheProgress, p < 1.0 {
          ProgressView()
            .tint(.white)
            .padding(8)
            .background(Color.brandScrim.opacity(0.55), in: Circle())
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("researcherMapOfflineTileSpinner")
        }

        if let cachedAt {
          cachedAtMapPill(cachedAt)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      }
    }
  }

  // MARK: - Cached-from indicator

  /// Small pill (top-leading on the map) when pins were served from disk
  /// after a failed live fetch. Matches the recall view's chrome so a
  /// guide who covers research duty sees the same affordance.
  @ViewBuilder
  private func cachedAtMapPill(_ at: Date) -> some View {
    let relative = Self.cachedAtRelativeFormatter.localizedString(for: at, relativeTo: Date())
    HStack(spacing: 4) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.researcherPrediction)
      Text("Cached \(relative)")
        .font(.brandCaption2.weight(.semibold))
        .foregroundColor(.researcherTextPrimary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(Color.brandScrim.opacity(0.55), in: Capsule())
    .accessibilityIdentifier("researcherMapCachedIndicator")
  }

  private static let cachedAtRelativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
  }()

  // MARK: - Nearest catch

  private struct NearestCatch {
    let label: String
    let coordinate: CLLocationCoordinate2D
  }

  /// Returns label + coordinate for the nearest catch, or nil when location/catches are unavailable.
  private var nearestCatch: NearestCatch? {
    guard let userLoc = loc.lastLocation else { return nil }
    let validReports = mapReports.compactMap { r -> (CLLocationCoordinate2D, CLLocation)? in
      guard let lat = r.latitude, let lon = r.longitude,
            lat.isFinite, lon.isFinite,
            !(lat == 0 && lon == 0) else { return nil }
      let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
      return (coord, CLLocation(latitude: lat, longitude: lon))
    }
    guard let (catchCoord, catchLoc) = validReports.min(by: {
      $0.1.distance(from: userLoc) < $1.1.distance(from: userLoc)
    }) else { return nil }

    let distanceMiles = catchLoc.distance(from: userLoc) / 1609.344
    let distanceStr = distanceMiles < 10
      ? String(format: "%.1f mi", distanceMiles)
      : String(format: "%.0f mi", distanceMiles)
    let cardinal = Self.cardinalDirection(from: userLoc.coordinate, to: catchCoord)
    return NearestCatch(label: "Nearest catch \(distanceStr) \(cardinal)", coordinate: catchCoord)
  }

  private static func cardinalDirection(
    from: CLLocationCoordinate2D,
    to: CLLocationCoordinate2D
  ) -> String {
    let lat1 = from.latitude  * .pi / 180
    let lat2 = to.latitude    * .pi / 180
    let dLon = (to.longitude - from.longitude) * .pi / 180
    let y = sin(dLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
    let bearing = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    let index = Int((bearing + 22.5) / 45) % 8
    return directions[index]
  }

  // MARK: - Fetch

  /// Fetches the catch-only subset of map reports for the active community,
  /// scoped to this researcher's member id. Reports without a memberId or
  /// with a non-`catch` type are dropped client-side as defense in depth in
  /// case the server stops honouring the filter.
  ///
  /// On success: persists pins to `MapRecallCache` (scoped by `memberId`)
  /// and kicks off the satellite-streets tile pre-cache for the community-
  /// wide bbox so the basemap renders off-line.
  /// On failure: loads the last cached snapshot, sets `cachedAt`, and
  /// surfaces the cached-pins pill over the map.
  private func fetchMapReports() async {
    defer { Task { @MainActor in fetchDone = true } }

    guard let communityId = CommunityService.shared.activeCommunityId else {
      AppLogging.log("[ResearcherMap] no active community — skipping fetch", level: .debug, category: .map)
      return
    }
    let memberId = (AuthService.shared.currentMemberId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !memberId.isEmpty else {
      AppLogging.log("[ResearcherMap] no current memberId — skipping fetch", level: .debug, category: .map)
      return
    }

    do {
      let all = try await MapReportService.fetch(communityId: communityId, memberId: memberId)
      let catches = all.filter { $0.type == "catch" }
      // Cache only the server payload — local-pending pins live in
      // CatchReportStore and are merged in fresh on every render below.
      MapRecallCache.save(reports: catches, communityId: communityId, scope: memberId)
      // Merge in the researcher's `savedLocally` catches so today's work is
      // visible immediately. The catch-only filter naturally drops the
      // researcher's local marks (the map intentionally only renders
      // catches for the research role).
      let merged = LocalMapPins.mergeWithServer(catches).filter { $0.type == "catch" }
      await MainActor.run {
        mapReports = merged
        cachedAt = nil
      }
      // Tile pre-cache uses the community-wide footprint — same call the
      // guide landing makes, so the region is shared across surfaces and
      // a second visit is a no-op.
      Task { await preCacheBasemap(communityId: communityId) }
    } catch {
      AppLogging.log("[ResearcherMap] fetch failed: \(error.localizedDescription)", level: .error, category: .map)
      if let snapshot = MapRecallCache.load(communityId: communityId, scope: memberId) {
        AppLogging.log("[ResearcherMap] serving cached pins from \(snapshot.cachedAt)", level: .info, category: .map)
        // Same merge + catch-only filter on the cached path.
        let merged = LocalMapPins.mergeWithServer(snapshot.reports).filter { $0.type == "catch" }
        await MainActor.run {
          mapReports = merged
          cachedAt = snapshot.cachedAt
        }
      } else {
        // No cache — fall back to local-only catches so the day's work
        // still shows up even when fully offline.
        let local = LocalMapPins.localPendingPins().filter { $0.type == "catch" }
        await MainActor.run {
          mapReports = local
          cachedAt = nil
        }
      }
    }
  }

  /// Looks up the active community's rivers + water bodies, flattens to a
  /// coordinate list, and asks `OfflineTileManager` to cache a bbox tile
  /// region. Same call the guide landing makes — Mapbox short-circuits
  /// when the region is already on disk.
  private func preCacheBasemap(communityId: String) async {
    let config = CommunityService.shared.activeCommunityConfig
    var coords: [CLLocationCoordinate2D] = []
    for river in config.resolvedLodgeRivers {
      if let spine = RiverAtlas.all[river], !spine.isEmpty {
        coords.append(contentsOf: spine)
      }
    }
    for body in config.resolvedLodgeWaterBodies {
      if let polygon = WaterBodyAtlas.all[body], !polygon.isEmpty {
        coords.append(contentsOf: polygon)
      }
    }
    guard !coords.isEmpty else {
      AppLogging.log("[ResearcherMap] no fishery geometry — skipping tile pre-cache", level: .debug, category: .map)
      return
    }
    await MainActor.run { tileCacheProgress = 0 }
    let result = await OfflineTileManager.preCacheLanding(
      communityId: communityId,
      fisheryCoordinates: coords,
      onProgress: { fraction in
        tileCacheProgress = min(max(fraction, 0), 1)
      }
    )
    switch result {
    case .success:
      await MainActor.run { tileCacheProgress = nil }
    case .failure(let error):
      AppLogging.log("[ResearcherMap] tile pre-cache failed: \(error.localizedDescription)", level: .warn, category: .map)
      await MainActor.run { tileCacheProgress = nil }
    }
  }
}
