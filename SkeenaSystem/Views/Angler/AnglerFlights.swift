// Bend Fly Shop
// AnglerFlights.swift
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import Foundation

// MARK: - URL composition helper for AnglerFlights (mirrors AnglerAboutYou style)
private enum AnglerFlightsAPI {
  private static let rawBaseURLString = APIURLUtilities.infoPlistString(forKey: "API_BASE_URL")
  private static let baseURLString = APIURLUtilities.normalizeBaseURL(rawBaseURLString)

  private static let flightDetailsPath: String = {
    let path = APIURLUtilities.infoPlistString(forKey: "FLIGHT_DETAILS")
    return path.isEmpty ? "/functions/v1/flight-details" : path
  }()

  private static let flightStatusPath: String = {
    let path = APIURLUtilities.infoPlistString(forKey: "FLIGHT_STATUS")
    return path.isEmpty ? "/functions/v1/flight-status" : path
  }()

  private static func logConfig() {
    AppLogging.log("AnglerFlights config — API_BASE_URL (raw): '\(rawBaseURLString)'", level: .debug, category: .angler)
    AppLogging.log("AnglerFlights config — API_BASE_URL (normalized): '\(baseURLString)'", level: .debug, category: .angler)
    AppLogging.log("AnglerFlights config — FLIGHT_DETAILS: '\(flightDetailsPath)'", level: .debug, category: .angler)
    AppLogging.log("AnglerFlights config — FLIGHT_STATUS: '\(flightStatusPath)'", level: .debug, category: .angler)
  }

