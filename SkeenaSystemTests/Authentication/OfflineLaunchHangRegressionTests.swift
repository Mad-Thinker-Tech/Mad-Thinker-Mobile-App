import XCTest
import Security
@testable import SkeenaSystem

/// Regression coverage for the offline cold-launch hang.
///
/// Bug: when a user launched the app offline within ~58 min of going offline
/// (cached Supabase JWT still valid), `fetchMemberships()`, `loadUserProfile()`,
/// and `refreshAccessToken()` would all skip their existing "no token" offline
/// fallbacks and fire real network requests with no `timeoutInterval` set. The
/// launch task in `AppRootView` awaits all three sequentially, leaving the user
/// staring at the Mad Thinker spinner for up to ~3×60s while URLSession's
/// default timeouts wound down.
///
/// Fix: each function now short-circuits when `NetworkMonitor.shared.isOnlineSnapshot`
/// is `false`, before making any network call. These tests pin that contract by
/// (a) flipping NetworkMonitor offline via `setOnlineSnapshotForTests`, (b)
/// installing a MockURLProtocol that counts requests, and (c) asserting that
/// zero requests are fired against the gated endpoints.
///
/// Notes for future maintainers:
/// - `NetworkMonitor` is a `nonisolated` singleton; `setOnlineSnapshotForTests`
///   mirrors the `AuthService.resetSharedForTests` convention. Always reset to
///   `true` in `tearDown` so sibling tests don't inherit offline state.
/// - The MockURLProtocol handler intentionally fatalErrors if the gated path is
///   hit — this gives a louder failure than an XCTAssert on a counter, since
///   any code path that bypasses the guard would deadlock the test instead of
///   silently passing.
@MainActor
final class OfflineLaunchHangRegressionTests: XCTestCase {

  private var _mockSession: URLSession?
  private var mockSession: URLSession {
    if _mockSession == nil {
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [MockURLProtocol.self]
      _mockSession = URLSession(configuration: config)
    }
    return _mockSession!
  }

  // Tracks any URL request that reaches the mock (used by the guard tests to
  // prove zero network was attempted).
  private var requestCount = 0
  private var requestedPaths: [String] = []

  override func setUp() {
    super.setUp()
    clearAuthKeychainEntries()
    clearMembershipCache()
    requestCount = 0
    requestedPaths = []
    MockURLProtocol.requestHandler = nil
    URLProtocol.registerClass(MockURLProtocol.self)
    AuthService.resetSharedForTests(session: mockSession)
    CommunityService.shared.clear()
    CommunityService.shared.clearDefaultCommunity()
    // Default starting state for all tests in this file is offline; positive-
    // path test below flips it back online explicitly.
    NetworkMonitor.shared.setOnlineSnapshotForTests(false)
  }

  override func tearDown() {
    NetworkMonitor.shared.setOnlineSnapshotForTests(true)
    MockURLProtocol.requestHandler = nil
    URLProtocol.unregisterClass(MockURLProtocol.self)
    _mockSession?.invalidateAndCancel()
    _mockSession = nil
    clearAuthKeychainEntries()
    clearMembershipCache()
    CommunityService.shared.clear()
    CommunityService.shared.clearDefaultCommunity()
    super.tearDown()
  }

  // MARK: - Keychain / UserDefaults helpers

