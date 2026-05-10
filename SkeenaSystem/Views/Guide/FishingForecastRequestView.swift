// Bend Fly Shop

import SwiftUI

struct FishingForecastRequestView: View {
  // Endpoint: public, no auth — built robustly like TripRosterAPI
  private static let rawBaseURLString = APIURLUtilities.infoPlistString(forKey: "API_BASE_URL")
  private static let baseURLString = APIURLUtilities.normalizeBaseURL(rawBaseURLString)
  private static let riverConditionsPath: String = {
    // Fallback default path (adjust if your function path differs)
    let path = APIURLUtilities.infoPlistString(forKey: "RIVER_CONDITIONS_PATH")
    return path.isEmpty ? "/functions/v1/river-conditions" : path
  }()

  private static func logConfig() {
    AppLogging.log("[Forecast] config — API_BASE_URL (raw): '" + rawBaseURLString + "'", level: .debug, category: .trip)
    AppLogging.log("[Forecast] config — API_BASE_URL (normalized): '" + baseURLString + "'", level: .debug, category: .trip)
    AppLogging.log("[Forecast] config — river path: '" + riverConditionsPath + "'", level: .debug, category: .trip)
  }

  private static func makeURL() throws -> URL {
    guard let base = URL(string: baseURLString), let scheme = base.scheme, let host = base.host else {
      AppLogging.log("[Forecast] invalid API_BASE_URL — raw: '" + rawBaseURLString + "', normalized: '" + baseURLString + "'", level: .error, category: .trip)
      throw NSError(domain: "Forecast", code: -1000, userInfo: [NSLocalizedDescriptionKey: "Invalid API_BASE_URL (raw: '" + rawBaseURLString + "', normalized: '" + baseURLString + "')"])
    }
    var comps = URLComponents()
    comps.scheme = scheme
    comps.host = host
    comps.port = base.port

    let basePath = base.path
    let normalizedBasePath = basePath == "/" ? "" : (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath)
    let normalizedPath = riverConditionsPath.hasPrefix("/") ? riverConditionsPath : "/" + riverConditionsPath
    comps.path = normalizedBasePath + normalizedPath

    // Preserve any base query from API_BASE_URL
    let existing = base.query != nil ? URLComponents(string: base.absoluteString)?.queryItems ?? [] : []
    comps.queryItems = existing

    guard let url = comps.url else {
      throw NSError(domain: "Forecast", code: -1001, userInfo: [NSLocalizedDescriptionKey: "Failed to build river-conditions URL"])
    }
    return url
  }

  // Batch endpoint: derived from single-river path
  private static let riverConditionsBatchPath = riverConditionsPath + "-batch"

  private static func makeBatchURL() throws -> URL {
    guard let base = URL(string: baseURLString), let scheme = base.scheme, let host = base.host else {
      AppLogging.log("[Forecast] invalid API_BASE_URL — raw: '" + rawBaseURLString + "', normalized: '" + baseURLString + "'", level: .error, category: .trip)
      throw NSError(domain: "Forecast", code: -1000, userInfo: [NSLocalizedDescriptionKey: "Invalid API_BASE_URL"])
    }
    var comps = URLComponents()
    comps.scheme = scheme
    comps.host = host
    comps.port = base.port

    let basePath = base.path
    let normalizedBasePath = basePath == "/" ? "" : (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath)
    let normalizedPath = riverConditionsBatchPath.hasPrefix("/") ? riverConditionsBatchPath : "/" + riverConditionsBatchPath
    comps.path = normalizedBasePath + normalizedPath

    let existing = base.query != nil ? URLComponents(string: base.absoluteString)?.queryItems ?? [] : []
    comps.queryItems = existing

    guard let url = comps.url else {
      throw NSError(domain: "Forecast", code: -1001, userInfo: [NSLocalizedDescriptionKey: "Failed to build river-conditions-batch URL"])
    }
    return url
  }

  // MARK: - Ordering