  private static func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
    AppLogging.log("AnglerFlights makeURL start — base(raw): '\(rawBaseURLString)', base(normalized): '\(baseURLString)', path: '\(path)'", level: .debug, category: .angler)
    guard let base = URL(string: baseURLString), let scheme = base.scheme, let host = base.host else {
      AppLogging.log("AnglerFlights invalid API_BASE_URL — raw: '\(rawBaseURLString)', normalized: '\(baseURLString)'", level: .error, category: .angler)
      throw NSError(domain: "AnglerFlights", code: -1000, userInfo: [
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
    AppLogging.log("AnglerFlights makeURL components — scheme: \(scheme), host: \(host), port: \(String(describing: base.port)), basePath: '\(base.path)', normalizedBasePath: '\(normalizedBasePath)', normalizedPath: '\(normalizedPath)'", level: .debug, category: .angler)
    comps.path = normalizedBasePath + normalizedPath

    let existing = base.query != nil ? (URLComponents(string: base.absoluteString)?.queryItems ?? []) : []
    let merged = existing + queryItems
    comps.queryItems = merged.isEmpty ? nil : merged
    AppLogging.log({
      let qi = comps.queryItems?.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&") ?? "<none>"
      return "AnglerFlights makeURL composed — path: '\(comps.path)', query: \(qi)"
    }(), level: .debug, category: .angler)

    guard let url = comps.url else {
      AppLogging.log("AnglerFlights makeURL failed to build URL for path: \(path)", level: .error, category: .angler)
      throw NSError(domain: "AnglerFlights", code: -1001, userInfo: [
        NSLocalizedDescriptionKey: "Failed to build URL for path: \(path)"
      ])
    }
    AppLogging.log("AnglerFlights makeURL success — URL: \(url.absoluteString)", level: .debug, category: .angler)
    return url
  }

  static func flightDetailsURL() throws -> URL {
    logConfig()
    return try makeURL(path: flightDetailsPath)
  }

  static func flightStatusURL() throws -> URL {
    logConfig()
    return try makeURL(path: flightStatusPath)
  }
}

struct AnglerFlights: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var auth = AuthService.shared

  // MARK: - View State
  @State private var isLoading: Bool = false
  @State private var errorText: String?
  @State private var infoText: String?

  @State private var itineraries: [Itinerary] = []
  @State private var selectedItinerary: Itinerary?
  @State private var showingAddSheet: Bool = false
    
    // Compose endpoints from config (fall back to environment-aware projectURL if composition fails)
    private let itinerariesEndpoint: URL = {
      do { return try AnglerFlightsAPI.flightDetailsURL() } catch {
        AppLogging.log("AnglerFlights — failed to compose itinerariesEndpoint, falling back to projectURL: \(error.localizedDescription)", level: .warn, category: .angler)
        return AppEnvironment.shared.projectURL.appendingPathComponent("functions/v1/flight-details")
      }
    }()

    private let statusEndpoint: URL = {
      do { return try AnglerFlightsAPI.flightStatusURL() } catch {
        AppLogging.log("AnglerFlights — failed to compose statusEndpoint, falling back to projectURL: \(error.localizedDescription)", level: .warn, category: .angler)
        return AppEnvironment.shared.projectURL.appendingPathComponent("functions/v1/flight-status")
      }
    }()

    private let localCacheKey = "LocalItinerariesCache"

  var body: some View {
    NavigationView {
      ZStack {
        Color.brandBackground.ignoresSafeArea()
        VStack(spacing: 18) {
          header

          // Messages
          if let errorText = errorText {
            Text(errorText)
              .font(.brandFootnote)
              .foregroundColor(.brandError)
              .multilineTextAlignment(.center)
              .padding(.horizontal, 16)
          }
          if let infoText = infoText {
            Text(infoText)
              .font(.brandFootnote)
              .foregroundColor(.brandSuccess)
              .multilineTextAlignment(.center)
              .padding(.horizontal, 16)
          }

          content

          Spacer(minLength: 0)
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .navigationBarHidden(false)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Text("Your flight itineraries")
            .font(.brandHeadline.weight(.semibold))
            .foregroundColor(.brandTextPrimary)
        }
      }
    }
    .preferredColorScheme(.dark)
    .task {
      AppLogging.log("AnglerFlights — task start", level: .debug, category: .angler)
      loadCachedItineraries()
      await refresh()
    }
    .sheet(isPresented: $showingAddSheet) {
      AddItinerarySheet(onSubmit: { payload in
        await uploadItinerary(payload: payload)
      })
      .preferredColorScheme(.dark)
    }
  }

  // MARK: - Subviews

  private var header: some View {
    VStack(spacing: 6) {
      CommunityLogoView(config: CommunityService.shared.activeCommunityConfig, size: 130)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(radius: 10)
        .padding(.bottom, 2)
    }
    .padding(.top, 16)
  }

  @ViewBuilder
  private var content: some View {
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        Button(action: { showingAddSheet = true }) {
          actionCapsule(title: "Add Itinerary", systemImage: "plus")
        }
        .disabled(isLoading)

        Button(action: { Task { await refresh() } }) {
          actionCapsule(title: isLoading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(isLoading || itineraries.isEmpty)
      }
      .padding(.horizontal, 16)

      if itineraries.isEmpty {
        VStack(spacing: 8) {
          Text("No itineraries yet.")
            .foregroundColor(.brandTextSecondary)
            .font(.brandSubheadline)
        }
        .padding(.top, 8)
      } else {
        List {
          ForEach(itineraries) { itin in
            Button {
              AppLogging.log("AnglerFlights — select itinerary id=\(itin.id)", level: .debug, category: .angler)
              selectedItinerary = itin
            } label: {
              ItineraryRow(itinerary: itin)
            }
            .listRowBackground(Color.brandStrokeSubtle)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
              Button(role: .destructive) {
                Task { await deleteItinerary(itineraryId: itin.id) }
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
        }
        .listStyle(.plain)
        .background(Color.clear)
        .hideScrollBackgroundIfAvailable()
        .sheet(item: $selectedItinerary) { itin in
          ItineraryDetailView(itinerary: itin, statusLoader: { segments in
            return try await fetchStatus(for: segments)
          })
          .preferredColorScheme(.dark)
        }
      }
    }
  }

  private func actionCapsule(title: String, systemImage: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
      Text(title)
        .font(.brandFootnote.weight(.semibold))
    }
    .foregroundColor(.brandTextPrimary)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      Group {
        if systemImage == "arrow.clockwise" && itineraries.isEmpty {
          Color.brandTextSecondary
        } else {
          Color.brandAccent
        }
      }
    )
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  // MARK: - Networking

  private func refresh() async {
    await fetchItineraries()
  }

  private func fetchItineraries(userId: String? = nil, itineraryId: String? = nil) async {
    guard !isLoading else { return }
    errorText = nil
    infoText = nil
    isLoading = true
    defer { isLoading = false }

    guard let token = await auth.currentAccessToken(), !token.isEmpty else {
      errorText = "You are not signed in."
      return
    }

    var url = itinerariesEndpoint
    if userId != nil || itineraryId != nil {
      var comps = URLComponents(url: itinerariesEndpoint, resolvingAgainstBaseURL: false)!
      var items: [URLQueryItem] = []
      if let userId { items.append(URLQueryItem(name: "userId", value: userId)) }
      if let itineraryId { items.append(URLQueryItem(name: "itineraryId", value: itineraryId)) }
      comps.queryItems = items
      url = comps.url!
    }
    AppLogging.log("AnglerFlights — Itineraries GET — URL: \(url.absoluteString)", level: .debug, category: .angler)

    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    AppLogging.log("AnglerFlights — Itineraries GET — Method: \(req.httpMethod ?? "<nil>")", level: .debug, category: .angler)
    AppLogging.log("AnglerFlights — Itineraries GET — Headers: Authorization=Bearer <redacted>", level: .debug, category: .angler)

    do {
      let (data, resp) = try await URLSession.shared.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
      AppLogging.log("AnglerFlights — Itineraries GET — Status: \(code)", level: .debug, category: .angler)
      guard (200 ..< 300).contains(code) else {
        let body = String(data: data, encoding: .utf8) ?? ""
        errorText = "Fetch failed (\(code))"
        AppLogging.log("AnglerFlights — Itineraries GET failed (\(code)) body: \(body)", level: .error, category: .angler)
        return
      }
      let decoded = try JSONDecoder().decode(ItinerariesListResponse.self, from: data)
      itineraries = decoded.itineraries
      AppLogging.log("AnglerFlights — Itineraries GET — Decoded count: \(decoded.itineraries.count)", level: .info, category: .angler)
      saveCachedItineraries(itineraries)
    } catch {
      errorText = "Network error: \(error.localizedDescription)"
    }
  }

  private func uploadItinerary(payload: UploadPayload) async {
    guard !isLoading else { return }
    errorText = nil
    infoText = nil

    guard let token = await auth.currentAccessToken(), !token.isEmpty else {
      errorText = "You are not signed in."
      return
    }

    var req = URLRequest(url: itinerariesEndpoint)
    req.httpMethod = "POST"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    switch payload {
    case .document(let doc):
      let body = DocumentUploadRequest(document: doc)
      req.httpBody = try? JSONEncoder().encode(body)
    case .manual(let manual):
      let body = ManualUploadRequest(
        airline: manual.airline,
        confirmationNumber: manual.confirmationNumber,
        outboundSegments: manual.outboundSegments,
        returnSegments: manual.returnSegments
      )
      req.httpBody = try? JSONEncoder().encode(body)
    }
    AppLogging.log("AnglerFlights — Itinerary POST — URL: \(itinerariesEndpoint.absoluteString)", level: .debug, category: .angler)
    AppLogging.log("AnglerFlights — Itinerary POST — Method: \(req.httpMethod ?? "<nil>")", level: .debug, category: .angler)
    AppLogging.log("AnglerFlights — Itinerary POST — Headers: Authorization=Bearer <redacted>, Content-Type=application/json", level: .debug, category: .angler)
    if let body = req.httpBody, let prettyObj = try? JSONSerialization.jsonObject(with: body), let pretty = try? JSONSerialization.data(withJSONObject: prettyObj, options: [.prettyPrinted, .sortedKeys]), let prettyStr = String(data: pretty, encoding: .utf8) {
      AppLogging.log("AnglerFlights — Itinerary POST — Body =>\n\(prettyStr)", level: .debug, category: .angler)
    }

    isLoading = true
    defer { isLoading = false }

    do {
      let (data, resp) = try await URLSession.shared.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
      AppLogging.log("AnglerFlights — Itinerary POST — Status: \(code)", level: .debug, category: .angler)
      guard (200 ..< 300).contains(code) else {
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        errorText = "Save failed (\(code))"
        AppLogging.log("AnglerFlights — Itinerary POST failed (\(code)) body: \(bodyStr)", level: .error, category: .angler)
        return
      }
      let decoded = try JSONDecoder().decode(UploadItineraryResponse.self, from: data)
      AppLogging.log("AnglerFlights — Itinerary POST — Message: \(decoded.message)", level: .info, category: .angler)
      infoText = decoded.message
      // Update list (upsert behavior)
      upsertItinerary(decoded.itinerary)
      saveCachedItineraries(itineraries)
    } catch {
      errorText = "Network error: \(error.localizedDescription)"
    }
  }

  private func deleteItinerary(itineraryId: String) async {
    guard let token = await auth.currentAccessToken(), !token.isEmpty else {
      errorText = "You are not signed in."
      return
    }

    var comps = URLComponents(url: itinerariesEndpoint, resolvingAgainstBaseURL: false)!
    comps.queryItems = [URLQueryItem(name: "itineraryId", value: itineraryId)]
    var req = URLRequest(url: comps.url!)
    req.httpMethod = "DELETE"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    AppLogging.log("AnglerFlights — Itinerary DELETE — URL: \(comps.url!.absoluteString)", level: .debug, category: .angler)
    AppLogging.log("AnglerFlights — Itinerary DELETE — Method: \(req.httpMethod ?? "<nil>")", level: .debug, category: .angler)
    AppLogging.log("AnglerFlights — Itinerary DELETE — Headers: Authorization=Bearer <redacted>", level: .debug, category: .angler)

    isLoading = true
    defer { isLoading = false }

    do {
      let (data, resp) = try await URLSession.shared.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
      AppLogging.log("AnglerFlights — Itinerary DELETE — Status: \(code)", level: .debug, category: .angler)
      guard (200 ..< 300).contains(code) else {
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        errorText = "Delete failed (\(code))"
        AppLogging.log("AnglerFlights — Itinerary DELETE failed (\(code)) body: \(bodyStr)", level: .error, category: .angler)
        return
      }
      // Remove locally
      itineraries.removeAll { $0.id == itineraryId }
      AppLogging.log("AnglerFlights — Itinerary DELETE — removed id=\(itineraryId)", level: .info, category: .angler)
      saveCachedItineraries(itineraries)
      infoText = "Itinerary deleted successfully"
    } catch {
      errorText = "Network error: \(error.localizedDescription)"
    }
  }

  private func fetchStatus(for segments: [FlightSegment]) async throws -> [FlightStatusResult] {
    var req = URLRequest(url: statusEndpoint)
    AppLogging.log("AnglerFlights — Status POST — start", level: .debug, category: .angler)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    AppLogging.log("AnglerFlights — Status POST — URL: \(statusEndpoint.absoluteString)", level: .debug, category: .angler)
    AppLogging.log("AnglerFlights — Status POST — Method: \(req.httpMethod ?? "<nil>")", level: .debug, category: .angler)

    let items: [FlightStatusRequestItem] = segments.compactMap { seg in
      guard let date = seg.departureDateOnly else { return nil }
      return FlightStatusRequestItem(flightNumber: seg.flightNumber, date: date)
    }
    let body = FlightStatusRequest(segments: items)
    req.httpBody = try JSONEncoder().encode(body)
    if let body = req.httpBody, let obj = try? JSONSerialization.jsonObject(with: body), let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]), let prettyStr = String(data: pretty, encoding: .utf8) {
      AppLogging.log("AnglerFlights — Status POST — Body =>\n\(prettyStr)", level: .debug, category: .angler)
    }

    let (data, resp) = try await URLSession.shared.data(for: req)
    AppLogging.log("AnglerFlights — Status POST — received response bytes=\(data.count)", level: .debug, category: .angler)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
    AppLogging.log("AnglerFlights — Status POST — Status: \(code)", level: .debug, category: .angler)
    guard (200 ..< 300).contains(code) else {
      let bodyStr = String(data: data, encoding: .utf8) ?? ""
      AppLogging.log("AnglerFlights — Status POST failed (\(code)) body: \(bodyStr)", level: .error, category: .angler)
      throw NSError(domain: "FlightStatus", code: code, userInfo: [NSLocalizedDescriptionKey: "Status fetch failed (\(code))"])
    }

    if let prettyObj = try? JSONSerialization.jsonObject(with: data),
       let pretty = try? JSONSerialization.data(withJSONObject: prettyObj, options: [.prettyPrinted, .sortedKeys]),
       let prettyStr = String(data: pretty, encoding: .utf8) {
      AppLogging.log("AnglerFlights — Status POST — Response Body =>\n\(prettyStr)", level: .debug, category: .angler)
    } else if let rawStr = String(data: data, encoding: .utf8) {
      AppLogging.log("AnglerFlights — Status POST — Response Body (raw) =>\n\(rawStr)", level: .debug, category: .angler)
    }

    AppLogging.log("AnglerFlights — Status POST — decoding", level: .debug, category: .angler)
    let decoded = try JSONDecoder().decode(FlightStatusResponse.self, from: data)
    AppLogging.log("AnglerFlights — Status POST — Decoded results count: \(decoded.results.count)", level: .info, category: .angler)
    return decoded.results
  }

