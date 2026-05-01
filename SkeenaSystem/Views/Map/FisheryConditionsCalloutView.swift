// Bend Fly Shop
//
// FisheryConditionsCalloutView.swift — Pin-tap callout for the conditions
// recall fishery map. Header carries a pin-colored dot + report-type label
// on the left and the date on the right. Catch pins additionally show
// species/length. Two metric rows compare the report's recorded value to
// "now" so a guide can eyeball the delta without doing math.
//
// Units honor the active community's preferences (imperial vs metric),
// matching the conditions detail view (see commit 95502ae).

import SwiftUI

struct FisheryConditionsCalloutView: View {
  let report: MapReportDTO
  /// Current water temp in °C — pulled from the latest entry of the
  /// fishery's hourly series. Nil when the detail view didn't have one.
  let currentWaterTempC: Double?
  /// Current water level in feet — same as above.
  let currentWaterLevelFt: Double?
  let onDismiss: () -> Void

  private var community: CommunityConfig { CommunityService.shared.activeCommunityConfig }

  private var reportType: GuideLandingAnnotation.ReportType {
    GuideLandingAnnotation.ReportType(rawValue: report.type) ?? .passed
  }

  private static let dateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateStyle = .medium
    df.timeStyle = .none
    return df
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header

      if reportType == .catch_ {
        catchSpeciesRow
      }

      Divider().background(Color.white.opacity(0.2))

      metricRow(
        label: "Water temp",
        reportValueC: report.waterTempC,
        currentValueC: currentWaterTempC,
        kind: .temperature
      )
      metricRow(
        label: "Water level",
        reportValueC: report.waterLevelFt,
        currentValueC: currentWaterLevelFt,
        kind: .level
      )
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(minWidth: 220)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(.regularMaterial)
        .shadow(radius: 4)
    )
    .onTapGesture { onDismiss() }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(Color(reportType.pinColor))
        .frame(width: 8, height: 8)
      Text(reportTypeLabel)
        .font(.subheadline.weight(.semibold))
        .foregroundColor(.primary)
      Spacer(minLength: 8)
      Text(formattedDate)
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  private var reportTypeLabel: String {
    switch reportType {
    case .catch_:    return "Catch"
    case .active:    return "Active"
    case .farmed:    return "Farmed"
    case .promising: return "Promising"
    case .passed:    return "Passed"
    }
  }

  private var formattedDate: String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = f.date(from: report.date)
      ?? ISO8601DateFormatter().date(from: report.date)
    guard let d = date else { return report.date }
    return Self.dateFormatter.string(from: d)
  }

  // MARK: - Catch metadata

  @ViewBuilder
  private var catchSpeciesRow: some View {
    let species = (report.species ?? "").trimmingCharacters(in: .whitespaces)
    let length = report.lengthInches
    if !species.isEmpty || length != nil {
      HStack(spacing: 6) {
        if !species.isEmpty {
          Text(species)
            .font(.footnote.weight(.medium))
            .foregroundColor(.primary)
        }
        if !species.isEmpty, length != nil {
          Text("·").foregroundColor(.secondary)
        }
        if let length {
          Text("\(length)″")
            .font(.footnote)
            .foregroundColor(.secondary)
        }
      }
    }
  }

  // MARK: - Metric rows

  private enum MetricKind { case temperature, level }

  /// Single comparison row. `reportValueC` and `currentValueC` are in the
  /// canonical units the API uses (°C and feet); we convert at display.
  private func metricRow(
    label: String,
    reportValueC: Double?,
    currentValueC: Double?,
    kind: MetricKind
  ) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(width: 80, alignment: .leading)

      Text(format(reportValueC, kind: kind))
        .font(.caption.weight(.semibold))
        .foregroundColor(.primary)
        .frame(width: 64, alignment: .leading)

      Text("now \(format(currentValueC, kind: kind))")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  private func format(_ valueC: Double?, kind: MetricKind) -> String {
    guard let v = valueC else { return "—" }
    switch kind {
    case .temperature:
      let display = community.isImperial ? (v * 9.0 / 5.0 + 32.0) : v
      return "\(round1(display))\(community.tempUnit)"
    case .level:
      let display = community.isImperial ? v : (v * 0.3048)
      let unit = community.isImperial ? "ft" : "m"
      return "\(round1(display)) \(unit)"
    }
  }

  private func round1(_ x: Double) -> String {
    String(format: "%.1f", x)
  }
}
