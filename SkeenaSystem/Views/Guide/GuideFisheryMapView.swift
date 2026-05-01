// Bend Fly Shop
//
// GuideFisheryMapView.swift — "Conditions recall" map drilling into a single
// fishery from FishingForecastResultView. Pins are filtered to:
//
//   1) The selected river (fuzzy-matched on report.river vs result.river)
//   2) Time window (server-side; defaults to last 30 days, up to 3 years)
//   3) Both water_temp_c and water_level_ft within ±10% of "now"
//
// Reports missing either metric are dropped — they can't be compared, and
// the on-screen claim "everything shown is within 10% of current" needs to
// be honest. Pin types (catch/active/farmed/promising/passed) all render
// together using the legend's colors; there is no per-category chip.

import CoreLocation
import SwiftUI

struct GuideFisheryMapView: View {
  /// River name + current temp/level snapshot — passed in from the
  /// conditions detail view so we don't re-fetch what's already on screen.
  let riverName: String
  let currentWaterTempC: Double?
  let currentWaterLevelFt: Double?

  @State private var mapReports: [MapReportDTO] = []
  @State private var hasLoaded = false
  @State private var isFetching = false
  @State private var timeWindow: GuideMapTimeWindow = .thirtyDays
  /// When true, both the ±10% temp/level filter AND the non-NULL-metric
  /// requirement are bypassed — every pin for the fishery in the time
  /// window is shown, including pre-enrichment reports without metrics.
  @State private var showAll: Bool = false

  private var community: CommunityConfig { CommunityService.shared.activeCommunityConfig }
  private var fetchKey: String { timeWindow.rawValue }

  // MARK: - Filtering

  /// Reports surviving every active filter. Pins missing river / temp /
  /// level are dropped — keeping them would either mis-scope the fishery or
  /// silently break the "within 10%" claim shown in the filter bar.
  private var filteredReports: [MapReportDTO] {
    let targetCore = Self.normalizeRiverName(riverName)
    return mapReports.filter { r in
      // 1. River — fuzzy match: lowercase, drop punctuation, strip common
      // water-body suffix tokens (River, Creek, Lake, etc. + "R"/"Cr"/"Lk"
      // abbreviations). Lets "Skeena R." match "Skeena River" without
      // letting "Skeena" alone match "Little Skeena Creek".
      guard let reportRiverRaw = r.river,
            !reportRiverRaw.trimmingCharacters(in: .whitespaces).isEmpty
      else { return false }
      let reportCore = Self.normalizeRiverName(reportRiverRaw)
      guard !reportCore.isEmpty, reportCore == targetCore else { return false }

      // "All" override — keep every pin for the fishery, including those
      // missing metric data, regardless of how far they sit from current.
      if showAll { return true }

      // 2. Both metrics must be present + within 10% of current.
      guard let reportTempC = r.waterTempC,
            let currentTempC = currentWaterTempC,
            Self.withinTenPercent(report: reportTempC, current: currentTempC)
      else { return false }

      guard let reportLevelFt = r.waterLevelFt,
            let currentLevelFt = currentWaterLevelFt,
            Self.withinTenPercent(report: reportLevelFt, current: currentLevelFt)
      else { return false }

      return true
    }
  }

  /// True when |report - current| ≤ 10% of |current|. Computed in the API's
  /// canonical units (°C / ft) so the result is unit-independent.
  static func withinTenPercent(report: Double, current: Double) -> Bool {
    abs(report - current) <= abs(current) * 0.10
  }

  /// Single source of truth for who can open the conditions-recall map. Only
  /// guides have access — they're the role with the historical catch /
  /// no-catch dataset to recall conditions against. Anglers, public, and
  /// researchers never see the entry point. Surfaced as a static so the
  /// caller (`FishingForecastResultView` toolbar) and the regression test
  /// pin to the same predicate.
  static func canAccess(role: AuthService.UserType?) -> Bool {
    role == .guide
  }

