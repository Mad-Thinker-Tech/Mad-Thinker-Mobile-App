// Bend Fly Shop

import SwiftUI
import Combine

// MARK: - Models

// `Codable` (not just `Decodable`) so the response can be re-encoded into the
// offline cache (`FisheryConditionsCache`) — see Managers/FisheryConditionsCache.swift.
struct RiverConditionsResponse: Codable {
  let river: String
  let stationId: String
  let date: String
  let isTidal: Bool

  let weather: WeatherBlock
  let tides: TidesBlock?
  let waterLevels: [WaterLevelEntry]
  let waterTemperatures: [WaterTemperatureEntry]?

  struct WeatherBlock: Codable {
    let previousDay: DayBlock
    let targetDay: DayBlock
    let nextDay: DayBlock
  }

  struct DayBlock: Codable {
    let date: String
    let highTempC: Double
    let lowTempC: Double
    let precipitationMm: Double
  }

  struct TidesBlock: Codable {
    let previousHigh: TidesPoint
    let nextHigh: TidesPoint
    let previousLow: TidesPoint
    let nextLow: TidesPoint
  }

  struct TidesPoint: Codable {
    let time: String
    let heightM: Double
    let type: String
  }

  /// Hour-aligned water-level sample.
  /// `recordedAt` is a UTC ISO 8601 timestamp (e.g. "2026-04-30T14:00:00.000Z");
  /// callers convert to the device's local timezone for display.
  struct WaterLevelEntry: Codable, Identifiable {
    let recordedAt: String
    let levelFt: Double
    var id: String { recordedAt }
  }

  /// Hour-aligned water-temperature sample. `recordedAt` is UTC ISO 8601.
  struct WaterTemperatureEntry: Codable, Identifiable {
    let recordedAt: String
    let tempC: Double
    var id: String { recordedAt }
  }
}

private enum ConditionsTab: String, CaseIterable, Identifiable {
  case level = "Water Level"
  case temperature = "Water Temperature"
  var id: String { rawValue }
}

// MARK: - Root View

/// Single-fishery conditions view. Accepts an optional `result` so the request
/// view can navigate to a friendly offline empty state when both the network
/// fetch failed AND no cached snapshot exists for the tapped fishery. When
/// `result` is non-nil the view renders the existing layout plus a "Last
/// updated: …" timestamp row above the weather tiles.
///
/// `lastUpdatedAt` is the time the underlying response was received on-device
/// (either `Date()` from a fresh fetch, or the `cachedAt` field of an offline
/// snapshot). Hidden when nil.
struct FishingForecastResultView: View {
  let result: RiverConditionsResponse?
  let lastUpdatedAt: Date?

  var body: some View {
    if let result = result {
      LoadedForecastResultView(result: result, lastUpdatedAt: lastUpdatedAt)
    } else {
      offlineEmptyView
    }
  }

  // MARK: - Offline empty state

  /// Rendered when we navigate to this view with no result AND no cache —
  /// i.e. the user tapped a fishery they've never opened before while
  /// offline. No retry button: the user can re-tap when they're back online.
  private var offlineEmptyView: some View {
    ZStack {
      Color.brandBackground.ignoresSafeArea()
      VStack(spacing: 12) {
        Image(systemName: "wifi.slash")
          .font(.brandTitle)
          .foregroundColor(.brandTextSecondary)
        Text("You need to be connected to see details on this fishery.")
          .font(.brandSubheadline)
          .foregroundColor(.brandTextSecondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
      }
    }
    .preferredColorScheme(.dark)
    .accessibilityIdentifier("fisheryConditionsOfflineEmpty")
  }
}

// MARK: - Loaded layout

/// The full conditions view, only instantiated when `result` is non-nil. Kept
/// as a separate type so the existing body and toolbar references to
/// `result.X` don't need optional-chaining gymnastics.
private struct LoadedForecastResultView: View {
  let result: RiverConditionsResponse
  let lastUpdatedAt: Date?

  @StateObject private var auth = AuthService.shared
  @State private var showTactics = false
  @State private var showFisheryMap = false
  @State private var conditionsTab: ConditionsTab = .level

  private var community: CommunityConfig { CommunityService.shared.activeCommunityConfig }

  /// Most-recent water temp in °C, derived from the same hourly series that
  /// powers the on-screen sparkline. Passed to the conditions-recall map so
  /// it can compare each pin's recorded value to "now" without re-fetching.
  private var currentWaterTempC: Double? {
    result.waterTemperatures?.last?.tempC
  }

