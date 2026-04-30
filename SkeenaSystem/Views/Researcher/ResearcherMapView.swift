// Bend Fly Shop
//
// ResearcherMapView.swift — Full-page map of the *current researcher's* catch
// reports. Reached from the Researcher bottom toolbar's "Maps" tab. Mirrors the
// Guide landing-page map but server-filters by member_id and drops every
// non-catch report type, so the map only shows pins this researcher logged.

import CoreLocation
import SwiftUI

struct ResearcherMapView: View {
  @StateObject private var loc = LocationManager()

  @State private var mapReports: [MapReportDTO] = []
  @State private var fetchDone = false

  var body: some View {
    DarkPageTemplate(bottomToolbar: {
      RoleAwareToolbar(activeTab: "maps")
    }) {
      content
    }
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
      ZStack {
        GuideLandingMapView(
          reports: mapReports,
          userLocation: loc.lastLocation?.coordinate
        )

        if mapReports.isEmpty {
          Text("No catches recorded yet")
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.6), in: Capsule())
            .accessibilityIdentifier("researcherMapEmptyState")
        }
      }
    }
  }

  // MARK: - Fetch

  /// Fetches the catch-only subset of map reports for the active community,
  /// scoped to this researcher's member id. Reports without a memberId or
  /// with a non-`catch` type are dropped client-side as defense in depth in
  /// case the server stops honouring the filter.
  private func fetchMapReports() async {
    defer { Task { @MainActor in fetchDone = true } }

    guard let communityId = CommunityService.shared.activeCommunityId else {
      AppLogging.log("[ResearcherMap] no active community — skipping fetch", level: .debug, category: .map)
      return
    }
    let memberId = (AuthService.shared.currentMemberId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !memberId.isEmpty else {
      AppLogging.log("[ResearcherMap] no current memberId — skipping fetch", level: .debug, category: .map)
      return
    }

    do {
      let all = try await MapReportService.fetch(communityId: communityId, memberId: memberId)
      let catches = all.filter { $0.type == "catch" }
      await MainActor.run { mapReports = catches }
    } catch {
      AppLogging.log("[ResearcherMap] fetch failed: \(error.localizedDescription)", level: .error, category: .map)
    }
  }
}
