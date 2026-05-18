// Bend Fly Shop
// AnglerLandingView.swift
// Bend Fly Shop – iOS 15+ nav-bar button + pinned footer

import CoreLocation
import SwiftUI
import Foundation

// Feature flags are now driven by backend community config (with xcconfig fallback).
// See CommunityConfig.flag(_:) for the resolution chain.

// MARK: - API config (mirrors other files' URL composition)

private enum AnglerLandingAPI {
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

  // Use the variable you specified:
  // DOWNLOAD_CATCH_URL = /functions/v1/download-catch-reports
  private static let downloadCatchPath: String = {
    (Bundle.main.object(forInfoDictionaryKey: "DOWNLOAD_CATCH_URL") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "/functions/v1/download-catch-reports"
  }()

  private static func logConfig() {
    AppLogging.log("AnglerLanding config — API_BASE_URL (raw): '\(rawBaseURLString)'", level: .debug, category: .catch)
    AppLogging.log("AnglerLanding config — API_BASE_URL (normalized): '\(baseURLString)'", level: .debug, category: .catch)
    AppLogging.log("AnglerLanding config — DOWNLOAD_CATCH_URL: '\(downloadCatchPath)'", level: .debug, category: .catch)
  }

  private static func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
    guard let base = URL(string: baseURLString), let scheme = base.scheme, let host = base.host else {
      AppLogging.log(
        "AnglerLanding invalid API_BASE_URL — raw: '\(rawBaseURLString)', normalized: '\(baseURLString)'",
        level: .debug,
        category: .catch
      )
      throw NSError(domain: "AnglerLanding", code: -1000, userInfo: [
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
      throw NSError(domain: "AnglerLanding", code: -1001, userInfo: [
        NSLocalizedDescriptionKey: "Failed to build URL for path: \(path)"
      ])
    }
    return url
  }

  static func downloadCatchURL() throws -> URL {
    logConfig()
    var queryItems: [URLQueryItem] = []
    if let communityId = CommunityService.shared.activeCommunityId {
      queryItems.append(URLQueryItem(name: "community_id", value: communityId))
      AppLogging.log("[AnglerLanding] download scoped to community_id: \(communityId)", level: .debug, category: .catch)
    }
    return try makeURL(path: downloadCatchPath, queryItems: queryItems)
  }
}

// MARK: - Navigation destinations

/// Hashable enum so we can push views onto a `NavigationPath`.
/// Also used by the `navigateTo` environment key for cross-view toolbar navigation.
enum AnglerDestination: Hashable {
  case conditions, learn, community, profile, trip, explore
}

// MARK: - View

struct AnglerLandingView: View {
  @StateObject private var auth = AuthService.shared
  @ObservedObject private var communityService = CommunityService.shared
  @Environment(\.dismiss) private var dismiss

  // Reactive entitlements — driven by backend config with xcconfig fallback
  private var E_CATCH_CAROUSEL: Bool { communityService.activeCommunityConfig.flag("E_CATCH_CAROUSEL") }
  private var E_CATCH_MAP: Bool { communityService.activeCommunityConfig.flag("E_CATCH_MAP") }

  // Data state
  @State private var reports: [CatchReportDTO] = []
  @State private var isLoading = false
  @State private var errorText: String?

  // Map reports (same data source as GuideLandingView)
  @State private var mapReports: [MapReportDTO] = []


  // Location (for weather)
  @StateObject private var locationManager = LocationManager()

  // Live weather
  @State private var liveWeather: LiveWeather? = nil

  // Navigation path (enables pop-to-root)
  @State private var navPath = NavigationPath()

  // UI state
  @State private var showTripPrep = false
  @State private var goToManageAccount = false
  @State private var goToCatchMap = false
  @State private var showOnboarding = false

  // MARK: - Centralized navigation handler
  //
  // Every toolbar tab in every child view calls this closure via
  // `@Environment(\.navigateTo)`.  Passing `nil` = go Home.
  // Passing a destination = pop to root first, then navigate there.

  private func handleNavigateTo(_ destination: AnglerDestination?) {
    if let destination {
      switch destination {
      case .trip:
        // Trip is a slide-over overlay — show it on top of the current view
        // without popping the nav stack to avoid flashing the landing screen.
        showTripPrep = true
      default:
        // Dismiss trip overlay if open
        showTripPrep = false
        // Replace the entire path with the new destination in one step
        // to avoid flashing the landing screen.
        var newPath = NavigationPath()
        newPath.append(destination)
        navPath = newPath
      }
    } else {
      // nil = go Home
      showTripPrep = false
      navPath = NavigationPath()
    }
  }

  var body: some View {
    NavigationStack(path: $navPath) {
      DarkPageTemplate(bottomToolbar: {
        ToolbarTab(icon: "house", label: "Home") {
          // Already on landing — no-op
        }
        ToolbarTab(icon: "suitcase", label: "My Trip") {
          showTripPrep = true
        }
        ToolbarTab(icon: "message", label: "Social") {
          navPath.append(AnglerDestination.community)
        }
        ToolbarTab(icon: "safari", label: "Learn") {
          navPath.append(AnglerDestination.explore)
        }
      }) {
        content
      }
      .navigationDestination(isPresented: $goToManageAccount) {
        ManageProfileView().environmentObject(auth)
      }
      .navigationDestination(isPresented: $goToCatchMap) {
        DarkPageTemplate {
          VStack(spacing: 4) {
            GuideLandingMapView(reports: mapReports)
              .ignoresSafeArea(edges: .bottom)
            GuideLandingMapLegend()
              .padding(.bottom, 8)
          }
        }
        .navigationTitle("Catch Map")
      }
      .navigationDestination(for: AnglerDestination.self) { dest in
        switch dest {
        case .conditions:
          FishingForecastRequestView()
            .environment(\.navigateTo, handleNavigateTo)
        case .learn:
          LearnTacticsView()
            .environment(\.navigateTo, handleNavigateTo)
            .environmentObject(communityService)
        case .community:
          SocialFeedView()
            .environment(\.navigateTo, handleNavigateTo)
        case .profile:
          ManageProfileView()
            .environmentObject(auth)
        case .trip:
          // Trip is shown as an overlay, not a pushed view — should not appear here
          EmptyView()
        case .explore:
          ExploreView()
            .environment(\.userRole, .angler)
            .environment(\.navigateTo, handleNavigateTo)
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
            CommunitySwitcherChevron()
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
    }
    .environmentObject(auth)
    .task {
      // Always refetch on appear. The previous `if reports.isEmpty` guard
      // caused stale catch history to persist across user/community switches
      // because the view instance survives those transitions and @State
      // retains the old array.
      await fetchReports()
      await fetchMapReports()
    }
    .onAppear {
      AppLogging.log("[AnglerLandingView] onAppear — requesting location, lastLocation=\(locationManager.lastLocation != nil), liveWeather=\(liveWeather != nil)", level: .debug, category: .network)
      locationManager.request()
      locationManager.start()
    }
    .onChange(of: locationManager.lastLocation) { loc in
      AppLogging.log("[AnglerLandingView] onChange lastLocation — loc=\(loc != nil), liveWeather=\(liveWeather != nil)", level: .debug, category: .network)
      guard liveWeather == nil, let loc else { return }
      AppLogging.log("[AnglerLandingView] onChange — fetching weather for \(loc.coordinate.latitude), \(loc.coordinate.longitude)", level: .debug, category: .network)
      Task { await fetchWeather(location: loc) }
    }
    .onDisappear {
      AppLogging.log("[AnglerLandingView] onDisappear", level: .debug, category: .auth)
    }
    .onAppear {
      AppLogging.log("[AnglerLandingView] onAppear — calling checkOnboarding", level: .info, category: .auth)
      checkOnboarding()
    }
    .onChange(of: communityService.activeCommunityTypeName) { newValue in
      AppLogging.log("[AnglerLandingView] onChange(activeCommunityTypeName) -> \(newValue ?? "nil") — calling checkOnboarding", level: .info, category: .auth)
      checkOnboarding()
    }
    .onChange(of: communityService.activeCommunityId) { newValue in
      AppLogging.log("[AnglerLandingView] onChange(activeCommunityId) -> \(newValue ?? "nil") — clearing stale reports and refetching", level: .info, category: .catch)
      // Clear immediately so the previous community's catches don't flash
      // onto the carousel while the next request is in flight.
      reports = []
      mapReports = []
      Task {
        await fetchReports()
        await fetchMapReports()
      }
    }
    .onChange(of: auth.currentMemberId) { newValue in
      AppLogging.log("[AnglerLandingView] onChange(currentMemberId) -> \(newValue ?? "nil") — clearing stale reports and refetching", level: .info, category: .catch)
      reports = []
      mapReports = []
      Task {
        await fetchReports()
        await fetchMapReports()
      }
    }
    .fullScreenCover(isPresented: $showOnboarding) {
      if let cid = communityService.activeCommunityId {
        AnglerOnboardingWizard(communityId: cid) {
          UserDefaults.standard.set(true, forKey: Self.onboardingKey(cid: cid, memberId: auth.currentMemberId))
          showOnboarding = false
        }
      }
    }
    // Custom slide-in panel for Trip Prep
    .overlay(
      ZStack(alignment: .trailing) {
        if showTripPrep {
          // Dimmed backdrop
          Color.brandScrim.opacity(0.45)
            .ignoresSafeArea()
            .onTapGesture { withAnimation(.easeInOut) { showTripPrep = false } }

          // Right-side panel (needs its own NavigationStack for internal links)
          NavigationStack {
            AnglerTripPrepView(onClose: { withAnimation(.easeInOut) { showTripPrep = false } })
          }
          .environment(\.navigateTo, handleNavigateTo)
          .environmentObject(auth)
          .preferredColorScheme(.dark)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.brandBackground)
          .transition(.move(edge: .trailing))
        }
      }
    )
    .animation(.easeInOut, value: showTripPrep)
  }

  // MARK: - Main content (no overlay/hit-test traps)

  private var content: some View {
    ScrollView {
      VStack(spacing: 8) {

        // ── Header: name → logo → display name → tagline ────
        VStack(spacing: 0) {
          // User name — left aligned
          Text("\(auth.currentFirstName ?? "") \(auth.currentLastName ?? "")")
            .font(.brandCaption.weight(.semibold))
            .foregroundColor(.brandTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)

          // Community logo — centred
          CommunityLogoView(config: communityService.activeCommunityConfig, size: 160)
            .frame(maxWidth: .infinity)

          // Community display name
          if let name = communityService.activeCommunityConfig.displayName, !name.isEmpty {
            Text(name)
              .font(.brandTitle2.weight(.bold))
              .foregroundColor(.brandTextPrimary)
              .multilineTextAlignment(.center)
              .padding(.top, -20)
          }

          // Community tagline
          if let tagline = communityService.activeCommunityConfig.tagline, !tagline.isEmpty {
            Text(tagline)
              .font(.brandSubheadline)
              .foregroundColor(.brandTextSecondary)
              .multilineTextAlignment(.center)
              .padding(.top, -16)
              .padding(.horizontal, 20)
          }
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
        Button { navPath.append(AnglerDestination.conditions) } label: {
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

  // Reports are pre-sorted newest-first at fetch time (see fetchReportsInternal).
  private var sortedReports: [CatchReportDTO] { reports }


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
      AppLogging.log("[AnglerLanding] No access token available", level: .error, category: .catch)
      errorText = "Please sign in to view your catch reports."
      return
    }

    let url: URL
    do {
      url = try AnglerLandingAPI.downloadCatchURL()
    } catch {
      AppLogging.log("[AnglerLanding] Failed to build download URL: \(error.localizedDescription)", level: .error, category: .catch)
      errorText = "Unable to load catch reports. Please try again later."
      return
    }

    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(auth.publicAnonKey, forHTTPHeaderField: "apikey")

    AppLogging.log("AnglerLanding download request URL: \(url.absoluteString)", level: .debug, category: .catch)
    AppLogging.log("AnglerLanding headers — apikey prefix: \(auth.publicAnonKey.prefix(8))…, Accept: application/json", level: .debug, category: .catch)

    do {
      let (data, resp) = try await URLSession.shared.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
      guard (200 ..< 300).contains(code) else {
        if allowRetryOnAuthError, [400, 401, 403].contains(code) {
          _ = await auth.currentAccessToken()
          await fetchReportsInternal(allowRetryOnAuthError: false)
          return
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        AppLogging.log("[AnglerLanding] Catch download failed (\(code)) body: \(body)", level: .error, category: .catch)
        errorText = "Unable to load catch reports. Please try again later."
        return
      }
      let decoded = try JSONDecoder().decode(DownloadResponse.self, from: data)
      let count = decoded.catch_reports.count
      AppLogging.log("AnglerLanding downloaded catch reports: count=\(count)", level: .debug, category: .catch)
      // Pre-sort newest-first so the view body doesn't re-sort on every render.
      let sorted = decoded.catch_reports.sorted {
        let d0 = DateFormatting.parseISO($0.createdAt) ?? .distantPast
        let d1 = DateFormatting.parseISO($1.createdAt) ?? .distantPast
        return d0 > d1
      }
      withAnimation { reports = sorted }
    } catch {
      AppLogging.log("[AnglerLanding] Network error fetching catches: \(error.localizedDescription)", level: .error, category: .catch)
      errorText = "Unable to load catch reports. Please check your connection and try again."
    }
  }

  // MARK: - Map reports

  private func fetchMapReports() async {
    guard let communityId = CommunityService.shared.activeCommunityId else { return }
    do {
      let reports = try await MapReportService.fetch(communityId: communityId)
      // Note: no `LocalMapPins.mergeWithServer` here. Anglers have no
      // on-device recording path — every catch they see on the map was
      // uploaded by their guide. Nothing ever lands in CatchReportStore /
      // FarmedReportStore under an angler-role session, so the merge would
      // always be a no-op. If anglers ever get a record path, wire the
      // merge in then (and the offline fallback below too).
      await MainActor.run { mapReports = reports }
    } catch {
      AppLogging.log("[AnglerLanding] Map reports fetch failed: \(error.localizedDescription)", level: .error, category: .network)
    }
  }

  // MARK: - Weather

  private func fetchWeather(location: CLLocation) async {
    AppLogging.log("[AnglerLandingView] fetchWeather called — \(location.coordinate.latitude), \(location.coordinate.longitude)", level: .debug, category: .network)
    let lat = location.coordinate.latitude
    let lon = location.coordinate.longitude

    // Reverse geocode for city name
    let geocoder = CLGeocoder()
    let locationName: String
    do {
      let placemarks = try await geocoder.reverseGeocodeLocation(location)
      AppLogging.log("[AnglerLandingView] geocoder returned \(placemarks.count) placemark(s)", level: .debug, category: .network)
      if let placemark = placemarks.first {
        let city = placemark.locality
          ?? placemark.subLocality
          ?? placemark.subAdministrativeArea
          ?? ""
        let state = placemark.administrativeArea ?? ""
        locationName = [city, state].filter { !$0.isEmpty }.joined(separator: ", ")
      } else {
        locationName = ""
      }
    } catch {
      AppLogging.log("[AnglerLandingView] geocoder FAILED: \(error.localizedDescription)", level: .error, category: .network)
      locationName = ""
    }
    AppLogging.log("[AnglerLandingView] locationName='\(locationName)', calling WeatherSnapshotService.fetch", level: .debug, category: .network)

    do {
      let response = try await WeatherSnapshotService.fetch(lat: lat, lon: lon)
      AppLogging.log("[AnglerLandingView] WeatherSnapshotService returned — temp=\(response.current.temperature), code=\(response.current.weatherCode), hourly=\(response.hourlyForecast.count)", level: .debug, category: .network)
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
        AppLogging.log("[AnglerLandingView] liveWeather SET — locationName='\(locationName)', temp=\(Int(w.temperature.rounded())), source=\(response.source ?? "unknown")", level: .info, category: .network)
      }
    } catch {
      AppLogging.log("[AnglerLandingView] WeatherSnapshotService FAILED: \(error.localizedDescription)", level: .error, category: .network)
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

  // MARK: - Onboarding

  /// Community types that trigger the angler onboarding wizard.
  static let onboardingCommunityTypes: Set<String> = ["Lodge", "MultiLodge", "FlyShop"]

  /// Build a per-user, per-community onboarding key so each new member
  /// gets their own wizard even on a shared simulator / device. Pure
  /// function (depends only on its arguments) so tests can lock the
  /// shape — mismatched keys silently re-show the wizard or skip it.
  static func onboardingKey(cid: String, memberId: String?) -> String {
    if let mid = memberId {
      return "anglerOnboarded_\(mid)_\(cid)"
    }
    return "anglerOnboarded_\(cid)"
  }

  private func checkOnboarding() {
    let cid = communityService.activeCommunityId
    let typeName = communityService.activeCommunityTypeName
    let hasFetched = communityService.hasFetchedMemberships
    let key = cid.map { Self.onboardingKey(cid: $0, memberId: auth.currentMemberId) }
    let alreadyOnboarded = key.map { UserDefaults.standard.bool(forKey: $0) } ?? false
    AppLogging.log("[AnglerLanding] checkOnboarding — cid=\(cid ?? "nil") typeName=\(typeName ?? "nil") hasFetched=\(hasFetched) alreadyOnboarded=\(alreadyOnboarded) key=\(key ?? "nil") memberId=\(auth.currentMemberId ?? "nil") showOnboarding=\(showOnboarding)", level: .info, category: .auth)

    guard let cid,
          let typeName,
          Self.onboardingCommunityTypes.contains(typeName),
          !alreadyOnboarded
    else {
      AppLogging.log("[AnglerLanding] checkOnboarding — SKIPPED (guard failed)", level: .info, category: .auth)
      return
    }
    AppLogging.log("[AnglerLanding] checkOnboarding — SHOWING onboarding for cid=\(cid) type=\(typeName)", level: .info, category: .auth)
    showOnboarding = true
  }

  // MARK: - Actions

  private func logoutTapped() {
    Task {
      await auth.signOutRemote()
      dismiss()
    }
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
