//
// TripFormView.swift
// Bend Fly Shop
//

import Combine
import CoreData
import SwiftUI
import UIKit

// MARK: - Draft model for in-form editing

struct TripClientDraft: Identifiable, Hashable {
  let id = UUID()
  var name: String = ""
  var licenseNumber: String = ""
  var licences: [ClassifiedLicenceDraft] = []
  // Optional profile details (if available via lookup)
  var dateOfBirth: Date?
  var residency: String? // e.g., "US", "CA", "other"
  var sex: String? // "male", "female", "other"
  var mailingAddress: String?
  var telephoneNumber: String?
  // License jurisdiction
  var licenseCountry: String = ""
  var licenseStateProvince: String = ""
  var licenseExpirationDate: Date?
  // Lookup UI state (per-row)
  var isLookingUp: Bool = false
  var lookupError: String?
}

struct ClassifiedLicenceDraft: Identifiable, Hashable {
  let id = UUID()
  var licNumber: String = ""
  var water: String = ""
  var validFrom: Date?
  var validTo: Date?
  var guideName: String = ""
  var vendor: String = ""
}

// MARK: - Angler Lookup API (inline helper, no UI)

struct AnglerProfileResponse: Decodable {
  let anglers: [AnglerProfile]
  let count: Int
}

struct AnglerProfile: Decodable, Identifiable {
  var id: String { memberId }
  let anglerName: String
  let memberId: String
  let classifiedWatersLicenses: [CWLicense]

  struct CWLicense: Decodable, Identifiable {
    var id: String { license_number }
    let license_number: String
    let river_name: String
    let start_date: String // "YYYY-MM-DD"
    let end_date: String // "YYYY-MM-DD"
  }
}

enum AnglerLookupError: LocalizedError {
  case badRequest(String)
  case unauthorized
  case httpStatus(Int)
  case server(String, String?)
  case unknown

  var errorDescription: String? {
    switch self {
    case let .badRequest(m): return m
    case .unauthorized: return "Sign in required to look up."
    case let .httpStatus(c): return "Unexpected HTTP \(c)."
    case let .server(m, d):
      return [m, d].compactMap { $0 }.joined(separator: " • ")
    case .unknown: return "Lookup failed."
    }
  }
}

enum AnglerAPI {
  static let endpoint = AppEnvironment.shared.anglerProfileURL
  static let anonKey = AppEnvironment.shared.anonKey

  static func search(memberId: String?, anglerName: String?, jwt: String) async throws -> [AnglerProfile] {
    guard (memberId?.trimmingCharacters(in: .whitespaces).isEmpty == false) ||
      (anglerName?.trimmingCharacters(in: .whitespaces).isEmpty == false)
    else {
      throw AnglerLookupError.badRequest("Enter a name or number to look up.")
    }

    // Re-resolve endpoint at call time (not static init) in case AppEnvironment wasn't ready
    let resolvedEndpoint = AppEnvironment.shared.anglerProfileURL
    AppLogging.log("[AnglerLookup] endpoint: \(resolvedEndpoint.absoluteString)", level: .debug, category: .trip)

    guard var comps = URLComponents(url: resolvedEndpoint, resolvingAgainstBaseURL: false) else {
      AppLogging.log("[AnglerLookup] URLComponents failed for: \(resolvedEndpoint)", level: .error, category: .trip)
      throw AnglerLookupError.badRequest("Invalid lookup URL configuration.")
    }
    var items: [URLQueryItem] = []
    if let n = memberId?.trimmingCharacters(in: .whitespaces), !n.isEmpty {
      items.append(URLQueryItem(name: "memberId", value: n))
    }
    if let nm = anglerName?.trimmingCharacters(in: .whitespaces), !nm.isEmpty {
      items.append(URLQueryItem(name: "anglerName", value: nm))
    }
    comps.queryItems = items

    guard let finalURL = comps.url else {
      AppLogging.log("[AnglerLookup] Failed to build final URL from components", level: .error, category: .trip)
      throw AnglerLookupError.badRequest("Failed to build lookup URL.")
    }
    AppLogging.log("[AnglerLookup] GET \(finalURL.absoluteString)", level: .debug, category: .trip)

    var req = URLRequest(url: finalURL)
    req.httpMethod = "GET"
    req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
    req.setValue(anonKey, forHTTPHeaderField: "apikey")

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw AnglerLookupError.unknown }
    AppLogging.log({ "[AnglerLookup] HTTP \(http.statusCode), body: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "<nil>")" }, level: .debug, category: .trip)