  /// Most-recent water level in feet — same idea as `currentWaterTempC`.
  private var currentWaterLevelFt: Double? {
    result.waterLevels.last?.levelFt
  }

  var body: some View {
    ZStack {
      Color.brandBackground.ignoresSafeArea()

      VStack(spacing: 12) {
        ScrollView {
          VStack(spacing: 12) {
            // "Last updated: …" row, just above the weather tiles. Same
            // `.brandCaption2` font / `.brandTextSecondary` color as the
            // Level / Temp column headers on the list view so the styling
            // reads consistently across both screens. Top padding keeps
            // the row from tucking under the navigation-bar title block.
            if let cachedAt = lastUpdatedAt {
              HStack {
                Text("Last updated: \(FishingForecastRequestView.formatLastUpdated(cachedAt))")
                  .font(.brandCaption2)
                  .foregroundColor(.brandTextSecondary)
                Spacer()
              }
              .padding(.top, 12)
            }
            weatherThreeDayCompact
            if result.isTidal, let tides = result.tides {
              tideWaveCard(tides: tides)
              tidesTextBlocks(tides: tides)
            }
            conditionsTabSection
            footer
          }
          .padding(.horizontal, 14)
          .padding(.bottom, 10)
        }
      }

    }
    .preferredColorScheme(.dark)
    .navigationDestination(isPresented: $showTactics) {
      TacticsRecommendationsView(
        date: result.date,
        river: result.river
      )
    }
    .navigationDestination(isPresented: $showFisheryMap) {
      GuideFisheryMapView(
        riverName: result.river,
        currentWaterTempC: currentWaterTempC,
        currentWaterLevelFt: currentWaterLevelFt
      )
    }
    // Custom 2-line nav title: river + Using Station
    .toolbar {
      ToolbarItem(placement: .principal) {
        VStack(spacing: 2) {
          Text(result.river)
            .font(.brandHeadline)
            .foregroundColor(.primary)

          Text("Using Station: \(result.stationId)")
            .font(.brandSubheadline)
            .foregroundColor(.secondary)
        }
      }

      // Conditions-recall map. Guide-only — gated through GuideFisheryMapView
      // so the predicate has one home and ConditionsRecallRegressionTests
      // can lock it down.
      if GuideFisheryMapView.canAccess(role: auth.currentUserType) {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            showFisheryMap = true
          } label: {
            Image(systemName: "map")
              .foregroundColor(.brandTextPrimary)
          }
          .accessibilityIdentifier("conditionsRecallMapButton")
        }
      }