  /// Orders water sources for the conditions list by metric availability,
  /// then alphabetically (case-insensitive) within each bucket. Buckets:
  ///   0 — both water level and water temperature available
  ///   1 — water level only
  ///   2 — water temperature only
  ///   3 — neither (or no batch entry yet)
  ///
  /// Exposed as a `static` taking closures so the regression test can pin
  /// the bucketing without standing up `BatchCondition` (a private type)
  /// or the full view.
  static func sortByConditions(
    sources: [String],
    hasLevel: (String) -> Bool,
    hasTemp: (String) -> Bool
  ) -> [String] {
    func bucket(_ name: String) -> Int {
      switch (hasLevel(name), hasTemp(name)) {
      case (true, true):   return 0
      case (true, false):  return 1
      case (false, true):  return 2
      case (false, false): return 3
      }
    }
    return sources.sorted { lhs, rhs in
      let (a, b) = (bucket(lhs), bucket(rhs))
      if a != b { return a < b }
      return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }
  }

  // MARK: - State

  @State private var loadingRiver: String?
  @State private var errorText: String?
  @State private var result: RiverConditionsResponse?
  @State private var goToResult = false

  // Batch conditions (fetched on appear)
  @State private var batchConditions: [String: BatchCondition] = [:]
  @State private var batchLoading = false

  @Environment(\.dismiss) private var dismiss

  // MARK: - Body

