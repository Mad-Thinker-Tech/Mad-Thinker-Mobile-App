import XCTest
import Security
@testable import SkeenaSystem

/// Regression tests for CommunitySwitcherView changes:
/// - Community dropdown always visible (even with one community)
/// - "Update Default Community" only shown with multiple communities
/// - "Join a Community" vs "Join Another Community" label logic
/// - Single-community users can still access the join flow
@MainActor
final class CommunitySwitcherRegressionTests: XCTestCase {

  private var _mockSession: URLSession?
  private var mockSession: URLSession {
    if _mockSession == nil {
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [MockURLProtocol.self]
      _mockSession = URLSession(configuration: config)
    }
    return _mockSession!
  }

  override func setUp() {
    super.setUp()
    clearKeychainEntries()
    MockURLProtocol.requestHandler = nil
    URLProtocol.registerClass(MockURLProtocol.self)
    AuthService.resetSharedForTests(session: mockSession)
    CommunityService.shared.clear()
    CommunityService.shared.clearDefaultCommunity()
  }

  override func tearDown() {
    MockURLProtocol.requestHandler = nil
    URLProtocol.unregisterClass(MockURLProtocol.self)
    _mockSession?.invalidateAndCancel()
    _mockSession = nil
    clearKeychainEntries()
    CommunityService.shared.clear()
    CommunityService.shared.clearDefaultCommunity()
    super.tearDown()
  }

