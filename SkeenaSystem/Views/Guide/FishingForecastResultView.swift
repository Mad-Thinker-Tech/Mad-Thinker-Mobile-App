// Bend Fly Shop

import SwiftUI
import Combine

// MARK: - Models

struct RiverConditionsResponse: Decodable {
  let river: String
  let stationId: String
  let date: String
  let isTidal: Bool

  let weather: WeatherBlock
  let tides: TidesBlock?
  let waterLevels: [WaterLevelEntry]
  let waterTemperatures: [WaterTemperatureEntry]?

  struct WeatherBlock: Decodable {
    let previousDay: DayBlock
    let targetDay: DayBlock
    let nextDay: DayBlock
  }

  struct DayBlock: Decodable {
    let date: String
    let highTempC: Double
    let lowTempC: Double
    let precipitationMm: Double
  }

  struct TidesBlock: Decodable {
    let previousHigh: TidesPoint
    let nextHigh: TidesPoint
    let previousLow: TidesPoint
    let nextLow: TidesPoint
  }

  struct TidesPoint: Decodable {
    let time: String
    let heightM: Double
    let type: String
  }

  /// Hour-aligned water-level sample.
  /// `recordedAt` is a UTC ISO 8601 timestamp (e.g. "2026-04-30T14:00:00.000Z");
  /// callers convert to the device's local timezone for display.
  struct WaterLevelEntry: Decodable, Identifiable {
    let recordedAt: String
    let levelFt: Double
    var id: String { recordedAt }
  }

  /// Hour-aligned water-temperature sample. `recordedAt` is UTC ISO 8601.
  struct WaterTemperatureEntry: Decodable, Identifiable {
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

struct FishingForecastResultView: View {
  let result: RiverConditionsResponse

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
      Color.black.ignoresSafeArea()

