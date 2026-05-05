// Bend Fly Shop
// ManageProfileView.swift
//
// Profile-only view (name, phone, DOB).
// Preferences are managed separately via the member-profile-fields API.
//
// URL composition:
//   API_BASE_URL + MY_PROFILE_URL (both from Info.plist)

import SwiftUI
import Foundation

// MARK: - Models

struct MyProfile: Codable, Equatable {
  var firstName: String?
  var lastName: String?
  var memberId: String?
  var dateOfBirth: String?
  var phoneNumber: String?
}

// MARK: - API Helper (URL composition convention)

enum ManageProfileAPI {
  static let saveMethod = "PUT"

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

  private static let profilePath: String = {
    (Bundle.main.object(forInfoDictionaryKey: "MY_PROFILE_URL") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    ?? "/functions/v1/my-profile"
  }()

  static func url() throws -> URL {
    guard let base = URL(string: baseURLString),
          let scheme = base.scheme,
          let host = base.host
    else { throw URLError(.badURL) }

    var comps = URLComponents()
    comps.scheme = scheme
    comps.host = host
    comps.port = base.port

    let basePath = base.path
    let normalizedBasePath =
      basePath == "/" ? "" : (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath)

    let normalizedPath = profilePath.hasPrefix("/") ? profilePath : "/" + profilePath
    comps.path = normalizedBasePath + normalizedPath

    let existing = base.query != nil
      ? (URLComponents(string: base.absoluteString)?.queryItems ?? [])
      : []
    comps.queryItems = existing.isEmpty ? nil : existing

    guard let url = comps.url else { throw URLError(.badURL) }
    return url
  }
}

// MARK: - View

struct ManageProfileView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var auth: AuthService
  @ObservedObject private var communityService = CommunityService.shared

  // ML training opt-out (public users only). Uses a draft/original pair so
  // the toggle participates in the Save button's dirty-state logic just like
  // profile fields. Committed to `MLTrainingOptOutStore.shared` on save only.
  @State private var mlOptOutDraft: Bool = MLTrainingOptOutStore.shared.isOptedOut
  @State private var originalMlOptOut: Bool = MLTrainingOptOutStore.shared.isOptedOut

  // Conservation mode (public users only). Same draft/original pattern as
  // mlOptOutDraft. Committed to `PublicConservationModeStore.shared` on save.
  @State private var conservationModeDraft: Bool = PublicConservationModeStore.shared.isEnabled
  @State private var originalConservationMode: Bool = PublicConservationModeStore.shared.isEnabled

  @State private var profile = MyProfile()
  @State private var originalProfile = MyProfile()
  @State private var isLoading = false
  @State private var isSaving = false
  @State private var errorText: String?
  @State private var infoText: String?
  @State private var showUnsavedConfirm = false
  @State private var showLeaveCommunityConfirm = false
  @State private var showDeleteAccountConfirm = false
  @State private var deleteConfirmationInput = ""
  @State private var isDeletingAccount = false
  @State private var isLeavingCommunity = false

  // Optional so we can distinguish "never set" (nil) from "intentionally set".
  // Previously defaulted to `Date()` which caused today's date to be silently
  // written to the backend any time a user saved other profile changes without
  // touching the DOB picker.
  @State private var dobDate: Date? = nil
  @State private var originalDobDate: Date? = nil

  @State private var showAppOverview = false

  private var hasUnsavedChanges: Bool {
    originalProfile != profile
      || dobDate != originalDobDate
      || mlOptOutDraft != originalMlOptOut
      || conservationModeDraft != originalConservationMode
  }

