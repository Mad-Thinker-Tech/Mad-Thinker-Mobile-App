import XCTest
@testable import SkeenaSystem

/// API-level regression tests for the public-user lifecycle.
///
/// Complements `PublicUserFlowTests` (XCUITest) by asserting Supabase backend
/// state directly, without a simulator.  Covers the same lifecycle steps:
///
///   1. Register a new public user via `/auth/v1/signup`
///   2. Verify the session token returns a valid user from `/auth/v1/user`
///   3. Verify the Babine river-conditions edge function returns structured data
///   4. Delete the account via `/functions/v1/delete-account`
///   5. Verify the old session token is rejected with 401 (account is gone)
///
/// Prerequisites:
///   - Supabase email confirmation must be disabled (GOTRUE_MAILER_AUTOCONFIRM=true)
///     so that signup returns an access_token immediately. If confirmation is
///     required the tests are automatically skipped.
///   - The `API_BASE_URL` and `SUPABASE_ANON_KEY` xcconfig values from the
///     DevTEST scheme must resolve to a reachable Supabase project.
///
/// Run with:
///   xcodebuild test -workspace SkeenaSystem.xcworkspace \
///     -scheme SkeenaSystem \
///     -destination 'platform=iOS Simulator,...' \
///     -testPlan RegressionTests \
///     -only-testing:SkeenaSystemTests/PublicUserAPITests
final class PublicUserAPITests: XCTestCase {

    // MARK: - Config

    private var projectURL: URL { AppEnvironment.shared.projectURL }
    private var anonKey: String { AppEnvironment.shared.anonKey }
    private var deleteAccountURL: URL { AppEnvironment.shared.deleteAccountURL }

    private let timeout: TimeInterval = 20

    // MARK: - Per-test state

    private var testEmail: String!
    private var accessToken: String?