    switch http.statusCode {
    case 200:
      let decoded = try JSONDecoder().decode(AnglerProfileResponse.self, from: data)
      return decoded.anglers
    case 400: throw AnglerLookupError.badRequest("Neither memberId nor anglerName was provided.")
    case 401: throw AnglerLookupError.unauthorized
    case 404: return []
    default:
      struct ServerErr: Decodable { let error: String; let details: String? }
      if let server = try? JSONDecoder().decode(ServerErr.self, from: data) {
        throw AnglerLookupError.server(server.error, server.details)
      }
      throw AnglerLookupError.httpStatus(http.statusCode)
    }
  }
}

// MARK: - ViewModel

private let maxAnglers = 8
private var defaultGuideNameConst: String {
  AuthService.shared.currentFirstName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    ? AuthService.shared.currentFirstName!
    : "Admin"
}

final class TripFormViewModel: ObservableObject {
  @Published var guideName: String = defaultGuideNameConst
  @Published var tripName: String = ""
  @Published var clientCount: Int = 1 { didSet { resizeClients(to: clientCount) } }
  @Published var clients: [TripClientDraft] = [TripClientDraft()]
  @Published var startDate: Date = .init()
  @Published var endDate: Date = .init()
  @Published var showToast: Bool = false
  @Published var toastMessage: String = ""
  @Published var isSaving: Bool = false

  // Picker for multiple lookup candidates
  @Published var candidateProfiles: [AnglerProfile] = []
  @Published var showCandidatePicker: Bool = false
  private var candidateRowIndex: Int?

  // Lodge selection (by stable UUID from Core Data)
  @Published var selectedLodgeId: UUID?

