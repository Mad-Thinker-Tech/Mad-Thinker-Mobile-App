// Bend Fly Shop
//
// GuideFullMapView.swift — Full-page version of the guide-landing map. Reached
// from the expand button on the landing tile. Re-fetches reports on appear so
// a catch the guide just logged shows up without a manual refresh, and shows
// every report type (catch + active/farmed/promising/passed), unlike the
// member-scoped, catch-only ResearcherMapView.

import CoreLocation
import SwiftUI

struct GuideFullMapView: View {
  @StateObject private var loc = LocationManager()

  @State private var mapReports: [MapReportDTO] = []
  @State private var fetchDone = false

  var body: some View {
    DarkPageTemplate(bottomToolbar: {
      RoleAwareToolbar(activeTab: "map")
    }) {
      content
    }
    .navigationTitle("Map")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      loc.request()
      loc.start()
    }
    .task {
      await fetchMapReports()
    }
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if !fetchDone {
      ZStack {
        Color.black
        ProgressView().tint(.white)
      }
    } else {
      VStack(spacing: 6) {
        GuideLandingMapView(
          reports: mapReports,
          userLocation: loc.lastLocation?.coordinate
        )

        GuideLandingMapLegend()
          .padding(.bottom, 6)
      }
    }
  }

  // MARK: - Fetch

  private func fetchMapReports() async {
    defer { Task { @MainActor in fetchDone = true } }
    guard let communityId = CommunityService.shared.activeCommunityId else {
      AppLogging.log("[GuideFullMap] no active community — skipping fetch", level: .debug, category: .map)
      return
    }
    do {
      let reports = try await MapReportService.fetch(communityId: communityId)
      await MainActor.run { mapReports = reports }
    } catch {
      AppLogging.log("[GuideFullMap] fetch failed: \(error.localizedDescription)", level: .error, category: .map)
    }
  }
}
