import Foundation

/// Single source of truth for legal-policy URLs surfaced in the app.
///
/// Linked from:
/// - `MemberRegistrationView` (signup footer)
/// - `PublicWelcomeView` (first-login overview for public users)
/// - `ManageProfileView` (Legal section, every role)
///
/// If marketing moves the site, update here once instead of three places.
enum LegalURLs {
  static let privacyPolicy = URL(string: "https://madthinkertech.com/privacy-policy")!
  static let acceptableUsePolicy = URL(string: "https://madthinkertech.com/acceptable-use-policy")!
}
