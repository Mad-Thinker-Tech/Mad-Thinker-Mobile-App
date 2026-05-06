// Bend Fly Shop
//
// Shared cached formatters. DateFormatter and ISO8601DateFormatter are expensive
// to create (~50-100 µs each). This file provides static instances for the
// handful of format patterns used throughout the app, so each pattern is only
// created once for the lifetime of the process.

import Foundation

nonisolated enum DateFormatting {

  // MARK: - ISO 8601 (parsing API timestamps)

  /// ISO 8601 with fractional seconds: "2025-06-01T14:30:00.000Z"
  static let iso8601WithFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  /// ISO 8601 without fractional seconds: "2025-06-01T14:30:00Z"
  static let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  /// ISO 8601 with fractional seconds and time zone.
  static let iso8601FractionalTZ: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
    return f
  }()

  /// ISO 8601 with time zone (no fractional seconds).
  static let iso8601TZ: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withTimeZone]
    return f
  }()

  // MARK: - Date-only patterns

  /// "yyyy-MM-dd" — the most common date-only format in the app.
  static let ymd: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  /// "ddMMyyyy" — used for solo trip ID generation.
  static let ddMMyyyy: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "ddMMyyyy"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  // MARK: - Date + time patterns

  /// "yyyy-MM-dd HH:mm" — used by forecast parsing.
  static let ymdHm: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  // MARK: - Display formatters (localized)

  /// Medium date, short time — "Jun 1, 2025, 2:30 PM"
  static let mediumDateTime: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()

  /// Medium date only — "Jun 1, 2025"
  static let mediumDate: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
  }()

  /// Short time only — "2:30 PM"
  static let shortTime: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f
  }()

  /// "EEE, MMM d" — "Mon, Jun 1"
  static let weekdayMonthDay: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE, MMM d"
    return f
  }()

  /// Template-based "MMM d" — "Jun 1"
  static let monthDay: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMM d")
    return f
  }()

  // MARK: - Hour label (weather)

  /// Input: "HH:mm" (24h) — used to parse weather hour strings.
  static let hour24: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  /// Output: "ha" — "2PM"
  static let hourAMPM: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "ha"
    return f
  }()

  // MARK: - Number formatting

  /// Up to 2 decimal places.
  static let decimal2: NumberFormatter = {
    let f = NumberFormatter()
    f.maximumFractionDigits = 2
    return f
  }()

  // MARK: - Convenience parsers

  /// Parse an ISO 8601 string, trying fractional seconds first then plain.
  static func parseISO(_ string: String) -> Date? {
    iso8601WithFractional.date(from: string)
      ?? iso8601.date(from: string)
  }

  /// Parse an ISO 8601 string with time zone variants (forecast data).
  static func parseISOWithTZ(_ string: String) -> Date? {
    iso8601FractionalTZ.date(from: string)
      ?? iso8601TZ.date(from: string)
      ?? ymdHm.date(from: string)
  }
}