  // MARK: - Local Cache
  private func loadCachedItineraries() {
    AppLogging.log("AnglerFlights — Cache — load", level: .debug, category: .angler)
    if let data = UserDefaults.standard.data(forKey: localCacheKey) {
      if let list = try? JSONDecoder().decode([Itinerary].self, from: data) {
        itineraries = list
        AppLogging.log("AnglerFlights — Cache — loaded \(list.count) itineraries", level: .debug, category: .angler)
      }
    }
  }

  private func saveCachedItineraries(_ list: [Itinerary]) {
    AppLogging.log("AnglerFlights — Cache — save count=\(list.count)", level: .debug, category: .angler)
    if let data = try? JSONEncoder().encode(list) {
      UserDefaults.standard.set(data, forKey: localCacheKey)
    }
  }

  private func upsertItinerary(_ new: Itinerary) {
    AppLogging.log("AnglerFlights — Upsert — id=\(new.id)", level: .debug, category: .angler)
    if let idx = itineraries.firstIndex(where: { $0.id == new.id }) {
      itineraries[idx] = new
    } else {
      itineraries.insert(new, at: 0)
    }
  }
}

// MARK: - Row & Detail Views

private struct ItineraryRow: View {
  let itinerary: Itinerary
  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(itinerary.airline) • \(itinerary.confirmationNumber)")
          .foregroundColor(.brandTextPrimary)
          .font(.brandHeadline)
        if let firstOutbound = itinerary.outboundSegments.first, let lastOutbound = itinerary.outboundSegments.last {
          // Show outbound origin to outbound final destination
          Text("\(firstOutbound.fromAirport) → \(lastOutbound.toAirport)")
            .foregroundColor(.brandTextPrimary.opacity(0.8))
            .font(.brandSubheadline)
        } else if let first = itinerary.outboundSegments.first ?? itinerary.returnSegments.first, let last = itinerary.returnSegments.last ?? itinerary.outboundSegments.last {
          // Fallback to previous behavior if outbound is missing
          Text("\(first.fromAirport) → \(last.toAirport)")
            .foregroundColor(.brandTextPrimary.opacity(0.8))
            .font(.brandSubheadline)
        }
      }
      Spacer()
      Image(systemName: "chevron.right")
        .foregroundColor(.brandTextPrimary.opacity(0.6))
    }
    .padding(.vertical, 8)
  }
}

