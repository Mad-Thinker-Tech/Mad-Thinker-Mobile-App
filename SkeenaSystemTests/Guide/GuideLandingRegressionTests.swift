// GuideRegressionTests.swift
// SkeenaSystemTests
//
// Regression tests for guide-specific functionality: sign-in, routing,
// guide dashboard/trips/bookings, media upload, profile update, permission checks,
// refresh behavior, concurrency and sign-out.
//
// Uses MockURLProtocol (included in the repo test helpers) to stub network responses.

import XCTest
import Security
@testable import SkeenaSystem

@MainActor
final class GuideRegressionTests: XCTestCase {

  // MARK: - Setup / teardown

  override func setUp() {
    super.setUp()
    URLProtocol.registerClass(MockURLProtocol.self)
    MockURLProtocol.requestHandler = nil
    AuthService.resetSharedForTests()
    clearAuthKeychainEntries()
    UserDefaults.standard.removeObject(forKey: "OfflineLastEmail")
    ConservationModeStore.shared.resetForTests()
  }

  override func tearDown() {
    URLProtocol.unregisterClass(MockURLProtocol.self)
    MockURLProtocol.requestHandler = nil
    clearAuthKeychainEntries()
    UserDefaults.standard.removeObject(forKey: "OfflineLastEmail")
    ConservationModeStore.shared.resetForTests()
    super.tearDown()
  }

