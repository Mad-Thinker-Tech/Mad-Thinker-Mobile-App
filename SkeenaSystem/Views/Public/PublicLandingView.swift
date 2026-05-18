// Bend Fly Shop

import CoreLocation
import SwiftUI

// MARK: - API config (mirrors AnglerLandingView's URL composition)

private enum PublicLandingAPI {
  private static let rawBaseURLString: String = {
    (Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }()

  private static let baseURLString: String = {
    var s = rawBaseURLString
    if !s.isEmpty, URL(string: s)?.scheme == nil {
      s = "https://" + s
    }
    return s
  }()

  private static let downloadCatchPath: String = {
    (Bundle.main.object(forInfoDictionaryKey: "DOWNLOAD_CATCH_URL") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "/functions/v1/download-catch-reports"
  }()

  private static func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
    guard let base = URL(string: baseURLString), let scheme = base.scheme, let host = base.host else {
      throw NSError(domain: "PublicLanding", code: -1000, userInfo: [
        NSLocalizedDescriptionKey: "Invalid API_BASE_URL (raw: '\(rawBaseURLString)', normalized: '\(baseURLString)')"
      ])
    }
    var comps = URLComponents()
    comps.scheme = scheme
    comps.host = host
    comps.port = base.port
    let basePath = base.path
    let normalizedBasePath = basePath == "/" ? "" : (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath)
    let normalizedPath = path.hasPrefix("/") ? path : "/" + path
    comps.path = normalizedBasePath + normalizedPath
    let existing = base.query != nil ? (URLComponents(string: base.absoluteString)?.queryItems ?? []) : []
    let merged = existing + queryItems
    comps.queryItems = merged.isEmpty ? nil : merged
    guard let url = comps.url else {
      throw NSError(domain: "PublicLanding", code: -1001, userInfo: [
        NSLocalizedDescriptionKey: "Failed to build URL for path: \(path)"
      ])
    }
    return url
  }

  static func downloadCatchURL() throws -> URL {
    var queryItems: [URLQueryItem] = []
    if let communityId = CommunityService.shared.activeCommunityId {
      queryItems.append(URLQueryItem(name: "community_id", value: communityId))
    }
    return try makeURL(path: downloadCatchPath, queryItems: queryItems)
  }
}

// MARK: - PublicLandingView
//
// Landing screen for users with the "public" community role.
// Identical to GuideLandingView except:
//   - No trip sync on appear (public users have no trip concept)
//   - No trip navigation destination
//   - ReportChatView opened in alwaysSolo mode
//   - userRole environment is .public (toolbar shows no Trips tab)

struct PublicLandingView: View {
  @StateObject private var auth = AuthService.shared
  @ObservedObject private var communityService = CommunityService.shared

  // Reactive entitlements — driven by backend config with xcconfig fallback
  private var E_CATCH_CAROUSEL: Bool { communityService.activeCommunityConfig.flag("E_CATCH_CAROUSEL") }
  private var E_CATCH_MAP: Bool { communityService.activeCommunityConfig.flag("E_CATCH_MAP") }

  @State private var goToAssistant = false
  @State private var goToManageAccount = false
  @State private var showRecordActivity = false
  @State private var showWelcome = false

  // Catch report data
  @State private var reports: [CatchReportDTO] = []
  @State private var isLoading = false
  @State private var errorText: String?
  @State private var goToCatchMap = false

  // Map reports (same data source as GuideLandingView)
  @State private var mapReports: [MapReportDTO] = []

  // Location (for weather)
  @StateObject private var locationManager = LocationManager()

  // Live weather
  @State private var liveWeather: LiveWeather? = nil

  // Path-based nav for toolbar navigation
  @State private var navPath = NavigationPath()