private struct ItineraryDetailView: View {
  let itinerary: Itinerary
  let statusLoader: ([FlightSegment]) async throws -> [FlightStatusResult]

  @Environment(\.dismiss) private var dismiss
  @State private var isLoading: Bool = false
  @State private var errorText: String?
  @State private var statusResults: [FlightStatusResult] = []

  var body: some View {
    NavigationView {
      ZStack {
        Color.brandBackground.ignoresSafeArea()
        VStack(alignment: .leading, spacing: 12) {
          Text("\(itinerary.airline) • \(itinerary.confirmationNumber)")
            .font(.brandTitle2.weight(.semibold))
            .foregroundColor(.brandTextPrimary)
            .padding(.top, 8)

          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              if !itinerary.outboundSegments.isEmpty {
                segmentSection(title: "Outbound", segments: itinerary.outboundSegments)
              }
              if !itinerary.returnSegments.isEmpty {
                segmentSection(title: "Return", segments: itinerary.returnSegments)
              }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
          }

          if let errorText { Text(errorText).foregroundColor(.brandError).font(.brandFootnote).padding(.horizontal, 16) }
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: { dismiss() }) { Image(systemName: "chevron.left").foregroundColor(.brandTextPrimary) }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: { Task { await loadStatus() } }) {
            HStack(spacing: 6) {
              Image(systemName: "wifi")
              Text(isLoading ? "Loading Status…" : "Get Status")
                .font(.brandFootnote.weight(.semibold))
            }
            .foregroundColor(.brandTextPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.brandAccent)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
          .disabled(isLoading)
        }
      }
    }
    .preferredColorScheme(.dark)
  }

  private func segmentSection(title: String, segments: [FlightSegment]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).foregroundColor(.brandTextPrimary).font(.brandHeadline)
      ForEach(segments) { seg in
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("\(seg.fromAirport) → \(seg.toAirport)")
              .foregroundColor(.brandTextPrimary)
              .font(.brandSubheadline.weight(.semibold))
            Spacer()
            StatusPill(status: pillStatus(for: seg))
          }
          Text("Flight \(seg.flightNumber)").foregroundColor(.brandTextPrimary.opacity(0.9)).font(.brandFootnote)
          Text("Departs: \(formattedDateTime(seg.departureDatetime))").foregroundColor(.brandTextPrimary.opacity(0.8)).font(.brandFootnote)
          Text("Arrives: \(formattedDateTime(seg.arrivalDatetime))").foregroundColor(.brandTextPrimary.opacity(0.8)).font(.brandFootnote)
        }
        .padding(12)
        .background(Color.brandStrokeSubtle)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brandStroke, lineWidth: 1))
      }
    }
  }

  private func pillStatus(for seg: FlightSegment) -> String? {
    func normalize(_ s: String) -> String {
      s.replacingOccurrences(of: " ", with: "")
       .replacingOccurrences(of: "-", with: "")
       .uppercased()
    }
    let target = normalize(seg.flightNumber)
    for result in statusResults {
      if let data = result.data?.first(where: { normalize($0.flightNumber) == target }) {
        return data.status
      }
    }
    return nil
  }

  private func formattedDateTime(_ isoString: String) -> String {
    guard let d = DateFormatting.parseISO(isoString) else { return isoString }
    return DateFormatting.mediumDateTime.string(from: d)
  }

  private func loadStatus() async {
    guard !isLoading else { return }
    AppLogging.log("ItineraryDetailView — Load Status — start", level: .debug, category: .angler)
    isLoading = true
    errorText = nil
    defer { isLoading = false }
    do {
      let segments = itinerary.outboundSegments + itinerary.returnSegments
      AppLogging.log("ItineraryDetailView — Load Status — segment count=\(segments.count)", level: .debug, category: .angler)
      statusResults = try await statusLoader(segments)
      AppLogging.log("ItineraryDetailView — Load Status — results count=\(statusResults.count)", level: .debug, category: .angler)
    } catch {
      AppLogging.log("ItineraryDetailView — Load Status — error: \(error.localizedDescription)", level: .error, category: .angler)
      errorText = error.localizedDescription
    }
    AppLogging.log("ItineraryDetailView — Load Status — end", level: .debug, category: .angler)
  }
}