  private func clearKeychainEntries() {
    for account in [
      "epicwaters.auth.access_token",
      "epicwaters.auth.refresh_token",
      "epicwaters.auth.access_token_exp"
    ] {
      let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrAccount: account
      ]
      SecItemDelete(query as CFDictionary)
    }
  }

  private func setAccessToken(_ token: String) {
    let data = token.data(using: .utf8)!
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccount: "epicwaters.auth.access_token",
      kSecValueData: data
    ]
    SecItemDelete(query as CFDictionary)
    SecItemAdd(query as CFDictionary, nil)
    let exp = Int(Date().timeIntervalSince1970) + 3600
    let expData = String(exp).data(using: .utf8)!
    let expQuery: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccount: "epicwaters.auth.access_token_exp",
      kSecValueData: expData
    ]
    SecItemDelete(expQuery as CFDictionary)
    SecItemAdd(expQuery as CFDictionary, nil)
  }

  // MARK: - JSON helpers

  private func makeMembershipsJSON(_ memberships: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: memberships)
  }

  private func makeMembership(
    communityId: String = "comm-uuid-1",
    communityName: String = "Emerald Waters Anglers",
    role: String = "guide",
    code: String = "EWA001"
  ) -> [String: Any] {
    [
      "id": UUID().uuidString,
      "community_id": communityId,
      "role": role,
      "is_active": true,
      "communities": [
        "id": communityId,
        "name": communityName,
        "code": code,
        "is_active": true
      ]
    ]
  }

  private func setupMockMemberships(_ memberships: [[String: Any]]) {
    let data = makeMembershipsJSON(memberships)
    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }
  }

  // MARK: - Tests: Dropdown always visible (single community)

  /// Verifies that hasMultipleCommunities is false with one community,
  /// but the toolbar button should still render (no longer gated).
  func testSingleCommunity_hasMultipleCommunitiesIsFalse() async {
    setAccessToken("valid-token")
    setupMockMemberships([makeMembership()])

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertEqual(svc.memberships.count, 1, "Should have exactly one membership")
    XCTAssertFalse(svc.hasMultipleCommunities, "hasMultipleCommunities should be false with one community")
    // The CommunityToolbarButton no longer checks hasMultipleCommunities —
    // it always renders. This test documents the expected state.
  }

  /// Verifies that the active community name is available for single-community
  /// users, so the toolbar button can display it.
  func testSingleCommunity_activeCommunityNameAvailable() async {
    setAccessToken("valid-token")
    setupMockMemberships([makeMembership(communityId: "c1", communityName: "River Lodge")])

    let svc = CommunityService.shared
    await svc.fetchMemberships()
    svc.setActiveCommunity(id: "c1")

    XCTAssertEqual(svc.activeCommunityName, "River Lodge",
                   "Active community name should be available for toolbar display")
  }

  // MARK: - Tests: Dropdown with multiple communities

  func testMultipleCommunities_hasMultipleCommunitiesIsTrue() async {
    setAccessToken("valid-token")
    let m1 = makeMembership(communityId: "c1", communityName: "Lodge A", role: "guide")
    let m2 = makeMembership(communityId: "c2", communityName: "Lodge B", role: "angler")
    setupMockMemberships([m1, m2])

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertEqual(svc.memberships.count, 2)
    XCTAssertTrue(svc.hasMultipleCommunities, "hasMultipleCommunities should be true with two communities")
  }

  // MARK: - Tests: "Update Default Community" visibility logic

  /// With a single community, "Update Default Community" should be hidden.
  /// The view gates this on hasMultipleCommunities.
  func testSingleCommunity_updateDefaultShouldBeHidden() async {
    setAccessToken("valid-token")
    setupMockMemberships([makeMembership()])

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertFalse(svc.hasMultipleCommunities,
                   "hasMultipleCommunities must be false — view hides 'Update Default Community' based on this")
  }

  /// With multiple communities, "Update Default Community" should be visible.
  func testMultipleCommunities_updateDefaultShouldBeVisible() async {
    setAccessToken("valid-token")
    let m1 = makeMembership(communityId: "c1", communityName: "Lodge A")
    let m2 = makeMembership(communityId: "c2", communityName: "Lodge B")
    setupMockMemberships([m1, m2])

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertTrue(svc.hasMultipleCommunities,
                  "hasMultipleCommunities must be true — view shows 'Update Default Community' based on this")
  }

  // MARK: - Tests: Join button label logic

  /// With one community, label should be "Join a Community".
  /// With multiple, label should be "Join Another Community".
  /// Both depend on hasMultipleCommunities.
  func testJoinButtonLabel_singleCommunity() async {
    setAccessToken("valid-token")
    setupMockMemberships([makeMembership()])

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    let expectedLabel = svc.hasMultipleCommunities ? "Join Another Community" : "Join a Community"
    XCTAssertEqual(expectedLabel, "Join a Community",
                   "Single community should show 'Join a Community'")
  }

  func testJoinButtonLabel_multipleCommunities() async {
    setAccessToken("valid-token")
    let m1 = makeMembership(communityId: "c1", communityName: "Lodge A")
    let m2 = makeMembership(communityId: "c2", communityName: "Lodge B")
    setupMockMemberships([m1, m2])

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    let expectedLabel = svc.hasMultipleCommunities ? "Join Another Community" : "Join a Community"
    XCTAssertEqual(expectedLabel, "Join Another Community",
                   "Multiple communities should show 'Join Another Community'")
  }

  // MARK: - Tests: Join flow from single community

  /// A single-community user can join a second community, after which
  /// hasMultipleCommunities should flip to true.
  func testSingleCommunity_afterJoin_becomesMultiple() async throws {
    setAccessToken("valid-token")

    let joinResponse: [String: Any] = [
      "success": true,
      "community_name": "New Lodge",
      "community_id": "c2",
      "role": "angler"
    ]
    let joinData = try JSONSerialization.data(withJSONObject: joinResponse)

    let m1 = makeMembership(communityId: "c1", communityName: "Original Lodge", role: "guide")
    let m1m2 = [
      m1,
      makeMembership(communityId: "c2", communityName: "New Lodge", role: "angler")
    ]
    let initialData = makeMembershipsJSON([m1])
    let postJoinData = makeMembershipsJSON(m1m2)

    var fetchCount = 0
    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/functions/v1/join-community") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, joinData)
      }
      if url.path.contains("/rest/v1/user_communities") {
        fetchCount += 1
        let data = fetchCount <= 1 ? initialData : postJoinData
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertEqual(svc.memberships.count, 1)
    XCTAssertFalse(svc.hasMultipleCommunities, "Should start with single community")

    // Join a second community
    _ = try await svc.joinCommunity(code: "NEW001", memberNumber: "MAD4ZQ7H9", role: "angler")

    XCTAssertEqual(svc.memberships.count, 2, "Should now have two memberships after join")
    XCTAssertTrue(svc.hasMultipleCommunities, "Should now have multiple communities after join")
  }

  // MARK: - Tests: Zero communities edge case

  /// With no communities, hasMultipleCommunities should be false and
  /// the toolbar button still renders (shows fallback community name).
  func testZeroCommunities_handledGracefully() async {
    setAccessToken("valid-token")
    setupMockMemberships([])

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertTrue(svc.memberships.isEmpty)
    XCTAssertFalse(svc.hasMultipleCommunities)
    // activeCommunityName falls back to AppEnvironment.shared.communityName
    XCTAssertFalse(svc.activeCommunityName.isEmpty,
                   "Should have a fallback community name even with no memberships")
  }

  // MARK: - Tests: Switching still works with multiple communities

  func testSwitchCommunity_updatesActiveName() async {
    setAccessToken("valid-token")
    let m1 = makeMembership(communityId: "c1", communityName: "Lodge Alpha", role: "guide")
    let m2 = makeMembership(communityId: "c2", communityName: "Lodge Beta", role: "angler")
    setupMockMemberships([m1, m2])

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    svc.setActiveCommunity(id: "c1")
    XCTAssertEqual(svc.activeCommunityName, "Lodge Alpha")

    svc.setActiveCommunity(id: "c2")
    XCTAssertEqual(svc.activeCommunityName, "Lodge Beta")
    XCTAssertEqual(svc.activeRole, "angler",
                   "Role should update when switching communities")
  }
}