  /// Reduces a water-body name to a comparable "core" so guide-entered
  /// variants match a server-stored canonical form. Lowercases, replaces
  /// punctuation with whitespace, splits on whitespace, then strips trailing
  /// water-body suffix tokens (and their abbreviations). Both sides of the
  /// compare are normalized, so as long as a name shares its leading
  /// distinctive word(s), abbreviation/punctuation/casing differences fold
  /// away. Examples:
  ///
  ///   "Skeena River"      → "skeena"
  ///   "Skeena R."         → "skeena"
  ///   "skeena  river!"    → "skeena"
  ///   "Little Skeena Cr." → "little skeena"
  ///
  /// Trade-off: distinct water bodies sharing a leading word (e.g. "Hood
  /// River" vs "Hood Canal") collapse to the same core. Acceptable in
  /// practice because a community's configured fisheries don't usually
  /// collide that way.
  static func normalizeRiverName(_ raw: String) -> String {
    let lowered = raw.lowercased()
    let stripped = lowered.unicodeScalars.map { scalar -> Character in
      if CharacterSet.letters.contains(scalar) { return Character(scalar) }
      if CharacterSet.decimalDigits.contains(scalar) { return Character(scalar) }
      return " "
    }
    var tokens = String(stripped)
      .split(separator: " ", omittingEmptySubsequences: true)
      .map(String.init)
    let suffixTokens: Set<String> = [
      "river", "r",
      "creek", "cr",
      "lake", "lk",
      "stream", "brook",
      "bay", "sound", "channel", "canal", "inlet",
      "pond", "lagoon",
    ]
    while let last = tokens.last, suffixTokens.contains(last) {
      tokens.removeLast()
    }
    return tokens.joined(separator: " ")
  }

  // MARK: - Fishery center resolution

  /// Best-effort GPS center for the active fishery — used as the camera
  /// fallback when no pins exist for this fishery yet. Tries:
  ///   1) Exact match in RiverAtlas (river spine midpoint)
  ///   2) Fuzzy-normalized match in RiverAtlas (handles abbreviations)
  ///   3) Exact match in WaterBodyAtlas (polygon vertex centroid)
  ///   4) Fuzzy-normalized match in WaterBodyAtlas
  /// Returns nil when nothing matches; the inner map then falls back to the
  /// community default.
  private var fisheryCenterCoordinate: CLLocationCoordinate2D? {
    if let spine = RiverAtlas.all[riverName], !spine.isEmpty {
      return spine[spine.count / 2]
    }
    let targetCore = Self.normalizeRiverName(riverName)
    if let match = RiverAtlas.all.first(where: {
      Self.normalizeRiverName($0.key) == targetCore && !$0.value.isEmpty
    }) {
      return match.value[match.value.count / 2]
    }
    if let polygon = WaterBodyAtlas.all[riverName], !polygon.isEmpty {
      return polygonCentroid(polygon)
    }
    if let match = WaterBodyAtlas.all.first(where: {
      Self.normalizeRiverName($0.key) == targetCore && !$0.value.isEmpty
    }) {
      return polygonCentroid(match.value)
    }
    return nil
  }

  /// Coarse centroid: average of polygon vertex lat/lon. Good enough for
  /// camera framing — the geometric centroid would be marginally better
  /// for non-convex shapes but isn't worth the math here.
  private func polygonCentroid(_ vertices: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
    let lat = vertices.reduce(0.0) { $0 + $1.latitude } / Double(vertices.count)
    let lon = vertices.reduce(0.0) { $0 + $1.longitude } / Double(vertices.count)
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
  }

  // MARK: - Body