  var body: some View {
    DarkPageTemplate(bottomToolbar: {
      RoleAwareToolbar(activeTab: "conditions")
    }) {
      ScrollView {
        VStack(spacing: 16) {
          // Logo + Title
          AppHeader()
            .padding(.top, 20)

          // Water body rows — rivers + water bodies, stacked vertically.
          // Ordered by metric availability so guides land on the most-
          // useful fisheries first; ties break alphabetically. Pre-batch
          // (empty `batchConditions`) every source falls into the "neither"
          // bucket, so the list reads alphabetically until the batch
          // arrives, then re-sorts.
          let rivers = CommunityService.shared.activeCommunityConfig.resolvedLodgeRivers
          let waterBodies = CommunityService.shared.activeCommunityConfig.resolvedLodgeWaterBodies
          let allWaterSources = Self.sortByConditions(
            sources: rivers + waterBodies,
            hasLevel: { batchConditions[$0]?.waterLevelFt != nil },
            hasTemp: { batchConditions[$0]?.waterTempC != nil }
          )

          if allWaterSources.isEmpty {
            VStack(spacing: 12) {
              Image(systemName: "mappin.slash")
                .font(.brandTitle)
                .foregroundColor(.brandTextSecondary)
              Text("No locations configured")
                .font(.brandHeadline)
                .foregroundColor(.brandTextPrimary)
              Text("Please contact your community administrator.")
                .font(.brandSubheadline)
                .foregroundColor(.brandTextSecondary)
                .multilineTextAlignment(.center)
            }
            .padding(.vertical, 40)
            .padding(.horizontal, 20)
          } else {
            VStack(spacing: 8) {
              // Column headers aligned above metrics
              HStack(spacing: 0) {
                Spacer()
                HStack(spacing: 12) {
                  Text("Level")
                    .font(.brandCaption2)
                    .foregroundColor(.brandTextSecondary)
                    .frame(width: 70, alignment: .center)
                  Text("Temp")
                    .font(.brandCaption2)
                    .foregroundColor(.brandTextSecondary)
                    .frame(width: 70, alignment: .center)
                }
                // Match chevron + padding space
                Color.clear.frame(width: 28)
              }
              .padding(.horizontal, 16)
              ForEach(allWaterSources, id: \.self) { source in
                Button {
                  fetchConditions(for: source)
                } label: {
                  riverRow(name: source, isLoading: loadingRiver == source)
                }
                .buttonStyle(.plain)
                .disabled(loadingRiver != nil)
              }
            }
            .padding(.horizontal, 20)
          }

          // Station note (from xcconfig) — only show when locations are configured
          if !allWaterSources.isEmpty, let notes = Bundle.main.object(forInfoDictionaryKey: "FORECAST_NOTES") as? String, !notes.isEmpty {
            Text(notes)
              .font(.brandCaption2)
              .foregroundColor(.brandTextSecondary)
              .multilineTextAlignment(.center)
              .padding(.horizontal, 24)
          }

          // Extended forecast link (gated by tacticsEnabled + location configured)
          if AppEnvironment.shared.tacticsEnabled, let forecastLoc = CommunityService.shared.activeCommunityConfig.resolvedForecastLocation {
            NavigationLink {
              AnglerForecastView(location: forecastLoc)
            } label: {
              HStack(spacing: 6) {
                Image(systemName: "cloud.sun.rain")
                  .font(.brandSubheadline)
                Text("Get extended forecast")
                  .font(.brandSubheadline.weight(.medium))
              }
              .foregroundColor(.brandAccent)
            }
            .buttonStyle(.plain)
          }

          // Error (if any)
          if let err = errorText {
            Text(err)
              .font(.brandCaption)
              .foregroundColor(.brandError.opacity(0.9))
              .multilineTextAlignment(.center)
              .padding(.horizontal, 20)
          }

          Spacer(minLength: 40)
        }
      }
    }
    .task { fetchBatchConditions() }
    .navigationTitle("Conditions")
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button {
          dismiss()
        } label: {
          Image(systemName: "chevron.left")
            .foregroundColor(.brandTextPrimary)
        }
        .accessibilityIdentifier("conditionsBackButton")
        .accessibilityLabel("Back")
      }
    }
    .navigationDestination(isPresented: $goToResult) {
      if let res = result {
        FishingForecastResultView(result: res)
      }
    }
  }

  // MARK: - River Row

  @ViewBuilder
  private func riverRow(name: String, isLoading: Bool) -> some View {
    HStack(spacing: 0) {
      // River name — left-justified
      Text(name)
        .font(.brandSubheadline.weight(.semibold))
        .foregroundColor(.brandTextPrimary)
        .lineLimit(1)

      Spacer(minLength: 12)

      // Metrics from batch response (or loading placeholder). Backend always
      // returns water level in feet and temperature in °C; we display in the
      // units configured for the active community.
      if let condition = batchConditions[name] {
        let community = CommunityService.shared.activeCommunityConfig
        HStack(spacing: 12) {
          if let level = condition.waterLevelFt {
            metricLabel(
              value: String(format: "%.2f", community.displayLevelFt(level)),
              unit: community.waterLevelUnit,
              icon: "water.waves"
            )
            .frame(width: 70)
          } else {
            Text("--")
              .font(.brandCaption)
              .foregroundColor(.brandTextSecondary.opacity(0.5))
              .frame(width: 70)
          }
          if let temp = condition.waterTempC {
            metricLabel(
              value: String(format: "%.1f", community.displayTempC(temp)),
              unit: community.tempUnit,
              icon: "thermometer.medium"
            )
            .frame(width: 70)
          } else {
            Text("--")
              .font(.brandCaption)
              .foregroundColor(.brandTextSecondary.opacity(0.5))
              .frame(width: 70)
          }
        }
      } else if batchLoading {
        ProgressView()
          .tint(.gray)
          .scaleEffect(0.7)
      }

      // Disclosure chevron
      Image(systemName: "chevron.right")
        .font(.brandCaption)
        .foregroundColor(.brandTextSecondary)
        .padding(.leading, 12)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .background(isLoading ? Color.brandSurface : Color.brandBackground)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.brandStrokeStrong, lineWidth: 0.5)
    )
    .overlay {
      if isLoading {
        ProgressView()
          .tint(.white)
      }
    }
  }

  @ViewBuilder
  private func metricLabel(value: String, unit: String, icon: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: icon)
        .font(.brandCaption2)
        .foregroundColor(.brandTextSecondary)
      Text(value)
        .font(.brandCaption.monospacedDigit())
        .foregroundColor(.brandTextPrimary)
      Text(unit)
        .font(.brandCaption2)
        .foregroundColor(.brandTextSecondary)
    }
  }

  // MARK: - Fetch Conditions

  private func fetchConditions(for river: String) {
    errorText = nil
    loadingRiver = river
    Task {
      do {
        let apiRiver = AppEnvironment.stripRiverSuffix(river)
        let loose = try await postForecast(river: apiRiver, date: Date())
        self.result = materializeStrict(from: loose)
        self.goToResult = true
      } catch {
        let msg = error.localizedDescription
        if msg.lowercased().contains("invalid water body") || msg.lowercased().contains("not supported") {
          self.errorText = "Gauge data is not yet available for \(river). Check back soon."
        } else {
          self.errorText = msg
        }
      }
      self.loadingRiver = nil
    }
  }

  // MARK: - Fetch Batch Conditions

  private func fetchBatchConditions() {
    let rivers = CommunityService.shared.activeCommunityConfig.resolvedLodgeRivers
    let waterBodies = CommunityService.shared.activeCommunityConfig.resolvedLodgeWaterBodies
    let allSources = rivers + waterBodies
    guard !allSources.isEmpty else { return }

    batchLoading = true

    Task {
      do {
        let url = try Self.makeBatchURL()
        AppLogging.log("[Forecast] POST batch request URL: \(url.absoluteString)", level: .debug, category: .trip)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        // Auth headers
        let anonKey = (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !anonKey.isEmpty {
          req.setValue(anonKey, forHTTPHeaderField: "apikey")
        }
        if let jwt = AuthStore.shared.jwt, !jwt.isEmpty {
          req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }

        // Community ID header (preferred over body for flexibility)
        let communityId = CommunityService.shared.activeCommunityId
        if let communityId, !communityId.isEmpty {
          req.setValue(communityId, forHTTPHeaderField: "x-community-id")
        }

        struct BatchPayload: Encodable {
          let rivers: [String]
          let communityId: String?
          enum CodingKeys: String, CodingKey {
            case rivers
            case communityId = "community_id"
          }
        }
        // Strip river suffixes for rivers; water bodies pass through as-is
        let apiNames = rivers.map { AppEnvironment.stripRiverSuffix($0) } + waterBodies
        let payload = BatchPayload(rivers: apiNames, communityId: communityId)
        req.httpBody = try JSONEncoder().encode(payload)
        AppLogging.log("[Forecast] batch request body: rivers=\(apiNames), community_id=\(communityId ?? "nil")", level: .debug, category: .trip)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
          throw NSError(domain: "RiverForecast", code: -1, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }

        if !(200...299).contains(http.statusCode) {
          let preview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
          throw NSError(domain: "RiverForecast", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(preview.prefix(300))"])
        }

        let rawResponse = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        AppLogging.log({ "[Forecast] batch response HTTP \(http.statusCode): \(rawResponse.prefix(500))" }, level: .debug, category: .trip)

        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let batch = try dec.decode(BatchResponse.self, from: data)

        var dict: [String: BatchCondition] = [:]
        for condition in batch.conditions {
          // Re-key using full display name:
          // Rivers: "Nehalem" → "Nehalem River" (match via stripRiverSuffix)
          // Water bodies: "Puget Sound" → "Puget Sound" (exact match)
          let displayName = allSources.first(where: { AppEnvironment.stripRiverSuffix($0) == condition.name }) ?? condition.name
          dict[displayName] = condition
          AppLogging.log({ "[Forecast] batch — \(condition.name): type=\(condition.waterType ?? "?"), level=\(condition.waterLevelFt.map { String(format: "%.2f", $0) } ?? "nil")ft, temp=\(condition.waterTempC.map { String(format: "%.1f", $0) } ?? "nil")°C" }, level: .debug, category: .trip)
        }
        self.batchConditions = dict
        AppLogging.log("[Forecast] batch loaded \(dict.count) conditions for date: \(batch.date)", level: .info, category: .trip)

      } catch {
        AppLogging.log("[Forecast] batch fetch failed: \(error.localizedDescription)", level: .warn, category: .trip)
        // Tiles remain functional, just without metrics
      }
      self.batchLoading = false
    }
  }

  // MARK: - Networking (POST JSON, no auth, resilient decode)

  private func postForecast(river: String, date: Date) async throws -> LooseResponse {
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = "yyyy-MM-dd"
    let ymd = df.string(from: date)

    Self.logConfig()
    let url = try Self.makeURL()
    AppLogging.log("[Forecast] POST request URL: \(url.absoluteString)", level: .debug, category: .trip)
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json", forHTTPHeaderField: "Accept")

    // Auth headers
    let anonKey = (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !anonKey.isEmpty {
      req.setValue(anonKey, forHTTPHeaderField: "apikey")
    }
    if let jwt = AuthStore.shared.jwt, !jwt.isEmpty {
      req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
    }

    // Community ID
    let communityId = CommunityService.shared.activeCommunityId
    if let communityId, !communityId.isEmpty {
      req.setValue(communityId, forHTTPHeaderField: "x-community-id")
    }

    struct Payload: Encodable {
      let date: String
      let river: String
      let includeWaterTemperature: Bool
      let communityId: String?
      enum CodingKeys: String, CodingKey {
        case date, river
        case includeWaterTemperature = "include_water_temperature"
        case communityId = "community_id"
      }
    }
    req.httpBody = try JSONEncoder().encode(Payload(date: ymd, river: river, includeWaterTemperature: true, communityId: communityId))
    AppLogging.log("[Forecast] request body: river=\(river), date=\(ymd), community_id=\(communityId ?? "nil")", level: .debug, category: .trip)

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else {
      throw NSError(
        domain: "RiverForecast",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "No HTTP response"]
      )
    }

    let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
    if !(200 ... 299).contains(http.statusCode) {
      if contentType.contains("application/json"),
         let apiErr = try? JSONDecoder().decode(APIError.self, from: data) {
        throw NSError(
          domain: "RiverForecast",
          code: http.statusCode,
          userInfo: [NSLocalizedDescriptionKey: apiErr.error]
        )
      }
      let preview = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
      throw NSError(
        domain: "RiverForecast",
        code: http.statusCode,
        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(preview.prefix(300))"]
      )
    }

    // Lenient decode (optionals, snake_case)
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    return try dec.decode(LooseResponse.self, from: data)
  }

  private struct APIError: Decodable { let error: String }

  // MARK: - Batch Response Types

  private struct BatchCondition: Decodable {
    let name: String
    let waterType: String?
    let stationId: String?
    let source: String?
    let date: String?
    let waterLevelFt: Double?
    let waterTempC: Double?
  }

  private struct BatchResponse: Decodable {
    let date: String
    let conditions: [BatchCondition]
  }

  // MARK: - Lenient (Loose) Response Types

  private struct LooseResponse: Decodable {
    let name: String?
    let waterType: String?
    let stationId: String?
    let source: String?
    let date: String?
    let isTidal: Bool?

    let weather: LooseWeatherBlock?
    let tides: LooseTidesBlock?
    let waterLevels: [LooseWaterLevelEntry]?
    let waterTemperatures: [LooseWaterTemperatureEntry]?

    struct LooseWeatherBlock: Decodable {
      let previousDay: LooseDayBlock?
      let targetDay: LooseDayBlock?
      let nextDay: LooseDayBlock?
    }

    struct LooseDayBlock: Decodable {
      let date: String?
      let highTempC: Double?
      let lowTempC: Double?
      let precipitationMm: Double?
    }

    struct LooseTidesBlock: Decodable {
      let previousHigh: LooseTidesPoint?
      let nextHigh: LooseTidesPoint?
      let previousLow: LooseTidesPoint?
      let nextLow: LooseTidesPoint?
    }

    struct LooseTidesPoint: Decodable {
      let time: String?
      let heightM: Double?
      let type: String?
    }

    struct LooseWaterLevelEntry: Decodable {
      let recordedAt: String?
      let levelFt: Double?
    }

    struct LooseWaterTemperatureEntry: Decodable {
      let recordedAt: String?
      let tempC: Double?
    }
  }

  // MARK: - Materialize strict model for FishingForecastResultView

  private func materializeStrict(from loose: LooseResponse) -> RiverConditionsResponse {
    // Helper: string date fallback -> today's yyyy-MM-dd
    func ymdOrToday(_ s: String?) -> String {
      if let s, !s.isEmpty { return s }
      let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
      return df.string(from: Date())
    }
    // Helper: normalize "YYYY-MM-DDTHH:mm:ss" -> "YYYY-MM-DD HH:mm"
    func normalizeTime(_ t: String?, defaultDate: String) -> String {
      guard var s = t, !s.isEmpty else { return "\(defaultDate) 00:00" }
      s = s.replacingOccurrences(of: "T", with: " ")
      if s.count >= 16 { s = String(s.prefix(16)) } // drop seconds if present
      return s
    }

    let river = loose.name ?? "Unknown"
    let date = ymdOrToday(loose.date)
    let stationId = loose.stationId ?? "Unknown"

    // Weather (fill zeros if missing)
    let wPrev = loose.weather?.previousDay
    let wCurr = loose.weather?.targetDay
    let wNext = loose.weather?.nextDay

    let weather = RiverConditionsResponse.WeatherBlock(
      previousDay: .init(
        date: ymdOrToday(wPrev?.date),
        highTempC: wPrev?.highTempC ?? 0,
        lowTempC: wPrev?.lowTempC ?? 0,
        precipitationMm: wPrev?.precipitationMm ?? 0
      ),
      targetDay: .init(
        date: ymdOrToday(wCurr?.date ?? date),
        highTempC: wCurr?.highTempC ?? 0,
        lowTempC: wCurr?.lowTempC ?? 0,
        precipitationMm: wCurr?.precipitationMm ?? 0
      ),
      nextDay: .init(
        date: ymdOrToday(wNext?.date),
        highTempC: wNext?.highTempC ?? 0,
        lowTempC: wNext?.lowTempC ?? 0,
        precipitationMm: wNext?.precipitationMm ?? 0
      )
    )

    // Tides — only materialize when the backend marks this water body as tidal.
    // Non-tidal water bodies receive null tide fields; we surface this as nil so
    // the result view can hide tide cards entirely.
    let isTidal = loose.isTidal ?? false
    let tides: RiverConditionsResponse.TidesBlock?
    if isTidal {
      let t = loose.tides
      tides = RiverConditionsResponse.TidesBlock(
        previousHigh: .init(
          time: normalizeTime(t?.previousHigh?.time, defaultDate: date),
          heightM: t?.previousHigh?.heightM ?? 0,
          type: t?.previousHigh?.type ?? "high"
        ),
        nextHigh: .init(
          time: normalizeTime(t?.nextHigh?.time, defaultDate: date),
          heightM: t?.nextHigh?.heightM ?? 0,
          type: t?.nextHigh?.type ?? "high"
        ),
        previousLow: .init(
          time: normalizeTime(t?.previousLow?.time, defaultDate: date),
          heightM: t?.previousLow?.heightM ?? 0,
          type: t?.previousLow?.type ?? "low"
        ),
        nextLow: .init(
          time: normalizeTime(t?.nextLow?.time, defaultDate: date),
          heightM: t?.nextLow?.heightM ?? 0,
          type: t?.nextLow?.type ?? "low"
        )
      )
    } else {
      tides = nil
    }

    // Water levels — hourly time-series (~96 entries over the last 4 days).
    // Drop entries with null timestamps or null values rather than zero-filling,
    // so gaps in the source data don't masquerade as legitimate readings.
    let levels: [RiverConditionsResponse.WaterLevelEntry] =
      (loose.waterLevels ?? [])
        .compactMap { entry in
          guard let t = entry.recordedAt, let v = entry.levelFt else { return nil }
          return .init(recordedAt: t, levelFt: v)
        }

    let temps: [RiverConditionsResponse.WaterTemperatureEntry]? =
      (loose.waterTemperatures ?? [])
        .compactMap { entry in
          guard let t = entry.recordedAt, let v = entry.tempC else { return nil }
          return .init(recordedAt: t, tempC: v)
        }

    return RiverConditionsResponse(
      river: river,
      stationId: stationId,
      date: date,
      isTidal: isTidal,
      weather: weather,
      tides: tides,
      waterLevels: levels,
      waterTemperatures: temps
    )
  }
}