  var body: some View {
    NavigationStack(path: $navPath) {
      DarkPageTemplate(bottomToolbar: {
        RoleAwareToolbar(activeTab: "home")
      }) {
        content
      }
      .navigationDestination(isPresented: $goToAssistant) {
        ReportChatView(alwaysSolo: true, directToChat: true, onSaved: {
          goToAssistant = false
        })
          .navigationBarTitleDisplayMode(.inline)
      }
      .navigationDestination(isPresented: $goToManageAccount) {
        ManageProfileView().environmentObject(auth)
      }
      .navigationDestination(isPresented: $showRecordActivity) {
        RecordActivityView()
          .environment(\.userRole, .public)
          .environment(\.guideNavigateTo, handleNavigateTo)
          .environmentObject(auth)
      }
      .navigationDestination(isPresented: $goToCatchMap) {
        DarkPageTemplate {
          VStack(spacing: 4) {
            GuideLandingMapView(reports: mapReports, userLocation: locationManager.lastLocation?.coordinate)
              .ignoresSafeArea(edges: .bottom)
            GuideLandingMapLegend()
              .padding(.bottom, 8)
          }
        }
        .navigationTitle("Catch Map")
      }
      .navigationDestination(for: GuideDestination.self) { dest in
        switch dest {
        case .conditions:
          FishingForecastRequestView()
            .environment(\.userRole, .public)
            .environment(\.guideNavigateTo, handleNavigateTo)
        case .community:
          SocialFeedView()
            .environment(\.userRole, .public)
            .environment(\.guideNavigateTo, handleNavigateTo)
        case .activities:
          ActivitiesView()
            .environment(\.userRole, .public)
            .environment(\.guideNavigateTo, handleNavigateTo)
        case .observations:
          // Standalone observations removed — now inside Activities → Observations tab.
          ActivitiesView()
            .environment(\.userRole, .public)
            .environment(\.guideNavigateTo, handleNavigateTo)
        case .trips:
          // Public users have no trips — should never be reached
          EmptyView()
        case .learn:
          LearnTacticsView()
            .environment(\.userRole, .public)
            .environment(\.guideNavigateTo, handleNavigateTo)
            .environmentObject(communityService)
        case .explore:
          ExploreView()
            .environment(\.userRole, .public)
            .environment(\.guideNavigateTo, handleNavigateTo)
        case .maps:
          // Maps is researcher-only — should not be reached from a public toolbar
          EmptyView()
        }
      }
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          HStack(spacing: 12) {
            Button(action: { goToManageAccount = true }) {
              Image(systemName: "person.circle")
                .font(.brandTitle3.weight(.semibold))
                .foregroundColor(.brandTextPrimary)
            }
            .accessibilityIdentifier("profileButton")
            CommunityToolbarButton()
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: logoutTapped) {
            HStack(spacing: 6) {
              Image(systemName: "person.crop.circle.badge.xmark")
                .font(.brandSubheadline)
              Text("Log out")
                .font(.brandCaption)
            }
          }
          .accessibilityIdentifier("logoutCapsule")
        }
      }
      .onAppear {
        locationManager.request()
        locationManager.start()
        checkWelcome()
        Task {
          await fetchReports()
          await fetchMapReports()
        }
      }
      .onChange(of: locationManager.lastLocation) { loc in
        guard liveWeather == nil, let loc else { return }
        Task { await fetchWeather(location: loc) }
      }
      .onChange(of: communityService.activeCommunityId) { newValue in
        AppLogging.log("[PublicLandingView] onChange(activeCommunityId) -> \(newValue ?? "nil") — clearing stale reports and refetching", level: .info, category: .catch)
        reports = []
        mapReports = []
        Task {
          await fetchReports()
          await fetchMapReports()
        }
      }
      .onChange(of: auth.currentMemberId) { newValue in
        AppLogging.log("[PublicLandingView] onChange(currentMemberId) -> \(newValue ?? "nil") — clearing stale reports and refetching", level: .info, category: .catch)
        reports = []
        mapReports = []
        checkWelcome()
        Task {
          await fetchReports()
          await fetchMapReports()
        }
      }
      .fullScreenCover(isPresented: $showWelcome) {
        PublicWelcomeView(onDismiss: {
          if let key = welcomeKey() {
            UserDefaults.standard.set(true, forKey: key)
          }
        })
      }
    }
    .environment(\.userRole, .public)
    .environment(\.guideNavigateTo, handleNavigateTo)
    .environmentObject(auth)
  }

  // MARK: - Main content

  private var content: some View {
    ScrollView {
      VStack(spacing: 8) {

        // ── Header: name → logo → record ──────────────────────────────
        VStack(spacing: 0) {
          // User name — left aligned
          Text("\(auth.currentFirstName ?? "") \(auth.currentLastName ?? "")")
            .font(.brandCaption.weight(.semibold))
            .foregroundColor(.brandTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .accessibilityIdentifier("userNameLabel")

          // Community logo — centred
          CommunityLogoView(config: communityService.activeCommunityConfig, size: 160)
            .frame(maxWidth: .infinity)

          // Record capsule — right aligned, directly below logo
          Button { showRecordActivity = true } label: {
            Text("Record")
              .font(.brandCaption.weight(.bold))
              .foregroundColor(.brandTextPrimary)
              .padding(.horizontal, 14)
              .padding(.vertical, 7)
              .background(Color.brandAccent, in: Capsule())
          }
          .buttonStyle(.plain)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .padding(.horizontal, 20)
          .padding(.top, 4)
          .accessibilityIdentifier("recordActivityButton")
        }
        .padding(.top, 12)

        // ── Weather tile ───────────────────────────────────────────────
        VStack(spacing: 0) {
          // Current conditions row: location | temp | wind | pressure
          HStack(spacing: 0) {
            Text(liveWeather?.locationName ?? "\u{2013}")
              .font(.system(size: 11, weight: .semibold))
              .foregroundColor(.brandTextPrimary)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 3) {
              Image(systemName: liveWeather?.icon ?? "thermometer")
                .font(.brandCaption)
                .foregroundColor(weatherIconColor(liveWeather?.icon))
              Text(liveWeather.map { "\(communityService.activeCommunityConfig.temperature(Double($0.temp)))\(communityService.activeCommunityConfig.tempUnit)" } ?? "\u{2013}")
                .font(.brandCaption.weight(.bold))
                .foregroundColor(.brandTextPrimary)
            }
            .frame(width: 56, alignment: .center)

            HStack(spacing: 3) {
              Image(systemName: "wind")
                .font(.brandCaption2)
                .foregroundColor(.brandTextSecondary)
              Text(liveWeather.map { "\($0.windDir) \(communityService.activeCommunityConfig.windSpeed(Double($0.windSpeed)))" } ?? "\u{2013}")
                .font(.brandCaption2.weight(.medium))
                .foregroundColor(.brandTextPrimary)
            }
            .frame(width: 56, alignment: .center)

            HStack(spacing: 3) {
              Image(systemName: "barometer")
                .font(.brandCaption2)
                .foregroundColor(.brandTextSecondary)
              Text(liveWeather.map { "\($0.pressureVal)" } ?? "\u{2013}")
                .font(.brandCaption2.weight(.medium))
                .foregroundColor(.brandTextPrimary)
              Image(systemName: liveWeather?.pressureTrend.sfSymbol ?? "minus")
                .font(.system(size: 8))
                .foregroundColor(pressureTrendColor(liveWeather?.pressureTrend))
            }
            .frame(width: 64, alignment: .center)
          }
          .padding(.horizontal, 14)
          .padding(.top, 8)
          .padding(.bottom, 6)

          // Hourly strip
          if let hourly = liveWeather?.hourly, !hourly.isEmpty {
            Rectangle()
              .fill(Color.brandStroke)
              .frame(height: 0.5)
              .padding(.horizontal, 14)

            HStack(spacing: 0) {
              ForEach(hourly) { slot in
                VStack(alignment: .center, spacing: 2) {
                  Text(slot.hour)
                    .font(.system(size: 9))
                    .foregroundColor(.brandTextSecondary)
                  Image(systemName: slot.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundColor(weatherIconColor(slot.icon))
                  Text("\(communityService.activeCommunityConfig.temperature(Double(slot.temp)))\u{00B0}")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.brandTextPrimary)
                  Text(slot.precipChance > 0 ? "\(slot.precipChance)%" : " ")
                    .font(.system(size: 9))
                    .foregroundColor(.cyan)
                }
                .frame(maxWidth: .infinity)
              }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
          }
        }
        .background(Color.brandSurface, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)

        // ── Fisheries Conditions ───────────────────────────────────────
        Button { handleNavigateTo(.conditions) } label: {
          HStack(spacing: 8) {
            Image(systemName: "water.waves")
              .font(.brandCaption)
              .foregroundColor(.brandTextPrimary)
            Text("Fisheries Conditions")
              .font(.brandCaption.weight(.semibold))
              .foregroundColor(.brandTextPrimary)
            Spacer()
            Image(systemName: "chevron.right")
              .font(.brandCaption.weight(.semibold))
              .foregroundColor(.brandTextPrimary.opacity(0.4))
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(Color.brandSurface, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("fishingForecastTile")

        // Section divider
        Rectangle()
          .fill(Color.brandStroke)
          .frame(height: 0.5)
          .padding(.vertical, 2)

        // Catch photo carousel
        if E_CATCH_CAROUSEL {
          VStack(alignment: .leading, spacing: 8) {
            // Header row — "Your recent activity" + map icon
            HStack(alignment: .center) {
              Text("Your recent activity")
                .font(.brandSubheadline.weight(.semibold))
                .foregroundColor(.brandTextPrimary)
              Spacer()
              if E_CATCH_MAP {
                Button { goToCatchMap = true } label: {
                  Image(systemName: "map")
                    .font(.brandSubheadline)
                    .foregroundColor(.brandTextPrimary.opacity(0.7))
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.horizontal, 16)

            if isLoading, sortedReports.isEmpty {
              ProgressView().tint(.white)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
            } else if sortedReports.isEmpty {
              Text("No catch reports yet.")
                .foregroundColor(.brandTextSecondary)
                .font(.brandSubheadline)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
            } else {
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                  ForEach(sortedReports) { r in
                    NavigationLink(destination: CatchDetailView(report: r).environmentObject(auth)) {
                      catchCard(r)
                    }
                    .buttonStyle(.plain)
                  }
                }
                .padding(.horizontal, 16)
              }
            }
          }
        }

        // Error banner
        if let err = errorText {
          Text(err)
            .foregroundColor(.brandError)
            .font(.brandFootnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
        }

        Spacer(minLength: 8)
      }
    }
  }

  // MARK: - Derived data

  private var sortedReports: [CatchReportDTO] {
    reports.sorted {
      let d0 = Self.parseISO($0.createdAt) ?? .distantPast
      let d1 = Self.parseISO($1.createdAt) ?? .distantPast
      return d0 > d1
    }
  }

  // MARK: - Catch card (carousel)

  @ViewBuilder
  private func catchCard(_ r: CatchReportDTO) -> some View {
    VStack(spacing: 0) {
      AsyncImage(url: r.photoURL) { phase in
        switch phase {
        case .empty:
          ZStack { Color.brandSurface; ProgressView().tint(.white) }
        case let .success(img):
          img.resizable().scaledToFill()
        case .failure:
          ZStack {
            Color.brandSurface
            Image(systemName: "photo")
              .font(.brandLargeTitle)
              .foregroundColor(.brandTextPrimary.opacity(0.3))
          }
        @unknown default:
          Color.brandSurface
        }
      }
      .frame(width: 140, height: 140)
      .clipped()

      HStack {
        VStack(alignment: .leading, spacing: 1) {
          Text(r.displayLocation)
            .font(.brandCaption2.weight(.semibold))
            .foregroundColor(.brandTextPrimary)
            .lineLimit(1)
          Text(Self.fmtDate(r.createdAt))
            .font(.brandCaption2)
            .foregroundColor(.brandTextSecondary)
            .lineLimit(1)
        }
        Spacer()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(Color.brandStrokeSubtle)
    }
    .frame(width: 140)
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  // MARK: - Networking

  private func fetchReports() async { await fetchReportsInternal(allowRetryOnAuthError: true) }

  private func fetchReportsInternal(allowRetryOnAuthError: Bool) async {
    guard !isLoading else { return }
    errorText = nil
    isLoading = true
    defer { isLoading = false }

    guard let token = await auth.currentAccessToken(), !token.isEmpty else {
      errorText = "Please sign in to view your catch reports."
      return
    }

    let url: URL
    do {
      url = try PublicLandingAPI.downloadCatchURL()
    } catch {
      AppLogging.log("[PublicLanding] Failed to build download URL: \(error.localizedDescription)", level: .error, category: .catch)
      errorText = "Unable to load catch reports. Please try again later."
      return
    }

    AppLogging.log("[PublicLanding] GET \(url.absoluteString)", level: .debug, category: .catch)

    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(auth.publicAnonKey, forHTTPHeaderField: "apikey")

    do {
      let (data, resp) = try await URLSession.shared.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
      guard (200 ..< 300).contains(code) else {
        if allowRetryOnAuthError, [400, 401, 403].contains(code) {
          _ = await auth.currentAccessToken()
          await fetchReportsInternal(allowRetryOnAuthError: false)
          return
        }
        errorText = "Unable to load catch reports. Please try again later."
        return
      }
      let decoded = try JSONDecoder().decode(DownloadResponse.self, from: data)
      let ids = decoded.catch_reports.map(\.catch_id)
      let uniqueIds = Set(ids)
      AppLogging.log("[PublicLanding] Server returned \(decoded.catch_reports.count) report(s), \(uniqueIds.count) unique catch_id(s): \(ids)", level: .info, category: .catch)
      if ids.count != uniqueIds.count {
        AppLogging.log("[PublicLanding] ⚠️ Server response contains duplicate catch_ids — ForEach will collapse to \(uniqueIds.count) row(s)", level: .warn, category: .catch)
      }
      withAnimation { reports = decoded.catch_reports }
    } catch {
      AppLogging.log("[PublicLanding] Network error fetching catches: \(error.localizedDescription)", level: .error, category: .catch)
      errorText = "Unable to load catch reports. Please check your connection and try again."
    }
  }

  // MARK: - Map reports

  private func fetchMapReports() async {
    guard let communityId = CommunityService.shared.activeCommunityId else { return }
    do {
      let reports = try await MapReportService.fetch(communityId: communityId, memberId: auth.currentMemberId)
      // Public users record their own catches + marks too — merge any
      // `savedLocally` pins so today's activity shows up before upload.
      let merged = LocalMapPins.mergeWithServer(reports)
      await MainActor.run { mapReports = merged }
    } catch {
      AppLogging.log("[PublicLanding] Map reports fetch failed: \(error.localizedDescription)", level: .error, category: .network)
      // Fetch failed — still surface local-pending pins offline.
      let local = LocalMapPins.localPendingPins()
      await MainActor.run { mapReports = local }
    }
  }

  // MARK: - Weather

  private func fetchWeather(location: CLLocation) async {
    let lat = location.coordinate.latitude
    let lon = location.coordinate.longitude

    // Reverse geocode for city name
    let geocoder = CLGeocoder()
    let locationName: String
    if let placemark = try? await geocoder.reverseGeocodeLocation(location).first {
      let city = placemark.locality
        ?? placemark.subLocality
        ?? placemark.subAdministrativeArea
        ?? ""
      let state = placemark.administrativeArea ?? ""
      locationName = [city, state].filter { !$0.isEmpty }.joined(separator: ", ")
    } else {
      locationName = ""
    }

    do {
      let response = try await WeatherSnapshotService.fetch(lat: lat, lon: lon)
      let w = response.current
      let slots = response.hourlyForecast.map { h in
        LiveWeather.HourlySlot(
          hour: WeatherSnapshotService.hourLabel(from: h.time),
          icon: WeatherSnapshotService.conditionIcon(for: h.weatherCode),
          temp: Int(h.temperature.rounded()),
          precipChance: h.precipitationProbability
        )
      }
      await MainActor.run {
        liveWeather = LiveWeather(
          locationName: locationName,
          condition: WeatherSnapshotService.conditionText(for: w.weatherCode),
          icon: WeatherSnapshotService.conditionIcon(for: w.weatherCode),
          temp: Int(w.temperature.rounded()),
          windDir: WeatherSnapshotService.windCardinal(from: w.windDirection),
          windSpeed: Int(w.windSpeed.rounded()),
          pressureVal: Int(w.pressure.rounded()),
          pressureTrend: WeatherSnapshotService.pressureTrend(current: w.pressure, hourly: response.hourlyForecast),
          hourly: slots,
          source: response.source
        )
      }
    } catch {
      AppLogging.log("[Weather] Fetch failed: \(error.localizedDescription)", level: .error, category: .network)
    }
  }

  private func pressureTrendColor(_ trend: WeatherPressureTrend?) -> Color {
    switch trend {
    case .rising:  return .brandSuccess
    case .falling: return .red
    default:       return .brandTextSecondary
    }
  }

  private func weatherIconColor(_ icon: String?) -> Color {
    guard let icon else { return .gray }
    if icon.contains("sun") { return .yellow }
    if icon.contains("snow") { return .cyan }
    if icon.contains("bolt") { return .yellow }
    return .gray
  }

  private func logoutTapped() {
    Task {
      await auth.signOutRemote()
      await MainActor.run {
        AuthStore.shared.clear()
      }
    }
  }

  // MARK: - Welcome (first-login overview)

  /// Per-member key so each new public member sees the welcome once.
  /// Returns nil until auth has resolved a memberId — the onChange(currentMemberId)
  /// handler re-runs checkWelcome() once it's available.
  private func welcomeKey() -> String? {
    guard let mid = auth.currentMemberId else { return nil }
    return "publicWelcome_\(mid)"
  }

  private func checkWelcome() {
    // UI tests that aren't exercising welcome behavior (PostLoginTestBase)
    // can opt out via this launch arg. Without it, the fullScreenCover
    // covers the landing screen and SwiftUI's hit-testing reports {-1,-1}
    // for both Get Started and Close on iOS 26.2 sim — see the same class
    // of issue noted in SkeenaSystemApp.registerUITestSignOutHook.
    if CommandLine.arguments.contains("-suppressWelcomeForUITests") { return }
    guard let key = welcomeKey() else { return }
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    guard !showWelcome else { return }
    showWelcome = true
  }

  // MARK: - Navigation

  private func handleNavigateTo(_ destination: GuideDestination?) {
    guard let destination else {
      navPath = NavigationPath()
      return
    }
    var newPath = NavigationPath()
    newPath.append(destination)
    navPath = newPath
  }

  // MARK: - Helpers

  private static func parseISO(_ iso: String) -> Date? {
    DateFormatting.parseISO(iso)
  }

  private static func fmtDate(_ iso: String) -> String {
    if let d = parseISO(iso) { return DateFormatting.mediumDateTime.string(from: d) }
    return iso
  }
}