  var body: some View {
    DarkPageTemplate(bottomToolbar: {
      RoleAwareToolbar(activeTab: "conditions")
    }) {
      VStack(spacing: 0) {
        filterBar
        mapPane
        legendFooter
      }
    }
    .navigationTitle("Conditions Recall")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: fetchKey) {
      await fetchMapReports()
    }
  }

  // MARK: - Filter bar

  /// Single row: time-window menu and the "All" override on the left,
  /// current conditions readout on the right. The readout doubles as the
  /// "everything shown is within 10%" claim — adapts to "Showing all pins"
  /// when the override is on.
  private var filterBar: some View {
    HStack(spacing: 10) {
      timeMenu
      allCheckbox
      Spacer(minLength: 8)
      currentConditionsReadout
    }
    .padding(.horizontal, 12)
    .padding(.top, 10)
    .padding(.bottom, 10)
    .background(Color.white.opacity(0.04))
  }

  private var allCheckbox: some View {
    Button {
      showAll.toggle()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: showAll ? "checkmark.square.fill" : "square")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(showAll ? .blue : .white.opacity(0.7))
        Text("All")
          .font(.caption.weight(.semibold))
          .foregroundColor(.white)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(Color.white.opacity(0.10), in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("fisheryMapAllCheckbox")
  }

  private var timeMenu: some View {
    Menu {
      ForEach(GuideMapTimeWindow.allCases) { option in
        Button {
          timeWindow = option
        } label: {
          if option == timeWindow {
            Label(option.label, systemImage: "checkmark")
          } else {
            Text(option.label)
          }
        }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "calendar")
          .font(.system(size: 12, weight: .semibold))
        Text(timeWindow.label)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .semibold))
      }
      .foregroundColor(.white)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(Color.white.opacity(0.10), in: Capsule())
      // Keep the capsule wide enough for the longest label ("Last 30 days")
      // so the surrounding HStack can't squeeze the text onto two lines.
      .fixedSize(horizontal: true, vertical: false)
    }
    .accessibilityIdentifier("fisheryMapTimeWindowMenu")
  }

  /// Right-aligned readout: "Now: 9.5°C · 4.3 ft" on top, "Pins within ±10%"
  /// underneath. Empty state — when either current value is missing — falls
  /// back to "Current conditions unavailable" so the user understands why
  /// the map looks empty.
  @ViewBuilder
  private var currentConditionsReadout: some View {
    if currentWaterTempC == nil && currentWaterLevelFt == nil {
      Text("Current conditions unavailable")
        .font(.caption2)
        .foregroundColor(.white.opacity(0.7))
    } else {
      VStack(alignment: .trailing, spacing: 2) {
        HStack(spacing: 6) {
          if let t = currentWaterTempC {
            Text("Now: \(formatTemp(t))")
              .font(.caption.weight(.semibold))
              .foregroundColor(.white)
          }
          if let l = currentWaterLevelFt {
            Text("·")
              .font(.caption)
              .foregroundColor(.white.opacity(0.5))
            Text(formatLevel(l))
              .font(.caption.weight(.semibold))
              .foregroundColor(.white)
          }
        }
        Text(showAll ? "Showing all pins" : "Pins within ±10%")
          .font(.caption2)
          .foregroundColor(.white.opacity(0.7))
      }
      .accessibilityIdentifier("fisheryMapCurrentConditions")
    }
  }

  // MARK: - Map pane

  @ViewBuilder
  private var mapPane: some View {
    if !hasLoaded {
      ZStack {
        Color.black
        ProgressView().tint(.white)
      }
    } else {
      ZStack(alignment: .topTrailing) {
        FisheryConditionsMapView(
          reports: filteredReports,
          calloutBuilder: { annotation, dismiss in
            FisheryConditionsCalloutView(
              report: annotation.report,
              currentWaterTempC: currentWaterTempC,
              currentWaterLevelFt: currentWaterLevelFt,
              onDismiss: dismiss
            )
          },
          fallbackCenter: fisheryCenterCoordinate
        )

        if isFetching {
          ProgressView()
            .tint(.white)
            .padding(8)
            .background(Color.black.opacity(0.55), in: Circle())
            .padding(10)
        }

        if filteredReports.isEmpty {
          VStack {
            Spacer()
            Text(showAll ? "No reports for this fishery" : "No reports within ±10% of current conditions")
              .font(.subheadline.weight(.semibold))
              .foregroundColor(.white)
              .padding(.horizontal, 14)
              .padding(.vertical, 8)
              .background(Color.black.opacity(0.6), in: Capsule())
              .accessibilityIdentifier("fisheryMapEmptyState")
            Spacer()
          }
          .frame(maxWidth: .infinity)
        }
      }
    }
  }

  private var legendFooter: some View {
    HStack {
      Spacer()
      GuideLandingMapLegend()
      Spacer()
    }
    .padding(.vertical, 8)
    .background(Color.white.opacity(0.04))
  }

  // MARK: - Fetch

  private func fetchMapReports() async {
    await MainActor.run { isFetching = true }
    defer {
      Task { @MainActor in
        isFetching = false
        hasLoaded = true
      }
    }

    guard let communityId = CommunityService.shared.activeCommunityId else {
      AppLogging.log("[FisheryMap] no active community — skipping fetch", level: .debug, category: .map)
      return
    }

    do {
      let reports = try await MapReportService.fetch(
        communityId: communityId,
        memberId: nil,
        fromDate: timeWindow.fromDate()
      )
      await MainActor.run { mapReports = reports }
    } catch {
      AppLogging.log("[FisheryMap] fetch failed: \(error.localizedDescription)", level: .error, category: .map)
    }
  }

  // MARK: - Display formatting

  private func formatTemp(_ celsius: Double) -> String {
    let display = community.isImperial ? (celsius * 9.0 / 5.0 + 32.0) : celsius
    return "\(round1(display))\(community.tempUnit)"
  }

  private func formatLevel(_ feet: Double) -> String {
    let display = community.isImperial ? feet : (feet * 0.3048)
    let unit = community.isImperial ? "ft" : "m"
    return "\(round1(display)) \(unit)"
  }

  private func round1(_ x: Double) -> String {
    String(format: "%.1f", x)
  }
}