      // Tactics recommendations. Same gating as before; the in-content
      // capsule was retired in favor of a navbar icon to free up vertical
      // space at the top of the conditions card stack.
      if auth.currentUserType == .guide, AppEnvironment.shared.tacticsEnabled {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            showTactics = true
          } label: {
            Image(systemName: "lightbulb")
              .foregroundColor(.brandTextPrimary)
          }
          .accessibilityIdentifier("getTacticsButton")
        }
      }
    }
  }

  // MARK: - 3-Day Weather

  private var weatherThreeDayCompact: some View {
    HStack(spacing: 8) {
      dayCard(label: "Yesterday", day: result.weather.previousDay, isToday: false)
      dayCard(label: "Today", day: result.weather.targetDay, isToday: true)
      dayCard(label: "Tomorrow", day: result.weather.nextDay, isToday: false)
    }
    .padding(8)
    .background(Color.brandStrokeSubtle)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .accessibilityIdentifier("weatherSection")
  }

  private func dayCard(label: String, day: RiverConditionsResponse.DayBlock, isToday: Bool) -> some View {
    VStack(spacing: 6) {
      Text(label)
        .font(.brandCaption).bold()
        .foregroundColor(isToday ? .brandAccent : .brandTextPrimary)

      Text(formattedDate(day.date))
        .font(.brandCaption2)
        .foregroundColor(isToday ? .brandAccent.opacity(0.9) : .brandTextSecondary)

      VStack(spacing: 3) {
        rowMetric("High", "\(number(displayTempC(day.highTempC)))\(community.tempUnit)", highlight: isToday)
        rowMetric("Low", "\(number(displayTempC(day.lowTempC)))\(community.tempUnit)", highlight: isToday)
        rowMetric("Precip", "\(number(displayPrecipMm(day.precipitationMm))) \(precipitationUnit)", highlight: isToday)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity)
    .background(Color.brandSurfaceMuted)
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private func rowMetric(_ label: String, _ value: String, highlight: Bool) -> some View {
    HStack {
      Text(label).font(.brandCaption2).foregroundColor(.brandTextSecondary)
      Spacer()
      Text(value).font(.brandFootnote).foregroundColor(highlight ? .brandAccent : .brandTextPrimary)
    }
  }

  // MARK: - Tide Wave Card

  private func tideWaveCard(tides: RiverConditionsResponse.TidesBlock) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Tide Heights")
        .font(.brandSubheadline).foregroundColor(.brandTextPrimary)

      TideWaveGraph(
        previousHigh: tides.previousHigh,
        nextHigh: tides.nextHigh,
        previousLow: tides.previousLow,
        nextLow: tides.nextLow,
        community: community
      )
      .frame(height: 140)
    }
    .padding(8)
    .background(Color.brandStrokeSubtle)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .accessibilityIdentifier("tidesWaveSection")
  }

  // MARK: - Tides Text Blocks

  private func tidesTextBlocks(tides: RiverConditionsResponse.TidesBlock) -> some View {
    // Reorganized: the user cares first about what's coming next, so the
    // "Next" block sits on top with both its High and its Low together.
    // The "Previous" block follows underneath for reference. Was: "High"
    // and "Low" groups each splitting Previous/Next.
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Next").font(.brandSubheadline).bold().foregroundColor(.brandTextPrimary)
        // The upcoming high tide is the headline number for a guide — keep
        // it highlighted in blue (matches the previous emphasis treatment).
        tideRow(title: "High", point: tides.nextHigh, highlight: true)
        tideRow(title: "Low", point: tides.nextLow, highlight: false)
      }
      .padding(8)
      .background(Color.brandStrokeSubtle)
      .clipShape(RoundedRectangle(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 6) {
        Text("Previous").font(.brandSubheadline).bold().foregroundColor(.brandTextPrimary)
        tideRow(title: "High", point: tides.previousHigh, highlight: false)
        tideRow(title: "Low", point: tides.previousLow, highlight: false)
      }
      .padding(8)
      .background(Color.brandStrokeSubtle)
      .clipShape(RoundedRectangle(cornerRadius: 10))
    }
  }

  private var tideDateColWidth: CGFloat { 170 }

  private func tideRow(title: String, point: RiverConditionsResponse.TidesPoint, highlight: Bool) -> some View {
    let dateText = formattedDateFromDateTime(point.time)
    let timeText = formattedTimeFromDateTime(point.time)

    return HStack(spacing: 6) {
      Text(title)
        .font(.brandCaption2)
        .foregroundColor(.brandTextSecondary)
        .frame(width: 62, alignment: .leading)

      HStack(spacing: 6) {
        Text(dateText)
        Text("•").foregroundColor(.brandTextSecondary)
        Text(timeText).monospacedDigit()
      }
      .font(.brandFootnote)
      .foregroundColor(highlight ? .brandAccent : .brandTextPrimary)
      .frame(width: tideDateColWidth, alignment: .leading)

      Spacer(minLength: 0)

      Text("\(number(displayTideM(point.heightM))) \(tideHeightUnit)")
        .font(.brandFootnote).bold()
        .foregroundColor(highlight ? .brandAccent : .brandTextPrimary)
        .frame(alignment: .trailing)
    }
  }

  // MARK: - Conditions Tab (Water Level / Water Temperature)

  private var conditionsTabSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("", selection: $conditionsTab) {
        ForEach(ConditionsTab.allCases) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("conditionsTabPicker")

      switch conditionsTab {
      case .level:
        waterLevelTabContent
      case .temperature:
        waterTemperatureTabContent
      }
    }
    .padding(8)
    .background(Color.brandStrokeSubtle)
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  @ViewBuilder
  private var waterLevelTabContent: some View {
    let levels = result.waterLevels
    if levels.isEmpty {
      Text("Water level data unavailable")
        .font(.brandFootnote)
        .foregroundColor(.brandTextSecondary)
        .accessibilityIdentifier("waterLevelUnavailable")
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      let last = levels.last!
      // Y-axis bounds in display units (ft / m per community), so the
      // labels in the leading column read in the same unit as the
      // headline above.
      let ysDisplay = levels.map { displayLevelFt($0.levelFt) }
      let minY = ysDisplay.min() ?? 0
      let maxY = ysDisplay.max() ?? 0
      VStack(alignment: .leading, spacing: 6) {
        currentConditionsHeadline(value: "\(number(displayLevelFt(last.levelFt))) \(waterLevelUnit)")
          .accessibilityIdentifier("waterLevelHeader")

        HStack(alignment: .top, spacing: 4) {
          yAxisColumn(min: minY, max: maxY)
          VStack(spacing: 6) {
            WaterLevelSparkline(levels: levels)
              .frame(height: chartHeight)
            xAxisDateLabels(timestamps: levels.map(\.recordedAt))
          }
        }
      }
    }
  }

  @ViewBuilder
  private var waterTemperatureTabContent: some View {
    if let temps = result.waterTemperatures, !temps.isEmpty {
      let last = temps.last!
      let ysDisplay = temps.map { displayTempC($0.tempC) }
      let minY = ysDisplay.min() ?? 0
      let maxY = ysDisplay.max() ?? 0
      VStack(alignment: .leading, spacing: 6) {
        currentConditionsHeadline(value: "\(number(displayTempC(last.tempC)))\(community.tempUnit)")
          .accessibilityIdentifier("waterTempHeader")

        HStack(alignment: .top, spacing: 4) {
          yAxisColumn(min: minY, max: maxY)
          VStack(spacing: 6) {
            WaterTemperatureSparkline(temps: temps)
              .frame(height: chartHeight)
            xAxisDateLabels(timestamps: temps.map(\.recordedAt))
          }
        }
      }
    } else {
      Text("Water temperature data unavailable")
        .font(.brandFootnote)
        .foregroundColor(.brandTextSecondary)
        .accessibilityIdentifier("waterTempUnavailable")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Chart Chrome

  private var chartHeight: CGFloat { 72 }

  private func currentConditionsHeadline(value: String) -> some View {
    Text("Current conditions: \(value)")
      .font(.brandCaption)
      .foregroundColor(.brandTextSecondary)
      // Right-justify so it visually anchors to the trailing edge of
      // the chart strip below it.
      .frame(maxWidth: .infinity, alignment: .trailing)
  }

  /// Fixed-width Y-axis column rendered to the LEFT of the sparkline —
  /// max value at the top, min at the bottom, no axis text. Numbers
  /// trail-align so they sit close to the chart edge, and the column's
  /// fixed width keeps the chart's starting x-position stable regardless
  /// of value length. No "Max"/"Min" label text per spec — just numbers.
  /// Same display unit as the current-conditions headline above (the call
  /// site passes already-converted values).
  private func yAxisColumn(min: Double, max: Double) -> some View {
    VStack(spacing: 0) {
      Text(number(max))
        .font(.brandCaption2)
        .foregroundColor(.brandTextSecondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
      Spacer(minLength: 0)
      Text(number(min))
        .font(.brandCaption2)
        .foregroundColor(.brandTextSecondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .frame(width: 42, height: chartHeight)
    .accessibilityHidden(true)
  }

  /// One date label per local-TZ calendar day, centered horizontally beneath
  /// that day's block of readings on the sparkline. The sparkline plots
  /// entries at uniform index spacing, so a day's center maps to its
  /// midpoint-index as a fraction of (count - 1).
  private func xAxisDateLabels(timestamps: [String]) -> some View {
    let runs = dayRuns(timestamps: timestamps)
    let denominator = Double(Swift.max(timestamps.count - 1, 1))
    return GeometryReader { geo in
      ZStack(alignment: .topLeading) {
        ForEach(runs.indices, id: \.self) { i in
          let r = runs[i]
          let centerIdx = Double(r.firstIndex + r.lastIndex) / 2.0
          let xFrac = denominator == 0 ? 0.5 : centerIdx / denominator
          Text(r.label)
            .font(.brandCaption2)
            .foregroundColor(.brandTextSecondary)
            .position(x: geo.size.width * CGFloat(xFrac), y: 8)
        }
      }
    }
    .frame(height: 16)
  }

  private struct DayRun {
    let label: String
    let firstIndex: Int
    let lastIndex: Int
  }

  private func dayRuns(timestamps: [String]) -> [DayRun] {
    var runs: [DayRun] = []
    var currentKey: DateComponents?
    var currentLabel: String?
    var currentStart: Int = 0
    let cal = Calendar.current
    for (i, ts) in timestamps.enumerated() {
      guard let d = parseDateTime(ts) else { continue }
      let key = cal.dateComponents([.year, .month, .day], from: d)
      if key != currentKey {
        if let label = currentLabel {
          runs.append(.init(label: label, firstIndex: currentStart, lastIndex: i - 1))
        }
        currentKey = key
        currentLabel = DateFormatting.monthDay.string(from: d)
        currentStart = i
      }
    }
    if let label = currentLabel {
      runs.append(.init(label: label, firstIndex: currentStart, lastIndex: timestamps.count - 1))
    }
    return runs
  }

  // MARK: - Footer

  private var footer: some View {
    Text("Powered by Mad Thinker™ 2026")
      .font(.brandFootnote)
      .foregroundColor(.brandTextSecondary.opacity(0.8))
      .multilineTextAlignment(.center)
      .padding(.top, 6)
  }

  // MARK: - Formatting Helpers

  private func number(_ x: Double) -> String {
    DateFormatting.decimal2.string(from: NSNumber(value: x)) ?? "\(x)"
  }

  private func formattedDate(_ ymd: String) -> String {
    if let d = DateFormatting.ymd.date(from: ymd) {
      return DateFormatting.mediumDate.string(from: d)
    }
    return ymd
  }

  private func parseDateTime(_ s: String) -> Date? {
    DateFormatting.parseISOWithTZ(s)
  }

  private func formattedDateFromDateTime(_ s: String) -> String {
    guard let d = parseDateTime(s) else { return s }
    return DateFormatting.monthDay.string(from: d)
  }

  private func formattedTimeFromDateTime(_ s: String) -> String {
    guard let d = parseDateTime(s) else { return s }
    return DateFormatting.shortTime.string(from: d)
  }

  // MARK: - Unit Conversion Helpers
  // Backend always returns: temps in °C, water level in ft, tide height in m,
  // precipitation in mm. Convert here based on the active community's units.

  private func displayTempC(_ celsius: Double) -> Double {
    community.isImperial ? celsius * 9.0 / 5.0 + 32.0 : celsius
  }

  private func displayLevelFt(_ feet: Double) -> Double {
    community.isImperial ? feet : feet * 0.3048
  }

  private var waterLevelUnit: String {
    community.isImperial ? "ft" : "m"
  }

  private func displayTideM(_ meters: Double) -> Double {
    community.isImperial ? meters * 3.28084 : meters
  }

  private var tideHeightUnit: String {
    community.isImperial ? "ft" : "m"
  }

  private func displayPrecipMm(_ mm: Double) -> Double {
    community.isImperial ? mm / 25.4 : mm
  }

  private var precipitationUnit: String {
    community.isImperial ? "in" : "mm"
  }
}

// MARK: - Tide Wave Graph

private struct TideWaveGraph: View {
  let previousHigh: RiverConditionsResponse.TidesPoint
  let nextHigh: RiverConditionsResponse.TidesPoint
  let previousLow: RiverConditionsResponse.TidesPoint
  let nextLow: RiverConditionsResponse.TidesPoint
  let community: CommunityConfig

  private var heightUnit: String { community.isImperial ? "ft" : "m" }
  private func displayHeight(_ meters: Double) -> Double {
    community.isImperial ? meters * 3.28084 : meters
  }

  private struct TideSample {
    let date: Date
    let height: Double
    let isHigh: Bool
  }

  private func parseDateTime(_ s: String) -> Date? {
    DateFormatting.parseISOWithTZ(s)
  }

  private var orderedSamples: [TideSample] {
    let pts: [(RiverConditionsResponse.TidesPoint, Bool)] = [
      (previousHigh, true),
      (previousLow, false),
      (nextHigh, true),
      (nextLow, false)
    ]
    let mapped: [TideSample] = pts.compactMap { p, isHigh in
      guard let d = parseDateTime(p.time) else { return nil }
      return .init(date: d, height: p.heightM, isHigh: isHigh)
    }
    let now = Date()
    let prevs = mapped.filter { $0.date <= now }.sorted { $0.date < $1.date }
    let nexts = mapped.filter { $0.date > now }.sorted { $0.date < $1.date }
    return prevs + nexts
  }

  private var minHeight: Double { orderedSamples.map(\.height).min() ?? 0 }
  private var maxHeight: Double { orderedSamples.map(\.height).max() ?? 1 }

  private func number(_ x: Double) -> String {
    DateFormatting.decimal2.string(from: NSNumber(value: x)) ?? "\(x)"
  }

  /// Vertical space reserved at the top + bottom of the chart for the value
  /// labels. The wave itself plots into the middle band so high-point dots
  /// can never touch the high-label row above them, and low-point dots
  /// can never touch the low-label row below them. Was: labels offset
  /// relative to each dot — produced visible overlaps when a peak/trough
  /// landed near the chart's vertical edge.
  private let labelBand: CGFloat = 22

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let h = geo.size.height
      let samples = orderedSamples
      let yRange = max(0.0001, maxHeight - minHeight)

      let n = max(1, samples.count - 1)
      let horizontalInset: CGFloat = w * 0.07
      let usableWidth = w - (horizontalInset * 2)
      // Plot the wave between [labelBand, h - labelBand] — reserving the
      // top and bottom strips for value labels.
      let waveTop = labelBand
      let waveBottom = h - labelBand
      let pts: [CGPoint] = samples.enumerated().map { idx, s in
        let nx = CGFloat(idx) / CGFloat(n)
        let ny = (s.height - minHeight) / yRange
        let x = horizontalInset + (nx * usableWidth)
        let y = (1 - CGFloat(ny)) * (waveBottom - waveTop) + waveTop
        return CGPoint(x: x, y: y)
      }

      ZStack {
        Canvas { context, _ in
          guard pts.count >= 2 else { return }

          let wave = catmullRomPath(through: pts, tension: 1.0)

          var fillPath = wave
          if let first = pts.first, let last = pts.last {
            fillPath.addLine(to: CGPoint(x: last.x, y: h - 2))
            fillPath.addLine(to: CGPoint(x: first.x, y: h - 2))
            fillPath.closeSubpath()
          }
          context.fill(fillPath, with: .color(Color.brandAccent.opacity(0.12)))

          context.stroke(wave, with: .color(.blue), lineWidth: 2)

          for i in 0 ..< min(pts.count, samples.count) {
            let p = pts[i]
            let isHigh = samples[i].isHigh
            let color: Color = isHigh ? .blue : .teal

            // Connector tick from the dot toward its label band — gives the
            // eye a hard association when the dot sits well away from the
            // top/bottom edge (typical mid-tide samples). Drawn first so
            // the dot draws on top.
            let labelEdgeY: CGFloat = isHigh ? labelBand : (h - labelBand)
            let dotEdgeY: CGFloat = isHigh ? p.y - 5 : p.y + 5
            if abs(dotEdgeY - labelEdgeY) > 3 {
              var line = Path()
              line.move(to: CGPoint(x: p.x, y: dotEdgeY))
              line.addLine(to: CGPoint(x: p.x, y: labelEdgeY))
              context.stroke(
                line,
                with: .color(color.opacity(0.45)),
                style: StrokeStyle(lineWidth: 1, dash: [2, 2])
              )
            }

            let dotRect = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: dotRect), with: .color(color))
            context.stroke(Path(ellipseIn: dotRect), with: .color(Color.brandScrim.opacity(0.85)), lineWidth: 1)
          }
        }

        ForEach(samples.indices, id: \.self) { i in
          let p = pts[i]
          let s = samples[i]
          makeLabel(
            text: "\(number(displayHeight(s.height))) \(heightUnit)",
            color: s.isHigh ? .blue : .teal,
            at: p,
            w: w,
            h: h,
            isHigh: s.isHigh
          )
        }
      }
    }
  }

  /// High labels pin to the chart's top label band; low labels pin to the
  /// bottom band. The wave is plotted between the two bands so the labels
  /// never sit on top of the curve or the dots. Horizontal position
  /// follows the underlying point, clamped so labels can't run off the
  /// chart edges.
  private func makeLabel(
    text: String,
    color: Color,
    at p: CGPoint,
    w: CGFloat,
    h: CGFloat,
    isHigh: Bool
  ) -> some View {
    let labelCenterY: CGFloat = isHigh ? labelBand / 2 : h - labelBand / 2
    return Text(text)
      .font(.brandCaption2)
      .foregroundColor(color)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(Color.brandScrim.opacity(0.5))
      .clipShape(RoundedRectangle(cornerRadius: 5))
      .position(
        x: clamp(p.x, 28, w - 28),
        y: labelCenterY
      )
  }

  private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    min(max(v, lo), hi)
  }

  private func catmullRomPath(through pts: [CGPoint], tension: CGFloat) -> Path {
    var path = Path()
    guard pts.count > 1 else { return path }
    path.move(to: pts[0])

    let n = pts.count
    for i in 0 ..< (n - 1) {
      let p0 = i == 0 ? pts[i] : pts[i - 1]
      let p1 = pts[i]
      let p2 = pts[i + 1]
      let p3 = (i + 2 < n) ? pts[i + 2] : pts[i + 1]

      let c1 = CGPoint(
        x: p1.x + (p2.x - p0.x) / 6.0 * tension,
        y: p1.y + (p2.y - p0.y) / 6.0 * tension
      )
      let c2 = CGPoint(
        x: p2.x - (p3.x - p1.x) / 6.0 * tension,
        y: p2.y - (p3.y - p1.y) / 6.0 * tension
      )

      path.addCurve(to: p2, control1: c1, control2: c2)
    }
    return path
  }
}

