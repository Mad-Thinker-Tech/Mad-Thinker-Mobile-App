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
  /// Timestamp on the disk snapshot when pins were populated from the
  /// `MapRecallCache` fallback (live fetch failed). nil when the current
  /// pin list came from a successful network fetch.
  @State private var cachedAt: Date?

  /// 0…1 while the offline-tile pre-cache is downloading the basemap for
  /// this fishery, nil when idle, 1.0 briefly after success before
  /// auto-hiding. Surfaces in the filter bar so the guide knows the map
  /// is being made off-line-safe.
  @State private var tileCacheProgress: Double?

  private var community: CommunityConfig { CommunityService.shared.activeCommunityConfig }
  private var fetchKey: String { timeWindow.rawValue }

  /// True when the ±10% temp/level filter is bypassed for *either* reason:
  /// the user manually checked "All", or current conditions weren't
  /// available (off-line, gauge missing) so the filter has no anchor to
  /// compare against. Auto-falling-back to "show every pin" is honest —
  /// labeling stale pins as "within 10%" without a live anchor would be a
  /// lie. The user-facing `showAll` checkbox state is preserved separately
  /// so the box doesn't appear pre-checked once connectivity returns.
  private var effectiveShowAll: Bool {
    showAll || (currentWaterTempC == nil && currentWaterLevelFt == nil)
  }

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
      // Also triggers automatically when current conditions are missing
      // (off-line, gauge gap) so the map isn't silently empty.
      if effectiveShowAll { return true }

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

  // MARK: - Fishery geometry resolution

  /// Full set of coordinates describing this fishery — river spine for
  /// rivers, polygon vertices for water bodies. Passed to the inner map so
  /// Mapbox can frame the camera to fit the whole fishery when no pins
  /// exist yet. Lookup order:
  ///   1) Exact match in RiverAtlas (full spine)
  ///   2) Fuzzy-normalized match in RiverAtlas
  ///   3) Exact match in WaterBodyAtlas (full polygon)
  ///   4) Fuzzy-normalized match in WaterBodyAtlas
  /// Returns [] when nothing matches; the inner map then falls back to the
  /// community default viewport.
  private var fisheryGeometry: [CLLocationCoordinate2D] {
    if let spine = RiverAtlas.all[riverName], !spine.isEmpty {
      return spine
    }
    let targetCore = Self.normalizeRiverName(riverName)
    if let match = RiverAtlas.all.first(where: {
      Self.normalizeRiverName($0.key) == targetCore && !$0.value.isEmpty
    }) {
      return match.value
    }
    if let polygon = WaterBodyAtlas.all[riverName], !polygon.isEmpty {
      return polygon
    }
    if let match = WaterBodyAtlas.all.first(where: {
      Self.normalizeRiverName($0.key) == targetCore && !$0.value.isEmpty
    }) {
      return match.value
    }
    return []
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
    .onChange(of: showAll) { _ in
      // Re-trace so the log reflects the new toggle state without forcing
      // the user to re-fetch (showAll is a client-side filter only). Using
      // the iOS 16-compatible single-parameter form since deployment target
      // is 16.6.
      logFilterTrace(reason: "showAll toggle")
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
    .background(Color.brandSurfaceMuted)
  }

  private var allCheckbox: some View {
    Button {
      showAll.toggle()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: showAll ? "checkmark.square.fill" : "square")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(showAll ? .brandAccent : .brandTextTertiary)
        Text("All")
          .font(.brandCaption.weight(.semibold))
          .foregroundColor(.brandTextPrimary)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(Color.brandTextPrimary.opacity(0.10), in: Capsule())
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
          .font(.brandCaption.weight(.semibold))
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .semibold))
      }
      .foregroundColor(.brandTextPrimary)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(Color.brandTextPrimary.opacity(0.10), in: Capsule())
      // Keep the capsule wide enough for the longest label ("Last 30 days")
      // so the surrounding HStack can't squeeze the text onto two lines.
      .fixedSize(horizontal: true, vertical: false)
    }
    .accessibilityIdentifier("fisheryMapTimeWindowMenu")
  }

  /// Right-aligned readout: "Now: 9.5°C · 4.3 ft" on top, "Pins within ±10%"
  /// underneath. When current temp/level are both missing, falls back to
  /// a two-line "unavailable / showing all" explanation. The "Cached N ago"
  /// indicator for stale pin data sits as an overlay on the map below —
  /// keeping the filter bar's vertical height stable across states.
  @ViewBuilder
  private var currentConditionsReadout: some View {
    if currentWaterTempC == nil && currentWaterLevelFt == nil {
      VStack(alignment: .trailing, spacing: 2) {
        Text("Current conditions unavailable")
          .font(.brandCaption2)
          .foregroundColor(.brandTextPrimary.opacity(0.7))
        Text("Showing all pins in window")
          .font(.brandCaption2)
          .foregroundColor(.brandTextPrimary.opacity(0.5))
      }
      .accessibilityIdentifier("fisheryMapCurrentConditionsUnavailable")
    } else {
      VStack(alignment: .trailing, spacing: 2) {
        HStack(spacing: 6) {
          if let t = currentWaterTempC {
            Text("Now: \(formatTemp(t))")
              .font(.brandCaption.weight(.semibold))
              .foregroundColor(.brandTextPrimary)
          }
          if let l = currentWaterLevelFt {
            Text("·")
              .font(.brandCaption)
              .foregroundColor(.brandTextPrimary.opacity(0.5))
            Text(formatLevel(l))
              .font(.brandCaption.weight(.semibold))
              .foregroundColor(.brandTextPrimary)
          }
        }
        Text(effectiveShowAll ? "Showing all pins" : "Pins within ±10%")
          .font(.brandCaption2)
          .foregroundColor(.brandTextPrimary.opacity(0.7))
      }
      .accessibilityIdentifier("fisheryMapCurrentConditions")
    }
  }

  /// Small pill overlaid on the map (top-leading) when the pin list was
  /// served from the on-device cache instead of a live fetch. Carries a
  /// scrim background so it stays readable over both bright and dark map
  /// imagery. Mutually exclusive in practice with the tile-saving spinner
  /// (cache fallback only fires when the live fetch failed; tile pre-cache
  /// only fires after the live fetch succeeded).
  @ViewBuilder
  private func cachedAtMapPill(_ at: Date) -> some View {
    let relative = Self.cachedAtRelativeFormatter.localizedString(for: at, relativeTo: Date())
    HStack(spacing: 4) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.brandSuccess)
      Text("Cached \(relative)")
        .font(.brandCaption2.weight(.semibold))
        .foregroundColor(.brandTextPrimary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(Color.brandScrim.opacity(0.55), in: Capsule())
    .accessibilityIdentifier("fisheryMapCachedIndicator")
  }

  /// Static formatter so we don't allocate per-frame. `.short` keeps the
  /// label tight ("2 min. ago", "3 days ago") to fit alongside the
  /// conditions readout.
  private static let cachedAtRelativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
  }()

  // MARK: - Map pane

  @ViewBuilder
  private var mapPane: some View {
    if !hasLoaded {
      ZStack {
        Color.brandBackground
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
          fisheryGeometry: fisheryGeometry
        )

        if isFetching {
          ProgressView()
            .tint(.white)
            .padding(8)
            .background(Color.brandScrim.opacity(0.55), in: Circle())
            .padding(10)
        }

        // Tile pre-cache progress — small spinner over the map at top-
        // leading. Visible only while the download is in flight; the
        // filter bar stays a fixed height regardless of state, which
        // was the old chip's bug.
        if let p = tileCacheProgress, p < 1.0 {
          ProgressView()
            .tint(.white)
            .padding(8)
            .background(Color.brandScrim.opacity(0.55), in: Circle())
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("fisheryMapOfflineTileSpinner")
        }

        // "Cached N ago" pill for pin data served from disk. Same top-
        // leading anchor as the spinner above, but the two states are
        // mutually exclusive (tile cache only after a successful fetch;
        // pin cache only after a failed fetch), so they never collide.
        if let cachedAt {
          cachedAtMapPill(cachedAt)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        if filteredReports.isEmpty {
          VStack {
            Spacer()
            Text(effectiveShowAll ? "No reports for this fishery" : "No reports within ±10% of current conditions")
              .font(.brandSubheadline.weight(.semibold))
              .foregroundColor(.brandTextPrimary)
              .padding(.horizontal, 14)
              .padding(.vertical, 8)
              .background(Color.brandScrim.opacity(0.6), in: Capsule())
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
    .background(Color.brandSurfaceMuted)
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
      // Persist on every successful fetch (including empty results — that's
      // the freshest reality and should overwrite stale cached pins).
      // Only the server-side payload goes into the cache — pending local
      // pins live in CatchReportStore / FarmedReportStore and are merged in
      // freshly on every render below.
      MapRecallCache.save(reports: reports, communityId: communityId)
      // Merge in the user's `savedLocally` catches and marks. The view's
      // existing per-river filter (matching `report.river` against
      // `riverName`) naturally scopes these to the current fishery, and
      // marks (which carry no river) get filtered out — same as today's
      // behaviour for server marks missing a river.
      let merged = LocalMapPins.mergeWithServer(reports)
      await MainActor.run {
        mapReports = merged
        cachedAt = nil
        logFilterTrace(reason: "fetch complete")
      }
      // Kick off the offline-tile pre-cache for this fishery's basemap.
      // Non-blocking and best-effort: the map renders pins immediately
      // and the chip in the filter bar shows download progress. A
      // failure (no token, no connectivity, no geometry) is logged and
      // silently swallowed — the live map still works.
      Task { await preCacheBasemap(communityId: communityId) }
    } catch {
      AppLogging.log("[FisheryMap] fetch failed: \(error.localizedDescription)", level: .error, category: .map)
      // Off-line / transport failure → fall back to the last snapshot
      // (if any). The pins are filtered client-side, so the existing
      // ±10% / "All" UI keeps working over the cached payload. Also merge
      // in local-pending pins so today's activity stays visible offline.
      if let snapshot = MapRecallCache.load(communityId: communityId) {
        AppLogging.log("[FisheryMap] serving cached pins from \(snapshot.cachedAt)", level: .info, category: .map)
        let merged = LocalMapPins.mergeWithServer(snapshot.reports)
        await MainActor.run {
          mapReports = merged
          cachedAt = snapshot.cachedAt
          logFilterTrace(reason: "cache fallback")
        }
      } else {
        // No cache either — surface bare local pins so the guide still sees
        // their own day's catches on the fishery they're recording on.
        let local = LocalMapPins.localPendingPins()
        await MainActor.run {
          mapReports = local
          cachedAt = nil
          logFilterTrace(reason: "no cache, local-only fallback")
        }
      }
    }
  }

  /// Pre-caches the satellite-streets basemap for the current fishery so
  /// the recall view still renders tiles when the guide is off-line. Non-
  /// blocking: pins render before this finishes. The chip in the filter
  /// bar shows progress and disappears 1.5s after success.
  private func preCacheBasemap(communityId: String) async {
    let coords = fisheryGeometry
    guard !coords.isEmpty else {
      AppLogging.log("[FisheryMap] no geometry — skipping tile pre-cache", level: .debug, category: .map)
      return
    }
    await MainActor.run { tileCacheProgress = 0 }
    let result = await OfflineTileManager.preCache(
      communityId: communityId,
      fisheryName: riverName,
      geometry: coords,
      onProgress: { fraction in
        tileCacheProgress = min(max(fraction, 0), 1)
      }
    )
    switch result {
    case .success:
      // Drop the indicator immediately on success. The chip-era held at
      // "Saved" for 1.5s as user feedback; with a spinner-only design
      // there's nothing to keep spinning, so the cleanest signal is
      // simply absence.
      await MainActor.run { tileCacheProgress = nil }
    case .failure(let error):
      AppLogging.log("[FisheryMap] tile pre-cache failed: \(error.localizedDescription)", level: .warn, category: .map)
      await MainActor.run { tileCacheProgress = nil }
    }
  }

  /// Logs every report's per-gate verdict (river / metrics) plus the inputs
  /// the filter is comparing against. Triggered after a fetch and whenever
  /// the "All" toggle flips. Use this to diagnose "I just saved a catch but
  /// it didn't show" — the trace identifies exactly which gate rejected
  /// the pin.
  private func logFilterTrace(reason: String) {
    let targetCore = Self.normalizeRiverName(riverName)
    let currentTemp = currentWaterTempC.map { String($0) } ?? "nil"
    let currentLevel = currentWaterLevelFt.map { String($0) } ?? "nil"
    AppLogging.log(
      "[FisheryMap] trace (\(reason)): river=\"\(riverName)\" core=\"\(targetCore)\" currentTempC=\(currentTemp) currentLevelFt=\(currentLevel) showAll=\(showAll) reports=\(mapReports.count)",
      level: .info,
      category: .map
    )

    for r in mapReports {
      AppLogging.log({ verdictLine(for: r, targetCore: targetCore) },
                     level: .info, category: .map)
    }
  }

  private func verdictLine(for r: MapReportDTO, targetCore: String) -> String {
    let id = r.id
    let type = r.type
    let rawRiver = r.river.map { "\"\($0)\"" } ?? "nil"

    // 1. River gate
    guard let reportRiverRaw = r.river,
          !reportRiverRaw.trimmingCharacters(in: .whitespaces).isEmpty else {
      return "[FisheryMap]   \(id) type=\(type) → DROP (river field missing/empty) river=\(rawRiver)"
    }
    let reportCore = Self.normalizeRiverName(reportRiverRaw)
    guard !reportCore.isEmpty, reportCore == targetCore else {
      return "[FisheryMap]   \(id) type=\(type) → DROP (river mismatch) river=\(rawRiver) reportCore=\"\(reportCore)\" targetCore=\"\(targetCore)\""
    }

    // 2. "All" override
    if showAll {
      let tempStr = r.waterTempC.map { "\($0)" } ?? "nil"
      let levelStr = r.waterLevelFt.map { "\($0)" } ?? "nil"
      return "[FisheryMap]   \(id) type=\(type) → KEEP (showAll) river=\(rawRiver) tempC=\(tempStr) levelFt=\(levelStr)"
    }

    // 3. Temp gate
    guard let reportTempC = r.waterTempC else {
      return "[FisheryMap]   \(id) type=\(type) → DROP (water_temp_c missing) river=\(rawRiver)"
    }
    guard let currentTempC = currentWaterTempC else {
      return "[FisheryMap]   \(id) type=\(type) → DROP (current water temp unavailable) reportTempC=\(reportTempC)"
    }
    if !Self.withinTenPercent(report: reportTempC, current: currentTempC) {
      let pct: Double = currentTempC == 0 ? .infinity : abs(reportTempC - currentTempC) / abs(currentTempC) * 100
      return "[FisheryMap]   \(id) type=\(type) → DROP (temp out of band) reportTempC=\(reportTempC) currentTempC=\(currentTempC) deltaPct=\(String(format: "%.1f", pct))%"
    }

    // 4. Level gate
    guard let reportLevelFt = r.waterLevelFt else {
      return "[FisheryMap]   \(id) type=\(type) → DROP (water_level_ft missing) river=\(rawRiver)"
    }
    guard let currentLevelFt = currentWaterLevelFt else {
      return "[FisheryMap]   \(id) type=\(type) → DROP (current water level unavailable) reportLevelFt=\(reportLevelFt)"
    }
    if !Self.withinTenPercent(report: reportLevelFt, current: currentLevelFt) {
      let pct: Double = currentLevelFt == 0 ? .infinity : abs(reportLevelFt - currentLevelFt) / abs(currentLevelFt) * 100
      return "[FisheryMap]   \(id) type=\(type) → DROP (level out of band) reportLevelFt=\(reportLevelFt) currentLevelFt=\(currentLevelFt) deltaPct=\(String(format: "%.1f", pct))%"
    }

    return "[FisheryMap]   \(id) type=\(type) → KEEP (within ±10%) tempC=\(reportTempC) levelFt=\(reportLevelFt)"
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
