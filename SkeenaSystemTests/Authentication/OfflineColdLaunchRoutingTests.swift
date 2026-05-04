import XCTest
import Security
@testable import SkeenaSystem

/// Regression coverage for the offline cold-launch routing path.
///
/// Scenario: a guide updates the app from the App Store, then opens it for the
/// first time while offline. The Keychain refresh token survives the update,
/// so AuthService.init flips `isAuthenticated = true`. Without cached profile
/// hydration, `currentUserType` stays nil and AppRootView renders an indefinite
/// loading spinner because every code path that sets `currentUserType` requires
/// the network.
///
/// These tests pin the contract on `AuthService.loadCachedAuthState()`, the
/// pure helper that init delegates to. Asserting against the helper rather than
/// reassigning the `shared` singleton avoids a deinit-time malloc crash on the
/// iOS 26.2 simulator that derails repeated `resetSharedForTests` calls.
@MainActor
final class OfflineColdLaunchRoutingTests: XCTestCase {

  override func setUp() {
    super.setUp()
    clearAuthState()
  }

  override func tearDown() {
    clearAuthState()
    super.tearDown()
  }

  // MARK: - Disk fixture helpers

  private func clearAuthState() {
    let keychainAccounts = [
      "epicwaters.auth.access_token",
      "epicwaters.auth.refresh_token",
      "epicwaters.auth.access_token_exp",
      "OfflineLastPassword",
    ]
    for account in keychainAccounts {
      let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: account]
      SecItemDelete(q as CFDictionary)
    }
    let defaultsKeys = [
      "OfflineLastEmail",
      "OfflineRememberMeEnabled",
      "CachedFirstName",
      "CachedLastName",
      "CachedUserType",
      "CachedMemberId",
    ]
    for key in defaultsKeys {
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

  /// Mirrors the post-online-sign-in disk state: refresh token in Keychain plus
  /// cached profile fields in UserDefaults (written by `loadUserProfile`).
  private func seedCachedSession(
    firstName: String,
    lastName: String,
    userType: String,
    memberId: String
  ) {
    _ = setKeychain(account: "epicwaters.auth.refresh_token", value: "stored-refresh-token")
    UserDefaults.standard.set(firstName, forKey: "CachedFirstName")
    UserDefaults.standard.set(lastName, forKey: "CachedLastName")
    UserDefaults.standard.set(userType, forKey: "CachedUserType")
    UserDefaults.standard.set(memberId, forKey: "CachedMemberId")
  }

  // MARK: - Tests

  /// The core regression: a cached refresh token alone is not enough to route
  /// the user. `currentUserType` must hydrate from UserDefaults so AppRootView
  /// can pick the correct landing view without a network round-trip.
  func testColdOfflineLaunch_hydratesCachedProfileFromUserDefaults() {
    seedCachedSession(
      firstName: "Geoff",
      lastName: "Sipperly",
      userType: "guide",
      memberId: "M-1234"
    )

    let state = AuthService.loadCachedAuthState()

    XCTAssertTrue(
      state.isAuthenticated,
      "Refresh token presence should mark session as authenticated"
    )
    XCTAssertEqual(
      state.userType,
      .guide,
      "Cached user_type must hydrate so AppRootView routes offline"
    )
    XCTAssertEqual(state.firstName, "Geoff")
    XCTAssertEqual(state.lastName, "Sipperly")
    XCTAssertEqual(state.memberId, "M-1234")
  }

  func testColdLaunch_anglerRoleHydrates() {
    seedCachedSession(firstName: "Erin", lastName: "Doe", userType: "angler", memberId: "M-99")
    XCTAssertEqual(AuthService.loadCachedAuthState().userType, .angler)
  }

  func testColdLaunch_researcherRoleHydrates() {
    seedCachedSession(firstName: "Ada", lastName: "Lovelace", userType: "researcher", memberId: "M-1")
    XCTAssertEqual(AuthService.loadCachedAuthState().userType, .researcher)
  }

  func testColdLaunch_publicRoleHydrates() {
    seedCachedSession(firstName: "Alex", lastName: "Kim", userType: "public", memberId: "M-2")
    XCTAssertEqual(AuthService.loadCachedAuthState().userType, .public)
  }

  /// Fresh install (no cached refresh token, no cached profile) — every field
  /// stays nil, isAuthenticated is false. Guards against the hydration code
  /// fabricating state on first launch.
  func testColdLaunch_freshInstall_leavesProfileFieldsNil() {
    let state = AuthService.loadCachedAuthState()

    XCTAssertFalse(state.isAuthenticated)
    XCTAssertNil(state.userType)
    XCTAssertNil(state.firstName)
    XCTAssertNil(state.lastName)
    XCTAssertNil(state.memberId)
    XCTAssertFalse(state.hasRefreshToken)
  }

  /// A corrupted or future-unknown role string must not crash and must not
  /// silently coerce to a default role. Other cached fields still hydrate.
  func testColdLaunch_invalidCachedUserType_leavesUserTypeNil() {
    _ = setKeychain(account: "epicwaters.auth.refresh_token", value: "stored-refresh-token")
    UserDefaults.standard.set("Geoff", forKey: "CachedFirstName")
    UserDefaults.standard.set("not-a-real-role", forKey: "CachedUserType")

    let state = AuthService.loadCachedAuthState()

    XCTAssertTrue(state.isAuthenticated)
    XCTAssertNil(
      state.userType,
      "Unrecognized role string must not be coerced to a default"
    )
    XCTAssertEqual(
      state.firstName,
      "Geoff",
      "Other cached fields should still hydrate independently"
    )
  }

  /// After signOut() with rememberMe=true, cached profile is preserved on disk
  /// so a subsequent cold launch could re-hydrate it. But isAuthenticated must
  /// stay false (no refresh token) so the user lands on LoginView, not on a
  /// cached landing view they no longer have a session for.
  func testColdLaunch_cachedProfileWithoutRefreshToken_doesNotAuthenticate() {
    UserDefaults.standard.set("Geoff", forKey: "CachedFirstName")
    UserDefaults.standard.set("guide", forKey: "CachedUserType")
    UserDefaults.standard.set("M-1234", forKey: "CachedMemberId")
    // Deliberately no refresh token in Keychain.

    let state = AuthService.loadCachedAuthState()

    XCTAssertFalse(
      state.isAuthenticated,
      "Cached profile without a refresh token must not flip isAuthenticated"
    )
    // Hydration is unconditional — fields populate but AppRootView ignores
    // them while isAuthenticated is false. Asserting this contract so a future
    // refactor doesn't accidentally start gating the routing on these.
    XCTAssertEqual(state.userType, .guide)
    XCTAssertEqual(state.firstName, "Geoff")
  }
}
