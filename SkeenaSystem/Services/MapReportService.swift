// Bend Fly Shop

import Foundation

// MARK: - DTOs

struct MapReportDTO: Decodable, Identifiable {
  var id: String
  let type: String          // "catch" | "active" | "farmed" | "promising" | "passed"
  let date: String
  let latitude: Double?
  let longitude: Double?
  let species: String?
  let lengthInches: Int?
  let memberId: String?
  /// River name the report was filed against. Used by the conditions-recall
  /// fishery map to scope pins to a single fishery.
  let river: String?
  /// Water temperature recorded with the report, in °C. NULL when the report
  /// pre-dates server-side enrichment or the gauge value was unavailable.
  /// Consumed by the conditions-recall fishery map.
  let waterTempC: Double?
  /// Water level recorded with the report, in feet. NULL — same as above.
  let waterLevelFt: Double?

  // Existing fields (`lengthInches`, `memberId`) come back camelCase from the
  // API; the new fields (`river`, `water_temp_c`, `water_level_ft`) come back
  // snake_case. Explicit keys keep both conventions honest in one place.
  private enum CodingKeys: String, CodingKey {
    case id, type, date, latitude, longitude, species, lengthInches, memberId, river
    case waterTempC = "water_temp_c"
    case waterLevelFt = "water_level_ft"
  }
}

struct MapReportsResponse: Decodable {
  let reports: [MapReportDTO]
  let count: Int
}

// MARK: - Service

enum MapReportService {

  /// Fetches map pins for a community.
  /// - Parameters:
  ///   - fromDate / toDate: window override. Defaults preserve the legacy
  ///     last-3-years window so existing callers (landing tiles) keep their
  ///     behavior; the full-page guide map passes a narrower window from the
  ///     filter bar.
  static func fetch(
    communityId: String,
    memberId: String? = nil,
    fromDate: Date? = nil,
    toDate: Date? = nil
  ) async throws -> [MapReportDTO] {
    let base = AppEnvironment.shared.projectURL
    guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      throw URLError(.badURL)
    }
    let existingPath = comps.path == "/" ? "" : comps.path
    comps.path = existingPath + "/functions/v1/map-reports"
    let resolvedTo = toDate ?? Date()
    let resolvedFrom = fromDate
      ?? Calendar.current.date(byAdding: .year, value: -3, to: resolvedTo)
      ?? resolvedTo
    let toDateString = DateFormatting.iso8601.string(from: resolvedTo)
    let fromDateString = DateFormatting.iso8601.string(from: resolvedFrom)
    var queryItems = [
      URLQueryItem(name: "community_id", value: communityId),
      URLQueryItem(name: "from_date",    value: fromDateString),
      URLQueryItem(name: "to_date",      value: toDateString),
    ]
    if let memberId {
      queryItems.append(URLQueryItem(name: "member_id", value: memberId))
    }
    comps.queryItems = queryItems
    guard let url = comps.url else { throw URLError(.badURL) }

    AppLogging.log("[MapReports] REQUEST → \(url.absoluteString)", level: .debug, category: .map)

    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue(AppEnvironment.shared.anonKey, forHTTPHeaderField: "apikey")

    if let token = await AuthService.shared.currentAccessToken(), !token.isEmpty {
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

    AppLogging.log("[MapReports] RESPONSE ← HTTP \(code), \(data.count) bytes", level: .debug, category: .map)

    guard (200..<300).contains(code) else {
      let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
      AppLogging.log("[MapReports] ERROR body: \(body)", level: .error, category: .map)
      throw URLError(.badServerResponse)
    }

    let decoded = try JSONDecoder().decode(MapReportsResponse.self, from: data)
    AppLogging.log({ "[MapReports] Decoded \(decoded.count) reports — types: \(decoded.reports.map(\.type).joined(separator: ", "))" }, level: .info, category: .map)
    for r in decoded.reports {
      AppLogging.log({
        let lat = r.latitude.map { String($0) } ?? "nil"
        let lon = r.longitude.map { String($0) } ?? "nil"
        let river = r.river.map { "\"\($0)\"" } ?? "nil"
        let temp = r.waterTempC.map { String($0) } ?? "nil"
        let level = r.waterLevelFt.map { String($0) } ?? "nil"
        return "[MapReports]   id=\(r.id) type=\(r.type) lat=\(lat) lon=\(lon) river=\(river) tempC=\(temp) levelFt=\(level)"
      }, level: .debug, category: .map)
    }
    return decoded.reports
  }
}
