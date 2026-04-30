// Bend Fly Shop
// GuideLandingView.swift
// Bend Fly Shop – iOS 15+ nav-bar button + pinned footer
import CoreLocation
import SwiftUI

// MARK: - GuideLandingView

struct GuideLandingView: View {
  @Environment(\.managedObjectContext) private var context
  @StateObject private var auth = AuthService.shared
  @ObservedObject private var communityService = CommunityService.shared

  // Conservation opt-in (persisted across launches in UserDefaults).
  // When on, every catch the guide records will be routed through the
  // researcher (research-grade) flow. See ConservationModeStore.swift.
  @ObservedObject private var conservationStore = ConservationModeStore.shared

  // OPS add-on — driven by community_addons table (replaces isOpsActive entitlement)
  private var isOpsActive: Bool { communityService.addons["OPS"] ?? false }

  // Navigation
  @State private var showRecordActivity = false
  @State private var goToManageAccount = false

  // Location (for weather)
  @StateObject private var locationManager = LocationManager()
  // showFarmedList removed — farmed marks are now in Activities → Observations → Marks

  // Map reports
  @State private var mapReports: [MapReportDTO] = []
  @State private var mapFetchDone = false

  // Pushed full-screen map (expand button on the landing tile)
  @State private var showFullMap = false

  // Live weather
  @State private var liveWeather: LiveWeather? = nil

  // Path-based nav for guide toolbar navigation
  @State private var navPath = NavigationPath()

  // One-time camera/location onboarding for guides
  @AppStorage("hasSeenGuideCameraLocationOnboarding")
  private var hasSeenGuideCameraLocationOnboarding: Bool = false

  @State private var showGuideLocationOnboarding = false