      VStack(spacing: 12) {
        ScrollView {
          VStack(spacing: 12) {
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
            .font(.headline)
            .foregroundColor(.primary)

          Text("Using Station: \(result.stationId)")
            .font(.subheadline)
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
              .foregroundColor(.white)
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
              .foregroundColor(.white)
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
    .background(Color.white.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .accessibilityIdentifier("weatherSection")
  }

  private func dayCard(label: String, day: RiverConditionsResponse.DayBlock, isToday: Bool) -> some View {
    VStack(spacing: 6) {
      Text(label)
        .font(.caption).bold()
        .foregroundColor(isToday ? .blue : .white)

      Text(formattedDate(day.date))
        .font(.caption2)
        .foregroundColor(isToday ? .blue.opacity(0.9) : .gray)

      VStack(spacing: 3) {
        rowMetric("High", "\(number(displayTempC(day.highTempC)))\(community.tempUnit)", highlight: isToday)
        rowMetric("Low", "\(number(displayTempC(day.lowTempC)))\(community.tempUnit)", highlight: isToday)
        rowMetric("Precip", "\(number(displayPrecipMm(day.precipitationMm))) \(precipitationUnit)", highlight: isToday)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity)
    .background(Color.white.opacity(0.04))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private func rowMetric(_ label: String, _ value: String, highlight: Bool) -> some View {
    HStack {
      Text(label).font(.caption2).foregroundColor(.gray)
      Spacer()
      Text(value).font(.footnote).foregroundColor(highlight ? .blue : .white)
    }
  }

  // MARK: - Tide Wave Card

  private func tideWaveCard(tides: RiverConditionsResponse.TidesBlock) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Tide Heights")
        .font(.subheadline).foregroundColor(.white)

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
    .background(Color.white.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .accessibilityIdentifier("tidesWaveSection")
  }

  // MARK: - Tides Text Blocks

  private func tidesTextBlocks(tides: RiverConditionsResponse.TidesBlock) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 6) {
        Text("High").font(.subheadline).bold().foregroundColor(.white)
        tideRow(title: "Previous", point: tides.previousHigh, highlight: false)
        tideRow(title: "Next", point: tides.nextHigh, highlight: true)
      }
      .padding(8)
      .background(Color.white.opacity(0.06))
      .clipShape(RoundedRectangle(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 6) {
        Text("Low").font(.subheadline).bold().foregroundColor(.white)
        tideRow(title: "Previous", point: tides.previousLow, highlight: false)
        tideRow(title: "Next", point: tides.nextLow, highlight: false)
      }
      .padding(8)
      .background(Color.white.opacity(0.06))
      .clipShape(RoundedRectangle(cornerRadius: 10))
    }
  }

  private var tideDateColWidth: CGFloat { 170 }

  private func tideRow(title: String, point: RiverConditionsResponse.TidesPoint, highlight: Bool) -> some View {
    let dateText = formattedDateFromDateTime(point.time)
    let timeText = formattedTimeFromDateTime(point.time)

    return HStack(spacing: 6) {
      Text(title)
        .font(.caption2)
        .foregroundColor(.gray)
        .frame(width: 62, alignment: .leading)

      HStack(spacing: 6) {
        Text(dateText)
        Text("•").foregroundColor(.gray)
        Text(timeText).monospacedDigit()
      }
      .font(.footnote)
      .foregroundColor(highlight ? .blue : .white)
      .frame(width: tideDateColWidth, alignment: .leading)

      Spacer(minLength: 0)

      Text("\(number(displayTideM(point.heightM))) \(tideHeightUnit)")
        .font(.footnote).bold()
        .foregroundColor(highlight ? .blue : .white)
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
    .background(Color.white.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  @ViewBuilder
  private var waterLevelTabContent: some View {
    let levels = result.waterLevels
    if levels.isEmpty {
      Text("Water level data unavailable")
        .font(.footnote)
        .foregroundColor(.gray)
        .accessibilityIdentifier("waterLevelUnavailable")
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      let last = levels.last!
      VStack(alignment: .leading, spacing: 6) {
        currentConditionsHeadline(value: "\(number(displayLevelFt(last.levelFt))) \(waterLevelUnit)")
          .accessibilityIdentifier("waterLevelHeader")

        WaterLevelSparkline(levels: levels)
          .frame(height: chartHeight)

        xAxisDateLabels(timestamps: levels.map(\.recordedAt))
      }
    }
  }

  @ViewBuilder
  private var waterTemperatureTabContent: some View {
    if let temps = result.waterTemperatures, !temps.isEmpty {
      let last = temps.last!
      VStack(alignment: .leading, spacing: 6) {
        currentConditionsHeadline(value: "\(number(displayTempC(last.tempC)))\(community.tempUnit)")
          .accessibilityIdentifier("waterTempHeader")

        WaterTemperatureSparkline(temps: temps)
          .frame(height: chartHeight)

        xAxisDateLabels(timestamps: temps.map(\.recordedAt))
      }
    } else {
      Text("Water temperature data unavailable")
        .font(.footnote)
        .foregroundColor(.gray)
        .accessibilityIdentifier("waterTempUnavailable")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Chart Chrome

  private var chartHeight: CGFloat { 72 }

  private func currentConditionsHeadline(value: String) -> some View {
    Text("Current conditions: \(value)")
      .font(.caption)
      .foregroundColor(.gray)
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
            .font(.caption2)
            .foregroundColor(.gray)
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
      .font(.footnote)
      .foregroundColor(.gray.opacity(0.8))
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

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let h = geo.size.height
      let samples = orderedSamples
      let yRange = max(0.0001, maxHeight - minHeight)

      let n = max(1, samples.count - 1)
      let horizontalInset: CGFloat = w * 0.07
      let usableWidth = w - (horizontalInset * 2)
      let pts: [CGPoint] = samples.enumerated().map { idx, s in
        let nx = CGFloat(idx) / CGFloat(n)
        let ny = (s.height - minHeight) / yRange
        let x = horizontalInset + (nx * usableWidth)
        let y = (1 - CGFloat(ny)) * (h - 20) + 10
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
          context.fill(fillPath, with: .color(Color.blue.opacity(0.12)))

          context.stroke(wave, with: .color(.blue), lineWidth: 2)

          for i in 0 ..< min(pts.count, samples.count) {
            let p = pts[i]
            let isHigh = samples[i].isHigh
            let color: Color = isHigh ? .blue : .teal
            let dotRect = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: dotRect), with: .color(color))
            context.stroke(Path(ellipseIn: dotRect), with: .color(Color.black.opacity(0.85)), lineWidth: 1)
          }
        }

        Group {
          if !pts.isEmpty, !samples.isEmpty {
            let p = pts[0]; let s = samples[0]
            makeLabel(
              text: "\(number(displayHeight(s.height))) \(heightUnit)",
              color: s.isHigh ? .blue : .teal,
              at: p,
              index: 0,
              w: w,
              h: h,
              isHigh: s.isHigh
            )
          }
          if pts.count > 1, samples.count > 1 {
            let p = pts[1]; let s = samples[1]
            makeLabel(
              text: "\(number(displayHeight(s.height))) \(heightUnit)",
              color: s.isHigh ? .blue : .teal,
              at: p,
              index: 1,
              w: w,
              h: h,
              isHigh: s.isHigh
            )
          }
          if pts.count > 2, samples.count > 2 {
            let p = pts[2]; let s = samples[2]
            makeLabel(
              text: "\(number(displayHeight(s.height))) \(heightUnit)",
              color: s.isHigh ? .blue : .teal,
              at: p,
              index: 2,
              w: w,
              h: h,
              isHigh: s.isHigh
            )
          }
          if pts.count > 3, samples.count > 3 {
            let p = pts[3]; let s = samples[3]
            makeLabel(
              text: "\(number(displayHeight(s.height))) \(heightUnit)",
              color: s.isHigh ? .blue : .teal,
              at: p,
              index: 3,
              w: w,
              h: h,
              isHigh: s.isHigh
            )
          }
        }
      }
    }
  }

  private func makeLabel(
    text: String,
    color: Color,
    at p: CGPoint,
    index i: Int,
    w: CGFloat,
    h: CGFloat,
    isHigh: Bool
  ) -> some View {
    var offsetY: CGFloat = isHigh ? -18 : 18
    if i == 1 || i == 2 { offsetY += isHigh ? -8 : 8 }

    return Text(text)
      .font(.caption2)
      .foregroundColor(color)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(Color.black.opacity(0.5))
      .clipShape(RoundedRectangle(cornerRadius: 5))
      .position(
        x: clamp(p.x, 24, w - 24),
        y: clamp(p.y + offsetY, 10, h - 10)
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
          .fill(Color.white.opacity(0.08))
        }

        Path { path in
          guard let first = pts.first else { return }
          path.move(to: first)
          for p in pts.dropFirst() {
            path.addLine(to: p)
          }
        }
        .stroke(Color.blue, lineWidth: 2)

        if let last = pts.last {
          Circle()
            .fill(Color.blue)
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
          .fill(Color.white.opacity(0.08))
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