// MARK: - Water Level Sparkline

private struct WaterLevelSparkline: View {
  let levels: [RiverConditionsResponse.WaterLevelEntry]

  private var normalizedPoints: [CGPoint] {
    guard !levels.isEmpty else { return [] }
    let ys = levels.map(\.levelFt)
    guard let minY = ys.min(), let maxY = ys.max(), maxY > minY else {
      return levels.indices.map {
        CGPoint(x: CGFloat($0) / CGFloat(max(1, levels.count - 1)), y: 0.5)
      }
    }
    let yRange = maxY - minY
    return levels.indices.map { idx in
      CGPoint(
        x: CGFloat(idx) / CGFloat(max(1, levels.count - 1)),
        y: CGFloat(1.0 - ((ys[idx] - minY) / yRange))
      )
    }
  }

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let h = geo.size.height
      let pts = normalizedPoints.map { CGPoint(x: $0.x * w, y: $0.y * h) }

      ZStack {
        if pts.count > 1 {
          Path { path in
            path.move(to: CGPoint(x: pts.first!.x, y: h))
            for p in pts {
              path.addLine(to: p)
            }
            path.addLine(to: CGPoint(x: pts.last!.x, y: h))
            path.closeSubpath()
          }
          .fill(Color.brandSurface)
        }

        Path { path in
          guard let first = pts.first else { return }
          path.move(to: first)
          for p in pts.dropFirst() {
            path.addLine(to: p)
          }
        }
        .stroke(Color.brandAccent, lineWidth: 2)

        if let last = pts.last {
          Circle()
            .fill(Color.brandAccent)
            .frame(width: 7, height: 7)
            .position(last)
        }
      }
    }
  }
}