private struct StatusPill: View {
  let status: String?
  @ViewBuilder
  var body: some View {
    let mapped = map(status: status) ?? (text: "Unknown", color: Color.brandTextSecondary)
    Text(mapped.text)
      .font(.brandCaption.weight(.semibold))
      .foregroundColor(.brandTextPrimary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(mapped.color)
      .clipShape(Capsule())
  }

  private func map(status: String?) -> (text: String, color: Color)? {
    guard let raw = status, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let s = raw.replacingOccurrences(of: " ", with: "").lowercased()
    // Exact mappings as specified
    if s == "scheduled" { return (raw, .brandSuccess) }
    if s == "departed" { return (raw, .brandSuccess) }
    if s == "enroute" { return (raw, .brandSuccess) }
    if s == "arrived" { return (raw, .brandSuccess) }
    if s == "expected" { return (raw, .brandSuccess) }
    if s == "delayed" { return (raw, .brandWarning) }
    if s == "cancelled" { return (raw, .red) }
    if s == "diverted" { return (raw, .red) }
    // Any other status — do not show a pill
    return nil
  }
}

// MARK: - Add Sheet

private struct AddItinerarySheet: View {
  enum Mode { case document, manual }
  
  enum TripType { case oneWay, roundTrip }
  @State private var tripType: TripType = .oneWay

  var onSubmit: (UploadPayload) async -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var mode: Mode = .document

  // Document upload
  @State private var filename: String = ""
  @State private var mimeType: String = "application/pdf"
  @State private var base64Data: String = ""

  // Manual entry
  @State private var airline: String = ""
  @State private var confirmation: String = ""
  @State private var outboundSegments: [FlightSegment] = []
  @State private var returnSegments: [FlightSegment] = []