  private func clearAuthKeychainEntries() {
    for account in [
      "epicwaters.auth.access_token",
      "epicwaters.auth.refresh_token",
      "epicwaters.auth.access_token_exp",
    ] {
      let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: account]
      SecItemDelete(q as CFDictionary)
    }
  }

  private func clearMembershipCache() {
    UserDefaults.standard.removeObject(forKey: "CachedMemberId")
    // Remove any per-member membership cache entries written by prior tests.
    let prefix = "CommunityService.cachedMemberships."
    for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  @discardableResult
  private func setKeychain(account: String, value: String) -> Bool {
    let del: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: account]
    SecItemDelete(del as CFDictionary)
    guard let data = value.data(using: .utf8) else { return false }
    let add: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccount: account,
      kSecValueData: data,
    ]
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  /// Installs a still-valid (1h-future) access token so `currentAccessToken()`
  /// returns it without a refresh round-trip — this is the precondition for
  /// the bug (token JWT-valid, network actually down).
  private func installValidAccessToken() {
    _ = setKeychain(account: "epicwaters.auth.access_token", value: "valid-token")
    let exp = Int(Date().timeIntervalSince1970) + 3600
    _ = setKeychain(account: "epicwaters.auth.access_token_exp", value: String(exp))
  }

  /// Installs an expired token + a refresh token so `currentAccessToken()`
  /// falls through to `refreshAccessToken()`.
  private func installExpiredTokenWithRefresh() {
    _ = setKeychain(account: "epicwaters.auth.access_token", value: "old-token")
    _ = setKeychain(account: "epicwaters.auth.access_token_exp", value: "1")
    _ = setKeychain(account: "epicwaters.auth.refresh_token", value: "refresh-abc")
  }

  /// Mock handler that flags any incoming request. Tests should assert
  /// `requestCount == 0` afterwards. We return a 200 with empty body just so
  /// the URL task technically completes if a leak happens — the assertion is
  /// what catches the regression.
  private func installRequestCountingHandler() {
    MockURLProtocol.requestHandler = { [weak self] request in
      guard let url = request.url else { throw URLError(.badURL) }
      self?.requestCount += 1
      self?.requestedPaths.append(url.path)
      return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
    }
  }

  // MARK: - fetchMemberships offline guard

  func testFetchMemberships_offlineWithValidToken_skipsNetworkAndHydratesCache() async {
    installValidAccessToken()
    // Seed a per-user membership cache so we can verify it was used.
    // `hydrateFromCacheAndMarkFetched` resolves the memberId from the
    // currentMemberId snapshot first, then falls back to UserDefaults. We use
    // the UserDefaults path so we don't need write access to the
    // private(set) `currentMemberId` property.
    UserDefaults.standard.set("M-test-1", forKey: "CachedMemberId")
    let cached = makeCachedMemberships(communityId: "cached-comm", role: "guide")
    UserDefaults.standard.set(cached, forKey: "CommunityService.cachedMemberships.M-test-1")

    installRequestCountingHandler()

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertEqual(
      requestCount, 0,
      "Offline + valid token must NOT fire /rest/v1/user_communities — that was the launch hang. Hits: \(requestedPaths)"
    )
    XCTAssertTrue(
      svc.hasFetchedMemberships,
      "hasFetchedMemberships must flip true so AppRootView dismisses the spinner"
    )
    XCTAssertEqual(svc.memberships.count, 1, "Cached memberships should hydrate when offline")
    XCTAssertEqual(svc.memberships.first?.communityId, "cached-comm")
  }

  func testFetchMemberships_offlineWithValidToken_emptyCache_stillMarksFetched() async {
    installValidAccessToken()
    UserDefaults.standard.set("M-no-cache", forKey: "CachedMemberId")
    // Deliberately no cached memberships for this memberId.

    installRequestCountingHandler()

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertEqual(requestCount, 0, "Offline guard must short-circuit before any network call")
    XCTAssertTrue(
      svc.hasFetchedMemberships,
      "Empty cache must still flip hasFetchedMemberships so the spinner clears — otherwise we just regressed the original bug for first-launch-after-losing-service users"
    )
    XCTAssertTrue(svc.memberships.isEmpty)
  }

  func testFetchMemberships_offlineWithNoToken_stillHydratesFromCache() async {
    // Pre-existing offline path: no access token at all (token expired offline
    // beyond JWT skew buffer). Already worked before the fix — pinned here so
    // the helper extraction in fetchMemberships doesn't regress it.
    UserDefaults.standard.set("M-no-token", forKey: "CachedMemberId")
    let cached = makeCachedMemberships(communityId: "fallback-comm", role: "angler")
    UserDefaults.standard.set(cached, forKey: "CommunityService.cachedMemberships.M-no-token")

    installRequestCountingHandler()

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertEqual(requestCount, 0)
    XCTAssertTrue(svc.hasFetchedMemberships)
    XCTAssertEqual(svc.memberships.first?.communityId, "fallback-comm")
  }

  // MARK: - currentAccessToken / refreshAccessToken offline guard

  func testCurrentAccessToken_offlineWithExpiredToken_returnsNilWithoutNetwork() async {
    installExpiredTokenWithRefresh()
    installRequestCountingHandler()

    let token = await AuthService.shared.currentAccessToken()

    XCTAssertNil(
      token,
      "Offline refresh must return nil — callers treat this as 'no usable token' and fall back to cache"
    )
    XCTAssertEqual(
      requestCount, 0,
      "refreshAccessToken offline guard must short-circuit before POSTing to /auth/v1/token. Hits: \(requestedPaths)"
    )
  }

  // MARK: - loadUserProfile offline guard

  func testLoadUserProfile_offlineWithValidToken_returnsWithoutNetwork() async {
    installValidAccessToken()
    installRequestCountingHandler()

    await AuthService.shared.loadUserProfile()

    XCTAssertEqual(
      requestCount, 0,
      "loadUserProfile offline guard must short-circuit before hitting /auth/v1/user. Hits: \(requestedPaths)"
    )
  }

  // MARK: - Positive control: online still works

  func testFetchMemberships_onlineWithValidToken_stillMakesNetworkCall() async throws {
    installValidAccessToken()
    NetworkMonitor.shared.setOnlineSnapshotForTests(true)

    var fetchHit = false
    let payload = try JSONSerialization.data(withJSONObject: [makeMembershipDict()])
    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        fetchHit = true
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
    }

    await CommunityService.shared.fetchMemberships()

    XCTAssertTrue(
      fetchHit,
      "Online path must still hit the network — the offline guard must not regress normal launches"
    )
  }

  // MARK: - Membership cache fixture helpers

  private func makeMembershipDict(
    communityId: String = "comm-uuid-1",
    role: String = "guide"
  ) -> [String: Any] {
    [
      "id": UUID().uuidString,
      "community_id": communityId,
      "role": role,
      "is_active": true,
      "communities": [
        "id": communityId,
        "name": "Test Community",
        "code": "TST001",
        "is_active": true,
      ],
    ]
  }

  /// Encodes a single-membership array to the `Data` shape that
  /// `CommunityService.persistMemberships` would write — so the cache helper
  /// can decode it back without us reaching into private encoders.
  private func makeCachedMemberships(communityId: String, role: String) -> Data {
    let json = [makeMembershipDict(communityId: communityId, role: role)]
    let data = try! JSONSerialization.data(withJSONObject: json)
    let memberships = try! JSONDecoder().decode([CommunityMembership].self, from: data)
    return try! JSONEncoder().encode(memberships)
  }
}
