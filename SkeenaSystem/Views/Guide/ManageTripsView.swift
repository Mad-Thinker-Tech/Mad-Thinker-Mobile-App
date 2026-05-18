// Bend Fly Shop

import SwiftUI
import CoreData

struct ManageTripsView: View {
  @Environment(\.dismiss) private var dismiss

  let guideFirstName: String

  @State private var serverTrips: [ServerTripItem] = []
  @State private var isLoading = false
  @State private var loadError: String?
  @State private var selectedTrip: TripAPI.TripSummary?
  @State private var navigateToDetail = false

  var body: some View {
    DarkPageTemplate(bottomToolbar: {
      RoleAwareToolbar(activeTab: "trips")
    }) {
      VStack(spacing: 0) {
        AppHeader()
          .padding(.bottom, 10)

        if isLoading {
          Spacer()
          ProgressView().tint(.white)
          Spacer()
        } else if let err = loadError {
          Spacer()
          Text(err).foregroundColor(.brandError).padding()
          Spacer()
        } else if serverTrips.isEmpty {
          Spacer()
          Text("No trips have been set up yet")
            .foregroundColor(.secondary)
          Spacer()
        } else {
          List {
            let grouped = Dictionary(grouping: serverTrips, by: { $0.status })
            let order: [TripRowStatus] = [.inProgress, .notStarted, .completed]
            ForEach(order.filter { grouped[$0] != nil }, id: \.self) { st in
              Section {
                ForEach(grouped[st]!.sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }) { trip in
                  Button {
                    selectedTrip = trip.summary
                    navigateToDetail = true
                  } label: {
                    HStack(alignment: .center) {
                      VStack(alignment: .leading, spacing: 6) {
                        Text(trip.name.isEmpty ? "-" : trip.name)
                          .foregroundColor(.brandTextPrimary)
                          .font(.brandHeadline)
                        Text(dateRangeString(start: trip.startDate, end: trip.endDate))
                          .font(.brandCaption)
                          .foregroundColor(.secondary)
                      }
                      Spacer()
                      Image(systemName: "chevron.right")
                        .font(.brandFootnote.weight(.semibold))
                        .foregroundColor(.brandTextPrimary.opacity(0.8))
                    }
                    .padding(.vertical, 8)
                  }
                  .buttonStyle(.plain)
                  .listRowBackground(Color.brandBackground)
                }
              } header: {
                HStack {
                  TripStatusPill(status: st)
                  Spacer()
                }
                .listRowBackground(Color.brandBackground)
              }
              .listRowBackground(Color.brandBackground)
            }
          }
          .listStyle(.insetGrouped)
          .modifier(HideListBackgroundModifier())
          .environment(\.colorScheme, .dark)
        }
      }
    }
    .navigationTitle("Trips")
    .navigationBarBackButtonHidden(true)
    .navigationDestination(isPresented: $navigateToDetail) {
      if let trip = selectedTrip {
        TripDetailView(trip: trip)
      }
    }
    .onAppear { fetchServerTrips() }
  }

  // MARK: - Helpers

  private func dayString(_ date: Date?) -> String {
    guard let d = date else { return "-" }
    return d.formatted(date: .abbreviated, time: .omitted)
  }

  private func dateRangeString(start: Date?, end: Date?) -> String {
    let s = dayString(start)
    let e = dayString(end)
    if e == "-" || e == s { return s }
    return "\(s) – \(e)"
  }

  /// Parse an ISO8601 or date-only string into a Date.
  private func parseDate(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    return DateFormatting.parseISO(s) ?? DateFormatting.ymd.date(from: s)
  }

  private func fetchServerTrips() {
    isLoading = true
    loadError = nil
    Task {
      await AuthStore.shared.refreshFromSupabase()
      guard let jwt = AuthStore.shared.jwt else {
        await MainActor.run {
          isLoading = false
          loadError = "Not signed in."
          serverTrips = []
        }
        return
      }
      do {
        let trips = try await TripAPI.getTrips(jwt: jwt)
        let mapped: [ServerTripItem] = trips.map { t in
          ServerTripItem(
            summary: t,
            name: t.tripName ?? "",
            startDate: parseDate(t.startDate),
            endDate: parseDate(t.endDate)
          )
        }
        await MainActor.run {
          self.serverTrips = mapped.sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
          self.isLoading = false
        }
      } catch {
        await MainActor.run {
          self.isLoading = false
          self.serverTrips = []
          self.loadError = error.localizedDescription
        }
      }
    }
  }
}

// MARK: - View models

private struct ServerTripItem: Identifiable {
  let summary: TripAPI.TripSummary
  let name: String
  let startDate: Date?
  let endDate: Date?

  var id: String { summary.id }

  var status: TripRowStatus {
    let cal = Calendar.current
    let now = Date()
    guard let s = startDate else { return .notStarted }
    let startOfToday = cal.startOfDay(for: now)
    // Compare all dates at day granularity to avoid UTC-vs-local edge cases
    let startDay = cal.startOfDay(for: s)
    if startDay > startOfToday { return .notStarted }
    if let e = endDate {
      let endDay = cal.startOfDay(for: e)
      return endDay >= startOfToday ? .inProgress : .completed
    }
    // No end date — 1-day trip, in progress if today is the start day
    return startDay == startOfToday ? .inProgress : .completed
  }
}

private enum TripRowStatus: String {
  case notStarted = "Not started"
  case inProgress = "In progress"
  case completed = "Completed"
}

private struct TripStatusPill: View {
  let status: TripRowStatus

  var body: some View {
    Text(status.rawValue)
      .font(.brandCaption2)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(backgroundColor)
      .foregroundColor(foregroundColor)
      .clipShape(Capsule())
  }

  private var backgroundColor: Color {
    switch status {
    case .notStarted: return Color.yellow.opacity(0.18)
    case .inProgress: return Color.brandSuccess.opacity(0.18)
    case .completed: return Color.brandTextSecondary.opacity(0.15)
    }
  }

  private var foregroundColor: Color {
    switch status {
    case .notStarted: return .orange
    case .inProgress: return .brandSuccess
    case .completed: return .gray
    }
  }
}

// MARK: - Helper: hide list background on iOS 16+

private struct HideListBackgroundModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 16.0, *) {
      content.scrollContentBackground(.hidden)
    } else {
      content
    }
  }
}