  // Pickers
  @State private var showingDocPicker: Bool = false
  @State private var isSubmitting: Bool = false

  var body: some View {
    NavigationView {
      ZStack {
        Color.brandBackground.ignoresSafeArea()
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Picker("Mode", selection: $mode) {
              Text("Upload itinerary").tag(Mode.document)
              Text("Manual entry").tag(Mode.manual)
            }
            .pickerStyle(.segmented)

            if mode == .document {
              Group {
                labeledField("Itinerary", text: $filename, placeholder: "itinerary.pdf")
              }

              HStack(spacing: 12) {
                if #available(iOS 16.0, *) {
                  PhotosPickerButton(onPicked: { data, suggestedName, mime in
                    self.filename = suggestedName
                    self.mimeType = mime
                    self.base64Data = data.base64EncodedString()
                  })
                  .frame(maxWidth: 180)
                }
                Button(action: { showingDocPicker = true }) {
                  HStack(spacing: 6) {
                    Image(systemName: "doc")
                    Text("Pick Document").font(.brandFootnote.weight(.semibold))
                  }
                  .foregroundColor(.brandTextPrimary)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .background(Color.brandBackground)
                  .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .frame(maxWidth: 180)
              }
              .frame(maxWidth: .infinity)
              .multilineTextAlignment(.center)
            } else {
              labeledField("Airline", text: $airline, placeholder: "Air Canada")
              labeledField("Airline confirmation #", text: $confirmation, placeholder: "ABC123")

              // Trip type selector
              Picker("Trip Type", selection: $tripType) {
                Text("One way").tag(TripType.oneWay)
                Text("Round trip").tag(TripType.roundTrip)
              }
              .pickerStyle(.segmented)

              SegmentEditor(title: "Outbound Segments", segments: $outboundSegments)

              if tripType == .roundTrip {
                SegmentEditor(title: "Return Segments", segments: $returnSegments)
              }
            }
          }
          .padding(16)
          .disabled(isSubmitting)
        }
      }
      .navigationTitle("Add Itinerary")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close") { dismiss() }
            .disabled(isSubmitting)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: submit) {
            HStack(spacing: 6) {
              if isSubmitting {
                ProgressView()
                  .progressViewStyle(.circular)
                  .tint(.white)
              }
              Text(isSubmitting ? "Submitting…" : "Submit")
                .font(.brandFootnote.weight(.semibold))
            }
            .foregroundColor(.brandTextPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background((isValid && !isSubmitting) ? Color.brandAccent : Color.brandTextSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
          .disabled(!isValid || isSubmitting)
        }
      }
    }
    .preferredColorScheme(.dark)
    .sheet(isPresented: $showingDocPicker) {
      DocumentPicker { url in
        guard let url else { return }
        if let data = try? Data(contentsOf: url) {
          self.filename = url.lastPathComponent
          self.mimeType = mimeType(for: url) ?? "application/octet-stream"
          self.base64Data = data.base64EncodedString()
        }
      }
      .preferredColorScheme(.dark)
    }
  }

  private var isValid: Bool {
    switch mode {
    case .document:
      return !filename.isEmpty && !mimeType.isEmpty && !base64Data.isEmpty
    case .manual:
      func segmentIsComplete(_ s: FlightSegment) -> Bool {
        return !s.flightNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               !s.fromAirport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               !s.toAirport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               !s.departureDatetime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               !s.arrivalDatetime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      let outboundNonEmpty = !outboundSegments.isEmpty
      let outboundAllComplete = outboundSegments.allSatisfy(segmentIsComplete)
      let outboundOK = outboundNonEmpty && outboundAllComplete

      if tripType == .oneWay {
        return !airline.isEmpty && !confirmation.isEmpty && outboundOK
      } else {
        let returnNonEmpty = !returnSegments.isEmpty
        let returnAllComplete = returnSegments.allSatisfy(segmentIsComplete)
        let returnOK = returnNonEmpty && returnAllComplete
        return !airline.isEmpty && !confirmation.isEmpty && outboundOK && returnOK
      }
    }
  }

  private func submit() {
    guard !isSubmitting else { return }
    isSubmitting = true
    Task {
      switch mode {
      case .document:
        let doc = DocumentPayload(filename: filename, mimeType: mimeType, data_base64: base64Data)
        await onSubmit(.document(doc))
      case .manual:
        let manual = ManualPayload(airline: airline, confirmationNumber: confirmation, outboundSegments: outboundSegments, returnSegments: returnSegments)
        await onSubmit(.manual(manual))
      }
      isSubmitting = false
      dismiss()
    }
  }

  private func labeledField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).foregroundColor(.brandTextPrimary).font(.brandFootnote.weight(.semibold))
      TextField(placeholder, text: text)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .keyboardType(.asciiCapable)
        .foregroundColor(.brandTextPrimary)
        .padding(10)
        .background(Color.brandSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
  }

  private func mimeType(for url: URL) -> String? {
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "pdf": return "application/pdf"
    case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    case "txt": return "text/plain"
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    default: return nil
    }
  }
}

private struct SegmentEditor: View {
  let title: String
  @Binding var segments: [FlightSegment]