  init(defaultGuideName: String? = nil) {
    self.guideName = (defaultGuideName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
      ? (defaultGuideName ?? defaultGuideNameConst)
      : defaultGuideNameConst
    resizeClients(to: clientCount)
  }

  // ✅ CENTRAL FIX: always update array-of-structs via copy+reassign
  func updateClient(at index: Int, _ mutate: (inout TripClientDraft) -> Void) {
    guard clients.indices.contains(index) else { return }
    var copy = clients
    mutate(&copy[index])
    clients = copy
  }

  func setLicences(_ rows: [ClassifiedLicenceDraft], for index: Int) {
    guard clients.indices.contains(index) else { return }
    let capped = Array(rows.prefix(20))
    updateClient(at: index) { $0.licences = capped }
  }

  // ✅ Bindings for manual entry: route through updateClient so values persist reliably
  func nameBinding(for index: Int) -> Binding<String> {
    Binding(
      get: { [weak self] in self?.clients.indices.contains(index) == true ? (self?.clients[index].name ?? "") : "" },
      set: { [weak self] newValue in
        self?.updateClient(at: index) { $0.name = newValue }
      }
    )
  }

  func licenseNumberBinding(for index: Int) -> Binding<String> {
    Binding(
      get: { [weak self] in self?.clients.indices.contains(index) == true ? (self?.clients[index].licenseNumber ?? "") : "" },
      set: { [weak self] newValue in
        self?.updateClient(at: index) { $0.licenseNumber = MemberNumber.normalize(newValue) }
      }
    )
  }

  private func resizeClients(to count: Int) {
    let capped = min(max(1, count), maxAnglers)
    var copy = clients
    if copy.count < capped {
      for _ in copy.count ..< capped { copy.append(TripClientDraft()) }
    } else if copy.count > capped {
      copy.removeLast(copy.count - capped)
    }
    clients = copy
  }

  var isValid: Bool {
    guard !tripName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !guideName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          startDate <= endDate else { return false }
    guard selectedLodgeId != nil else { return false }
    for i in 0 ..< clientCount {
      if clients[i].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
      if clients[i].licenseNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
    }
    return true
  }

  // MARK: - Lookup

  func lookupAngler(for index: Int) {
    guard clients.indices.contains(index) else { return }
    Task { @MainActor in
      updateClient(at: index) {
        $0.lookupError = nil
        $0.isLookingUp = true
      }
      defer { updateClient(at: index) { $0.isLookingUp = false } }

      // 1) Get JWT from Supabase
      await AuthStore.shared.refreshFromSupabase()
      guard let jwt = AuthStore.shared.jwt else {
        withAnimation { updateClient(at: index) { $0.lookupError = "Sign in required to look up." } }
        return
      }

      // 2) Call API
      do {
        let current = clients[index]
        let results = try await AnglerAPI.search(
          memberId: current.licenseNumber,
          anglerName: current.name,
          jwt: jwt
        )
        guard !results.isEmpty else {
          withAnimation { updateClient(at: index) { $0.lookupError = "No angler found." } }
          return
        }
        if results.count == 1 {
          apply(results[0], to: index)
        } else {
          candidateProfiles = results
          candidateRowIndex = index
          showCandidatePicker = true
        }
      } catch let e as AnglerLookupError {
        withAnimation { updateClient(at: index) { $0.lookupError = e.localizedDescription } }
      } catch {
        withAnimation { updateClient(at: index) { $0.lookupError = "Lookup failed." } }
      }
    }
  }

  func pickCandidate(_ profile: AnglerProfile) {
    guard let idx = candidateRowIndex else { return }
    apply(profile, to: idx)
    showCandidatePicker = false
    candidateProfiles = []
    candidateRowIndex = nil
  }

  private func apply(_ profile: AnglerProfile, to index: Int) {
    guard clients.indices.contains(index) else { return }
    updateClient(at: index) { draft in
      draft.name = profile.anglerName
      draft.licenseNumber = profile.memberId
      draft.licences = profile.classifiedWatersLicenses.map { lic in
        ClassifiedLicenceDraft(
          licNumber: lic.license_number,
          water: lic.river_name,
          validFrom: parseYMD(lic.start_date),
          validTo: parseYMD(lic.end_date),
          guideName: "",
          vendor: ""
        )
      }
    }
  }
}

// MARK: - TripFormView

struct TripFormView: View {
  @Environment(\.managedObjectContext) private var context
  @Environment(\.dismiss) private var dismiss

  @StateObject private var vm = TripFormViewModel()
  init() {
    _vm = StateObject(wrappedValue: TripFormViewModel())
  }

  // Lodges fetched from Core Data (sorted by name)
  @FetchRequest(
    sortDescriptors: [NSSortDescriptor(keyPath: \Lodge.name, ascending: true)],
    animation: .default
  ) private var lodges: FetchedResults<Lodge>

  @State private var showStartPicker = false
  @State private var showEndPicker = false

  @State private var showUploadAlert = false
  @State private var uploadSucceeded = false
  @State private var uploadErrorMessage: String?
  @State private var pendingUpsertRequest: TripAPI.UpsertTripRequest?

  // MARK: - Body

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.brandBackground.ignoresSafeArea()

      List {
        Section { communitySection }
          .listRowBackground(Color.brandBackground)

        Section { tripDatesSection }
          .listRowBackground(Color.brandBackground)

        Section { anglersSection }
          .listRowBackground(Color.brandBackground)
      }
      .listStyle(.insetGrouped)
      .modifier(HideListBackgroundIfAvailable())