    // MARK: - Setup / Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()
        let short = UUID().uuidString.prefix(8).lowercased()
        testEmail = "apitest_\(short)@test.invalid"
        accessToken = nil
    }

    override func tearDownWithError() throws {
        // Best-effort cleanup: if any test left an account behind, delete it.
        if let token = accessToken {
            let sem = DispatchSemaphore(value: 0)
            Task.detached { [weak self] in
                guard let self else { sem.signal(); return }
                _ = try? await self.deleteAccount(token: token)
                sem.signal()
            }
            sem.wait(timeout: .now() + 15)
        }
        accessToken = nil
        try super.tearDownWithError()
    }

    // MARK: - Tests

    /// Step 1: POST /auth/v1/signup returns an access_token for a new public user.
    func testSignupReturnsAccessToken() async throws {
        let (token, userEmail) = try await signupAndExtractToken()
        accessToken = token
        XCTAssertFalse(token.isEmpty, "Signup should return a non-empty access_token")
        XCTAssertEqual(userEmail.lowercased(), testEmail.lowercased(),
            "Signed-up email should match the submitted email")
    }

    /// Step 2: A valid session token returns the correct user from /auth/v1/user.
    func testGetUserWithValidTokenReturnsCorrectEmail() async throws {
        let (token, _) = try await signupAndExtractToken()
        accessToken = token

        let email = try await getUser(token: token)
        XCTAssertEqual(email.lowercased(), testEmail.lowercased(),
            "GET /auth/v1/user should return the signed-up account's email")
    }

    /// Step 3: The Babine river-conditions edge function returns structured data.
    func testBabineRiverConditionsReturnsStructuredData() async throws {
        let (token, _) = try await signupAndExtractToken()
        accessToken = token

        let response = try await fetchRiverConditions(river: "Babine", token: token)

        let name = try XCTUnwrap(response.name, "river-conditions response should include a `name` field")
        XCTAssertTrue(name.lowercased().contains("babine"),
            "river-conditions `name` field should identify Babine — got '\(name)'")
        let levels = try XCTUnwrap(response.waterLevels, "river-conditions response should include waterLevels")
        XCTAssertFalse(levels.isEmpty,
            "river-conditions response should include at least one water level entry")
    }

    /// Step 4: DELETE account succeeds and step 5: old token is rejected by Supabase.
    func testDeleteAccountInvalidatesSession() async throws {
        let (token, _) = try await signupAndExtractToken()
        // Don't store in accessToken — we'll assert deletion explicitly
        // and the teardown cleanup would otherwise double-delete.

        try await deleteAccount(token: token)

        // Verify the session is gone. Supabase returns 403 (user record not found)
        // rather than 401 (token expired) when the account has been deleted outright.
        // Either 4xx code confirms the session is no longer accepted.
        let statusCode = try await getUserStatusCode(token: token)
        XCTAssertTrue(statusCode >= 400,
            "After account deletion GET /auth/v1/user should return a 4xx — got \(statusCode)")
    }

    // MARK: - API Helpers

    /// Signs up a new public user and returns the (accessToken, email) pair.
    /// Skips the test automatically when email confirmation is required.
    private func signupAndExtractToken() async throws -> (token: String, email: String) {
        let url = projectURL.appendingPathComponent("auth/v1/signup")
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")

        let body: [String: Any] = [
            "email": testEmail!,
            "password": "Testuser1",
            "data": [
                "first_name": "APITest",
                "last_name": "Public",
                "user_type": "public"
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertTrue((200..<300).contains(http.statusCode),
            "Signup should succeed — got \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Signup response should be a JSON object"
        )

        // If the project requires email confirmation, access_token is absent.
        let token = json["access_token"] as? String ?? ""
        try XCTSkipIf(token.isEmpty,
            "Supabase email confirmation is enabled — signup did not return an access_token. " +
            "Disable 'Confirm email' in Auth settings or set GOTRUE_MAILER_AUTOCONFIRM=true " +
            "to run these API tests.")

        let userObj = try XCTUnwrap(json["user"] as? [String: Any])
        let email = try XCTUnwrap(userObj["email"] as? String)
        return (token, email)
    }

    /// GET /auth/v1/user — returns the account email for a valid token.
    private func getUser(token: String) async throws -> String {
        let url = projectURL.appendingPathComponent("auth/v1/user")
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200, "GET /auth/v1/user should return 200")

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["email"] as? String)
    }

    /// GET /auth/v1/user — returns the raw HTTP status code (used for 401 assertions).
    private func getUserStatusCode(token: String) async throws -> Int {
        let url = projectURL.appendingPathComponent("auth/v1/user")
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return http.statusCode
    }

    /// Fetches Babine river conditions and decodes the response into a minimal struct.
    private func fetchRiverConditions(river: String, token: String) async throws -> ConditionsResponse {
        // Build from projectURL directly — riverConditionsURL reads RIVER_CONDITIONS_URL
        // from xcconfig which is set to a bare path ("/functions/v1/river-conditions"),
        // and URL(string:) accepts that as a path-only URL with no host.
        let url = projectURL.appendingPathComponent("functions/v1/river-conditions")
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let body: [String: Any] = [
            "river": river,
            "date": df.string(from: Date()),
            "include_water_temperature": true
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertTrue((200..<300).contains(http.statusCode),
            "river-conditions should succeed — got \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")

        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(ConditionsResponse.self, from: data)
    }

    /// Calls the delete-account edge function. Throws on non-2xx.
    @discardableResult
    private func deleteAccount(token: String) async throws -> Int {
        var req = URLRequest(url: deleteAccountURL, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["confirmationText": "DELETE"])

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertTrue((200..<300).contains(http.statusCode),
            "delete-account should succeed — got \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        return http.statusCode
    }

    // MARK: - Minimal response models

    // The edge function returns `name` (not `river`) and snake_case keys.
    // Decoded with .convertFromSnakeCase — no manual CodingKeys needed.
    private struct ConditionsResponse: Decodable {
        let name: String?
        let waterLevels: [WaterLevel]?

        struct WaterLevel: Decodable {
            let recordedAt: String
            let levelFt: Double?
        }
    }
}