  @State private var flightNumber: String = ""
  @State private var fromAirport: String = ""
  @State private var toAirport: String = ""
  @State private var departureDate: Date = Date()
  @State private var departureTime: Date = Date()
  @State private var arrivalDate: Date = Date()
  @State private var arrivalTime: Date = Date()
  @State private var didApply: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(title).foregroundColor(.brandTextPrimary).font(.brandHeadline)
        Spacer()
      }

      ForEach(segments) { seg in
        VStack(alignment: .leading, spacing: 4) {
          Text("\(seg.fromAirport) → \(seg.toAirport) • \(seg.flightNumber)")
            .foregroundColor(.brandTextPrimary)
            .font(.brandSubheadline)
          Text("Departs: \(seg.departureDatetime)").foregroundColor(.brandTextPrimary.opacity(0.8)).font(.brandCaption)
          Text("Arrives: \(seg.arrivalDatetime)").foregroundColor(.brandTextPrimary.opacity(0.8)).font(.brandCaption)
        }
        .padding(8)
        .background(Color.brandStrokeSubtle)
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }

      VStack(alignment: .leading, spacing: 6) {
        if !didApply {
          field("Flight Number", text: $flightNumber, placeholder: "AC123")
          field("From (IATA)", text: $fromAirport, placeholder: "JFK")
          field("To (IATA)", text: $toAirport, placeholder: "YYC")

          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
              Text("Departure Date").foregroundColor(.brandTextPrimary).font(.brandFootnote.weight(.semibold))
              DatePicker("", selection: $departureDate, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(.brandAccent)
            }
            VStack(alignment: .leading, spacing: 6) {
              Text("Departure Time").foregroundColor(.brandTextPrimary).font(.brandFootnote.weight(.semibold))
              DatePicker("", selection: $departureTime, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(.brandAccent)
            }
          }
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
              Text("Arrival Date").foregroundColor(.brandTextPrimary).font(.brandFootnote.weight(.semibold))
              DatePicker("", selection: $arrivalDate, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(.brandAccent)
            }
            VStack(alignment: .leading, spacing: 6) {
              Text("Arrival Time").foregroundColor(.brandTextPrimary).font(.brandFootnote.weight(.semibold))
              DatePicker("", selection: $arrivalTime, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(.brandAccent)
            }
          }

          Button(action: applySegment) {
            HStack(spacing: 6) { Text("Apply").font(.brandFootnote.weight(.semibold)) }
              .foregroundColor(.brandTextPrimary)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(Color.brandAccent)
              .clipShape(RoundedRectangle(cornerRadius: 10))
          }
          .disabled(!canAdd)
        } else {
          Button(action: { didApply = false }) {
            HStack(spacing: 6) { Image(systemName: "plus"); Text("Add another segment").font(.brandFootnote.weight(.semibold)) }
              .foregroundColor(.brandTextPrimary)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(Color.brandSurface)
              .clipShape(RoundedRectangle(cornerRadius: 10))
          }
        }
      }
    }
  }

  private var canAdd: Bool {
    !flightNumber.isEmpty && !fromAirport.isEmpty && !toAirport.isEmpty
  }

  private func applySegment() {
    addSegment()
    didApply = true
  }

  private func addSegment() {
    guard canAdd else { return }
    func combine(_ date: Date, _ time: Date) -> Date {
      let cal = Calendar.current
      let dateComps = cal.dateComponents([.year, .month, .day], from: date)
      let timeComps = cal.dateComponents([.hour, .minute, .second], from: time)
      var comps = DateComponents()
      comps.year = dateComps.year
      comps.month = dateComps.month
      comps.day = dateComps.day
      comps.hour = timeComps.hour
      comps.minute = timeComps.minute
      comps.second = timeComps.second ?? 0
      return cal.date(from: comps) ?? date
    }
    let dep = combine(departureDate, departureTime)
    let arr = combine(arrivalDate, arrivalTime)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    let depISO = iso.string(from: dep)
    let arrISO = iso.string(from: arr)
    let seg = FlightSegment(flightNumber: flightNumber, fromAirport: fromAirport, toAirport: toAirport, departureDatetime: depISO, arrivalDatetime: arrISO)
    segments.append(seg)
    flightNumber = ""
    fromAirport = ""
    toAirport = ""
    departureDate = Date()
    departureTime = Date()
    arrivalDate = Date()
    arrivalTime = Date()
  }

  private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).foregroundColor(.brandTextPrimary).font(.brandFootnote.weight(.semibold))
      TextField(placeholder, text: text)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled(true)
        .keyboardType(.asciiCapable)
        .foregroundColor(.brandTextPrimary)
        .padding(10)
        .background(Color.brandSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
  }
}

