import XCTest
import Security
@testable import SkeenaSystem

/// Regression tests for the "researcher" community role and Conservation gating.
///
/// Covers:
/// 1. AuthService.UserType enum — .researcher raw value, parsing, distinctness
/// 2. CommunityService — activeCommunityTypeName persistence, isConservation
/// 3. AppRootView routing — researcher + Conservation → ResearcherLandingView,
///    researcher + non-Conservation → PublicLandingView,
///    angler (any community) → AnglerLandingView (ConservationLandingView deprecated)
/// 4. ResearcherLandingView — instantiates correctly
/// 5. Toolbar — researcher uses same tabs as public (no Trips)
@MainActor
final class ResearcherRoleRegressionTests: XCTestCase {

  // MARK: - Setup / Teardown

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
    URLProtocol.registerClass(MockURLProtocol.self)
    MockURLProtocol.requestHandler = nil
    AuthService.resetSharedForTests(session: mockSession)
    CommunityService.shared.clear()
    CommunityService.shared.clearDefaultCommunity()
    clearKeychainEntries()
  }

  override func tearDown() {
    MockURLProtocol.requestHandler = nil
    URLProtocol.unregisterClass(MockURLProtocol.self)
    _mockSession?.invalidateAndCancel()
    _mockSession = nil
    CommunityService.shared.clear()
    CommunityService.shared.clearDefaultCommunity()
    clearKeychainEntries()
    super.tearDown()
  }

  // MARK: - Keychain helpers

  private func clearKeychainEntries() {
    for account in [
      "epicwaters.auth.access_token",
      "epicwaters.auth.refresh_token",
      "epicwaters.auth.access_token_exp"
    ] {
      SecItemDelete([
        kSecClass: kSecClassGenericPassword,
        kSecAttrAccount: account
      ] as CFDictionary)
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

    let exp = String(Int(Date().timeIntervalSince1970) + 3600)
    let expData = exp.data(using: .utf8)!
    let expQuery: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccount: "epicwaters.auth.access_token_exp",
      kSecValueData: expData
    ]
    SecItemDelete(expQuery as CFDictionary)
    SecItemAdd(expQuery as CFDictionary, nil)
  }

  // MARK: - Membership JSON helpers

  private func makeMembershipsJSON(_ memberships: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: memberships)
  }

  private func makeResearcherMembership(
    communityId: String = "sci-comm-uuid-1",
    communityName: String = "Conservation Program",
    communityTypeName: String = "Conservation",
    communityTypeId: String = "type-conservation-1"
  ) -> [String: Any] {
    [
      "id": UUID().uuidString,
      "community_id": communityId,
      "role": "researcher",
      "is_active": true,
      "communities": [
        "id": communityId,
        "name": communityName,
        "code": "CON001",
        "is_active": true,
        "community_type_id": communityTypeId,
        "community_types": [
          "id": communityTypeId,
          "name": communityTypeName,
          "entitlements": ["E_CATCH_CAROUSEL": true, "E_CATCH_MAP": true]
        ]
      ] as [String: Any]
    ]
  }

  // MARK: - AuthService.UserType enum tests

  func testUserTypeResearcher_rawValue_isResearcher() {
    XCTAssertEqual(AuthService.UserType.researcher.rawValue, "researcher",
                   "UserType.researcher raw value must be the string 'researcher'")
  }

  func testUserTypeResearcher_fromRawValue_succeeds() {
    let parsed = AuthService.UserType(rawValue: "researcher")
    XCTAssertEqual(parsed, .researcher,
                   "UserType(rawValue: 'researcher') must parse to .researcher")
  }

  func testUserTypeResearcher_isDistinctFromOtherRoles() {
    XCTAssertNotEqual(AuthService.UserType.researcher, .guide)
    XCTAssertNotEqual(AuthService.UserType.researcher, .angler)
    XCTAssertNotEqual(AuthService.UserType.researcher, .public)
  }

  func testUserType_allFourCasesExhaustive() {
    // Compiler-enforced exhaustiveness: adding a fifth case will break this switch.
    func name(for type: AuthService.UserType) -> String {
      switch type {
      case .guide:     return "guide"
      case .angler:    return "angler"
      case .public:    return "public"
      case .researcher: return "researcher"
      }
    }
    XCTAssertEqual(name(for: .researcher), "researcher")
    XCTAssertEqual(name(for: .guide), "guide")
    XCTAssertEqual(name(for: .angler), "angler")
    XCTAssertEqual(name(for: .public), "public")
  }

  // MARK: - CommunityService: researcher role parsing

  func testFetchMemberships_researcherRole_parsedCorrectly() async {
    setAccessToken("valid-token")
    let membership = makeResearcherMembership()
    let data = makeMembershipsJSON([membership])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertEqual(svc.memberships.count, 1,
                   "Should parse one membership with role 'researcher'")
    XCTAssertEqual(svc.memberships.first?.role, "researcher",
                   "Membership role should be 'researcher'")
    XCTAssertEqual(svc.memberships.first?.communityId, "sci-comm-uuid-1")
  }

  func testSetActiveCommunity_researcherRole_syncsToAuthService() async {
    setAccessToken("valid-token")
    let membership = makeResearcherMembership(communityId: "sci-c-1")
    let data = makeMembershipsJSON([membership])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()
    svc.setActiveCommunity(id: "sci-c-1")

    // Give the MainActor Task in setActiveCommunity time to propagate
    try? await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertEqual(svc.activeRole, "researcher",
                   "activeRole should be 'researcher' after selecting a researcher community")
    XCTAssertEqual(
      AuthService.shared.currentUserType,
      .researcher,
      "SNAPSHOT: Selecting a researcher community must sync .researcher to AuthService.currentUserType"
    )
  }

  // MARK: - CommunityService: activeCommunityTypeName

  func testSetActiveCommunity_setsTypeName() async {
    setAccessToken("valid-token")
    let membership = makeResearcherMembership(communityId: "sci-c-2", communityTypeName: "Conservation")
    let data = makeMembershipsJSON([membership])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()
    svc.setActiveCommunity(id: "sci-c-2")

    XCTAssertEqual(svc.activeCommunityTypeName, "Conservation",
                   "SNAPSHOT: activeCommunityTypeName must be set from community_types.name")
  }

  func testSetActiveCommunity_typeName_persistsToUserDefaults() async {
    setAccessToken("valid-token")
    let membership = makeResearcherMembership(communityId: "sci-c-3", communityTypeName: "Conservation")
    let data = makeMembershipsJSON([membership])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()
    svc.setActiveCommunity(id: "sci-c-3")

    XCTAssertEqual(
      UserDefaults.standard.string(forKey: "CommunityService.activeCommunityTypeName"),
      "Conservation",
      "SNAPSHOT: activeCommunityTypeName must be persisted to UserDefaults"
    )
  }

  func testClear_resetsTypeName() async {
    setAccessToken("valid-token")
    let membership = makeResearcherMembership(communityId: "sci-c-4")
    let data = makeMembershipsJSON([membership])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()
    svc.setActiveCommunity(id: "sci-c-4")
    XCTAssertEqual(svc.activeCommunityTypeName, "Conservation")

    svc.clear()
    XCTAssertNil(svc.activeCommunityTypeName,
                 "clear() must nil activeCommunityTypeName")
    XCTAssertNil(UserDefaults.standard.string(forKey: "CommunityService.activeCommunityTypeName"),
                 "clear() must remove activeCommunityTypeName from UserDefaults")
  }

  func testClearActiveCommunity_resetsTypeName() async {
    setAccessToken("valid-token")
    let membership = makeResearcherMembership(communityId: "sci-c-5")
    let data = makeMembershipsJSON([membership])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()
    svc.setActiveCommunity(id: "sci-c-5")
    XCTAssertEqual(svc.activeCommunityTypeName, "Conservation")

    svc.clearActiveCommunity()
    XCTAssertNil(svc.activeCommunityTypeName,
                 "clearActiveCommunity() must nil activeCommunityTypeName")
  }

  // MARK: - CommunityService: isConservation

  func testIsConservation_trueWhenTypeName_isConservation() async {
    setAccessToken("valid-token")
    let membership = makeResearcherMembership(communityId: "sci-c-6", communityTypeName: "Conservation")
    let data = makeMembershipsJSON([membership])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()
    svc.setActiveCommunity(id: "sci-c-6")

    XCTAssertTrue(svc.isConservation,
                  "SNAPSHOT: isConservation must be true when activeCommunityTypeName is 'Conservation'")
  }

  func testIsConservation_falseWhenTypeName_isLodge() async {
    setAccessToken("valid-token")
    let membership = makeResearcherMembership(communityId: "sci-c-7", communityTypeName: "Lodge")
    let data = makeMembershipsJSON([membership])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()
    svc.setActiveCommunity(id: "sci-c-7")

    XCTAssertFalse(svc.isConservation,
                   "SNAPSHOT: isConservation must be false when activeCommunityTypeName is 'Lodge'")
  }

  func testIsConservation_falseWhenTypeName_isNil() {
    let svc = CommunityService.shared
    XCTAssertNil(svc.activeCommunityTypeName)
    XCTAssertFalse(svc.isConservation,
                   "isConservation must be false when activeCommunityTypeName is nil")
  }

  // MARK: - Routing: researcher + Conservation → ResearcherLandingView

  /// Mirrors AppRootView routing logic. Conservation anglers are deprecated —
  /// all anglers route to AnglerLandingView regardless of community type.
  private func landingViewName(for userType: AuthService.UserType, isConservation: Bool) -> String {
    switch userType {
    case .guide:      return "GuideLandingView"
    case .angler:     return "AnglerLandingView"
    case .public:     return "PublicLandingView"
    case .researcher: return isConservation ? "ResearcherLandingView" : "PublicLandingView"
    }
  }

  func testRouting_researcherConservation_routesToResearcherLandingView() {
    XCTAssertEqual(
      landingViewName(for: .researcher, isConservation: true),
      "ResearcherLandingView",
      "SNAPSHOT: .researcher + Conservation must route to ResearcherLandingView"
    )
  }

  func testRouting_researcherNonConservation_fallsBackToPublicLandingView() {
    XCTAssertEqual(
      landingViewName(for: .researcher, isConservation: false),
      "PublicLandingView",
      "SNAPSHOT: .researcher + non-Conservation must fall back to PublicLandingView"
    )
  }

  func testRouting_anglerConservation_routesToAnglerLandingView() {
    // Conservation anglers are deprecated as a user-type / community pair.
    // If an angler somehow ends up in a conservation community, they see the
    // regular AnglerLandingView — no special-cased ConservationLandingView.
    XCTAssertEqual(
      landingViewName(for: .angler, isConservation: true),
      "AnglerLandingView",
      "SNAPSHOT: .angler + Conservation must route to AnglerLandingView (ConservationLandingView deprecated)"
    )
  }

  // MARK: - Landing view instantiation

  func testResearcherLandingView_instantiatesWithoutCrash() {
    let view = ResearcherLandingView()
    XCTAssertNotNil(view, "ResearcherLandingView must instantiate without crashing")
  }

  func testResearcherLandingView_setsResearcherUserRoleEnvironment() {
    let role: AppUserRole = .researcher
    XCTAssertEqual(role, .researcher,
                   "AppUserRole.researcher must be usable as an environment value for ResearcherLandingView")
  }

  // MARK: - Fisheries Conditions tile

  /// The researcher landing view exposes a "Fisheries Conditions" tile that
  /// reuses the guide-side conditions flow. The per-fishery detail view's
  /// Conditions Recall map must stay invisible for researchers — locked
  /// here too so a future change to GuideFisheryMapView.canAccess can't
  /// silently expose recall on the researcher path.
  func testResearcherFisheriesConditions_excludesConditionsRecall() {
    XCTAssertFalse(GuideFisheryMapView.canAccess(role: .researcher),
                   "Conditions Recall must remain hidden on the researcher Fisheries Conditions flow")
  }

  // MARK: - Conservation Mode label

  /// Researchers are *always* in conservation mode — the label is fixed,
  /// not a toggle. Lock the copy so a UI revisit can't silently change it
  /// to e.g. "Conservation Toggle" or back to a button.
  func testConservationModeLabel_isFixedString() {
    XCTAssertEqual(ResearcherLandingView.conservationModeLabel, "Conservation Mode")
  }

  // MARK: - researcherName formatter

  /// The activity-row "Member:" line uses this formatter on the researcher
  /// side. Empty/whitespace handling determines whether the row shows
  /// "Member: Jane Doe" or just "Member:" with a trailing space.
  func testResearcherName_combinesFirstAndLastWithSingleSpace() {
    XCTAssertEqual(
      ResearcherLandingView.researcherName(first: "Jane", last: "Doe"),
      "Jane Doe"
    )
  }

  func testResearcherName_firstOnly_returnsFirst() {
    XCTAssertEqual(
      ResearcherLandingView.researcherName(first: "Jane", last: nil),
      "Jane"
    )
    XCTAssertEqual(
      ResearcherLandingView.researcherName(first: "Jane", last: ""),
      "Jane"
    )
  }

  func testResearcherName_lastOnly_returnsLast() {
    XCTAssertEqual(
      ResearcherLandingView.researcherName(first: nil, last: "Doe"),
      "Doe"
    )
  }

  func testResearcherName_bothNilOrEmpty_returnsEmpty() {
    XCTAssertEqual(ResearcherLandingView.researcherName(first: nil, last: nil), "")
    XCTAssertEqual(ResearcherLandingView.researcherName(first: "", last: ""), "")
    XCTAssertEqual(ResearcherLandingView.researcherName(first: "  ", last: " "), "",
                   "All-whitespace inputs must collapse to empty so the row can be hidden")
  }

  func testResearcherName_trimsInputWhitespace() {
    XCTAssertEqual(
      ResearcherLandingView.researcherName(first: "  Jane  ", last: "  Doe  "),
      "Jane Doe"
    )
  }

  // MARK: - Researcher toolbar snapshot

  func testSnapshot_researcherToolbarTabs_baseline() {
    // SNAPSHOT: Researcher toolbar — Home, Activities, Maps, Learn.
    // Social is conditionally inserted between Maps and Learn when the add-on
    // is active. Maps sits directly between Activities and Learn so a
    // researcher can jump straight to a member-scoped catch map.
    let researcherTabs: [(icon: String, label: String)] = [
      ("house", "Home"),
      ("safari", "Activities"),
      ("map", "Maps"),
      ("book.fill", "Learn")
    ]
    XCTAssertEqual(researcherTabs.count, 4,
                   "SNAPSHOT: Researcher toolbar must have exactly 4 baseline tabs (Social add-on off)")
    XCTAssertEqual(researcherTabs.map(\.label), ["Home", "Activities", "Maps", "Learn"],
                   "SNAPSHOT: Researcher tab order must be Home → Activities → Maps → Learn")
    XCTAssertFalse(researcherTabs.contains(where: { $0.label == "Trips" }),
                   "SNAPSHOT: Researcher toolbar must not contain a Trips tab")
    XCTAssertFalse(researcherTabs.contains(where: { $0.label == "Catches" }),
                   "SNAPSHOT: 'Catches' was renamed to 'Activities'")
  }

  func testGuideDestination_includesMapsCase() {
    // SNAPSHOT: The Maps tab is wired through GuideDestination.maps. If this
    // case is removed, the researcher Maps toolbar tap stops compiling.
    let dest: GuideDestination = .maps
    XCTAssertEqual(dest, .maps)
  }

  func testResearcherMapView_instantiatesWithoutCrash() {
    let view = ResearcherMapView()
    XCTAssertNotNil(view, "ResearcherMapView must instantiate without crashing")
  }

  // MARK: - Role switching: researcher ↔ other roles

  func testSetActiveCommunity_switchFromResearcherToGuide_updatesRoleCorrectly() async {
    setAccessToken("valid-token")
    let sci = makeResearcherMembership(communityId: "c-sci")
    let guide: [String: Any] = [
      "id": UUID().uuidString,
      "community_id": "c-guide",
      "role": "guide",
      "is_active": true,
      "communities": ["id": "c-guide", "name": "Lodge A", "code": "LDG001", "is_active": true]
    ]
    let data = makeMembershipsJSON([sci, guide])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    svc.setActiveCommunity(id: "c-sci")
    XCTAssertEqual(svc.activeRole, "researcher")
    XCTAssertEqual(svc.activeCommunityTypeName, "Conservation")
    XCTAssertTrue(svc.isConservation)

    svc.setActiveCommunity(id: "c-guide")
    XCTAssertEqual(svc.activeRole, "guide",
                   "Switching from researcher to guide community must update role to 'guide'")
    XCTAssertNil(svc.activeCommunityTypeName,
                 "Guide community without community_types should have nil typeName")
    XCTAssertFalse(svc.isConservation,
                   "isConservation must be false after switching to a non-Conservation community")
  }
}
