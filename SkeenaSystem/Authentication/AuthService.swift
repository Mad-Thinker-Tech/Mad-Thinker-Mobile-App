// Bend Fly Shop
// Logging via AppLogging (.auth category)

import Combine
import Foundation
import Security
import os
import LocalAuthentication
// Uses AppLogging for centralized logging

final class AuthService: ObservableObject {
    nonisolated(unsafe) static var shared: AuthService = AuthService()

     #if DEBUG
     /// Test helper: reset the shared singleton to a fresh instance.
     static func resetSharedForTests(session: URLSession = .shared) {
       shared = AuthService(session: session)
     }
     #endif
  // ---- Configure these two constants ----
  private let projectURL = AppEnvironment.shared.projectURL
  private let anonPublicKey = AppEnvironment.shared.anonKey
  // --------------------------------------

  // -------- Offline Login Cache -----------
  private let kOfflineEmailKey = "OfflineLastEmail"
  private let kOfflinePasswordKey = "OfflineLastPassword" // (stored in Keychain)
  private let kOfflineRememberMeKey = "OfflineRememberMeEnabled"
  private let kCachedFirstName = "CachedFirstName"
  private let kCachedLastName = "CachedLastName"
  private let kCachedUserType = "CachedUserType"
  private let kCachedMemberId = "CachedMemberId"
  // ---------------------------------------

  var publicAnonKey: String { anonPublicKey }

  @Published private(set) var isAuthenticated: Bool = false
  @Published private(set) var currentUserType: UserType? // <- role for routing
  @Published private(set) var currentFirstName: String?
  @Published private(set) var currentLastName: String?
  @Published private(set) var currentMemberId: String? {
    didSet { _currentMemberIdSubject.send(currentMemberId) }
  }

  /// Nonisolated publisher mirror of `currentMemberId`. Used by upload-side
  /// stores (CatchReportStore, FarmedReportStore) that subscribe from
  /// nonisolated init code. CurrentValueSubject emits the current value on
  /// subscribe, so first-emission semantics are identical to `$currentMemberId`.
  nonisolated private let _currentMemberIdSubject = CurrentValueSubject<String?, Never>(nil)
  nonisolated var currentMemberIdPublisher: AnyPublisher<String?, Never> { _currentMemberIdSubject.eraseToAnyPublisher() }
  nonisolated var currentMemberIdSnapshot: String? { _currentMemberIdSubject.value }

  /// Called by CommunityService when the active community (and thus role) changes.
  /// This keeps views that read `auth.currentUserType` working without modification.
  @MainActor
  func updateUserType(_ type: UserType) {
    if currentUserType != type {
      currentUserType = type
      AppLogging.log("[AuthService] userType updated from CommunityService: \(type.rawValue)", level: .info, category: .auth)
    }
  }

  // Transient (in-memory only) last sign-in credentials for remember-me recording after role resolution
  private var lastSignInEmail: String?
  private var lastSignInPassword: String?