private struct WaterTemperatureSparkline: View {
  let temps: [RiverConditionsResponse.WaterTemperatureEntry]
  private var normalizedPoints: [CGPoint] {
    guard !temps.isEmpty else { return [] }
    let ys = temps.map(\.tempC)
    guard let minY = ys.min(), let maxY = ys.max(), maxY > minY else {
      return temps.indices.map {
        CGPoint(x: CGFloat($0) / CGFloat(max(1, temps.count - 1)), y: 0.5)
      }
    }
    let yRange = maxY - minY
    return temps.indices.map { idx in
      CGPoint(
        x: CGFloat(idx) / CGFloat(max(1, temps.count - 1)),
        y: CGFloat(1.0 - ((ys[idx] - minY) / yRange))
      )
    }
  }

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let h = geo.size.height
      let pts = normalizedPoints.map { CGPoint(x: $0.x * w, y: $0.y * h) }

      ZStack {
        if pts.count > 1 {
          Path { path in
            path.move(to: CGPoint(x: pts.first!.x, y: h))
            for p in pts {
              path.addLine(to: p)
            }
            path.addLine(to: CGPoint(x: pts.last!.x, y: h))
            path.closeSubpath()
          }
          .fill(Color.brandSurface)
        }

        Path { path in
          guard let first = pts.first else { return }
          path.move(to: first)
          for p in pts.dropFirst() {
            path.addLine(to: p)
          }
        }
        .stroke(Color.teal, lineWidth: 2)

        if let last = pts.last {
          Circle()
            .fill(Color.teal)
            .frame(width: 7, height: 7)
            .position(last)
        }
      }
    }
  }
}