  var body: some View {
    DarkPageTemplate {
      VStack(alignment: .leading, spacing: 16) {
        if let err = errorText {
          Text(err).foregroundColor(.brandError).font(.brandFootnote)
        }
        if let info = infoText {
          Text(info).foregroundColor(.brandTextSecondary).font(.brandFootnote)
        }

        if #available(iOS 16.0, *) {
          Form {
            profileFields
            legalSection
            if auth.currentUserType == .public {
              appOverviewSection
              privacySection
            }
            dangerSection
          }
          .scrollContentBackground(.hidden)
          .background(Color.brandBackground)
        } else {
          Form {
            profileFields
            legalSection
            if auth.currentUserType == .public {
              appOverviewSection
              privacySection
            }
            dangerSection
          }
          .background(Color.brandBackground)
        }

        Spacer()
      }
      .padding(.top, 8)
    }
    .navigationTitle("Manage Profile")
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button(action: {
          if hasUnsavedChanges { showUnsavedConfirm = true } else { dismiss() }
        }) { Image(systemName: "chevron.left")
        }
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: { Task { await saveProfile() } }) {
          HStack(spacing: 6) {
            if isSaving { ProgressView() }
            Text("Save")
              .font(.brandSubheadline.weight(.semibold))
              .foregroundColor(.brandTextPrimary)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background((hasUnsavedChanges && !isSaving && !isLoading) ? Color.brandAccent : Color.brandTextSecondary)
              .clipShape(Capsule())
          }
        }
        .buttonStyle(.plain)
        .disabled(isSaving || isLoading)
        .accessibilityIdentifier("saveProfileButton")
      }
    }
    .confirmationDialog(
      "You have unsaved changes",
      isPresented: $showUnsavedConfirm,
      titleVisibility: .visible
    ) {
      Button("Save Changes") { Task { await saveProfile() } }
      Button("Discard Changes", role: .destructive) { dismiss() }
      Button("Cancel", role: .cancel) {}
    }
    .alert("Leave \(communityService.activeCommunityName)?", isPresented: $showLeaveCommunityConfirm) {
      Button("Cancel", role: .cancel) {}
      Button("OK", role: .destructive) { Task { await leaveCommunityTapped() } }
    } message: {
      Text("Once you leave the community, you will need to be re-invited by the community administrator.")
    }
    .alert("Delete Mad Thinker Account?", isPresented: $showDeleteAccountConfirm) {
      TextField("Type DELETE", text: $deleteConfirmationInput)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
      Button("Cancel", role: .cancel) { deleteConfirmationInput = "" }
      Button("Delete", role: .destructive) {
        let input = deleteConfirmationInput
        deleteConfirmationInput = ""
        Task { await performDeleteAccount(confirmationText: input) }
      }
    } message: {
      Text("This cannot be undone. All member data associated with Mad Thinker will be permanently deleted.\n\nType DELETE to confirm.")
    }
    .task { await loadProfile() }
    .fullScreenCover(isPresented: $showAppOverview) {
      PublicWelcomeView()
    }
  }

  // MARK: - Legal (all users)

  /// Required policy links shown in every user's profile, regardless of role.
  /// Same URLs as MemberRegistrationView signup footer and PublicWelcomeView
  /// first-login overview — keep them in sync if the marketing site moves.
  @ViewBuilder
  private var legalSection: some View {
    Section {
      Link(destination: LegalURLs.privacyPolicy) {
        HStack {
          Image(systemName: "lock.shield")
          Text("Privacy Policy")
          Spacer()
          Image(systemName: "arrow.up.right.square")
            .foregroundColor(.brandTextSecondary)
        }
        .foregroundColor(.brandAccent)
        .font(.callout)
      }
      .accessibilityIdentifier("manageProfilePrivacyPolicyLink")

      Link(destination: LegalURLs.acceptableUsePolicy) {
        HStack {
          Image(systemName: "doc.text")
          Text("Acceptable Use Policy")
          Spacer()
          Image(systemName: "arrow.up.right.square")
            .foregroundColor(.brandTextSecondary)
        }
        .foregroundColor(.brandAccent)
        .font(.callout)
      }
      .accessibilityIdentifier("manageProfileAcceptableUsePolicyLink")
    } header: {
      Text("Legal")
    }
    .listRowBackground(Color.brandSurfaceMuted)
  }

  // MARK: - App overview (public users only)

  @ViewBuilder
  private var appOverviewSection: some View {
    Section {
      Button { showAppOverview = true } label: {
        HStack(spacing: 10) {
          Image(systemName: "sparkles")
            .foregroundColor(.brandAccent)
          Text("App Overview")
            .foregroundColor(.brandAccent)
            .font(.callout.weight(.semibold))
          Spacer()
          Image(systemName: "chevron.right")
            .font(.brandCaption.weight(.semibold))
            .foregroundColor(.brandTextPrimary.opacity(0.4))
        }
      }
      .accessibilityIdentifier("appOverviewButton")
    } footer: {
      Text("Revisit the welcome overview — what Mad Thinker does, and links to the privacy and acceptable use policies.")
        .font(.brandCaption)
        .foregroundColor(.brandTextSecondary)
    }
    .listRowBackground(Color.brandSurfaceMuted)
  }

  // MARK: - Privacy (public users only)

  @ViewBuilder
  private var privacySection: some View {
    Section {
      Toggle(isOn: $conservationModeDraft) {
        Text("Conservation mode")
          .foregroundColor(.brandAccent)
          .font(.callout)
      }
      .tint(.brandAccent)
      .accessibilityIdentifier("conservationModeToggle")

      Toggle(isOn: Binding(
        get: { !mlOptOutDraft },
        set: { mlOptOutDraft = !$0 }
      )) {
        Text("Help improve species detection")
          .foregroundColor(.brandAccent)
          .font(.callout)
      }
      .tint(.brandAccent)
      .accessibilityIdentifier("mlTrainingOptOutToggle")
    } header: {
      Text("Privacy")
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        Text("Conservation mode: when on, your catches contribute additional data (head photo, measurements, sample IDs) used in conservation research. Turn off for a faster, lighter recording experience.")
        Text("Help improve species detection: your anonymized catch photos and measurements help our models get better at identifying fish and improve your usability. Turn off to opt out of this use.")
      }
      .font(.brandCaption)
      .foregroundColor(.brandTextSecondary)
    }
    .listRowBackground(Color.brandSurfaceMuted)
  }

  // MARK: - Danger zone

  @ViewBuilder
  private var dangerSection: some View {
    Section {
      Button(role: .destructive) {
        showLeaveCommunityConfirm = true
      } label: {
        HStack {
          if isLeavingCommunity {
            ProgressView()
          } else {
            Image(systemName: "person.fill.xmark")
          }
          Text("Leave \(communityService.activeCommunityName)")
        }
        .font(.callout.weight(.semibold))
        .foregroundColor(.brandError)
      }
      .disabled(isLeavingCommunity)
      .accessibilityIdentifier("leaveCommunityButton")

      Button(role: .destructive) {
        deleteConfirmationInput = ""
        showDeleteAccountConfirm = true
      } label: {
        HStack {
          if isDeletingAccount {
            ProgressView()
          } else {
            Image(systemName: "trash")
          }
          Text("Delete Mad Thinker Account")
        }
        .font(.callout.weight(.semibold))
        .foregroundColor(.brandError)
      }
      .disabled(isDeletingAccount)
      .accessibilityIdentifier("deleteAccountButton")
    }
    .listRowBackground(Color.brandSurfaceMuted)
  }

  // MARK: - Destructive actions (backend stubs)

  private func leaveCommunityTapped() async {
    errorText = nil
    infoText = nil

    guard let communityId = communityService.activeCommunityId else {
      errorText = "No active community to leave."
      return
    }

    isLeavingCommunity = true
    defer { isLeavingCommunity = false }

    do {
      try await communityService.leaveCommunity(communityId: communityId)
      AppLogging.log("[ManageProfile] Left community \(communityId) — dismissing", level: .info, category: .community)
      await MainActor.run { dismiss() }
    } catch let err as CommunityError {
      errorText = err.errorDescription
      AppLogging.log("[ManageProfile] Leave community failed: \(err)", level: .error, category: .community)
    } catch {
      errorText = "Could not leave the community: \(error.localizedDescription)"
      AppLogging.log("[ManageProfile] Leave community error: \(error)", level: .error, category: .community)
    }
  }

  private func performDeleteAccount(confirmationText: String) async {
    errorText = nil
    infoText = nil

    guard confirmationText == "DELETE" else {
      errorText = "Please type DELETE exactly to confirm account deletion."
      return
    }

    guard let token = await auth.currentAccessToken(), !token.isEmpty else {
      errorText = "You are not signed in."
      return
    }

    isDeletingAccount = true
    defer { isDeletingAccount = false }

    let url = AppEnvironment.shared.deleteAccountURL

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(auth.publicAnonKey, forHTTPHeaderField: "apikey")
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["confirmationText": "DELETE"])

    AppLogging.log("[ManageProfile] deleteAccount POST url=\(url.absoluteString) scheme=\(url.scheme ?? "nil") host=\(url.host ?? "nil") path=\(url.path)", level: .info, category: .auth)

    do {
      let (data, resp) = try await URLSession.shared.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
      let bodyText = String(data: data, encoding: .utf8) ?? ""
      AppLogging.log("[ManageProfile] deleteAccount response status=\(code) body=\(bodyText)", level: .info, category: .auth)

      guard (200..<300).contains(code) else {
        let body = bodyText
        AppLogging.log("[ManageProfile] deleteAccount failed status=\(code) body=\(body)", level: .error, category: .auth)
        switch code {
        case 400: errorText = "Confirmation text did not match. Please try again."
        case 401: errorText = "Your session has expired. Please sign in again."
        case 403: errorText = "Account deletion is not currently available."
        case 429: errorText = "Too many attempts. Please try again later."
        default:  errorText = "Account deletion failed (\(code)). Please contact support."
        }
        return
      }

      AppLogging.log("[ManageProfile] account deleted; clearing local session.", level: .info, category: .auth)
      // Server already invalidated the session via cascade; local sign-out is
      // enough to return AppRootView to the login screen.
      await auth.signOut()
    } catch {
      AppLogging.log("[ManageProfile] deleteAccount error: \(error)", level: .error, category: .auth)
      errorText = "Account deletion failed: \(error.localizedDescription)"
    }
  }

  // MARK: - Profile Fields

  @ViewBuilder
  private var profileFields: some View {
    Section {
      if let memberId = profile.memberId, !memberId.isEmpty {
        HStack {
          Text("Member #").foregroundColor(.brandAccent).font(.callout)
          Spacer()
          Text(memberId)
            .foregroundColor(.brandTextSecondary)
            .font(.callout)
        }
      }
      HStack {
        Text("First Name").foregroundColor(.brandAccent).font(.callout)
        Spacer()
        TextField("First name", text: Binding(get: { profile.firstName ?? "" }, set: { profile.firstName = $0 }))
          .multilineTextAlignment(.trailing)
          .foregroundColor(.brandTextPrimary)
          .font(.callout)
          .accessibilityIdentifier("firstNameTextField")
      }
      HStack {
        Text("Last Name").foregroundColor(.brandAccent).font(.callout)
        Spacer()
        TextField("Last name", text: Binding(get: { profile.lastName ?? "" }, set: { profile.lastName = $0 }))
          .multilineTextAlignment(.trailing)
          .foregroundColor(.brandTextPrimary)
          .font(.callout)
          .accessibilityIdentifier("lastNameTextField")
      }
      HStack {
        Text("Date of Birth").foregroundColor(.brandAccent).font(.callout)
        Spacer()
        if let currentDob = dobDate {
          DatePicker(
            "Date of Birth",
            selection: Binding(
              get: { currentDob },
              set: { dobDate = $0 }
            ),
            displayedComponents: .date
          )
          .labelsHidden()
          .foregroundColor(.brandTextPrimary)
          .accessibilityIdentifier("dobPicker")
        } else {
          Button("Set") {
            // Seed with today when the user taps to set. They'll open the
            // picker wheel to pick their actual DOB.
            dobDate = Date()
          }
          .font(.callout.weight(.semibold))
          .foregroundColor(.brandAccent)
          .accessibilityIdentifier("setDateOfBirthButton")
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("Phone Number").foregroundColor(.brandAccent).font(.callout)
          Spacer()
          TextField("Phone number", text: Binding(get: { profile.phoneNumber ?? "" }, set: { profile.phoneNumber = $0 }))
            .multilineTextAlignment(.trailing)
            .foregroundColor(.brandTextPrimary)
            .font(.callout)
            .accessibilityIdentifier("phoneTextField")
        }
        if let phone = profile.phoneNumber, !phone.isEmpty, !isValidPhone(phone) {
          Text("Please enter a valid phone number (10\u{2013}15 digits, digits only or formatted).")
            .font(.brandCaption)
            .foregroundColor(.brandError)
        }
      }
    }
  }

  // MARK: - Validation

  private func isValidPhone(_ s: String) -> Bool {
    let digits = s.filter { $0.isNumber }
    return digits.count >= 10 && digits.count <= 15
  }

  // MARK: - Networking

  private func loadProfile() async {
    errorText = nil
    infoText = nil
    isLoading = true
    defer { isLoading = false }

    guard let token = await auth.currentAccessToken(), !token.isEmpty else {
      errorText = "You are not signed in."
      return
    }

    let url: URL
    do {
      url = try ManageProfileAPI.url()
    } catch {
      errorText = "Unsupported URL (check API_BASE_URL / MY_PROFILE_URL)."
      AppLogging.log("[ManageProfile] URL compose error: \(error)", level: .error, category: .network)
      return
    }

    AppLogging.log("[ManageProfile] loadProfile URL: \(url.absoluteString)", level: .debug, category: .network)

    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(auth.publicAnonKey, forHTTPHeaderField: "apikey")

    do {
      let (data, resp) = try await URLSession.shared.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

      AppLogging.log("[ManageProfile] loadProfile status: \(code)", level: .debug, category: .network)

      guard (200..<300).contains(code) else {
        errorText = "Load failed (\(code))."
        return
      }

      struct Resp: Decodable {
        let profile: MyProfile
      }

      let decoded = try JSONDecoder().decode(Resp.self, from: data)

      profile = decoded.profile

      if let dob = profile.dateOfBirth, !dob.isEmpty {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        if let d = f.date(from: dob) { dobDate = d }
      }
      // If backend returned no DOB, dobDate stays nil so the UI shows
      // "Set" instead of today's date.

      originalProfile = profile
      originalDobDate = dobDate
    } catch {
      errorText = error.localizedDescription
    }
  }

  private func saveProfile() async {
    errorText = nil
    infoText = nil
    isSaving = true
    defer { isSaving = false }

    guard let token = await auth.currentAccessToken(), !token.isEmpty else {
      errorText = "You are not signed in."
      return
    }

    if let phone = profile.phoneNumber, !phone.isEmpty, !isValidPhone(phone) {
      errorText = "Invalid phone number. Please correct it before saving."
      return
    }

    if let dob = dobDate {
      let df = DateFormatter()
      df.calendar = Calendar(identifier: .gregorian)
      df.locale = Locale(identifier: "en_US_POSIX")
      df.timeZone = TimeZone(secondsFromGMT: 0)
      df.dateFormat = "yyyy-MM-dd"
      profile.dateOfBirth = df.string(from: dob)
    } else {
      // User never set a DOB — don't send a stale/default value.
      profile.dateOfBirth = nil
    }

    let url: URL
    do {
      url = try ManageProfileAPI.url()
    } catch {
      errorText = "Unsupported URL (check API_BASE_URL / MY_PROFILE_URL)."
      AppLogging.log("[ManageProfile] URL compose error: \(error)", level: .error, category: .network)
      return
    }

    AppLogging.log("[ManageProfile] saveProfile URL: \(url.absoluteString)", level: .debug, category: .network)

    var req = URLRequest(url: url)
    req.httpMethod = ManageProfileAPI.saveMethod
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(auth.publicAnonKey, forHTTPHeaderField: "apikey")

    var body: [String: Any] = [:]
    if let v = profile.firstName, !v.isEmpty { body["firstName"] = v }
    if let v = profile.lastName, !v.isEmpty { body["lastName"] = v }
    if let v = profile.phoneNumber, !v.isEmpty { body["phoneNumber"] = v }
    if let v = profile.dateOfBirth, !v.isEmpty { body["dateOfBirth"] = v }

    do {
      req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

      let (data, resp) = try await URLSession.shared.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

      AppLogging.log("[ManageProfile] saveProfile status: \(code)", level: .debug, category: .network)

      guard (200..<300).contains(code) else {
        let msg = String(data: data, encoding: .utf8) ?? ""
        errorText = "Save failed (\(code)). \(msg)"
        return
      }

      // Persist ML opt-out (public users) once the server save succeeded.
      if auth.currentUserType == .public, mlOptOutDraft != originalMlOptOut {
        MLTrainingOptOutStore.shared.isOptedOut = mlOptOutDraft
        originalMlOptOut = mlOptOutDraft
      }

      // Persist Conservation mode (public users) once the server save succeeded.
      if auth.currentUserType == .public, conservationModeDraft != originalConservationMode {
        PublicConservationModeStore.shared.isEnabled = conservationModeDraft
        originalConservationMode = conservationModeDraft
      }

      infoText = "Saved."
      originalProfile = profile
      originalDobDate = dobDate
      dismiss()
    } catch {
      errorText = error.localizedDescription
    }
  }
}

#Preview {
  NavigationView {
    ManageProfileView()
      .environmentObject(AuthService.shared)
  }
}