  var rememberMeEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: kOfflineRememberMeKey) }
    set { UserDefaults.standard.set(newValue, forKey: kOfflineRememberMeKey); AppLogging.log("[Offline][RememberMe] set=\(newValue)", level: .debug, category: .auth) }
  }

  private let kAccessToken = "epicwaters.auth.access_token"
  private let kRefreshToken = "epicwaters.auth.refresh_token"
  private let kAccessTokenExp = "epicwaters.auth.access_token_exp" // seconds since epoch

  // Ensures only one refresh runs at a time and that all callers await the same result.
  private var refreshTask: Task<String?, Never>?
  private let refreshQueue = DispatchQueue(label: "AuthService.refresh.serial")
  private let session: URLSession

  private init(session: URLSession = .shared) {
    self.session = session

    // Hydrate cached auth state so AppRootView can route to the correct landing
    // view on a cold offline launch. Without this, isAuthenticated=true (from a
    // stored refresh token) leaves currentUserType=nil and the app sits on a
    // loading spinner forever because loadUserProfile() needs the network.
    let cached = Self.loadCachedAuthState()
    self.isAuthenticated = cached.isAuthenticated
    self.currentFirstName = cached.firstName
    self.currentLastName = cached.lastName
    self.currentUserType = cached.userType
    self.currentMemberId = cached.memberId

    AppLogging.log("init: hasAccess=\(cached.hasAccessToken) accessValid=\(cached.accessTokenValid) host=\(projectURL.host ?? "?") hasRefresh=\(cached.hasRefreshToken) cachedType=\(cached.userType?.rawValue ?? "<nil>") cachedMember=\(cached.memberId ?? "<nil>")", level: .debug, category: .auth)

    // IMPORTANT: Do not start network I/O from init(). Any early refresh should be invoked
    // explicitly from app lifecycle (e.g., AppRootView.task or similar).
  }

  /// Snapshot of the auth state derived from on-disk caches (Keychain + UserDefaults).
  /// Pure read — no mutation, no network. Exposed at internal visibility so
  /// regression tests can verify offline cold-launch hydration without
  /// reassigning the `shared` singleton (which is flaky to deinit on iOS 26.2 sim).
  internal struct CachedAuthState: Equatable {
    let isAuthenticated: Bool
    let firstName: String?
    let lastName: String?
    let userType: UserType?
    let memberId: String?
    let hasAccessToken: Bool
    let accessTokenValid: Bool
    let hasRefreshToken: Bool
  }

  internal static func loadCachedAuthState() -> CachedAuthState {
    let kAccessToken = "epicwaters.auth.access_token"
    let kAccessTokenExp = "epicwaters.auth.access_token_exp"
    let kRefreshToken = "epicwaters.auth.refresh_token"
    let kCachedFirstName = "CachedFirstName"
    let kCachedLastName = "CachedLastName"
    let kCachedUserType = "CachedUserType"
    let kCachedMemberId = "CachedMemberId"

    let token = Keychain.get(kAccessToken)
    let exp = Keychain.get(kAccessTokenExp).flatMap { Double($0) }
    let accessValid = isJWTValid(accessToken: token, expSeconds: exp)
    let hasRefresh = Keychain.get(kRefreshToken) != nil

    let userType: UserType?
    if let raw = UserDefaults.standard.string(forKey: kCachedUserType) {
      userType = UserType(rawValue: raw)
    } else {
      userType = nil
    }

    return CachedAuthState(
      isAuthenticated: accessValid || hasRefresh,
      firstName: UserDefaults.standard.string(forKey: kCachedFirstName),
      lastName: UserDefaults.standard.string(forKey: kCachedLastName),
      userType: userType,
      memberId: UserDefaults.standard.string(forKey: kCachedMemberId),
      hasAccessToken: token != nil,
      accessTokenValid: accessValid,
      hasRefreshToken: hasRefresh
    )
  }

  // MARK: - Public API

  enum UserType: String, Codable, CaseIterable { case angler, guide, `public`, researcher }

  enum InputValidationError: Error, LocalizedError {
    case invalidInput(String)
    var errorDescription: String? {
      switch self {
      case let .invalidInput(reason): reason
      }
    }
  }

  // MARK: - Error mapping
  private func mapAuthHTTPError(status: Int, responseBody: Data?) -> AuthError {
    let body = responseBody.flatMap { String(data: $0, encoding: .utf8) }?.lowercased() ?? ""

    // Common Supabase/Auth messages often include strings like these
    if status == 400 || status == 401 {
      if body.contains("invalid login") || body.contains("invalid email or password") || body.contains("invalid credentials") {
        return .invalidCredentials
      }
      if body.contains("email not confirmed") || body.contains("email not confirmed") || body.contains("confirm your email") {
        return .emailNotConfirmed
      }
      // Default for 400/401 if not recognized
      return .invalidCredentials
    }

    if status == 429 { return .rateLimited }
    if status >= 500 && status < 600 { return .serverUnavailable }

    // Fallback: keep original for logging, but UI will show generic if needed
    let msg = responseBody.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
    return .http(code: status, message: msg)
  }

  /// Sign Up (First Time Users) per API:
  /// POST /auth/v1/signup
  func signUp(
    email: String,
    password: String,
    firstName: String,
    lastName: String,
    userType: UserType,
    communityCode: String? = nil
  ) async throws {
    // Validate
    let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
    let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !first.isEmpty else { throw InputValidationError.invalidInput("First name is required.") }
    guard !last.isEmpty else { throw InputValidationError.invalidInput("Last name is required.") }

    let commCode: String? = {
      let trimmed = (communityCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      return trimmed.isEmpty ? nil : trimmed
    }()
    if let code = commCode {
      let codeValid = code.range(of: #"^[A-Z0-9]{6}$"#, options: .regularExpression) != nil
      guard codeValid else { throw InputValidationError.invalidInput("Community code must be 6 alphanumeric characters.") }
    }

    AppLogging.log("signUp -> email=\(email) type=\(userType.rawValue) name=\(firstName) \(lastName) communityCode=\(commCode ?? "<none>")", level: .info, category: .auth)

    let url = projectURL.appendingPathComponent("/auth/v1/signup")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(anonPublicKey, forHTTPHeaderField: "apikey")

    var dataObj: [String: Any] = [
      "first_name": first,
      "last_name": last,
      "user_type": userType.rawValue
    ]
    if let code = commCode { dataObj["community_code"] = code }

    let body: [String: Any] = [
      "email": email,
      "password": password,
      "data": dataObj
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

    if (200 ..< 300).contains(code) {
      AppLogging.log("signUp success (status \(code)).", level: .info, category: .auth)
      // We already know the role; publish immediately so UI can react
      await MainActor.run { self.currentUserType = userType }

      // Try immediate sign-in (may fail if email confirmation is enforced)
      do {
        try await signIn(email: email, password: password)
      } catch {
        AppLogging.log("signUp completed but signIn failed (possibly email confirmation required). error=\(error)", level: .error, category: .auth)
        throw error
      }
    } else {
      let msg = String(data: data, encoding: .utf8) ?? "<no body>"
      AppLogging.log("[ERROR] signUp failed status=\(code) body=\(msg)", level: .error, category: .auth)
      throw AuthError.http(code: code, message: msg)
    }
  }

  /// Invite-Based Sign Up (Path A):
  /// Only email, password, community_code, and member_number are sent. The server
  /// populates the user's profile from a pending invite matching the email + community.
  func signUpWithInvite(
    email: String,
    password: String,
    communityCode: String,
    memberNumber: String
  ) async throws {
    let commCode = communityCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !commCode.isEmpty else { throw InputValidationError.invalidInput("Community code is required.") }
    let codeValid = commCode.range(of: #"^[A-Z0-9]{6}$"#, options: .regularExpression) != nil
    guard codeValid else { throw InputValidationError.invalidInput("Community code must be 6 alphanumeric characters.") }

    let memNum = MemberNumber.normalize(memberNumber)
    guard MemberNumber.isValid(memNum) else {
      throw InputValidationError.invalidInput("Member number must be a 9-character MAD-format code (e.g. MAD4ZQ7H9).")
    }

    AppLogging.log("signUpWithInvite -> email=\(email) communityCode=\(commCode)", level: .info, category: .auth)

    let url = projectURL.appendingPathComponent("/auth/v1/signup")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(anonPublicKey, forHTTPHeaderField: "apikey")

    let body: [String: Any] = [
      "email": email,
      "password": password,
      "data": [
        "community_code": commCode,
        "member_number": memNum
      ]
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

    if (200 ..< 300).contains(code) {
      AppLogging.log("signUpWithInvite success (status \(code)).", level: .info, category: .auth)

      // Try immediate sign-in; signIn will populate currentUserType from JWT metadata
      do {
        try await signIn(email: email, password: password)
      } catch {
        AppLogging.log("signUpWithInvite completed but signIn failed (possibly email confirmation required). error=\(error)", level: .error, category: .auth)
        throw error
      }
    } else {
      // Parse user-friendly error message from response body
      let rawBody = String(data: data, encoding: .utf8) ?? "<no body>"
      AppLogging.log("[ERROR] signUpWithInvite failed status=\(code) body=\(rawBody)", level: .error, category: .auth)

      // Extract the message field from the JSON response for display
      var displayMessage = "Signup failed (\(code))."
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let msg = json["msg"] as? String { displayMessage = msg }
        else if let msg = json["message"] as? String { displayMessage = msg }
        else if let msg = json["error_description"] as? String { displayMessage = msg }
        else if let msg = json["error"] as? String { displayMessage = msg }
      }
      throw AuthError.http(code: code, message: displayMessage)
    }
  }

  /// Convenience for legacy call sites (requires a community code):
  func signUp(email: String, password: String, communityCode: String) async throws {
    try await signUp(
      email: email,
      password: password,
      firstName: "Unknown",
      lastName: "User",
      userType: .guide,
      communityCode: communityCode
    )
  }

  // MARK: - Sign In (with offline fallback)

  func signIn(email: String, password: String) async throws {
    // Reset some in-memory state synchronously on the MainActor so callers see deterministic state.
    await MainActor.run {
      self.currentUserType = nil
      self.currentFirstName = nil
      self.currentLastName = nil
      self.currentMemberId = nil
      self.isAuthenticated = false
    }

    self.lastSignInEmail = email
    self.lastSignInPassword = password

    AppLogging.log("signIn -> email=\(email)", level: .info, category: .auth)

    var comps = URLComponents(
      url: projectURL.appendingPathComponent("/auth/v1/token"),
      resolvingAgainstBaseURL: false
    )!
    comps.queryItems = [URLQueryItem(name: "grant_type", value: "password")]

    var req = URLRequest(url: comps.url!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(anonPublicKey, forHTTPHeaderField: "apikey")

    let body: [String: String] = ["email": email, "password": password]
    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    AppLogging.log("signIn request prepared: url=/auth/v1/token method=POST contentType=application/json", level: .debug, category: .auth)

    do {
      // --- ONLINE PATH ---
      let (data, resp) = try await session.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

      AppLogging.log("signIn status=\(code)", level: .debug, category: .auth)

      guard (200 ..< 300).contains(code) else {
        let msg = String(data: data, encoding: .utf8) ?? "<no body>"
        AppLogging.log("[ERROR] signIn failed status=\(code) body=\(msg)", level: .error, category: .auth)
        self.lastSignInPassword = nil
        throw mapAuthHTTPError(status: code, responseBody: data)
      }

      let rawBody = String(data: data, encoding: .utf8) ?? "<unable to decode>"
      AppLogging.log("signIn response body: \(rawBody)", level: .debug, category: .auth)

      let token = try JSONDecoder().decode(TokenResponse.self, from: data)

      persistTokens(
        accessToken: token.access_token,
        refreshToken: token.refresh_token,
        expiresIn: token.expires_in
      )
      // Removed setting currentUserId here as per instructions

      recordOfflineCredentials(email: email, password: password)
      AppLogging.log("[Offline] record attempt after token persist (rememberMe=\(rememberMeEnabled))", level: .debug, category: .auth)

      await loadUserProfile()
      await MainActor.run { self.isAuthenticated = true }

      AppLogging.log("signIn success. access.len=\(token.access_token.count) refresh.len=\(token.refresh_token?.count ?? 0) expIn=\(token.expires_in)s", level: .info, category: .auth)

    } catch {
      // --- OFFLINE FALLBACK PATH ---
      if let urlError = error as? URLError {
        AppLogging.log("URLError during signIn code=\(urlError.code.rawValue) desc=\(urlError)", level: .warn, category: .auth)

        let offEmail = UserDefaults.standard.string(forKey: kOfflineEmailKey) ?? "<nil>"
        let offPwLen = (Keychain.get(kOfflinePasswordKey) ?? "").count
        AppLogging.log("[Offline] cachedEmail=\(offEmail) cachedPw.len=\(offPwLen)", level: .debug, category: .auth)

        if canSignInOffline(email: email, password: password) {
          AppLogging.log("[Offline] sign-in success for \(email)", level: .info, category: .auth)

          let cachedFirst = UserDefaults.standard.string(forKey: kCachedFirstName)
          let cachedLast = UserDefaults.standard.string(forKey: kCachedLastName)
          let cachedTypeRaw = UserDefaults.standard.string(forKey: kCachedUserType)
          let cachedMid = UserDefaults.standard.string(forKey: kCachedMemberId)
          await MainActor.run {
            self.currentFirstName = cachedFirst
            self.currentLastName = cachedLast
            if let raw = cachedTypeRaw, let t = UserType(rawValue: raw) { self.currentUserType = t }
            self.currentMemberId = cachedMid
            self.isAuthenticated = true
          }
          AppLogging.log("[Offline] restored cached profile first=\(cachedFirst ?? "<nil>") last=\(cachedLast ?? "<nil>") type=\(cachedTypeRaw ?? "<nil>") memberId=\(cachedMid ?? "<nil>")", level: .debug, category: .auth)
          return
        } else {
          AppLogging.log("[Offline] sign-in failed – no matching cached credentials.", level: .warn, category: .auth)
          self.lastSignInPassword = nil
          throw AuthError.networkUnavailable
        }
      } else {
        // Non-network error: propagate but prefer friendly mapping if it's an HTTP error wrapped elsewhere
        self.lastSignInPassword = nil
        throw error
      }
    }
  }

  func requestPasswordReset(email: String) async throws {
    AppLogging.log("resetPassword -> email=\(email)", level: .info, category: .auth)
    let url = projectURL.appendingPathComponent("/auth/v1/recover")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(anonPublicKey, forHTTPHeaderField: "apikey")
    let body: [String: String] = ["email": email]
    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

    if (200 ..< 300).contains(code) {
      AppLogging.log("resetPassword requested (status \(code)).", level: .info, category: .auth)
    } else {
      let msg = String(data: data, encoding: .utf8) ?? "<no body>"
      AppLogging.log("[ERROR] resetPassword failed status=\(code) body=\(msg)", level: .error, category: .auth)
      throw mapAuthHTTPError(status: code, responseBody: data)
    }
  }

  /// Returns a valid access token if one is stored and not expired.
  func currentAccessToken() async -> String? {
    let token = Keychain.get(kAccessToken)
    let exp = Keychain.get(kAccessTokenExp).flatMap { Double($0) }
    let valid = Self.isJWTValid(accessToken: token, expSeconds: exp)

    if valid {
      AppLogging.log("currentAccessToken valid=true len=\(token?.count ?? 0) exp=\(exp ?? -1)", level: .debug, category: .auth)
      return token
    }

    AppLogging.log("currentAccessToken expired/invalid; checking for refresh token…", level: .debug, category: .auth)

    guard let refresh = Keychain.get(kRefreshToken), !refresh.isEmpty else {
      AppLogging.log("currentAccessToken: no refresh token available; returning nil isAuth=\(isAuthenticated)", level: .debug, category: .auth)
      // In offline-login-only mode, we simply don't have a token for server calls.
      return nil
    }

    let refreshed = await refreshAccessToken()
    AppLogging.log("currentAccessToken after refresh -> \(refreshed != nil ? "obtained" : "nil")", level: .debug, category: .auth)
    return refreshed
  }

  /// Networked sign-out:
  func signOutRemote() async {
    AppLogging.log("signOutRemote -> sending logout request", level: .info, category: .auth)
    let url = projectURL.appendingPathComponent("/auth/v1/logout")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(anonPublicKey, forHTTPHeaderField: "apikey")

    // Use the currently cached token *without* forcing a refresh.
    let token = Keychain.get(kAccessToken)
    if let token,
       Self.isJWTValid(accessToken: token, expSeconds: Keychain.get(kAccessTokenExp).flatMap { Double($0) }) {
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    } else {
      AppLogging.log("signOutRemote: no valid access token; will clear locally.", level: .warn, category: .auth)
    }

    do {
      let (_, resp) = try await session.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
      if code == 204 || (200 ..< 300).contains(code) {
        AppLogging.log("remote logout succeeded (status \(code)).", level: .info, category: .auth)
      } else {
        AppLogging.log("remote logout non-2xx (status \(code)); continuing with local sign out.", level: .warn, category: .auth)
      }
    } catch {
      AppLogging.log("remote logout error: \(error); continuing with local sign out.", level: .error, category: .auth)
    }

    await signOut()
  }

    /// Clears tokens and flips `isAuthenticated` to false (deterministic).
    func signOut() async {
      AppLogging.log("signOut: clearing tokens and flipping isAuthenticated=false", level: .info, category: .auth)
      // Centralized clearing that removes keychain items, UserDefaults, and flips
      // published state on the MainActor before returning.
      await clearStoredTokens()
      // Keep other cleanup
      AuthStore.shared.clear()
      CommunityService.shared.clear()
    }

  // MARK: - Profile / Role
    func loadUserProfile() async {
      AppLogging.log("[Profile] fetch /auth/v1/user", level: .debug, category: .auth)
      guard let token = await currentAccessToken() else {
        AppLogging.log("[Profile] no access token for profile fetch", level: .warn, category: .auth)
        return
      }

      var req = URLRequest(url: projectURL.appendingPathComponent("/auth/v1/user"))
      req.httpMethod = "GET"
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      req.setValue(anonPublicKey, forHTTPHeaderField: "apikey")

      do {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
          let body = String(data: data, encoding: .utf8) ?? ""
          AppLogging.log("[Profile][WARN] non-2xx status=\(code) body=\(body)", level: .warn, category: .auth)
          return
        }

        // Robust decoding for the Supabase user response shape.
        struct UserProfile: Decodable {
          let id: String
          let email: String?
          let user_metadata: UserMetadata?
        }
        struct UserMetadata: Decodable {
          let first_name: String?
          let last_name: String?
          let user_type: String?
          let member_id: String?

          private enum CodingKeys: String, CodingKey {
            case first_name, last_name, user_type, member_id, angler_number
          }

          init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.first_name = try container.decodeIfPresent(String.self, forKey: .first_name)
            self.last_name = try container.decodeIfPresent(String.self, forKey: .last_name)
            self.user_type = try container.decodeIfPresent(String.self, forKey: .user_type)

            // member_id (new) with fallback to angler_number (legacy). May be String or Number.
            if let s = try? container.decodeIfPresent(String.self, forKey: .member_id) {
              self.member_id = s
            } else if let i = try? container.decodeIfPresent(Int.self, forKey: .member_id) {
              self.member_id = String(i)
            } else if let s = try? container.decodeIfPresent(String.self, forKey: .angler_number) {
              self.member_id = s
            } else if let i = try? container.decodeIfPresent(Int.self, forKey: .angler_number) {
              self.member_id = String(i)
            } else {
              self.member_id = nil
            }
          }
        }

        // Log raw user_metadata for debugging
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
          let metaRaw = json["user_metadata"] ?? "<missing>"
          AppLogging.log("[Profile][RAW] user_metadata = \(metaRaw)", level: .info, category: .auth)
        }

        let profile = try JSONDecoder().decode(UserProfile.self, from: data)

        AppLogging.log("[Profile][PARSED] first_name=\(profile.user_metadata?.first_name ?? "<nil>") last_name=\(profile.user_metadata?.last_name ?? "<nil>") user_type=\(profile.user_metadata?.user_type ?? "<nil>") member_id=\(profile.user_metadata?.member_id ?? "<nil>")", level: .info, category: .auth)

        await MainActor.run {
          if let md = profile.user_metadata {
            self.currentFirstName = md.first_name
            self.currentLastName = md.last_name
            if let utype = md.user_type, let ut = UserType(rawValue: utype) {
              self.currentUserType = ut
            } else {
              self.currentUserType = nil
            }
            self.currentMemberId = md.member_id
          } else {
            self.currentFirstName = nil
            self.currentLastName = nil
            self.currentUserType = nil
            self.currentMemberId = nil
          }
          // Persist minimal cached profile for offline use
          UserDefaults.standard.set(self.currentFirstName, forKey: kCachedFirstName)
          UserDefaults.standard.set(self.currentLastName, forKey: kCachedLastName)
          UserDefaults.standard.set(self.currentUserType?.rawValue, forKey: kCachedUserType)
          UserDefaults.standard.set(self.currentMemberId, forKey: kCachedMemberId)
          AppLogging.log("[Offline][ProfileCache] saved first=\(self.currentFirstName ?? "<nil>") last=\(self.currentLastName ?? "<nil>") userType=\(self.currentUserType?.rawValue ?? "<nil>") memberId=\(self.currentMemberId ?? "<nil>")", level: .debug, category: .auth)

          // Default Remember Me ON for every role so all users can sign in
          // offline after a successful first online sign-in. Previously this
          // was role-gated (guides only) which left anglers / researchers /
          // public users locked out after sign-out + network loss because
          // `signOut()` deletes the cached credentials when Remember Me is
          // OFF. Password lives in the Keychain under
          // `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` until an
          // explicit "Forget this device" action clears it.
          if !self.rememberMeEnabled {
            self.rememberMeEnabled = true
            AppLogging.log("[Offline][RememberMe] auto-set on profile load -> true", level: .debug, category: .auth)
          }

          // Ensure offline credentials are recorded after Remember Me is on.
          if self.rememberMeEnabled {
            let hasPw = (Keychain.get(self.kOfflinePasswordKey)?.isEmpty == false)
            if !hasPw, let le = self.lastSignInEmail, let lp = self.lastSignInPassword, !le.isEmpty, !lp.isEmpty {
              self.recordOfflineCredentials(email: le, password: lp)
              AppLogging.log("[Offline] post-profile recordOfflineCredentials (rememberMe=true)", level: .debug, category: .auth)
            }
          }
          // Clear transient password ASAP
          self.lastSignInPassword = nil
        }

      } catch {
        AppLogging.log("[Profile][ERROR] \(error)", level: .error, category: .auth)
      }

      // Supplement with /functions/v1/my-profile — the documented source of
      // truth for firstName/lastName. user_metadata is not reliably populated
      // for members created via admin invite or the members table directly;
      // my-profile joins the members table and returns the canonical values.
      await fetchMyProfileSupplement()
    }

  /// Hits /functions/v1/my-profile and, when it returns usable firstName /
  /// lastName values, writes them into `currentFirstName` / `currentLastName`
  /// and refreshes the offline cache. Safe to call repeatedly; errors are
  /// logged and swallowed so this never blocks the auth flow.
  private func fetchMyProfileSupplement() async {
    guard let token = await currentAccessToken() else {
      AppLogging.log("[Profile][my-profile] no access token; skipping supplement fetch", level: .debug, category: .auth)
      return
    }

    let url = projectURL.appendingPathComponent("/functions/v1/my-profile")
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(anonPublicKey, forHTTPHeaderField: "apikey")

    do {
      let (data, resp) = try await session.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
      let rawBody = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
      AppLogging.log("[Profile][my-profile][RAW] status=\(code) body=\(rawBody)", level: .info, category: .auth)

      guard (200..<300).contains(code) else {
        AppLogging.log("[Profile][my-profile][WARN] non-2xx status=\(code)", level: .warn, category: .auth)
        return
      }

      // Edge function wraps the payload in { "profile": { ... } }. Accept
      // both that shape and a bare top-level object. Accept both camelCase
      // (documented GET response) and snake_case as a belt-and-braces
      // guard against future drift.
      struct ProfileFields: Decodable {
        let firstName: String?
        let lastName: String?
        let memberId: String?

        private enum CodingKeys: String, CodingKey {
          case firstName, lastName, memberId
          case first_name, last_name, member_id
        }

        init(from decoder: Decoder) throws {
          let c = try decoder.container(keyedBy: CodingKeys.self)
          self.firstName = try c.decodeIfPresent(String.self, forKey: .firstName)
            ?? c.decodeIfPresent(String.self, forKey: .first_name)
          self.lastName = try c.decodeIfPresent(String.self, forKey: .lastName)
            ?? c.decodeIfPresent(String.self, forKey: .last_name)
          self.memberId = try c.decodeIfPresent(String.self, forKey: .memberId)
            ?? c.decodeIfPresent(String.self, forKey: .member_id)
        }
      }
      struct MyProfileEnvelope: Decodable {
        let profile: ProfileFields?
      }

      let decoder = JSONDecoder()
      // Try wrapped shape first, fall back to bare object if decode fails
      // or the wrapper is absent.
      let fields: ProfileFields
      if let envelope = try? decoder.decode(MyProfileEnvelope.self, from: data),
         let inner = envelope.profile {
        fields = inner
      } else {
        fields = try decoder.decode(ProfileFields.self, from: data)
      }

      let first = fields.firstName?.trimmingCharacters(in: .whitespacesAndNewlines)
      let last = fields.lastName?.trimmingCharacters(in: .whitespacesAndNewlines)
      let memberId = fields.memberId?.trimmingCharacters(in: .whitespacesAndNewlines)

      AppLogging.log("[Profile][my-profile][PARSED] firstName=\(first ?? "<nil>") lastName=\(last ?? "<nil>") memberId=\(memberId ?? "<nil>")", level: .info, category: .auth)

      await MainActor.run {
        if let first, !first.isEmpty {
          self.currentFirstName = first
          UserDefaults.standard.set(first, forKey: self.kCachedFirstName)
        }
        if let last, !last.isEmpty {
          self.currentLastName = last
          UserDefaults.standard.set(last, forKey: self.kCachedLastName)
        }
        if let memberId, !memberId.isEmpty, (self.currentMemberId ?? "").isEmpty {
          self.currentMemberId = memberId
          UserDefaults.standard.set(memberId, forKey: self.kCachedMemberId)
        }
      }
    } catch {
      AppLogging.log("[Profile][my-profile][ERROR] \(error)", level: .error, category: .auth)
    }
  }

  // MARK: - Update Member ID (for guides using Solo mode)

  /// Updates the current user's member_id in Supabase user_metadata
  /// and refreshes the local cache.
  func updateMemberId(_ id: String) async throws {
    let trimmed = MemberNumber.normalize(id.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !trimmed.isEmpty else {
      throw InputValidationError.invalidInput("Member Number cannot be empty.")
    }

    guard let token = await currentAccessToken() else {
      throw InputValidationError.invalidInput("Session expired. Please sign in again.")
    }

    let url = projectURL.appendingPathComponent("/auth/v1/user")
    var req = URLRequest(url: url)
    req.httpMethod = "PUT"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(anonPublicKey, forHTTPHeaderField: "apikey")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let body: [String: Any] = [
      "data": ["member_id": trimmed]
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0

    guard (200...299).contains(status) else {
      let msg = String(data: data, encoding: .utf8) ?? "<no body>"
      AppLogging.log("[AuthService] updateMemberId failed: HTTP \(status) \(msg)", level: .error, category: .auth)
      throw mapAuthHTTPError(status: status, responseBody: data)
    }

    await MainActor.run {
      self.currentMemberId = trimmed
      UserDefaults.standard.set(trimmed, forKey: kCachedMemberId)
      AppLogging.log("[AuthService] updateMemberId -> \(trimmed)", level: .info, category: .auth)
    }
  }

  // MARK: - Biometric Login

  enum BiometricLoginResult {
    case resumedSession
    case signedInOnline
    case signedInOffline
    case noCredentials
    case authFailed(String)
  }

  // Re-entrancy guard used to prevent concurrent biometric login flows.
  // Marked as non-public; access is serialized via @MainActor on the flows.
  private var isPerformingBiometricLogin: Bool = false

  /// Biometric-protected login flow that assumes the system biometric prompt has already succeeded.
  /// It performs the same logic as `biometricLogin()` but without presenting LAContext.
  @MainActor
  func biometricLoginAfterAuth(authenticationContext: LAContext? = nil) async -> BiometricLoginResult {
    // Prevent concurrent biometric login attempts
    guard !isPerformingBiometricLogin else {
      AppLogging.log("[Biometric] Reentrant biometric login blocked", level: .warn, category: .auth)
      return .authFailed("Another biometric login is already in progress")
    }
    isPerformingBiometricLogin = true
    defer { isPerformingBiometricLogin = false }

    AppLogging.log("[Biometric] biometricLoginAfterAuth: start", level: .debug, category: .auth)

    // Try resume session first if we have stored tokens
    if hasStoredSession {
      let resumed = await resumeSessionIfPossible()
      if resumed {
        AppLogging.log("[Biometric] Resumed session via tokens (after-auth).", level: .info, category: .auth)
        return .resumedSession
      }
      AppLogging.log("[Biometric] Resume failed (after-auth); will try offline credentials path.", level: .debug, category: .auth)
    }

    // Fallback to cached offline credentials (use the provided LAContext if present)
    guard let creds = getOfflineCredentials(authenticationContext: authenticationContext) else {
      AppLogging.log("[Biometric] No cached offline credentials (after-auth).", level: .warn, category: .auth)
      return .noCredentials
    }

    do {
      try await signIn(email: creds.email, password: creds.password)
      AppLogging.log("[Biometric] Signed in online using cached credentials (after-auth).", level: .info, category: .auth)
      return .signedInOnline
    } catch let err as AuthError {
      switch err {
      case .networkUnavailable:
        AppLogging.log("[Biometric] Network unavailable; attempting explicit offline sign-in (after-auth).", level: .warn, category: .auth)
        if canSignInOffline(email: creds.email, password: creds.password) {
          let cachedFirst = UserDefaults.standard.string(forKey: kCachedFirstName)
          let cachedLast = UserDefaults.standard.string(forKey: kCachedLastName)
          let cachedTypeRaw = UserDefaults.standard.string(forKey: kCachedUserType)
          let cachedMid = UserDefaults.standard.string(forKey: kCachedMemberId)
          // We're on MainActor so we can update directly
          self.currentFirstName = cachedFirst
          self.currentLastName = cachedLast
          if let raw = cachedTypeRaw, let t = UserType(rawValue: raw) { self.currentUserType = t }
          self.currentMemberId = cachedMid
          self.isAuthenticated = true

          AppLogging.log("[Biometric][Offline] Restored cached profile (after-auth).", level: .info, category: .auth)
          return .signedInOffline
        } else {
          AppLogging.log("[Biometric][Offline] Cached credentials did not match (after-auth).", level: .warn, category: .auth)
          return .noCredentials
        }
      default:
        AppLogging.log("[Biometric] Sign-in failed with error (after-auth): \(err)", level: .error, category: .auth)
        return .authFailed(err.localizedDescription)
      }
    } catch {
      AppLogging.log("[Biometric] Sign-in threw unexpected error (after-auth): \(error)", level: .error, category: .auth)
      return .authFailed(error.localizedDescription)
    }
  }

  /// Attempts a biometric-protected login path.
  /// Flow:
  /// 1) Authenticate with Face ID/Touch ID (local LAContext).
  /// 2) Delegate to `biometricLoginAfterAuth(authenticationContext:)` so the LAContext can be reused for Keychain reads.
  func biometricLogin() async -> BiometricLoginResult {
    // Step 1: Biometric auth (create ephemeral LAContext)
    let context = LAContext()
    var error: NSError?
    let reason = "Authenticate to login"

    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
      let msg = error?.localizedDescription ?? "Biometrics not available"
      AppLogging.log("[Biometric] Not available: \(msg)", level: .warn, category: .auth)
      return .authFailed(msg)
    }

    do {
      // Using async evaluatePolicy (SDK availability assumed)
      try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
    } catch {
      AppLogging.log("[Biometric] Auth failed: \(error)", level: .warn, category: .auth)
      return .authFailed(error.localizedDescription)
    }

    // Delegate to after-auth flow, passing the same LAContext so Keychain reads can use it.
    return await biometricLoginAfterAuth(authenticationContext: context)
  }

  // MARK: - Debug Helpers (safe to call from UI for diagnostics)

  func getStoredAccessToken() -> String? {
    Keychain.get(kAccessToken)
  }

  func getStoredRefreshToken() -> String? {
    Keychain.get(kRefreshToken)
  }

    // MARK: - Token refresh
    private func refreshAccessToken() async -> String? {
      // If a refresh Task already exists, await it
      if let existing = refreshTask {
        AppLogging.log("[Refresh] awaiting existing refresh task…", level: .debug, category: .auth)
        return await existing.value
      }

      // Create and store a new refresh Task in a synchronized way
      var task: Task<String?, Never>!
      refreshQueue.sync {
        if let existing = refreshTask {
          task = existing
          return
        }
        task = Task<String?, Never> {
          // Ensure we clear the stored task when done
          defer {
            self.refreshQueue.sync { self.refreshTask = nil }
          }

          guard let refreshTok = Keychain.get(self.kRefreshToken), !refreshTok.isEmpty else {
            AppLogging.log("[Refresh] No refresh token available.", level: .warn, category: .auth)
            return nil
          }

          let rPrefix = String(refreshTok.prefix(24))
          AppLogging.log("[Refresh] Attempting refresh_token grant… using refresh prefix=\(rPrefix) len=\(refreshTok.count)", level: .debug, category: .auth)

          // Build URL with query param for grant_type (helps mocks that inspect query)
          var comps = URLComponents(url: self.projectURL.appendingPathComponent("/auth/v1/token"),
                                    resolvingAgainstBaseURL: false)!
          comps.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]

          var req = URLRequest(url: comps.url!)
          req.httpMethod = "POST"
          req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
          req.setValue(self.anonPublicKey, forHTTPHeaderField: "apikey")

          // Build a form-encoded body too (covers mocks that inspect body)
          let encodedRefresh = refreshTok.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refreshTok
          let bodyStr = "grant_type=refresh_token&refresh_token=\(encodedRefresh)"
          req.httpBody = bodyStr.data(using: .utf8)

          func performRequest() async throws -> (Data, URLResponse) {
            try await session.data(for: req)
          }

          do {
            let (data, resp) = try await performRequest()
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

            if (200 ..< 300).contains(code) {
              let token = try JSONDecoder().decode(TokenResponse.self, from: data)

              // Check refresh token rotation and log accordingly
              let currentStoredRefresh = Keychain.get(self.kRefreshToken)
              if token.refresh_token == nil {
                AppLogging.log("[Refresh] No new refresh token provided; preserving existing.", level: .info, category: .auth)
              } else if let newRefresh = token.refresh_token {
                if newRefresh != currentStoredRefresh {
                  AppLogging.log("[Refresh] Refresh token rotated.", level: .info, category: .auth)
                } else {
                  AppLogging.log("[Refresh] Refresh token unchanged.", level: .info, category: .auth)
                }
              }

              // Persist new tokens & expiry
              persistTokens(accessToken: token.access_token, refreshToken: token.refresh_token, expiresIn: token.expires_in)
              AppLogging.log("[Refresh] Success. new access.len=\(token.access_token.count) expIn=\(token.expires_in)s", level: .info, category: .auth)
              // Ensure in-memory authenticated state is updated on main actor
              await MainActor.run { self.isAuthenticated = true }
              return token.access_token
            } else if code == 400 || code == 401 {
              let body = String(data: data, encoding: .utf8) ?? ""
              AppLogging.log("[Refresh][ERROR] Hard failure status=\(code) body=\(body). Clearing tokens.", level: .error, category: .auth)
              // Invalid refresh (e.g., token revoked). Clear stored tokens and mark signed out.
              await handleRefreshFailure()
              return nil
            } else if code == 429 || (code >= 500 && code < 600) {
              let body = String(data: data, encoding: .utf8) ?? ""
              AppLogging.log("[Refresh][WARN] Transient error status=\(code) body=\(body). Retrying once after delay.", level: .warn, category: .auth)
              try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

              // Retry once
              do {
                let (retryData, retryResp) = try await performRequest()
                let retryCode = (retryResp as? HTTPURLResponse)?.statusCode ?? -1
                if (200 ..< 300).contains(retryCode) {
                  let token = try JSONDecoder().decode(TokenResponse.self, from: retryData)

                  // Check refresh token rotation and log accordingly on retry
                  let currentStoredRefresh = Keychain.get(self.kRefreshToken)
                  if token.refresh_token == nil {
                    AppLogging.log("[Refresh] No new refresh token provided; preserving existing.", level: .info, category: .auth)
                  } else if let newRefresh = token.refresh_token {
                    if newRefresh != currentStoredRefresh {
                      AppLogging.log("[Refresh] Refresh token rotated.", level: .info, category: .auth)
                    } else {
                      AppLogging.log("[Refresh] Refresh token unchanged.", level: .info, category: .auth)
                    }
                  }

                  persistTokens(accessToken: token.access_token, refreshToken: token.refresh_token, expiresIn: token.expires_in)
                  AppLogging.log("[Refresh] Retry success. new access.len=\(token.access_token.count) expIn=\(token.expires_in)s", level: .info, category: .auth)
                  await MainActor.run { self.isAuthenticated = true }
                  return token.access_token
                } else {
                  AppLogging.log("[Refresh][WARN] Retry also failed with status \(retryCode). Tokens preserved.", level: .warn, category: .auth)
                  return nil
                }
              } catch {
                AppLogging.log("[Refresh][WARN] Retry network error: \(error). Tokens preserved.", level: .warn, category: .auth)
                return nil
              }
            } else {
              let body = String(data: data, encoding: .utf8) ?? ""
              AppLogging.log("[Refresh][WARN] Unexpected status \(code) body=\(body). Tokens preserved.", level: .warn, category: .auth)
              return nil
            }
          } catch {
            if let uerr = error as? URLError {
              AppLogging.log("[Refresh][ERROR] URLError code=\(uerr.code.rawValue) desc=\(uerr)", level: .error, category: .auth)
            } else {
              AppLogging.log("[Refresh][ERROR] exception: \(error)", level: .error, category: .auth)
            }
            AppLogging.log("[Refresh] Network error; preserving tokens and returning nil.", level: .warn, category: .auth)
            return nil
          }
        }
        self.refreshTask = task
      }

      return await task.value
    }
    
    /// Remove stored tokens directly via the Security framework and reset in-memory auth state.
    private func clearStoredTokens() async {
      AppLogging.log("clearStoredTokens: deleting keychain items and clearing defaults", level: .info, category: .auth)
      let keys: [String] = [
        kAccessToken,
        kRefreshToken,
        kAccessTokenExp
      ]

      for account in keys {
        let query: [CFString: Any] = [
          kSecClass: kSecClassGenericPassword,
          kSecAttrAccount: account
        ]
        // ignore result — we just want the item gone
        SecItemDelete(query as CFDictionary)
      }

      // Conditionally remove offline credentials based on Remember Me
      if !UserDefaults.standard.bool(forKey: kOfflineRememberMeKey) {
        // Remove offline email and password when remember me is OFF
        UserDefaults.standard.removeObject(forKey: kOfflineEmailKey)
        Keychain.delete(kOfflinePasswordKey)
        UserDefaults.standard.removeObject(forKey: kCachedFirstName)
        UserDefaults.standard.removeObject(forKey: kCachedLastName)
        UserDefaults.standard.removeObject(forKey: kCachedUserType)
        UserDefaults.standard.removeObject(forKey: kCachedMemberId)
        AppLogging.log("[Offline] rememberMe=false; cleared cached offline credentials", level: .debug, category: .auth)
        AppLogging.log("[Offline] cleared cached profile (rememberMe=false)", level: .debug, category: .auth)
      } else {
        AppLogging.log("[Offline] rememberMe=true; preserving cached offline credentials on sign out", level: .debug, category: .auth)
        AppLogging.log("[Offline] preserving cached profile on sign out (rememberMe=true)", level: .debug, category: .auth)
      }

      // Update in-memory state on MainActor so callers (and tests) see the effect immediately.
      await MainActor.run {
        self.isAuthenticated = false
        self.currentUserType = nil
        self.currentFirstName = nil
        self.currentLastName = nil
        self.currentMemberId = nil
      }
    }

  // MARK: - Offline helpers

    private func canSignInOffline(email: String, password: String) -> Bool {
      let inputEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let inputPw = password

      let storedEmailRaw = UserDefaults.standard.string(forKey: kOfflineEmailKey)
      let storedPw = Keychain.get(kOfflinePasswordKey)

      let storedEmail = storedEmailRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

      let hasStoredEmail = (storedEmail?.isEmpty == false)
      let hasStoredPw = (storedPw?.isEmpty == false)
      let emailMatches = (storedEmail == inputEmail)
      let pwMatches = (storedPw == inputPw)

      AppLogging.log("[Offline][CHECK] hasStoredEmail=\(hasStoredEmail) hasStoredPw=\(hasStoredPw) emailMatches=\(emailMatches) pwMatches=\(pwMatches) inputPw.len=\(inputPw.count)", level: .debug, category: .auth)

      guard hasStoredEmail, hasStoredPw, emailMatches, pwMatches else { return false }
      return true
    }

    private func recordOfflineCredentials(email: String, password: String) {
      guard rememberMeEnabled else {
        AppLogging.log("[Offline] rememberMe=false; not recording offline credentials", level: .debug, category: .auth)
        return
      }
      UserDefaults.standard.set(email, forKey: kOfflineEmailKey)
      Keychain.set(password, forKey: kOfflinePasswordKey)
      AppLogging.log("[Offline] recordOfflineCredentials for \(email)", level: .debug, category: .auth)
    }

  // MARK: - Refresh failure

    @MainActor
    private func handleRefreshFailure() async {
      // Use the centralized async clear so state updates are deterministic.
      await clearStoredTokens()
      AuthStore.shared.clear()
      CommunityService.shared.clear()
      AppLogging.log("[Refresh] Failed; tokens and community state cleared, isAuthenticated=false.", level: .error, category: .auth)
    }

  // MARK: - Token Handling

    private func persistTokens(accessToken: String, refreshToken: String?, expiresIn: Int) {
      // Store access token (value, forKey:)
      Keychain.set(accessToken, forKey: kAccessToken)

      // Store refresh token if provided
      if let r = refreshToken {
        Keychain.set(r, forKey: kRefreshToken)
      }

      // Store expiry time as seconds since epoch
      let exp = Int(Date().timeIntervalSince1970) + expiresIn
      Keychain.set(String(exp), forKey: kAccessTokenExp)

      AppLogging.log("persistTokens -> access.len=\(accessToken.count) refresh.len=\(refreshToken?.count ?? 0) exp=\(exp)", level: .debug, category: .auth)
    }

  private static func isJWTValid(accessToken: String?, expSeconds: Double?) -> Bool {
    guard let tok = accessToken, !tok.isEmpty else { return false }
    let now = Date().timeIntervalSince1970
    if let exp = expSeconds { return exp - now > 120 } // 120s buffer
    if let jwtExp = decodeJWTExp(tok) { return jwtExp - now > 120 }
    return false
  }

  private static func decodeJWTExp(_ jwt: String) -> Double? {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    let payloadB64 = String(parts[1])
    var base64 = payloadB64.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 {
      base64.append("=")
    }
    guard let data = Data(base64Encoded: base64),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    if let expNumber = obj["exp"] as? NSNumber {
      return expNumber.doubleValue
    } else if let exp = obj["exp"] as? Double {
      return exp
    } else if let exp = obj["exp"] as? Int {
      return Double(exp)
    } else {
      return nil
    }
  }

  // MARK: - Models / Errors

  private struct TokenResponse: Decodable {
    let access_token: String
    let token_type: String
    let expires_in: Int
    let refresh_token: String?
    let user: User?

    struct User: Decodable {
      let id: String
      let email: String?
    }
  }

  enum AuthError: Error, LocalizedError, Equatable {
    case http(code: Int, message: String)
    case invalidCredentials
    case emailNotConfirmed
    case rateLimited
    case networkUnavailable
    case serverUnavailable
    case unknown

    var errorDescription: String? {
      switch self {
      case let .http(code, message):
        // Fallback if we haven't mapped it yet
        return "Auth error (\(code)): \(message)"
      case .invalidCredentials:
        return "That email and password don’t match. Please check your credentials and try again."
      case .emailNotConfirmed:
        return "Please confirm your email to continue. Check your inbox for a confirmation link."
      case .rateLimited:
        return "Too many attempts. Please wait a moment and try again."
      case .networkUnavailable:
        return "You appear to be offline. Please check your connection and try again."
      case .serverUnavailable:
        return "Our servers are temporarily unavailable. Please try again in a little while."
      case .unknown:
        return "Something went wrong. Please try again."
      }
    }

    static func == (lhs: AuthError, rhs: AuthError) -> Bool {
      switch (lhs, rhs) {
      case let (.http(lc, lm), .http(rc, rm)):
        return lc == rc && lm == rm
      case (.invalidCredentials, .invalidCredentials): return true
      case (.emailNotConfirmed, .emailNotConfirmed): return true
      case (.rateLimited, .rateLimited): return true
      case (.networkUnavailable, .networkUnavailable): return true
      case (.serverUnavailable, .serverUnavailable): return true
      case (.unknown, .unknown): return true
      default: return false
      }
    }
  }
}

// MARK: - Face ID / Session helpers

extension AuthService {
  /// True if we have a stored refresh token and can attempt to resume a session.
  var hasStoredSession: Bool {
    Keychain.get("epicwaters.auth.refresh_token") != nil
  }

  /// Cached offline credentials (email & password) if we've logged in at least once.
  /// This overload preserves the original signature and calls the new implementation.
  func getOfflineCredentials() -> (email: String, password: String)? {
    return getOfflineCredentials(authenticationContext: nil)
  }

  /// New: Accepts an optional LAContext so Keychain reads can be done with the same authentication context
  func getOfflineCredentials(authenticationContext: LAContext?) -> (email: String, password: String)? {
    // Email is stored in UserDefaults (unchanged)
    guard let storedEmail = UserDefaults.standard.string(forKey: kOfflineEmailKey),
          !storedEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    let email = storedEmail.trimmingCharacters(in: .whitespacesAndNewlines)

    // If caller supplied an LAContext, attempt to read the password using that context
    if let ctx = authenticationContext {
      // Configure the context to fail instead of prompting again —
      // we expect caller already did the biometric prompt.
      ctx.interactionNotAllowed = true

      var query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrAccount: kOfflinePasswordKey,
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne
      ]
      // Use the same authentication context the caller used to authenticate to Face ID.
      query[kSecUseAuthenticationContext] = ctx

      var result: AnyObject?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecSuccess, let data = result as? Data, let pw = String(data: data, encoding: .utf8), !pw.isEmpty {
        return (email, pw)
      } else {
        AppLogging.log("[Keychain] getOfflineCredentials(authContext) SecItemCopyMatching status=\(status)", level: .debug, category: .auth)
        // Fall through to fallback below (Keychain.get) in case the item wasn't protected with an access control.
      }
    }

    // Fallback: use existing Keychain wrapper (no authentication context)
    if let storedPassword = Keychain.get(kOfflinePasswordKey), !storedPassword.isEmpty {
      return (email, storedPassword)
    }

    return nil
  }

  /// True if we have any cached offline credentials.
  var hasOfflineCredentials: Bool {
    getOfflineCredentials() != nil
  }

  /// Attempts to resume a session using stored tokens.
  @discardableResult
  func resumeSessionIfPossible() async -> Bool {
    guard Keychain.get("epicwaters.auth.refresh_token") != nil else {
      AppLogging.log("[AuthService][Biometric] No stored refresh token; cannot resume session.", level: .debug, category: .auth)
      return false
    }

    AppLogging.log("[AuthService][Biometric] Attempting session resume using stored tokens…", level: .debug, category: .auth)

    guard let token = await currentAccessToken() else {
      AppLogging.log("[AuthService][Biometric] currentAccessToken returned nil; resume failed.", level: .debug, category: .auth)
      return false
    }

    let prefix = String(token.prefix(24))
    AppLogging.log("[AuthService][Biometric] Obtained access token during resume. prefix=\(prefix)", level: .debug, category: .auth)

    await loadUserProfile()
    await MainActor.run {
      self.isAuthenticated = true
    }

    return true
  }
}

