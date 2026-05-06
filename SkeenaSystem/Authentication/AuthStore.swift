// Bend Fly Shop

import Foundation

/// Thin cache for the Supabase user access JWT so sync code (like your uploader)
/// can read it without `await`. Refresh it *before* uploads.
///
/// `nonisolated` so the upload pipeline (which runs off MainActor) can read
/// `jwt` synchronously. `cachedJWT` is `nonisolated(unsafe)` because the
/// only mutator is `refreshFromSupabase` which already runs on MainActor —
/// the unsynchronized read window during a refresh is acceptable (worst
/// case: an upload retries with a stale token and gets a 401).
nonisolated final class AuthStore {
  static let shared = AuthStore()
  private init() {}

  nonisolated(unsafe) private var cachedJWT: String?

  /// Synchronous accessor used by other components (e.g., UploadCatchReportAPI).
  var jwt: String? { cachedJWT }

  /// Refresh from Supabase and cache it for synchronous use.
  @MainActor
  func refreshFromSupabase() async {
    let token = await AuthService.shared.currentAccessToken()
    self.cachedJWT = token
  }

  /// Optional: clear on logout
  func clear() { cachedJWT = nil }

  #if DEBUG
  /// Test helper: set JWT directly for testing upload flows
  func setJWTForTesting(_ token: String?) {
    cachedJWT = token
  }
  #endif
}