  var body: some View {
    NavigationStack(path: $navPath) {
      DarkPageTemplate(bottomToolbar: {
        RoleAwareToolbar(activeTab: "home")
      }) {
        content
      }
      .navigationDestination(isPresented: $showRecordActivity) {
        GuideRecordActivityView(onCatchSaved: {
          showRecordActivity = false
          navPath = NavigationPath()
        })
        .environment(\.guideNavigateTo, handleGuideNavigateTo)
        .environmentObject(auth)
      }
      .navigationDestination(isPresented: $goToManageAccount) {
        ManageProfileView().environmentObject(auth)
      }
      .navigationDestination(isPresented: $showFullMap) {
        GuideFullMapView()
          .environment(\.userRole, .guide)
          .environment(\.guideNavigateTo, handleGuideNavigateTo)
      }
      // Farmed list nav removed — farmed marks are now in Activities → Observations → Marks
      .navigationDestination(for: GuideDestination.self) { dest in
        switch dest {
        case .conditions:
          FishingForecastRequestView()
            .environment(\.userRole, .guide)
            .environment(\.guideNavigateTo, handleGuideNavigateTo)
        case .community:
          SocialFeedView()
            .environment(\.userRole, .guide)
            .environment(\.guideNavigateTo, handleGuideNavigateTo)
        case .trips:
          ManageTripsView(guideFirstName: auth.currentFirstName ?? "Guide")
            .environment(\.userRole, .guide)
            .environment(\.guideNavigateTo, handleGuideNavigateTo)
        case .activities:
          ActivitiesView()
            .environment(\.userRole, .guide)
            .environment(\.guideNavigateTo, handleGuideNavigateTo)
        case .observations:
          // Standalone observations view removed — now inside Activities → Observations tab.
          // Keep the case to avoid exhaustive-switch errors; navigates to Activities instead.
          ActivitiesView()
            .environment(\.userRole, .guide)
            .environment(\.guideNavigateTo, handleGuideNavigateTo)
        case .learn:
          // Guides don't use Learn — should not be reached
          EmptyView()
        case .explore:
          // Guides don't use Explore — should not be reached
          EmptyView()
        case .maps:
          // Maps is researcher-only — should not be reached from a guide toolbar
          EmptyView()
        }
      }
      .toolbar {
        // Leading manage-profile + community switcher
        ToolbarItem(placement: .navigationBarLeading) {
          HStack(spacing: 12) {
            Button(action: { goToManageAccount = true }) {
              Image(systemName: "person.circle")
                .font(.title3.weight(.semibold))
                .foregroundColor(.white)
            }
            CommunityToolbarButton()
          }
        }
        // Leading ops tickets button (guides only, when isOpsActive)
        if isOpsActive {
          ToolbarItem(placement: .navigationBarLeading) {
            NavigationLink { OpsTicketsListView() } label: {
              Image(systemName: "wrench.and.screwdriver")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
            }
            .accessibilityIdentifier("manageTicketsTile")
          }
        }
        // Trailing logout
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: logoutTapped) {
            HStack(spacing: 6) {
              Image(systemName: "person.crop.circle.badge.xmark")
                .font(.subheadline)
              Text("Log out")
                .font(.caption)
            }
          }
          .accessibilityIdentifier("logoutCapsule")
        }
      }
      // NEW: one-time camera/location onboarding for guides
      .fullScreenCover(isPresented: $showGuideLocationOnboarding) {
        GuideCameraLocationOnboardingView {
          // Mark as seen and dismiss
          hasSeenGuideCameraLocationOnboarding = true
          showGuideLocationOnboarding = false
        }
      }
      // Decide when to show the onboarding
      .onAppear {
        if auth.currentUserType == .guide,
           !hasSeenGuideCameraLocationOnboarding {
          showGuideLocationOnboarding = true
        }
        // Start location updates for farmed button
        AppLogging.log("[GuideLandingView] onAppear — requesting location, lastLocation=\(locationManager.lastLocation != nil), liveWeather=\(liveWeather != nil)", level: .debug, category: .network)
        locationManager.request()
        locationManager.start()
      }
      // Fetch weather once location is available
      .onChange(of: locationManager.lastLocation) { loc in
        AppLogging.log("[GuideLandingView] onChange lastLocation — loc=\(loc != nil), liveWeather=\(liveWeather != nil)", level: .debug, category: .network)
        guard liveWeather == nil, let loc else { return }
        AppLogging.log("[GuideLandingView] onChange — fetching weather for \(loc.coordinate.latitude), \(loc.coordinate.longitude)", level: .debug, category: .network)
        Task { await fetchWeather(location: loc) }
      }
      // Sync server trips into Core Data so they're available
      // when the guide taps "Record a Catch".
      .task {
        await TripSyncService.shared.syncTripsIfNeeded(context: context)
        await fetchMapReports()
      }
    }
    .environment(\.userRole, .guide)
    .environment(\.guideNavigateTo, handleGuideNavigateTo)
    .environmentObject(auth)
  }

  // MARK: - Main content

  private var content: some View {
    ScrollView {
      VStack(spacing: 8) {

        // ── Header: name → logo → display name → tagline → record ─────
        VStack(spacing: 0) {
          // Guide name (leading) + Conservation Mode toggle (trailing) — same row
          HStack(spacing: 12) {
            Text("\(auth.currentFirstName ?? "") \(auth.currentLastName ?? "")")
              .font(.caption.weight(.semibold))
              .foregroundColor(.white)

            Spacer()

            Toggle(isOn: $conservationStore.isEnabled) {
              Text("Conservation Mode")
                .font(.caption.weight(.semibold))
                .foregroundColor(.green)
            }
            .toggleStyle(SwitchToggleStyle(tint: .green))
            .fixedSize()
            .accessibilityIdentifier("conservationToggle")
          }
          .padding(.horizontal, 20)

          // Community logo — centred
          CommunityLogoView(config: communityService.activeCommunityConfig, size: 160)
            .frame(maxWidth: .infinity)

          // Community display name
          if let name = communityService.activeCommunityConfig.displayName, !name.isEmpty {
            Text(name)
              .font(.title2.weight(.bold))
              .foregroundColor(.white)
              .multilineTextAlignment(.center)
              .padding(.top, -20)
          }

          // Community tagline
          if let tagline = communityService.activeCommunityConfig.tagline, !tagline.isEmpty {
            Text(tagline)
              .font(.subheadline)
              .foregroundColor(.gray)
              .multilineTextAlignment(.center)
              .padding(.top, -16)
              .padding(.horizontal, 20)
          }

          // Record capsule — right aligned, directly below logo
          Button { showRecordActivity = true } label: {
            Text("Record")
              .font(.caption.weight(.bold))
              .foregroundColor(.white)
              .padding(.horizontal, 14)
              .padding(.vertical, 7)
              .background(Color.blue, in: Capsule())
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
            Text(liveWeather?.locationName ?? "–")
              .font(.system(size: 11, weight: .semibold))
              .foregroundColor(.white)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 3) {
              Image(systemName: liveWeather?.icon ?? "thermometer")
                .font(.caption)
                .foregroundColor(weatherIconColor(liveWeather?.icon))
              Text(liveWeather.map { "\(communityService.activeCommunityConfig.temperature(Double($0.temp)))\(communityService.activeCommunityConfig.tempUnit)" } ?? "–")
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
            }
            .frame(width: 56, alignment: .center)

            HStack(spacing: 3) {
              Image(systemName: "wind")
                .font(.caption2)
                .foregroundColor(.gray)
              Text(liveWeather.map { "\($0.windDir) \(communityService.activeCommunityConfig.windSpeed(Double($0.windSpeed)))" } ?? "–")
                .font(.caption2.weight(.medium))
                .foregroundColor(.white)
            }
            .frame(width: 56, alignment: .center)

            HStack(spacing: 3) {
              Image(systemName: "barometer")
                .font(.caption2)
                .foregroundColor(.gray)
              Text(liveWeather.map { "\($0.pressureVal)" } ?? "–")
                .font(.caption2.weight(.medium))
                .foregroundColor(.white)
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
              .fill(Color.white.opacity(0.12))
              .frame(height: 0.5)
              .padding(.horizontal, 14)

            HStack(spacing: 0) {
              ForEach(hourly) { slot in
                VStack(alignment: .center, spacing: 2) {
                  Text(slot.hour)
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                  Image(systemName: slot.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundColor(weatherIconColor(slot.icon))
                  Text("\(communityService.activeCommunityConfig.temperature(Double(slot.temp)))°")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
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
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)

        // ── Fisheries Conditions ───────────────────────────────────────
        Button { handleGuideNavigateTo(.conditions) } label: {
          HStack(spacing: 8) {
            Image(systemName: "water.waves")
              .font(.caption)
              .foregroundColor(.white)
            Text("Fisheries Conditions")
              .font(.caption.weight(.semibold))
              .foregroundColor(.white)
            Spacer()
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundColor(.white.opacity(0.4))
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("fishingForecastTile")

        // ── Map ────────────────────────────────────────────────────────
        if !mapFetchDone {
          ZStack {
            RoundedRectangle(cornerRadius: 14)
              .fill(Color.white.opacity(0.06))
            ProgressView().tint(.white)
          }
          .frame(height: 230)
          .padding(.horizontal, 16)
        } else {
          VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
              GuideLandingMapView(
                reports: mapReports,
                userLocation: locationManager.lastLocation?.coordinate
              )
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 14))

              Button { showFullMap = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                  .font(.system(size: 14, weight: .semibold))
                  .foregroundColor(.white)
                  .padding(8)
                  .background(Color.black.opacity(0.55), in: Circle())
              }
              .buttonStyle(.plain)
              .padding(8)
              .accessibilityIdentifier("expandMapButton")
              .accessibilityLabel("Expand map")
            }

            GuideLandingMapLegend()
          }
          .padding(.horizontal, 16)
        }

        Spacer(minLength: 8)
      }
    }
  }

  // MARK: - Map reports

  private func fetchMapReports() async {
    defer { Task { @MainActor in mapFetchDone = true } }
    guard let communityId = CommunityService.shared.activeCommunityId else { return }
    do {
      let reports = try await MapReportService.fetch(communityId: communityId)
      await MainActor.run { mapReports = reports }
    } catch {
      AppLogging.log("[LandingMap] Fetch failed: \(error.localizedDescription)", level: .error, category: .network)
    }
  }

  // MARK: - Weather

  private func fetchWeather(location: CLLocation) async {
    AppLogging.log("[GuideLandingView] fetchWeather called — \(location.coordinate.latitude), \(location.coordinate.longitude)", level: .debug, category: .network)
    let lat = location.coordinate.latitude
    let lon = location.coordinate.longitude

    // Reverse geocode for city name — try multiple placemark fields for robustness
    let geocoder = CLGeocoder()
    let locationName: String
    do {
      let placemarks = try await geocoder.reverseGeocodeLocation(location)
      AppLogging.log("[GuideLandingView] geocoder returned \(placemarks.count) placemark(s)", level: .debug, category: .network)
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
      AppLogging.log("[GuideLandingView] geocoder FAILED: \(error.localizedDescription)", level: .error, category: .network)
      locationName = ""
    }
    AppLogging.log("[GuideLandingView] locationName='\(locationName)', calling WeatherSnapshotService.fetch", level: .debug, category: .network)

    do {
      let response = try await WeatherSnapshotService.fetch(lat: lat, lon: lon)
      AppLogging.log("[GuideLandingView] WeatherSnapshotService returned — temp=\(response.current.temperature), code=\(response.current.weatherCode), hourly=\(response.hourlyForecast.count)", level: .debug, category: .network)
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
        AppLogging.log("[GuideLandingView] liveWeather SET — locationName='\(locationName)', temp=\(Int(w.temperature.rounded())), source=\(response.source ?? "unknown")", level: .info, category: .network)
      }
    } catch {
      AppLogging.log("[GuideLandingView] WeatherSnapshotService FAILED: \(error.localizedDescription)", level: .error, category: .network)
    }
  }

  private func pressureTrendColor(_ trend: WeatherPressureTrend?) -> Color {
    switch trend {
    case .rising:  return .green
    case .falling: return .red
    default:       return .gray
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

  // MARK: - Guide Navigation

  /// Centralized handler for guide toolbar navigation.
  /// Pass `nil` to pop to root (Home). Pass a destination to navigate there.
  private func handleGuideNavigateTo(_ destination: GuideDestination?) {
    guard let destination else {
      // Home — pop to root
      navPath = NavigationPath()
      return
    }

    // Replace the entire path with the new destination in one step
    // to avoid flashing the landing screen.
    var newPath = NavigationPath()
    newPath.append(destination)
    navPath = newPath
  }

}
