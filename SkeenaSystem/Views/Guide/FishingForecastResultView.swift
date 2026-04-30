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

  struct WaterLevelEntry: Decodable, Identifiable {
    let date: String
    let levelFt: Double
    var id: String { date }
  }

  struct WaterTemperatureEntry: Decodable, Identifiable {
    let date: String
    let tempC: Double
    var id: String { date }
  }
}

// MARK: - Root View

struct FishingForecastResultView: View {
  let result: RiverConditionsResponse

  @StateObject private var auth = AuthService.shared
  @State private var showTactics = false

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      VStack(spacing: 12) {
        headerRow // ⬅️ "Get Tactics" aligned to the right

        ScrollView {
          VStack(spacing: 12) {
            weatherThreeDayCompact
            if result.isTidal, let tides = result.tides {
              tideWaveCard(tides: tides)
              tidesTextBlocks(tides: tides)
            }
            waterLevelTrendSection
            waterTemperatureSection
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
    }
  }

  // MARK: - Header Row: "Get Tactics" pushed to the right

  private var headerRow: some View {
    HStack {
      Spacer()

      if auth.currentUserType == .guide, AppEnvironment.shared.tacticsEnabled {
        Button {
          showTactics = true
        } label: {
          Text("Get Tactics")
            .font(.caption).bold()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
              Capsule()
                .fill(Color.blue.opacity(0.9))
            )
            .overlay(
              Capsule()
                .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 8)
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
        rowMetric("High", "\(number(day.highTempC))°C", highlight: isToday)
        rowMetric("Low", "\(number(day.lowTempC))°C", highlight: isToday)
        rowMetric("Precip", "\(number(day.precipitationMm)) mm", highlight: isToday)
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
        nextLow: tides.nextLow
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

      Text("\(number(point.heightM)) m")
        .font(.footnote).bold()
        .foregroundColor(highlight ? .blue : .white)
        .frame(alignment: .trailing)
    }
  }

  // MARK: - Water Level Trend

  private var waterLevelTrendSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Water Level (Last 4 Days)")
        .font(.subheadline).foregroundColor(.white)
        .accessibilityIdentifier("waterLevelHeader")

      WaterLevelSparkline(levels: result.waterLevels)
        .frame(height: 72)

      HStack {
        if let first = result.waterLevels.first {
          Text("\(formattedDate(first.date)) • \(number(first.levelFt)) ft")
            .font(.caption2).foregroundColor(.gray)
        }
        Spacer()
        if let last = result.waterLevels.last {
          Text("\(formattedDate(last.date)) • \(number(last.levelFt)) ft")
            .font(.caption2).foregroundColor(.white)
        }
      }
    }
    .padding(8)
    .background(Color.white.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  // MARK: - Water Temperature (Optional)

  private var waterTemperatureSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Water Temperature (Last 4 Days)")
        .font(.subheadline).foregroundColor(.white)
        .accessibilityIdentifier("waterTempHeader")

      if let temps = result.waterTemperatures, !temps.isEmpty {
        WaterTemperatureSparkline(temps: temps)
          .frame(height: 72)

        HStack {
          if let first = temps.first {
            Text("\(formattedDate(first.date)) • \(number(first.tempC)) °C")
              .font(.caption2).foregroundColor(.gray)
          }
          Spacer()
          if let last = temps.last {
            Text("\(formattedDate(last.date)) • \(number(last.tempC)) °C")
              .font(.caption2).foregroundColor(.white)
          }
        }
      } else {
        Text("Current water temperature unavailable")
          .font(.footnote)
          .foregroundColor(.gray)
          .accessibilityIdentifier("waterTempUnavailable")
      }
    }
    .padding(8)
    .background(Color.white.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 10))
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
}

// MARK: - Tide Wave Graph

private struct TideWaveGraph: View {
  let previousHigh: RiverConditionsResponse.TidesPoint
  let nextHigh: RiverConditionsResponse.TidesPoint
  let previousLow: RiverConditionsResponse.TidesPoint
  let nextLow: RiverConditionsResponse.TidesPoint

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
              text: "\(number(s.height)) m",
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
              text: "\(number(s.height)) m",
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
              text: "\(number(s.height)) m",
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
              text: "\(number(s.height)) m",
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
