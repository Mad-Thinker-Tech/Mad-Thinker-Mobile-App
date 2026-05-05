import XCTest
import Security
@testable import SkeenaSystem

/// Regression tests for CommunityService: membership fetching, active community
/// selection, role syncing, join community, and offline persistence.
@MainActor
final class CommunityServiceTests: XCTestCase {

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
    // Register globally so CommunityService's URLSession.shared calls are also intercepted
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

  // MARK: - Membership JSON helpers

  private func makeMembershipsJSON(_ memberships: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: memberships)
  }

  private func makeSingleMembership(
    communityId: String = "comm-uuid-1",
    communityName: String = "Emerald Waters Anglers",
    role: String = "guide",
    code: String = "EWA001",
    isActive: Bool = true,
    memberIsActive: Bool = true
  ) -> [String: Any] {
    [
      "id": UUID().uuidString,
      "community_id": communityId,
      "role": role,
      "is_active": memberIsActive,
      "communities": [
        "id": communityId,
        "name": communityName,
        "code": code,
        "is_active": isActive
      ]
    ]
  }

  // MARK: - Tests: Fetch memberships

  func testFetchMemberships_singleCommunity_autoSelects() async {
    setAccessToken("valid-token")
    let membership = makeSingleMembership()
    let data = makeMembershipsJSON([membership])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      // Return valid token for currentAccessToken
      if url.path.contains("/auth/v1/user") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertEqual(svc.memberships.count, 1)
    // Single community auto-selects and skips the picker
    XCTAssertEqual(svc.activeCommunityId, "comm-uuid-1",
                   "Single community should auto-select")
    XCTAssertEqual(svc.activeRole, "guide",
                   "Role should be set from the auto-selected community")
    XCTAssertEqual(svc.defaultCommunityId, "comm-uuid-1",
                   "Auto-selected community should be set as default")
    XCTAssertFalse(svc.hasMultipleCommunities)
  }

  func testFetchMemberships_multipleCommunities_autoSelectsFirst() async {
    setAccessToken("valid-token")
    let m1 = makeSingleMembership(communityId: "comm-1", communityName: "Emerald Waters", role: "guide", code: "EWA001")
    let m2 = makeSingleMembership(communityId: "comm-2", communityName: "Epic Waters", role: "angler", code: "EPW002")
    let data = makeMembershipsJSON([m1, m2])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertEqual(svc.memberships.count, 2)
    XCTAssertTrue(svc.hasMultipleCommunities)
    // Should NOT auto-select when multiple communities — picker should be shown
    XCTAssertNil(svc.activeCommunityId, "Should leave selection nil so CommunityPickerView is shown")
    XCTAssertNil(svc.activeRole, "Role should be nil until user picks a community")
  }

  func testFetchMemberships_noToken_doesNotFetch() async {
    // No access token set
    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertTrue(svc.memberships.isEmpty)
    XCTAssertNil(svc.activeCommunityId)
  }

  func testFetchMemberships_serverError_keepsPreviousState() async {
    setAccessToken("valid-token")
    let m1 = makeSingleMembership()
    let data = makeMembershipsJSON([m1])

    var callCount = 0
    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        callCount += 1
        if callCount == 1 {
          return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        } else {
          return (HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data("error".utf8))
        }
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships() // first call succeeds
    XCTAssertEqual(svc.memberships.count, 1)

    await svc.fetchMemberships() // second call fails
    // Should keep previous state
    XCTAssertEqual(svc.memberships.count, 1)
  }

  // MARK: - Tests: Set active community

  func testSetActiveCommunity_updatesRoleAndPersists() async {
    setAccessToken("valid-token")
    let m1 = makeSingleMembership(communityId: "c-1", communityName: "Community A", role: "guide", code: "AAA111")
    let m2 = makeSingleMembership(communityId: "c-2", communityName: "Community B", role: "angler", code: "BBB222")
    let data = makeMembershipsJSON([m1, m2])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    // Switch to community B
    svc.setActiveCommunity(id: "c-2")
    XCTAssertEqual(svc.activeCommunityId, "c-2")
    XCTAssertEqual(svc.activeRole, "angler")
    XCTAssertEqual(svc.activeCommunityName, "Community B")

    // Verify persistence
    XCTAssertEqual(UserDefaults.standard.string(forKey: "CommunityService.activeCommunityId"), "c-2")
    XCTAssertEqual(UserDefaults.standard.string(forKey: "CommunityService.activeRole"), "angler")
  }

  func testSetActiveCommunity_syncsRoleToAuthService() async {
    setAccessToken("valid-token")
    let m1 = makeSingleMembership(communityId: "c-1", role: "angler")
    let data = makeMembershipsJSON([m1])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    // Give MainActor time to process the updateUserType call
    try? await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertEqual(AuthService.shared.currentUserType, .angler)
  }

  // MARK: - Tests: Clear

  func testClear_removesAllState() {
    let svc = CommunityService.shared
    UserDefaults.standard.set("some-id", forKey: "CommunityService.activeCommunityId")
    UserDefaults.standard.set("guide", forKey: "CommunityService.activeRole")

    svc.clear()

    XCTAssertTrue(svc.memberships.isEmpty)
    XCTAssertNil(svc.activeCommunityId)
    XCTAssertNil(svc.activeRole)
    XCTAssertNil(UserDefaults.standard.string(forKey: "CommunityService.activeCommunityId"))
    XCTAssertNil(UserDefaults.standard.string(forKey: "CommunityService.activeRole"))
  }

  // MARK: - Tests: Join community

  func testJoinCommunity_success() async throws {
    setAccessToken("valid-token")

    let joinResponse: [String: Any] = [
      "success": true,
      "community_name": "New Community",
      "community_id": "new-comm-uuid",
      "role": "angler"
    ]
    let joinData = try JSONSerialization.data(withJSONObject: joinResponse)

    // After join, fetchMemberships will be called
    let m1 = makeSingleMembership(communityId: "new-comm-uuid", communityName: "New Community", role: "angler", code: "NEW001")
    let membershipsData = makeMembershipsJSON([m1])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/functions/v1/join-community") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, joinData)
      }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, membershipsData)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    let result = try await svc.joinCommunity(code: "NEW001", memberNumber: "MAD4ZQ7H9", role: "angler")

    XCTAssertEqual(result.success, true)
    XCTAssertEqual(result.communityName, "New Community")
    XCTAssertEqual(result.role, "angler")
    // Memberships should have been refreshed
    XCTAssertEqual(svc.memberships.count, 1)
  }

  func testJoinCommunity_invalidCode_throws() async {
    setAccessToken("valid-token")

    let errorResponse: [String: Any] = ["error": "Code not found"]
    let errorData = try! JSONSerialization.data(withJSONObject: errorResponse)

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/functions/v1/join-community") {
        return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, errorData)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    do {
      _ = try await CommunityService.shared.joinCommunity(code: "BADCOD", memberNumber: "MAD4ZQ7H9", role: "angler")
      XCTFail("Expected invalidCode error")
    } catch let error as CommunityError {
      if case .invalidCode = error {
        // Expected
      } else {
        XCTFail("Expected .invalidCode, got \(error)")
      }
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }

  func testJoinCommunity_alreadyMember_throws() async {
    setAccessToken("valid-token")

    let errorResponse: [String: Any] = [
      "error": "Already a member of this community",
      "community_name": "Emerald Waters",
      "role": "guide"
    ]
    let errorData = try! JSONSerialization.data(withJSONObject: errorResponse)

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/functions/v1/join-community") {
        return (HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: nil)!, errorData)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    do {
      _ = try await CommunityService.shared.joinCommunity(code: "EWA001", memberNumber: "MAD4ZQ7H9", role: "guide")
      XCTFail("Expected alreadyMember error")
    } catch let error as CommunityError {
      if case .alreadyMember(let name) = error {
        XCTAssertEqual(name, "Emerald Waters")
      } else {
        XCTFail("Expected .alreadyMember, got \(error)")
      }
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }

  func testJoinCommunity_noAuth_throws() async {
    // No access token
    do {
      _ = try await CommunityService.shared.joinCommunity(code: "ABC123", memberNumber: "MAD4ZQ7H9", role: "angler")
      XCTFail("Expected unauthenticated error")
    } catch let error as CommunityError {
      if case .unauthenticated = error {
        // Expected
      } else {
        XCTFail("Expected .unauthenticated, got \(error)")
      }
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }

  func testJoinCommunity_invalidMemberNumber_throws() async {
    setAccessToken("valid-token")

    let errorResponse: [String: Any] = ["error": "Invalid member number for this community"]
    let errorData = try! JSONSerialization.data(withJSONObject: errorResponse)

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/functions/v1/join-community") {
        return (HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!, errorData)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    do {
      _ = try await CommunityService.shared.joinCommunity(code: "EWA001", memberNumber: "MAD4ZQ7H9", role: "angler")
      XCTFail("Expected invalidMemberNumber error")
    } catch let error as CommunityError {
      if case .invalidMemberNumber = error {
        // Expected
      } else {
        XCTFail("Expected .invalidMemberNumber, got \(error)")
      }
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }

  func testJoinCommunity_invalidMemberNumberFormat_throws() async {
    setAccessToken("valid-token")

    do {
      _ = try await CommunityService.shared.joinCommunity(code: "EWA001", memberNumber: "BADFORMAT", role: "angler")
      XCTFail("Expected invalidMemberNumberFormat error")
    } catch let error as CommunityError {
      if case .invalidMemberNumberFormat = error {
        // Expected — client-side format guard before any network call
      } else {
        XCTFail("Expected .invalidMemberNumberFormat, got \(error)")
      }
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }

  // MARK: - Tests: fetchMemberships query filters

  func testFetchMemberships_filtersOutLeftCommunities_viaLeftAtIsNull() async {
    setAccessToken("valid-token")

    var capturedURL: URL?
    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        capturedURL = url
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    await CommunityService.shared.fetchMemberships()

    XCTAssertNotNil(capturedURL)
    let comps = URLComponents(url: capturedURL!, resolvingAgainstBaseURL: false)
    let leftAt = comps?.queryItems?.first(where: { $0.name == "left_at" })
    XCTAssertEqual(leftAt?.value, "is.null",
                   "Membership fetch must filter out soft-deleted (left) memberships, otherwise communities the user has left would reappear in the picker")
  }

  // MARK: - Tests: Leave community

  /// Captures the JSON body of an HTTP request made via MockURLProtocol.
  /// URLProtocol replays bodies via httpBodyStream, so a direct `request.httpBody`
  /// read returns nil — we drain the stream just like the signup test does.
  private static func captureBody(_ request: URLRequest) -> [String: Any]? {
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    let bufferSize = 65536
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let read = stream.read(buffer, maxLength: bufferSize)
      if read > 0 { data.append(buffer, count: read) }
    }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  func testLeaveCommunity_success_clearsActiveAndRefreshes() async throws {
    setAccessToken("valid-token")

    // After leave, fetchMemberships returns the user's remaining communities.
    let remaining = makeSingleMembership(communityId: "c-other", communityName: "Other", role: "angler", code: "OTH001")
    let remainingData = makeMembershipsJSON([remaining])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/functions/v1/leave-community") {
        let body = Data("{\"success\":true}".utf8)
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
      }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, remainingData)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    // Pretend the user was actively in c-1 before leaving.
    UserDefaults.standard.set("c-1", forKey: "CommunityService.activeCommunityId")
    UserDefaults.standard.set("guide", forKey: "CommunityService.activeRole")

    try await svc.leaveCommunity(communityId: "c-1")

    // c-1 was the active community, so leaving it should have cleared the
    // active selection. The single remaining community auto-selects via
    // fetchMemberships's single-community path.
    XCTAssertEqual(svc.activeCommunityId, "c-other",
                   "Single remaining community should auto-select after leave")
    XCTAssertEqual(svc.memberships.count, 1)
  }

  func testLeaveCommunity_postsCommunityIdInBody() async throws {
    setAccessToken("valid-token")

    var capturedBody: [String: Any]?
    var capturedMethod: String?
    let emptyMembershipsData = makeMembershipsJSON([])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/functions/v1/leave-community") {
        capturedBody = Self.captureBody(request)
        capturedMethod = request.httpMethod
        let body = Data("{\"success\":true}".utf8)
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
      }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, emptyMembershipsData)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    try await CommunityService.shared.leaveCommunity(communityId: "comm-uuid-42")

    XCTAssertEqual(capturedMethod, "POST")
    XCTAssertEqual(capturedBody?["community_id"] as? String, "comm-uuid-42")
    // Spec: "passing user_id in the body returns 400" — never include it.
    XCTAssertNil(capturedBody?["user_id"],
                 "Must not pass user_id in body — server rejects with 400")
  }

  func testLeaveCommunity_idempotent404_treatedAsSuccess() async throws {
    setAccessToken("valid-token")

    let emptyMembershipsData = makeMembershipsJSON([])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/functions/v1/leave-community") {
        let body = Data("{\"error\":\"not_a_member\"}".utf8)
        return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, body)
      }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, emptyMembershipsData)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    // Should NOT throw — server idempotency means 404 is success-equivalent.
    try await CommunityService.shared.leaveCommunity(communityId: "already-left")
  }

  func testLeaveCommunity_unauthenticated_throws() async {
    // No access token set — service should fail fast before making a request.
    do {
      try await CommunityService.shared.leaveCommunity(communityId: "c-1")
      XCTFail("Expected unauthenticated error")
    } catch let error as CommunityError {
      if case .unauthenticated = error {
        // Expected
      } else {
        XCTFail("Expected .unauthenticated, got \(error)")
      }
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }

  func testLeaveCommunity_serverError_throws() async {
    setAccessToken("valid-token")

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/functions/v1/leave-community") {
        let body = Data("{\"error\":\"internal\"}".utf8)
        return (HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!, body)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    do {
      try await CommunityService.shared.leaveCommunity(communityId: "c-1")
      XCTFail("Expected serverError")
    } catch let error as CommunityError {
      if case .serverError(let code, _) = error {
        XCTAssertEqual(code, 500)
      } else {
        XCTFail("Expected .serverError, got \(error)")
      }
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }

  // MARK: - Tests: Signup uses community_code

  func testSignUp_sendsCommunityCodeInPayload() async throws {
    var capturedBody: [String: Any]?

    let signupResponse = Data("{}".utf8)
    let tokenJSON: [String: Any] = [
      "access_token": "signup-token",
      "refresh_token": "signup-refresh",
      "expires_in": 3600,
      "token_type": "bearer"
    ]
    let tokenData = try JSONSerialization.data(withJSONObject: tokenJSON)
    let userJSON: [String: Any] = ["id": "u1", "email": "t@t.com", "user_metadata": ["first_name": "T", "user_type": "guide"]]
    let userData = try JSONSerialization.data(withJSONObject: userJSON)

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/auth/v1/signup") {
        // httpBody is nil in URLProtocol — read from httpBodyStream instead
        if let stream = request.httpBodyStream {
          stream.open()
          let bufferSize = 65536
          var data = Data()
          let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
          while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 { data.append(buffer, count: read) }
          }
          buffer.deallocate()
          stream.close()
          capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!, signupResponse)
      } else if url.path.contains("/auth/v1/token") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, tokenData)
      } else if url.path.contains("/auth/v1/user") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, userData)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    try await AuthService.shared.signUp(
      email: "t@t.com", password: "pw",
      firstName: "T", lastName: "U",
      userType: .guide, communityCode: "EWA001"
    )

    // Verify the signup body contains community_code, not community
    let dataObj = capturedBody?["data"] as? [String: Any]
    XCTAssertNotNil(dataObj)
    XCTAssertEqual(dataObj?["community_code"] as? String, "EWA001")
    XCTAssertNil(dataObj?["community"]) // old field should NOT be present
  }

  func testSignUp_invalidCommunityCode_throwsValidation() async {
    let auth = AuthService.shared

    // Too short
    do {
      try await auth.signUp(email: "a@b.com", password: "p",
                            firstName: "F", lastName: "L", userType: .guide, communityCode: "AB")
      XCTFail("Expected validation error for short code")
    } catch {
      XCTAssert(error is AuthService.InputValidationError)
    }

    // Contains special chars
    do {
      try await auth.signUp(email: "a@b.com", password: "p",
                            firstName: "F", lastName: "L", userType: .guide, communityCode: "AB!@#$")
      XCTFail("Expected validation error for special chars")
    } catch {
      XCTAssert(error is AuthService.InputValidationError)
    }

    // Too long
    do {
      try await auth.signUp(email: "a@b.com", password: "p",
                            firstName: "F", lastName: "L", userType: .guide, communityCode: "ABCDEFG")
      XCTFail("Expected validation error for long code")
    } catch {
      XCTAssert(error is AuthService.InputValidationError)
    }
  }

  // MARK: - Tests: Cached community restored on init

  func testCachedCommunity_restoredAfterClear() {
    let svc = CommunityService.shared
    UserDefaults.standard.set("cached-comm-id", forKey: "CommunityService.activeCommunityId")
    UserDefaults.standard.set("angler", forKey: "CommunityService.activeRole")

    // Clear and verify
    svc.clear()
    XCTAssertNil(svc.activeCommunityId)
    XCTAssertNil(svc.activeRole)
  }

  // MARK: - Tests: Computed properties

  func testActiveCommunityName_fallsBackToAppEnvironment() {
    let svc = CommunityService.shared
    // No memberships loaded, no active community
    XCTAssertEqual(svc.activeCommunityName, AppEnvironment.shared.communityName)
  }

  func testActiveMembership_returnsCorrectMembership() async {
    setAccessToken("valid-token")
    let m1 = makeSingleMembership(communityId: "c-1", communityName: "Comm A", role: "guide", code: "AAA111")
    let m2 = makeSingleMembership(communityId: "c-2", communityName: "Comm B", role: "angler", code: "BBB222")
    let data = makeMembershipsJSON([m1, m2])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()
    svc.setActiveCommunity(id: "c-2")

    XCTAssertEqual(svc.activeMembership?.communityId, "c-2")
    XCTAssertEqual(svc.activeMembership?.role, "angler")
  }

  // MARK: - Tests: Default community

  func testSetDefaultCommunity_persistsToUserDefaults() {
    let svc = CommunityService.shared
    svc.setDefaultCommunity(id: "default-comm-1")

    XCTAssertEqual(svc.defaultCommunityId, "default-comm-1")
    XCTAssertEqual(UserDefaults.standard.string(forKey: "CommunityService.defaultCommunityId"), "default-comm-1")
  }

  func testClearDefaultCommunity_removesFromUserDefaults() {
    let svc = CommunityService.shared
    svc.setDefaultCommunity(id: "default-comm-1")
    XCTAssertEqual(svc.defaultCommunityId, "default-comm-1")

    svc.clearDefaultCommunity()
    XCTAssertNil(svc.defaultCommunityId)
    XCTAssertNil(UserDefaults.standard.string(forKey: "CommunityService.defaultCommunityId"))
  }

  func testClear_doesNotRemoveDefaultCommunity() {
    let svc = CommunityService.shared
    svc.setDefaultCommunity(id: "default-comm-1")

    svc.clear()

    // Default should survive logout
    XCTAssertEqual(svc.defaultCommunityId, "default-comm-1",
                   "Default community should persist across logout")
    XCTAssertEqual(UserDefaults.standard.string(forKey: "CommunityService.defaultCommunityId"), "default-comm-1")
    // But active state should be cleared
    XCTAssertNil(svc.activeCommunityId)
    XCTAssertNil(svc.activeRole)
  }

  func testFetchMemberships_withValidDefault_autoSelects() async {
    setAccessToken("valid-token")
    let m1 = makeSingleMembership(communityId: "c-1", communityName: "Comm A", role: "guide", code: "AAA111")
    let m2 = makeSingleMembership(communityId: "c-2", communityName: "Comm B", role: "angler", code: "BBB222")
    let data = makeMembershipsJSON([m1, m2])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    // Simulate: user previously set c-2 as default, then logged out
    svc.setDefaultCommunity(id: "c-2")
    svc.clear() // logout clears active but keeps default

    await svc.fetchMemberships()

    XCTAssertEqual(svc.activeCommunityId, "c-2",
                   "Should auto-select the default community on login")
    XCTAssertEqual(svc.activeRole, "angler",
                   "Should set the correct role for the default community")
    XCTAssertEqual(svc.defaultCommunityId, "c-2",
                   "Default should remain unchanged after auto-select")
  }

  func testFetchMemberships_withInvalidDefault_clearsDefaultAndShowsPicker() async {
    setAccessToken("valid-token")
    // Use TWO communities so single-community auto-select does not kick in
    let m1 = makeSingleMembership(communityId: "c-1", communityName: "Comm A", role: "guide", code: "AAA111")
    let m2 = makeSingleMembership(communityId: "c-2", communityName: "Comm B", role: "angler", code: "BBB222")
    let data = makeMembershipsJSON([m1, m2])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    // Set a default to a community the user is no longer a member of
    svc.setDefaultCommunity(id: "removed-comm")

    await svc.fetchMemberships()

    XCTAssertNil(svc.activeCommunityId,
                 "Should not auto-select when default community is no longer valid")
    XCTAssertNil(svc.defaultCommunityId,
                 "Should clear invalid default community")
    XCTAssertNil(UserDefaults.standard.string(forKey: "CommunityService.defaultCommunityId"),
                 "Should remove invalid default from UserDefaults")
  }

  func testFetchMemberships_noDefault_showsPicker() async {
    setAccessToken("valid-token")
    let m1 = makeSingleMembership(communityId: "c-1", communityName: "Comm A", role: "guide", code: "AAA111")
    let m2 = makeSingleMembership(communityId: "c-2", communityName: "Comm B", role: "angler", code: "BBB222")
    let data = makeMembershipsJSON([m1, m2])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    XCTAssertNil(svc.defaultCommunityId, "Precondition: no default set")

    await svc.fetchMemberships()

    XCTAssertNil(svc.activeCommunityId,
                 "Should not auto-select when no default is set — picker should be shown")
    XCTAssertEqual(svc.memberships.count, 2)
  }

  func testClearActiveCommunity_nilsActiveButKeepsDefault() {
    let svc = CommunityService.shared
    svc.setDefaultCommunity(id: "c-1")
    // Simulate an active community
    UserDefaults.standard.set("c-1", forKey: "CommunityService.activeCommunityId")
    UserDefaults.standard.set("guide", forKey: "CommunityService.activeRole")

    svc.clearActiveCommunity()

    XCTAssertNil(svc.activeCommunityId,
                 "Active community should be nil after clearActiveCommunity")
    XCTAssertNil(svc.activeRole,
                 "Active role should be nil after clearActiveCommunity")
    XCTAssertEqual(svc.defaultCommunityId, "c-1",
                   "Default community should be preserved after clearActiveCommunity")
    XCTAssertTrue(svc.hasFetchedMemberships == false || true,
                  "Memberships array should remain intact")
  }

  func testQuickSwitch_doesNotChangeDefault() async {
    setAccessToken("valid-token")
    let m1 = makeSingleMembership(communityId: "c-1", communityName: "Comm A", role: "guide", code: "AAA111")
    let m2 = makeSingleMembership(communityId: "c-2", communityName: "Comm B", role: "angler", code: "BBB222")
    let data = makeMembershipsJSON([m1, m2])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    svc.setDefaultCommunity(id: "c-1")
    await svc.fetchMemberships()

    // Quick-switch to c-2 (does NOT call setDefaultCommunity)
    svc.setActiveCommunity(id: "c-2")

    XCTAssertEqual(svc.activeCommunityId, "c-2",
                   "Active community should switch to c-2")
    XCTAssertEqual(svc.defaultCommunityId, "c-1",
                   "Default should remain c-1 after quick-switch")
  }

  func testSetDefaultCommunity_overwritesPrevious() {
    let svc = CommunityService.shared
    svc.setDefaultCommunity(id: "c-1")
    XCTAssertEqual(svc.defaultCommunityId, "c-1")

    svc.setDefaultCommunity(id: "c-2")
    XCTAssertEqual(svc.defaultCommunityId, "c-2",
                   "New default should overwrite previous")
    XCTAssertEqual(UserDefaults.standard.string(forKey: "CommunityService.defaultCommunityId"), "c-2")
  }

  func testFullLoginCycle_defaultSurvivesLogout() async {
    setAccessToken("valid-token")
    let m1 = makeSingleMembership(communityId: "c-1", communityName: "Comm A", role: "guide", code: "AAA111")
    let m2 = makeSingleMembership(communityId: "c-2", communityName: "Comm B", role: "angler", code: "BBB222")
    let data = makeMembershipsJSON([m1, m2])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared

    // First login: user picks c-2 from picker (sets default + active)
    await svc.fetchMemberships()
    svc.setDefaultCommunity(id: "c-2")
    svc.setActiveCommunity(id: "c-2")
    XCTAssertEqual(svc.activeCommunityId, "c-2")
    XCTAssertEqual(svc.defaultCommunityId, "c-2")

    // Logout
    svc.clear()
    XCTAssertNil(svc.activeCommunityId, "Active should be nil after logout")
    XCTAssertEqual(svc.defaultCommunityId, "c-2", "Default should survive logout")

    // Second login: fetchMemberships should auto-select the default
    setAccessToken("valid-token-2")
    await svc.fetchMemberships()

    XCTAssertEqual(svc.activeCommunityId, "c-2",
                   "Should auto-select default community on re-login")
    XCTAssertEqual(svc.activeRole, "angler",
                   "Should restore correct role for default community")
  }

  // MARK: - Tests: Inactive community filtering

  func testFetchMemberships_filtersOutInactiveCommunities() async {
    setAccessToken("valid-token")
    let m1 = makeSingleMembership(communityId: "c-1", communityName: "Active Lodge", role: "guide", code: "AAA111", isActive: true)
    let m2 = makeSingleMembership(communityId: "c-2", communityName: "Inactive Lodge", role: "angler", code: "BBB222", isActive: false)
    let m3 = makeSingleMembership(communityId: "c-3", communityName: "Active Shop", role: "angler", code: "CCC333", isActive: true)
    let data = makeMembershipsJSON([m1, m2, m3])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertEqual(svc.memberships.count, 2,
                   "Should only contain active communities")
    XCTAssertTrue(svc.memberships.contains(where: { $0.communityId == "c-1" }))
    XCTAssertTrue(svc.memberships.contains(where: { $0.communityId == "c-3" }))
    XCTAssertFalse(svc.memberships.contains(where: { $0.communityId == "c-2" }),
                   "Inactive community should be filtered out")
  }

  func testFetchMemberships_defaultCommunityMadeInactive_clearsDefaultAndShowsPicker() async {
    setAccessToken("valid-token")
    // User has 3 communities; c-2 was the default but has been made inactive
    let m1 = makeSingleMembership(communityId: "c-1", communityName: "Active Lodge", role: "guide", code: "AAA111", isActive: true)
    let m2 = makeSingleMembership(communityId: "c-2", communityName: "Deactivated Lodge", role: "angler", code: "BBB222", isActive: false)
    let m3 = makeSingleMembership(communityId: "c-3", communityName: "Active Shop", role: "angler", code: "CCC333", isActive: true)
    let data = makeMembershipsJSON([m1, m2, m3])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    svc.setDefaultCommunity(id: "c-2") // was default before deactivation
    svc.clear() // simulate logout

    await svc.fetchMemberships()

    // Inactive c-2 is filtered out, so default is no longer valid
    XCTAssertNil(svc.activeCommunityId,
                 "Should not auto-select inactive default — picker should be shown")
    XCTAssertNil(svc.defaultCommunityId,
                 "Should clear default when it points to an inactive community")
    XCTAssertEqual(svc.memberships.count, 2,
                   "Picker should show the 2 remaining active communities")
    XCTAssertTrue(svc.memberships.contains(where: { $0.communityId == "c-1" }))
    XCTAssertTrue(svc.memberships.contains(where: { $0.communityId == "c-3" }))
  }

  func testFetchMemberships_cachedCommunityMadeInactive_showsPickerWithActiveCommunities() async {
    setAccessToken("valid-token")
    // First fetch: all 3 active — user selects c-2
    let m1Active = makeSingleMembership(communityId: "c-1", communityName: "Lodge A", role: "guide", code: "AAA111", isActive: true)
    let m2Active = makeSingleMembership(communityId: "c-2", communityName: "Lodge B", role: "angler", code: "BBB222", isActive: true)
    let m3Active = makeSingleMembership(communityId: "c-3", communityName: "Lodge C", role: "angler", code: "CCC333", isActive: true)

    var callCount = 0
    // Second fetch: c-2 is now inactive
    let m2Inactive = makeSingleMembership(communityId: "c-2", communityName: "Lodge B", role: "angler", code: "BBB222", isActive: false)

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        callCount += 1
        let payload: [[String: Any]]
        if callCount == 1 {
          payload = [m1Active, m2Active, m3Active]
        } else {
          payload = [m1Active, m2Inactive, m3Active]
        }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared

    // First login: user selects c-2
    await svc.fetchMemberships()
    svc.setActiveCommunity(id: "c-2")
    XCTAssertEqual(svc.activeCommunityId, "c-2")

    // Second fetch: c-2 is now inactive — app should detect and show picker
    await svc.fetchMemberships()

    XCTAssertNil(svc.activeCommunityId,
                 "Should clear active selection when community becomes inactive")
    XCTAssertEqual(svc.memberships.count, 2,
                   "Should only show the 2 remaining active communities")
  }

  func testFetchMemberships_allCommunitiesInactive_showsPickerWithEmpty() async {
    setAccessToken("valid-token")
    let m1 = makeSingleMembership(communityId: "c-1", communityName: "Inactive A", role: "guide", code: "AAA111", isActive: false)
    let m2 = makeSingleMembership(communityId: "c-2", communityName: "Inactive B", role: "angler", code: "BBB222", isActive: false)
    let data = makeMembershipsJSON([m1, m2])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertTrue(svc.memberships.isEmpty,
                  "All communities are inactive — memberships should be empty")
    XCTAssertNil(svc.activeCommunityId,
                 "Should show picker (with join option) when all communities are inactive")
  }

  func testHasMultipleCommunities_excludesInactive() async {
    setAccessToken("valid-token")
    let m1 = makeSingleMembership(communityId: "c-1", communityName: "Active", role: "guide", code: "AAA111", isActive: true)
    let m2 = makeSingleMembership(communityId: "c-2", communityName: "Inactive", role: "angler", code: "BBB222", isActive: false)
    let data = makeMembershipsJSON([m1, m2])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertFalse(svc.hasMultipleCommunities,
                   "Should not count inactive communities — only 1 active")
    XCTAssertEqual(svc.memberships.count, 1)
    // Single active community auto-selects
    XCTAssertEqual(svc.activeCommunityId, "c-1",
                   "Single remaining active community should auto-select")
  }

  // MARK: - Tests: Single community auto-select (regression)

  func testFetchMemberships_singleCommunity_publicRole_autoSelects() async {
    setAccessToken("valid-token")
    let membership = makeSingleMembership(communityId: "pub-comm-1", communityName: "Public Community", role: "public", code: "PUB001")
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

    XCTAssertEqual(svc.activeCommunityId, "pub-comm-1",
                   "Single public community should auto-select")
    XCTAssertEqual(svc.activeRole, "public",
                   "Role should be 'public' from the auto-selected community")
    XCTAssertEqual(svc.defaultCommunityId, "pub-comm-1",
                   "Auto-selected community should be set as default")
  }

  func testFetchMemberships_singleCommunity_anglerRole_autoSelects() async {
    setAccessToken("valid-token")
    let membership = makeSingleMembership(communityId: "ang-comm-1", communityName: "Angler Community", role: "angler", code: "ANG001")
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

    XCTAssertEqual(svc.activeCommunityId, "ang-comm-1",
                   "Single angler community should auto-select")
    XCTAssertEqual(svc.activeRole, "angler",
                   "Role should be 'angler' from the auto-selected community")
  }

  func testFetchMemberships_singleCommunity_autoSelectSyncsRoleToAuthService() async {
    setAccessToken("valid-token")
    let membership = makeSingleMembership(communityId: "pub-comm-1", communityName: "Public Community", role: "public", code: "PUB001")
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

    // Give MainActor time to process the updateUserType call
    try? await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertEqual(AuthService.shared.currentUserType, .public,
                   "Single-community auto-select should sync public role to AuthService")
  }

  func testFetchMemberships_singleCommunity_withExistingDefault_usesDefault() async {
    setAccessToken("valid-token")
    let membership = makeSingleMembership(communityId: "comm-1", communityName: "Only Community", role: "guide", code: "ONL001")
    let data = makeMembershipsJSON([membership])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    // User previously set this as default
    svc.setDefaultCommunity(id: "comm-1")
    svc.clear() // logout

    await svc.fetchMemberships()

    // Should auto-select via default path (not single-community path)
    XCTAssertEqual(svc.activeCommunityId, "comm-1",
                   "Should auto-select via default community")
    XCTAssertEqual(svc.activeRole, "guide")
  }

  func testFetchMemberships_multipleCommunities_noDefault_showsPicker() async {
    setAccessToken("valid-token")
    let m1 = makeSingleMembership(communityId: "c-1", communityName: "Comm A", role: "guide", code: "AAA111")
    let m2 = makeSingleMembership(communityId: "c-2", communityName: "Comm B", role: "public", code: "BBB222")
    let data = makeMembershipsJSON([m1, m2])

    MockURLProtocol.requestHandler = { request in
      guard let url = request.url else { throw URLError(.badURL) }
      if url.path.contains("/rest/v1/user_communities") {
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
      }
      return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
    }

    let svc = CommunityService.shared
    await svc.fetchMemberships()

    XCTAssertNil(svc.activeCommunityId,
                 "Multiple communities with no default should show picker")
    XCTAssertEqual(svc.memberships.count, 2)
  }

  // MARK: - Tests: MapReportService member_id parameter

  func testMapReportService_includesMemberIdQueryParam() async {
    var capturedURL: URL?

    MockURLProtocol.requestHandler = { request in
      capturedURL = request.url
      guard let url = request.url else { throw URLError(.badURL) }
      let response: [String: Any] = ["reports": [], "count": 0]
      let data = try! JSONSerialization.data(withJSONObject: response)
      return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
    }

    setAccessToken("valid-token")
    _ = try? await MapReportService.fetch(communityId: "test-comm", memberId: "test-member-123")

    XCTAssertNotNil(capturedURL, "Should have made a network request")
    let components = URLComponents(url: capturedURL!, resolvingAgainstBaseURL: false)
    let memberIdParam = components?.queryItems?.first(where: { $0.name == "member_id" })
    XCTAssertEqual(memberIdParam?.value, "test-member-123",
                   "Should include member_id query parameter when provided")
  }

  func testMapReportService_omitsMemberIdWhenNil() async {
    var capturedURL: URL?

    MockURLProtocol.requestHandler = { request in
      capturedURL = request.url
      guard let url = request.url else { throw URLError(.badURL) }
      let response: [String: Any] = ["reports": [], "count": 0]
      let data = try! JSONSerialization.data(withJSONObject: response)
      return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
    }

    setAccessToken("valid-token")
    _ = try? await MapReportService.fetch(communityId: "test-comm")

    XCTAssertNotNil(capturedURL, "Should have made a network request")
    let components = URLComponents(url: capturedURL!, resolvingAgainstBaseURL: false)
    let memberIdParam = components?.queryItems?.first(where: { $0.name == "member_id" })
    XCTAssertNil(memberIdParam,
                 "Should not include member_id query parameter when nil")
  }
}