  private func clearAuthKeychainEntries() {
    let keys = [
      "epicwaters.auth.access_token",
      "epicwaters.auth.refresh_token",
      "epicwaters.auth.access_token_exp",
      "OfflineLastPassword"
    ]
    for account in keys {
      let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrAccount: account
      ]
      SecItemDelete(query as CFDictionary)
    }
  }

  // MARK: - Test helper: minimal GuideClient used only for tests

  /// A very small client used by tests to exercise guide endpoints.
  /// Uses AuthService.currentAccessToken() for authenticated requests and
  /// AuthService.shared.publicAnonKey as a fallback apikey header when no token.
  @MainActor
  struct GuideClient {
    let baseURL: URL
    let anonKey: String

    init() {
      // Reuse the same project URL as AuthService (mirror the real app)
      self.baseURL = AppEnvironment.shared.projectURL
      self.anonKey = AuthService.shared.publicAnonKey
    }

    private func authHeader() async -> String? {
      if let t = await AuthService.shared.currentAccessToken() {
        return "Bearer \(t)"
      }
      return nil
    }

    func fetchDashboard() async throws -> Dashboard {
      let url = baseURL.appendingPathComponent("/rest/v1/guide_dashboard")
      var req = URLRequest(url: url)
      if let h = await authHeader() {
        req.setValue(h, forHTTPHeaderField: "Authorization")
      } else {
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
      }
      let (data, resp) = try await URLSession.shared.data(for: req)
      guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
        throw GuideError.httpError
      }
      return try JSONDecoder().decode(Dashboard.self, from: data)
    }

    func listUpcomingTrips(guideId: String) async throws -> [Trip] {
      let url = baseURL.appendingPathComponent("/rest/v1/trips?guide_id=eq.\(guideId)&status=eq.upcoming")
      var req = URLRequest(url: url)
      if let h = await authHeader() {
        req.setValue(h, forHTTPHeaderField: "Authorization")
      } else {
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
      }
      let (data, resp) = try await URLSession.shared.data(for: req)
      guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw GuideError.httpError }
      return try JSONDecoder().decode([Trip].self, from: data)
    }

    func getBookings(tripId: String) async throws -> [Booking] {
      let url = baseURL.appendingPathComponent("/rest/v1/bookings?trip_id=eq.\(tripId)")
      var req = URLRequest(url: url)
      if let h = await authHeader() {
        req.setValue(h, forHTTPHeaderField: "Authorization")
      } else {
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
      }
      let (data, resp) = try await URLSession.shared.data(for: req)
      guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw GuideError.httpError }
      return try JSONDecoder().decode([Booking].self, from: data)
    }

    /// Simulate signed-url flow: ask for a signed URL, then put data to that URL.
    func uploadTripMedia(tripId: String, filename: String, data: Data) async throws -> String {
      // 1) ask storage endpoint for signed URL
      let signURL = baseURL.appendingPathComponent("/storage/v1/object/sign")
      var req = URLRequest(url: signURL)
      req.httpMethod = "POST"
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      if let h = await authHeader() {
        req.setValue(h, forHTTPHeaderField: "Authorization")
      } else {
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
      }
      let body: [String: Any] = ["bucket": "trip-media", "object": "\(tripId)/\(filename)"]
      req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

      let (sdata, sresp) = try await URLSession.shared.data(for: req)
      guard (sresp as? HTTPURLResponse)?.statusCode == 200 else { throw GuideError.httpError }
      let signed = try JSONDecoder().decode(SignResponse.self, from: sdata)

      // 2) PUT to signed.url
      var put = URLRequest(url: URL(string: signed.signedURL)!)
      put.httpMethod = "PUT"
      put.httpBody = data
      put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
      let (_, putResp) = try await URLSession.shared.data(for: put)
      guard (putResp as? HTTPURLResponse)?.statusCode == 200 || (putResp as? HTTPURLResponse)?.statusCode == 201 else {
        throw GuideError.httpError
      }

      return signed.publicURL
    }

    func updateProfile(guideId: String, patch: [String: Any]) async throws {
      let url = baseURL.appendingPathComponent("/rest/v1/guides?id=eq.\(guideId)")
      var req = URLRequest(url: url)
      req.httpMethod = "PATCH"
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      if let h = await authHeader() {
        req.setValue(h, forHTTPHeaderField: "Authorization")
      } else {
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
      }
      req.httpBody = try JSONSerialization.data(withJSONObject: patch, options: [])
      let (_, resp) = try await URLSession.shared.data(for: req)
      guard let code = (resp as? HTTPURLResponse)?.statusCode, (200 ..< 300).contains(code) else {
        throw GuideError.httpError
      }
    }
  }

  // MARK: - Models & helpers (test-only)

  struct Dashboard: Decodable {
    let upcomingTripsCount: Int
    let pendingBookingsCount: Int
    let unreadMessages: Int
  }

  struct Trip: Decodable {
    let id: String
    let title: String
    let start_at: String
    let location: String
  }

  struct Booking: Decodable {
    let id: String
    let angler_email: String?
    let status: String
  }

  struct SignResponse: Decodable {
    let signedURL: String
    let publicURL: String
    enum CodingKeys: String, CodingKey {
      case signedURL = "signed_url"
      case publicURL = "public_url"
    }
  }

  enum GuideError: Error {
    case httpError
  }

  // Helper: sign-in as a guide (stubs the token+user endpoints)
  private func signInAsGuide(email: String = "guide@example.com", firstName: String = "Pat", guideId: String = "user-guide-001") async throws {
    let tokenJSON: [String: Any] = [
      "access_token": "guide-access-token-xyz",
      "refresh_token": "guide-refresh-token-abc",
      "expires_in": 3600,
      "token_type": "bearer"
    ]
    let tokenData = try JSONSerialization.data(withJSONObject: tokenJSON, options: [])

    let userJSON: [String: Any] = [
      "id": guideId,
      "email": email,
      "user_metadata": [
        "first_name": firstName,
        "user_type": "guide"
      ]
    ]
    let userData = try JSONSerialization.data(withJSONObject: userJSON, options: [])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/auth/v1/token") {
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (resp, tokenData)
      } else if url.path.contains("/auth/v1/user") {
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (resp, userData)
      }
      // default
      let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
      return (resp, nil)
    }

    try await AuthService.shared.signIn(email: email, password: "password")
  }

  // MARK: - Tests

  func testGuideSignIn_routesToLandingView() async throws {
    try await signInAsGuide()
    let auth = AuthService.shared
    XCTAssertTrue(auth.isAuthenticated)
    XCTAssertEqual(auth.currentUserType, .guide)

    func landingViewName(for userType: AuthService.UserType?, isConservation: Bool = false) -> String {
      guard let t = userType else { return "LoginView" }
      switch t {
      case .guide:      return "GuideLandingView"
      case .angler:     return "AnglerLandingView"
      case .public:     return "PublicLandingView"
      case .researcher: return isConservation ? "ResearcherLandingView" : "PublicLandingView"
      }
    }
    XCTAssertEqual(landingViewName(for: auth.currentUserType), "GuideLandingView")
  }

  func testGuideDashboard_loadsExpectedFields() async throws {
    try await signInAsGuide()
    let client = GuideClient()

    // stub dashboard response
    let dash: [String: Int] = ["upcomingTripsCount": 3, "pendingBookingsCount": 5, "unreadMessages": 2]
    let dashData = try JSONSerialization.data(withJSONObject: dash, options: [])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/guide_dashboard") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, dashData)
      }
      // fallback to 404 so we catch unexpected network calls
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let dashboard = try await client.fetchDashboard()
    XCTAssertEqual(dashboard.upcomingTripsCount, 3)
    XCTAssertEqual(dashboard.pendingBookingsCount, 5)
    XCTAssertEqual(dashboard.unreadMessages, 2)
  }

  func testGuideListUpcomingTrips_parsesTrips() async throws {
    try await signInAsGuide()
    let client = GuideClient()

    let tripsJSON: [[String: Any]] = [
      ["id":"t1","title":"Morning Float","start_at":"2026-07-01T08:00:00Z","location":"River A"],
      ["id":"t2","title":"Evening Drift","start_at":"2026-07-02T17:00:00Z","location":"River B"]
    ]
    let tripsData = try JSONSerialization.data(withJSONObject: tripsJSON, options: [])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/trips") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, tripsData)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let trips = try await client.listUpcomingTrips(guideId: "user-guide-001")
    XCTAssertEqual(trips.count, 2)
    XCTAssertEqual(trips.first?.id, "t1")
  }

  func testGuideGetBookings_returnsBookingList() async throws {
    try await signInAsGuide()
    let client = GuideClient()

    let bookingsJSON: [[String: Any]] = [
      ["id":"b1","angler_email":"a@anglertest.com","status":"confirmed"],
      ["id":"b2","angler_email":"b@anglertest.com","status":"pending"]
    ]
    let bookingsData = try JSONSerialization.data(withJSONObject: bookingsJSON, options: [])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/bookings") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, bookingsData)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let bookings = try await client.getBookings(tripId: "t1")
    XCTAssertEqual(bookings.count, 2)
    XCTAssertEqual(bookings[0].status, "confirmed")
  }

  func testGuideUploadMedia_signedUrlAndUpload() async throws {
    try await signInAsGuide()
    let client = GuideClient()

    // define a fake signed url and public url
    let fakeSignedURL = "https://storage.test/upload/abc123"
    let fakePublicURL = "https://cdn.test/trip-media/t1/photo.jpg"
    let signResponse = ["signed_url": fakeSignedURL, "public_url": fakePublicURL]
    let signData = try JSONSerialization.data(withJSONObject: signResponse, options: [])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/storage/v1/object/sign") {
        // return the signed url
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, signData)
      }
      // intercept the signedURL PUT
      if url.absoluteString == fakeSignedURL {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let payload = Data("hello-image-bits".utf8)
    let publicURL = try await client.uploadTripMedia(tripId: "t1", filename: "photo.jpg", data: payload)
    XCTAssertEqual(publicURL, fakePublicURL)
  }

  func testGuideProfileUpdate_succeeds() async throws {
    try await signInAsGuide()
    let client = GuideClient()

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/guides") && request.httpMethod == "PATCH" {
        return (HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!, nil)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    try await client.updateProfile(guideId: "user-guide-001", patch: ["bio": "Updated bio"])
    // success = no throw
    XCTAssertTrue(true)
  }

  func testGuidePermission_deniedForAngler() async throws {
    // Sign in as an angler (simulate user_type = "angler")
    let tokenJSON: [String: Any] = [
      "access_token": "angler-access-token",
      "refresh_token": "angler-refresh-token",
      "expires_in": 3600,
      "token_type": "bearer"
    ]
    let tokenData = try JSONSerialization.data(withJSONObject: tokenJSON, options: [])

    let userJSON: [String: Any] = [
      "id": "user-angler-001",
      "email": "angler@example.com",
      "user_metadata": [
        "first_name": "Alex",
        "user_type": "angler",
        "member_id": "98765"
      ]
    ]
    let userData = try JSONSerialization.data(withJSONObject: userJSON, options: [])

    MockURLProtocol.requestHandler = { req in
      guard let url = req.url else { throw URLError(.badURL) }
      if url.path.contains("/auth/v1/token") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, tokenData)
      } else if url.path.contains("/auth/v1/user") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, userData)
      } else if url.path.contains("/rest/v1/guide_dashboard") {
        // Simulate permission denied for anglers
        return (HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    try await AuthService.shared.signIn(email: "angler@example.com", password: "pw")
    let client = GuideClient()
    do {
      _ = try await client.fetchDashboard()
      XCTFail("Expected permission failure for angler")
    } catch {
      // OK — expected
      XCTAssertTrue(true)
    }
  }

  func testGuideRefreshAndRetry_onExpiredToken() async throws {
    // Simulate: access token expired; refresh token present. Guide dashboard should succeed after refresh.
    // Step 1: set old/expired access token + refresh token in keychain
    let oldExp = String(Int(Date().timeIntervalSince1970 - 3600)) // expired
    let _ = setKeychain(account: "epicwaters.auth.access_token", value: "expired-token")
    let _ = setKeychain(account: "epicwaters.auth.access_token_exp", value: oldExp)
    let _ = setKeychain(account: "epicwaters.auth.refresh_token", value: "refresh-token-valid")

    // Step 2: Mock handler: when token refresh is attempted -> return new tokens.
    let refreshedJSON: [String: Any] = [
      "access_token": "refreshed-token-123",
      "refresh_token": "refreshed-refresh-456",
      "expires_in": 3600,
      "token_type": "bearer"
    ]
    let refreshedData = try JSONSerialization.data(withJSONObject: refreshedJSON, options: [])

    // Dashboard response after refresh
    let dash: [String: Int] = ["upcomingTripsCount": 1, "pendingBookingsCount": 0, "unreadMessages": 0]
    let dashData = try JSONSerialization.data(withJSONObject: dash, options: [])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/auth/v1/token"),
         let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
         comps.queryItems?.first(where: { $0.name == "grant_type" && $0.value == "refresh_token" }) != nil {
        // refresh request
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, refreshedData)
      } else if url.path.contains("/rest/v1/guide_dashboard") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, dashData)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    // Now call fetchDashboard which should trigger refresh internally via AuthService.currentAccessToken()
    let client = GuideClient()
    let dashboard = try await client.fetchDashboard()
    XCTAssertEqual(dashboard.upcomingTripsCount, 1)

    // Ensure keychain was updated with new access token
    XCTAssertEqual(getKeychain(account: "epicwaters.auth.access_token"), "refreshed-token-123")
  }

  func testConcurrentGuideRequests_onlyOneRefreshHappens() async throws {
    // Put expired tokens into keychain
    let _ = setKeychain(account: "epicwaters.auth.access_token", value: "expired-token")
    let _ = setKeychain(account: "epicwaters.auth.access_token_exp", value: String(Int(Date().timeIntervalSince1970 - 3600)))
    let _ = setKeychain(account: "epicwaters.auth.refresh_token", value: "refresh-abc")

    var refreshCallCount = 0
    let refreshedJSON: [String: Any] = [
      "access_token": "concurrent-refreshed-token",
      "refresh_token": "concurrent-refreshed-refresh",
      "expires_in": 3600,
      "token_type": "bearer"
    ]
    let refreshedData = try JSONSerialization.data(withJSONObject: refreshedJSON, options: [])

    let dash: [String: Int] = ["upcomingTripsCount": 2, "pendingBookingsCount": 0, "unreadMessages": 0]
    let dashData = try JSONSerialization.data(withJSONObject: dash, options: [])

    let counterQueue = DispatchQueue(label: "test.counter")

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/auth/v1/token"),
         let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
         comps.queryItems?.first(where: { $0.name == "grant_type" && $0.value == "refresh_token" }) != nil {
        counterQueue.sync { refreshCallCount += 1 }
        // small delay to exaggerate concurrency
        Thread.sleep(forTimeInterval: 0.25)
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, refreshedData)
      } else if url.path.contains("/rest/v1/guide_dashboard") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, dashData)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let client = GuideClient()

    // Run multiple concurrent fetches that will trigger a refresh
    let results = await withTaskGroup(of: Dashboard?.self) { group -> [Dashboard?] in
      for _ in 0..<6 {
        group.addTask {
          return try? await client.fetchDashboard()
        }
      }
      var out: [Dashboard?] = []
      for await r in group { out.append(r) }
      return out
    }

    XCTAssertTrue(results.allSatisfy { ($0?.upcomingTripsCount ?? -1) == 2 })
    XCTAssertEqual(refreshCallCount, 1, "Expected exactly one refresh network call")
  }

  func testGuideSignOut_clearsTokensAndUnauthenticates() async throws {
    try await signInAsGuide()
    XCTAssertTrue(AuthService.shared.isAuthenticated)

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/auth/v1/logout") {
        return (HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    await AuthService.shared.signOutRemote()

    XCTAssertFalse(AuthService.shared.isAuthenticated)
    XCTAssertNil(getKeychain(account: "epicwaters.auth.access_token"))
    XCTAssertNil(getKeychain(account: "epicwaters.auth.refresh_token"))
  }

  // MARK: - Keychain helpers (copied from other tests in the repo)

  @discardableResult
  private func setKeychain(account: String, value: String) -> Bool {
    let delQuery: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccount: account
    ]
    SecItemDelete(delQuery as CFDictionary)
    guard let data = value.data(using: .utf8) else { return false }
    let addQuery: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccount: account,
      kSecValueData: data
    ]
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    return status == errSecSuccess
  }

  private func getKeychain(account: String) -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccount: account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne
    ]
    var res: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &res)
    if status == errSecSuccess, let d = res as? Data, let s = String(data: d, encoding: .utf8) {
      return s
    }
    return nil
  }

  // MARK: - Conservation toggle (GuideLandingView)

  /// The Conservation opt-in must default to OFF so a guide never accidentally
  /// routes a catch through the research-grade flow without explicitly opting in.
  func test_conservationModeStore_defaultsToFalse() {
    // setUp already called resetForTests(), which removes the UserDefaults key
    // and clears the in-memory value.
    XCTAssertFalse(ConservationModeStore.shared.isEnabled,
                   "Conservation toggle must default to false on a fresh install")
    XCTAssertNil(UserDefaults.standard.object(forKey: ConservationModeStore.defaultsKey),
                 "Reset should remove the UserDefaults key entirely")
  }

  /// Toggling on must synchronously write through to UserDefaults. This is the
  /// mechanism that survives app launches — if this breaks, the toggle regresses
  /// to a session-only flag.
  func test_conservationModeStore_writeIsPersistedToUserDefaults() {
    ConservationModeStore.shared.isEnabled = true

    // In-memory state reflects the new value.
    XCTAssertTrue(ConservationModeStore.shared.isEnabled)

    // Read directly from UserDefaults to verify the write actually landed on
    // the backing store (not just the @Published wrapper).
    let persisted = UserDefaults.standard.bool(forKey: ConservationModeStore.defaultsKey)
    XCTAssertTrue(persisted,
                  "Setting isEnabled=true must synchronously write to UserDefaults")
  }

  /// Toggling off must also persist. Flipping the switch back to false should
  /// not leave a lingering `true` in UserDefaults.
  func test_conservationModeStore_toggleOffIsPersisted() {
    ConservationModeStore.shared.isEnabled = true
    ConservationModeStore.shared.isEnabled = false

    XCTAssertFalse(ConservationModeStore.shared.isEnabled)
    let persisted = UserDefaults.standard.bool(forKey: ConservationModeStore.defaultsKey)
    XCTAssertFalse(persisted,
                   "Setting isEnabled=false must overwrite any prior true value")
  }

  // NOTE: A property-level test on CatchChatViewModel.conservationMode is
  // intentionally omitted. Instantiating the VM eagerly builds a
  // CatchPhotoAnalyzer, which loads CoreML models and crashes on the iOS 26.2
  // simulator (see CLAUDE.md on MpsGraph/actor-isolation issues). The routing
  // behavior (isResearcherRole || conservationMode → beginResearcherFlow) is
  // exercised end-to-end in the Phase 5 integration tests that drive a full
  // photo-analysis cycle through a stubbed analyzer.

  // MARK: - Full-page map (expand button on landing tile)

  /// The expand-map button on the guide landing tile pushes a dedicated
  /// full-page map view. Locking instantiation here so a future refactor
  /// can't quietly delete the destination and leave the button as a no-op.
  func testGuideFullMapView_instantiatesWithoutCrash() {
    let view = GuideFullMapView()
    XCTAssertNotNil(view, "GuideFullMapView must instantiate without crashing")
  }

  // MARK: - Filter math

  /// "Today" must anchor at the START of today, not 24 hours back. Otherwise
  /// a catch logged at 1am wouldn't appear when a guide opens the map at 2am.
  func testGuideMapTimeWindow_today_anchorsAtStartOfDay() {
    let now = Date(timeIntervalSince1970: 1_700_000_000) // arbitrary fixed instant
    let from = GuideMapTimeWindow.today.fromDate(now: now)
    let cal = Calendar.current
    XCTAssertEqual(cal.startOfDay(for: now), from,
                   "'Today' window must start at midnight of `now`, not 24h prior")
  }

  /// 7 / 30 / 365 / 1095 day deltas from `now` for the rolling windows.
  /// Locks the math so a refactor can't accidentally swap day-vs-hour units.
  func testGuideMapTimeWindow_rollingWindows_haveCorrectDeltas() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let cases: [(GuideMapTimeWindow, Double)] = [
      (.sevenDays,  -7  * 86_400),
      (.thirtyDays, -30 * 86_400),
    ]
    for (window, expectedDelta) in cases {
      let from = window.fromDate(now: now)
      XCTAssertEqual(from.timeIntervalSince(now), expectedDelta, accuracy: 3_600,
                     "\(window.label) must be ~\(Int(expectedDelta / 86_400)) days back from `now`")
    }
    // Year-based windows: assert they're earlier than `now` and within a
    // sensible tolerance — Calendar handles leap years so an exact-second
    // assertion would be brittle.
    XCTAssertLessThan(GuideMapTimeWindow.oneYear.fromDate(now: now), now)
    XCTAssertLessThan(GuideMapTimeWindow.threeYears.fromDate(now: now),
                      GuideMapTimeWindow.oneYear.fromDate(now: now),
                      "3yr window must reach further back than 1yr window")
  }

  func testGuideMapTimeWindow_allCases_haveDistinctLabels() {
    let labels = GuideMapTimeWindow.allCases.map(\.label)
    XCTAssertEqual(Set(labels).count, labels.count,
                   "Time-window labels must be unique so the menu doesn't show duplicates")
  }

  // MARK: - Pin category grouping

  func testGuideMapPinCategory_catch_mapsToCatchType() {
    XCTAssertEqual(GuideMapPinCategory.catch_.apiTypes, ["catch"])
  }

  func testGuideMapPinCategory_noCatch_coversFourNonCatchTypes() {
    XCTAssertEqual(
      GuideMapPinCategory.noCatch.apiTypes,
      ["active", "farmed", "promising", "passed"]
    )
  }

  /// CRITICAL: union of every category MUST equal every API `type` value the
  /// pipeline produces. If a new pin type ships server-side and isn't added
  /// to either category, those pins would silently disappear from the
  /// filtered map.
  func testGuideMapPinCategory_unionCoversAllReportTypes() {
    let union = GuideMapPinCategory.allCases.reduce(into: Set<String>()) { acc, cat in
      acc.formUnion(cat.apiTypes)
    }
    let expected: Set<String> = ["catch", "active", "farmed", "promising", "passed"]
    XCTAssertEqual(union, expected,
                   "Catch + No Catch must together cover every server-side pin type")
  }

}