// Tiny Keychain wrapper (unchanged)
private enum Keychain {
  @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
      guard let data = value.data(using: .utf8) else { return false }

      // Delete any existing item that matches the account (do NOT include the new value here)
      let deleteQuery: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrAccount: key
      ]
      SecItemDelete(deleteQuery as CFDictionary)

      // Add new item with value + accessibility
      let addQuery: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrAccount: key,
        kSecValueData: data,
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      ]
      let status = SecItemAdd(addQuery as CFDictionary, nil)

      // If it failed because the item already exists for some reason, attempt update as a fallback
      if status == errSecDuplicateItem {
        let updateQuery: [CFString: Any] = [
          kSecClass: kSecClassGenericPassword,
          kSecAttrAccount: key
        ]
        let updateAttrs: [CFString: Any] = [
          kSecValueData: data
        ]
        let ustatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        return ustatus == errSecSuccess
      }

      return status == errSecSuccess
    }

  static func get(_ key: String) -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccount: key,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let str = String(data: data, encoding: .utf8) else { return nil }
    return str
  }

  @discardableResult
  static func delete(_ key: String) -> Bool {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccount: key
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }
}

// MARK: - Cross-Project Token Guard

extension AuthService {
  /// Decodes the `iss` claim from the cached access token and returns its host.
  /// Returns nil if no token is cached or the JWT is malformed.
  private static func projectHostFromCachedAccessToken() -> String? {
    guard let token = Keychain.get("epicwaters.auth.access_token"),
          !token.isEmpty else { return nil }
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var b64 = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64.append("=") }
    guard let data = Data(base64Encoded: b64),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let iss = obj["iss"] as? String,
          let url = URL(string: iss)
    else { return nil }
    return url.host
  }

  /// Wipes cached auth + offline state when the cached access token was issued
  /// for a different Supabase project than this build targets. Prevents
  /// PGRST301 "No suitable key" 401s when developers / TestFlight testers
  /// switch between DEV / STAGE / PROD builds without signing out first.
  /// Safe to call before `AuthService.shared` is accessed — invoke from `App.init`.
  static func wipeAuthIfProjectMismatch() {
    guard let tokenHost = projectHostFromCachedAccessToken() else { return }
    let bundledHost = AppEnvironment.shared.projectURL.host ?? ""
    guard !bundledHost.isEmpty, tokenHost != bundledHost else { return }

    AppLogging.log(
      "[AuthService] project host mismatch: token issued for '\(tokenHost)', build expects '\(bundledHost)'. Wiping cached auth + offline state.",
      level: .warn,
      category: .auth
    )

    let keychainAccounts = [
      "epicwaters.auth.access_token",
      "epicwaters.auth.refresh_token",
      "epicwaters.auth.access_token_exp",
      "OfflineLastPassword",
    ]
    for account in keychainAccounts {
      Keychain.delete(account)
    }
    for key in ["OfflineLastEmail", "CachedFirstName", "CachedLastName", "CachedUserType", "CachedMemberId"] {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
}

// MARK: - JWT Helpers

extension AuthService {
  /// Extracts the Supabase user id (UUID) from a JWT access token's `sub` claim.
  func userId(fromAccessToken token: String) -> String? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var b64 = parts[1]
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 {
      b64.append("=")
    }
    guard
      let data = Data(base64Encoded: b64),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj["sub"] as? String
  }
}