@available(iOS 16.0, *)
private struct PhotosPickerButton: View {
  @State private var photoItem: PhotosPickerItem?
  var onPicked: (Data, String, String) -> Void
  var body: some View {
    PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
      HStack(spacing: 6) {
        Image(systemName: "photo.on.rectangle")
        Text("Pick Photo").font(.brandFootnote.weight(.semibold))
      }
      .foregroundColor(.brandTextPrimary)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color.brandBackground)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .onChange(of: photoItem) { newItem in
      guard let item = newItem else { return }
      Task {
        // First try to get a file URL to preserve the original filename when possible
        if let url = try? await item.loadTransferable(type: URL.self),
           let data = try? Data(contentsOf: url) {
          let name = url.lastPathComponent
          // Infer MIME from extension
          let ext = url.pathExtension.lowercased()
          let mime: String
          switch ext {
          case "jpg", "jpeg": mime = "image/jpeg"
          case "png": mime = "image/png"
          case "heic": mime = "image/heic"
          default: mime = "image/jpeg"
          }
          onPicked(data, name, mime)
          return
        }
        // Fallback to Data-only load with a better suggested filename
        if let data = try? await item.loadTransferable(type: Data.self) {
          // Try to infer extension from supported content types
          let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
          let base = "photo"
          let name = base + "." + ext
          let mime: String
          switch ext.lowercased() {
          case "jpg", "jpeg": mime = "image/jpeg"
          case "png": mime = "image/png"
          case "heic": mime = "image/heic"
          default: mime = "image/jpeg"
          }
          onPicked(data, name, mime)
        }
      }
    }
  }
}

private struct DocumentPickersRow: View {
  var onPhotoPicked: (Data, String, String) -> Void
  var onDocTap: () -> Void
  var body: some View {
    HStack(spacing: 12) {
      if #available(iOS 16.0, *) {
        PhotosPickerButton(onPicked: onPhotoPicked)
      }
      Button(action: onDocTap) {
        HStack(spacing: 6) {
          Image(systemName: "doc")
          Text("Pick Document").font(.brandFootnote.weight(.semibold))
        }
        .foregroundColor(.brandTextPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.brandAccent)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
    }
  }
}

private struct DocumentPicker: UIViewControllerRepresentable {
  typealias UIViewControllerType = UIDocumentPickerViewController

  var onPick: (URL?) -> Void

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let types: [UTType] = [
      UTType.pdf,
      UTType(filenameExtension: "docx")!,
      UTType.plainText,
      UTType.jpeg,
      UTType.png
    ]
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    let onPick: (URL?) -> Void
    init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      onPick(urls.first)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      onPick(nil)
    }
  }
}

private extension View {
  @ViewBuilder
  func hideScrollBackgroundIfAvailable() -> some View {
    if #available(iOS 16.0, *) {
      self.scrollContentBackground(.hidden)
    } else {
      self
    }
  }
}

// MARK: - Models

private struct ItinerariesListResponse: Codable { let success: Bool; let itineraries: [Itinerary] }

private struct UploadItineraryResponse: Codable { let success: Bool; let message: String; let itinerary: Itinerary }

private struct Itinerary: Codable, Identifiable, Equatable { 
  let id: String
  let userId: String
  let airline: String
  let confirmationNumber: String
  let source: String?
  let outboundSegments: [FlightSegment]
  let returnSegments: [FlightSegment]
  let createdAt: String?
  let updatedAt: String?
}

private struct FlightSegment: Codable, Identifiable, Equatable {
  var id: String { "\(flightNumber)-\(fromAirport)-\(toAirport)-\(departureDatetime)" }
  let flightNumber: String
  let fromAirport: String
  let toAirport: String
  let departureDatetime: String
  let arrivalDatetime: String

  var departureDateOnly: String? {
    // Extract YYYY-MM-DD from ISO 8601
    if let idx = departureDatetime.firstIndex(of: "T") {
      return String(departureDatetime[..<idx])
    }
    return nil
  }
}

// Upload payloads
private enum UploadPayload {
  case document(DocumentPayload)
  case manual(ManualPayload)
}

private struct DocumentPayload: Codable { let filename: String; let mimeType: String; let data_base64: String }
private struct ManualPayload: Codable { let airline: String; let confirmationNumber: String; let outboundSegments: [FlightSegment]; let returnSegments: [FlightSegment] }

private struct DocumentUploadRequest: Codable { let document: DocumentPayload }
private struct ManualUploadRequest: Codable {
  let airline: String
  let confirmationNumber: String
  let outboundSegments: [FlightSegment]
  let returnSegments: [FlightSegment]
}

// Flight status models
private struct FlightStatusRequestItem: Codable { let flightNumber: String; let date: String }
private struct FlightStatusRequest: Codable { let segments: [FlightStatusRequestItem] }

private struct FlightStatusResponse: Codable { let success: Bool; let allSucceeded: Bool?; let results: [FlightStatusResult] }

private struct FlightStatusResult: Codable, Identifiable { 
  var id: String { request.flightNumber + "-" + request.date }
  let request: FlightStatusRequestItem
  let success: Bool
  let data: [FlightStatusData]? 
}

private struct FlightStatusData: Codable { 
  let flightNumber: String
  let status: String?
  let airline: AirlineInfo?
  let departure: FlightPoint?
  let arrival: FlightPoint?
  let aircraft: AircraftInfo?
}

private struct AirlineInfo: Codable { let name: String?; let iataCode: String? }
private struct FlightPoint: Codable { let airport: AirportInfo?; let scheduledTime: String?; let actualTime: String?; let terminal: String?; let gate: String?; let baggage: String? }
private struct AirportInfo: Codable { let code: String?; let name: String? }
private struct AircraftInfo: Codable { let registration: String?; let model: String?; }