      if vm.showToast {
        Toast(message: vm.toastMessage)
          .padding(.bottom, 24)
      }
    }
    .navigationTitle("Create new trip")
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button { dismiss() } label: {
          Image(systemName: "chevron.backward")
        }
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: save) {
          if vm.isSaving { ProgressView() } else { Text("Save") }
        }
        .buttonStyle(.borderedProminent)
        .tint(vm.isValid && !vm.isSaving ? .brandAccent : Color.brandTextSecondary.opacity(0.5))
        .disabled(!vm.isValid || vm.isSaving)
        .accessibilityIdentifier("createTripToolbarButton")
      }
    }
    .onChange(of: vm.startDate) { newValue in
      if vm.endDate < newValue { vm.endDate = newValue }
    }
    .onAppear {
      PersistenceController.shared.seedCommunityIfNeeded(context: context)
      if vm.selectedLodgeId == nil { vm.selectedLodgeId = defaultLodgeId() }
    }
    .alert(uploadSucceeded ? "Trip uploaded" : "Upload failed", isPresented: $showUploadAlert) {
      if uploadSucceeded {
        Button("OK") { dismiss() }
      } else {
        Button("Retry") {
          if let req = pendingUpsertRequest { performUpload(req) }
        }
        Button("Try Again Later") { dismiss() }
        Button("Cancel", role: .cancel) {}
      }
    } message: {
      if let msg = uploadErrorMessage, !uploadSucceeded {
        Text(msg)
      } else {
        Text("Your trip has been uploaded successfully.")
      }
    }
    .sheet(isPresented: $showStartPicker) {
      DatePickerSheet(
        title: "Select Start Date",
        date: $vm.startDate,
        range: Date.distantPast ... Date.distantFuture
      )
    }
    .sheet(isPresented: $showEndPicker) {
      DatePickerSheet(
        title: "Select End Date",
        date: $vm.endDate,
        range: vm.startDate ... Date.distantFuture
      )
    }
    .environment(\.colorScheme, .dark)
  }

  // MARK: - Form content split into smaller pieces

  private var communitySection: some View {
    Section {
      HStack {
        Text("Community").foregroundColor(.brandAccent)
        Spacer()
        Text(CommunityService.shared.activeCommunityName)
          .foregroundColor(.secondary)
          .accessibilityIdentifier("communityLabel")
      }

      // Lodge picker hidden – auto-selected via defaultLodgeId()

      HStack {
        Text("Trip Name").foregroundColor(.brandAccent)
        Spacer()
        TextField("Trip Name", text: $vm.tripName)
          .multilineTextAlignment(.trailing)
          .textInputAutocapitalization(.words)
          .disableAutocorrection(true)
          .foregroundColor(.brandTextPrimary)
          .onChange(of: vm.tripName) { newValue in
            if newValue.count > 25 { vm.tripName = String(newValue.prefix(25)) }
          }
          .accessibilityIdentifier("tripNameTextField")
      }
      if vm.tripName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text("Required")
          .font(.brandCaption)
          .foregroundColor(.brandError)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }

      HStack(alignment: .firstTextBaseline) {
        Text("Guide Name").foregroundColor(.brandAccent)
        Spacer()
        TextField("Guide Name", text: $vm.guideName)
          .multilineTextAlignment(.trailing)
          .textInputAutocapitalization(.words)
          .disableAutocorrection(true)
          .foregroundColor(.brandTextPrimary)
          .accessibilityIdentifier("guideNameTextField")
      }
      if vm.guideName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text("Required")
          .font(.brandCaption)
          .foregroundColor(.brandError)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  private var tripDatesSection: some View {
    Section {
      Button { showStartPicker = true } label: {
        HStack {
          Text("Trip Start Date").foregroundColor(.brandAccent)
          Image(systemName: "calendar")
          Spacer()
          Text(vm.startDate.formatted(date: .abbreviated, time: .omitted))
            .foregroundColor(.brandTextPrimary)
        }
      }
      .accessibilityIdentifier("startDateRow")

      Button { showEndPicker = true } label: {
        HStack {
          Text("Trip End Date").foregroundColor(.brandAccent)
          Image(systemName: "calendar.badge.plus")
          Spacer()
          Text(vm.endDate.formatted(date: .abbreviated, time: .omitted))
            .foregroundColor(.brandTextPrimary)
        }
      }
      .accessibilityIdentifier("endDateRow")

      if vm.endDate < vm.startDate {
        Text("End date must be ≥ start date")
          .font(.brandCaption)
          .foregroundColor(.brandError)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  private var anglersSection: some View {
    Section {
      Picker(selection: $vm.clientCount) {
        ForEach(1 ... maxAnglers, id: \.self) { n in
          Text("\(n)").foregroundColor(.brandTextPrimary).tag(n)
        }
      } label: {
        Text("Number of Anglers").foregroundColor(.brandAccent)
      }
      .pickerStyle(.menu)
      .tint(.white)
      .accessibilityIdentifier("anglerCountPicker")

      ForEach(0 ..< vm.clientCount, id: \.self) { i in
        anglerBlock(for: i)
      }
    }
  }

  @ViewBuilder
  private func anglerBlock(for index: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      anglerHeaderRow(for: index)
      anglerFields(for: index)
    }
    .padding(.vertical, 4)
  }

  private func anglerHeaderRow(for index: Int) -> some View {
    HStack {
      Text("Angler \(index + 1)")
        .font(.brandSubheadline)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)
      Spacer()
    }
  }

  // ✅ Manual entry uses vm.<field>Binding(for:) so edits always update vm.clients via copy+reassign
  private func anglerFields(for index: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Angler Name", text: vm.nameBinding(for: index))
        .textInputAutocapitalization(.words)
        .disableAutocorrection(true)
        .accessibilityIdentifier("anglerNameField_\(index + 1)")
      if vm.clients[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text("Required").font(.brandCaption).foregroundColor(.brandError)
      }

      TextField("Member Number", text: vm.licenseNumberBinding(for: index))
        .textInputAutocapitalization(.characters)
        .disableAutocorrection(true)
        .keyboardType(.asciiCapable)
        .accessibilityIdentifier("memberIdField_\(index + 1)")
      if vm.clients[index].licenseNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text("Required").font(.brandCaption).foregroundColor(.brandError)
      }

      // Lookup button
      Button {
        vm.lookupAngler(for: index)
      } label: {
        HStack(spacing: 6) {
          if vm.clients[index].isLookingUp {
            ProgressView()
              .scaleEffect(0.7)
              .tint(.brandAccent)
          } else {
            Image(systemName: "magnifyingglass")
          }
          Text("Look Up Angler")
            .font(.brandSubheadline.weight(.medium))
        }
        .foregroundColor(.brandAccent)
      }
      .buttonStyle(.plain)
      .disabled(vm.clients[index].isLookingUp ||
        (vm.clients[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
         vm.clients[index].licenseNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

      if let error = vm.clients[index].lookupError {
        Text(error)
          .font(.brandCaption)
          .foregroundColor(.brandWarning)
      }

      // Show licences if populated via lookup (gated by entitlement)
      if CommunityService.shared.activeCommunityConfig.flag("E_MANAGE_LICENSES"),
         !vm.clients[index].licences.isEmpty {
        licencesList(for: index)
      }
    }
    .sheet(isPresented: $vm.showCandidatePicker) {
      candidatePickerSheet
    }
  }

  // MARK: - Candidate Picker (multiple lookup results)

  private var candidatePickerSheet: some View {
    NavigationStack {
      ZStack {
        Color.brandBackground.ignoresSafeArea()
        List(vm.candidateProfiles) { profile in
          Button {
            vm.pickCandidate(profile)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(profile.anglerName)
                .font(.brandHeadline)
                .foregroundColor(.brandTextPrimary)
              Text("# \(profile.memberId)")
                .font(.brandCaption)
                .foregroundColor(.brandTextSecondary)
              if CommunityService.shared.activeCommunityConfig.flag("E_MANAGE_LICENSES"),
                 !profile.classifiedWatersLicenses.isEmpty {
                Text("\(profile.classifiedWatersLicenses.count) licence(s)")
                  .font(.brandCaption2)
                  .foregroundColor(.brandAccent)
              }
            }
            .padding(.vertical, 4)
          }
          .listRowBackground(Color.brandBackground)
        }
        .listStyle(.plain)
      }
      .navigationTitle("Select Angler")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Cancel") { vm.showCandidatePicker = false }
            .foregroundColor(.brandTextPrimary)
        }
      }
    }
    .preferredColorScheme(.dark)
  }

  @ViewBuilder
  private func licencesList(for index: Int) -> some View {
    if vm.clients[index].licences.isEmpty {
      Text("No licences scanned yet.")
        .font(.brandCaption)
        .foregroundColor(.secondary)
    } else {
      ForEach(vm.clients[index].licences) { lic in
        VStack(alignment: .leading, spacing: 4) {
          Text("\(lic.water) • \(lic.licNumber)")
            .font(.callout)
          HStack(spacing: 8) {
            if let from = lic.validFrom {
              Text("From: \(from.formatted(date: .abbreviated, time: .omitted))")
                .font(.brandCaption)
            }
            if let to = lic.validTo {
              Text("To: \(to.formatted(date: .abbreviated, time: .omitted))")
                .font(.brandCaption)
            }
          }
          if !lic.guideName.isEmpty || !lic.vendor.isEmpty {
            Text([lic.guideName, lic.vendor].filter { !$0.isEmpty }.joined(separator: " • "))
              .font(.brandCaption)
              .foregroundColor(.secondary)
          }
        }
        .padding(.vertical, 4)
      }
    }
  }

  // MARK: - Lodges / Community helpers

  private func defaultLodgeId() -> UUID? {
    if let first = lodges.first(where: { ($0.name ?? "").localizedCaseInsensitiveContains(CommunityService.shared.activeCommunityName) }) {
      return first.lodgeId
    }
    return lodges.first?.lodgeId
  }

  // Seed logic moved to PersistenceController.seedCommunityIfNeeded
  // so it runs at app launch before any sync or catch recording.

  private func performUpload(_ upsert: TripAPI.UpsertTripRequest) {
    Task { @MainActor in
      await AuthStore.shared.refreshFromSupabase()
      if let jwt = AuthStore.shared.jwt {
        do {
          _ = try await TripAPI.upsertTrip(upsert, jwt: jwt)
          uploadSucceeded = true
          uploadErrorMessage = nil
          showUploadAlert = true
        } catch {
          uploadSucceeded = false
          uploadErrorMessage = error.localizedDescription
          showUploadAlert = true
        }
      } else {
        uploadSucceeded = false
        uploadErrorMessage = "Not signed in."
        showUploadAlert = true
      }
    }
  }

  // MARK: - Save

  private func save() {
    guard vm.isValid else { return }
    vm.isSaving = true
    do {
      let trip = Trip(context: context)
      trip.tripId = UUID()
      trip.guideName = vm.guideName
      trip.name = vm.tripName
      trip.startDate = vm.startDate
      trip.endDate = vm.endDate
      trip.createdAt = Date()

      if let sel = vm.selectedLodgeId,
         let lodge = lodges.first(where: { $0.lodgeId == sel }) {
        trip.lodge = lodge
      }

      for i in 0 ..< vm.clientCount {
        let draft = vm.clients[i]
        let c = TripClient(context: context)
        c.name = draft.name
        // The "Member Number" field on the angler form holds the angler's
        // app-wide memberId. The draft struct's property is still named
        // `licenseNumber` for now (separate cosmetic refactor), but the
        // value is the memberId. Persist to both columns during the
        // licenseNumber → memberId transition.
        c.memberId = draft.licenseNumber
        c.licenseNumber = draft.licenseNumber
        c.trip = trip

        var seen = Set<String>()
        for row in draft.licences {
          let key = "\(row.licNumber)|\(row.water)|\(row.validFrom?.timeIntervalSince1970 ?? -1)|\(row.validTo?.timeIntervalSince1970 ?? -1)"
          guard seen.insert(key).inserted else { continue }

          let cw = ClassifiedWaterLicense(context: context)
          cw.licNumber = row.licNumber
          cw.water = row.water
          cw.validFrom = row.validFrom
          cw.validTo = row.validTo
          cw.guideName = row.guideName
          cw.vendor = row.vendor
          cw.client = c
        }
      }

      try context.save()

      // After local persistence succeeds, attempt to upload to the server.
      let selectedLodgeName = lodges.first(where: { $0.lodgeId == vm.selectedLodgeId })?.name
      let anglersPayload: [TripAPI.UpsertTripRequest.UpsertAngler] = vm.clients.prefix(vm.clientCount).map { draft in
        let licenses: [TripAPI.UpsertTripRequest.UpsertAngler.UpsertLicense] = draft.licences.compactMap { lic in
          guard let from = lic.validFrom, let to = lic.validTo else { return nil }
          return .init(
            licenseNumber: lic.licNumber,
            riverName: lic.water,
            startDate: from.yyyyMMdd,
            endDate: to.yyyyMMdd
          )
        }

        let fullName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = fullName.split(separator: " ").map(String.init)
        let firstName: String? = parts.first
        let lastName: String? = (parts.count > 1) ? parts.dropFirst().joined(separator: " ") : nil

        return .init(
          memberId: draft.licenseNumber,
          firstName: firstName,
          lastName: lastName,
          dateOfBirth: draft.dateOfBirth?.yyyyMMdd,
          residency: draft.residency,
          sex: draft.sex,
          mailingAddress: (draft.mailingAddress?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true) ? nil : draft.mailingAddress,
          telephoneNumber: (draft.telephoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true) ? nil : draft.telephoneNumber,
          licenseCountry: draft.licenseCountry.isEmpty ? nil : draft.licenseCountry,
          licenseStateProvince: draft.licenseStateProvince.isEmpty ? nil : draft.licenseStateProvince,
          licenseExpirationDate: draft.licenseExpirationDate?.yyyyMMdd,
          classifiedWatersLicenses: licenses.isEmpty ? nil : licenses
        )
      }

      let upsert = TripAPI.UpsertTripRequest(
        tripId: trip.tripId?.uuidString ?? UUID().uuidString,
        tripName: vm.tripName,
        startDate: vm.startDate.iso8601ZString,
        endDate: vm.endDate.iso8601ZString,
        guideName: vm.guideName,
        clientName: nil,
        community: CommunityService.shared.activeCommunityName,
        lodge: selectedLodgeName,
        anglers: anglersPayload
      )

      pendingUpsertRequest = upsert
      performUpload(upsert)

      vm.isSaving = false
      vm.toastMessage = "Trip created"
      vm.showToast = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dismiss() }
    } catch {
      vm.isSaving = false
      vm.toastMessage = "Failed to save trip: \(error.localizedDescription)"
      vm.showToast = true
    }
  }
}

// MARK: - Date helpers

private func parseYMD(_ s: String) -> Date? {
  DateFormatting.ymd.date(from: s)
}

private extension Date {
  var iso8601ZString: String {
    DateFormatting.iso8601.string(from: self)
  }

  var yyyyMMdd: String {
    DateFormatting.ymd.string(from: self)
  }
}

// MARK: - Date Picker Sheet

private struct DatePickerSheet: View {
  let title: String
  @Binding var date: Date
  let range: ClosedRange<Date>
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationView {
      ZStack {
        Color.brandBackground.ignoresSafeArea()
        VStack {
          DatePicker("", selection: $date, in: range, displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .tint(.brandAccent)
            .padding()
          Spacer()
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button(action: { dismiss() }) {
            Image(systemName: "chevron.backward")
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: { dismiss() }) { Text("Done") }
            .tint(.brandAccent)
        }
      }
    }
    .environment(\.colorScheme, .dark)
  }
}

private struct HideListBackgroundIfAvailable: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 16.0, *) {
      content.scrollContentBackground(.hidden)
    } else {
      content
    }
  }
}
