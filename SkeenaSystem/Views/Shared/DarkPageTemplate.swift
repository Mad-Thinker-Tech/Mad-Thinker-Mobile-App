// Bend Fly Shop
// DarkPageTemplate.swift — Shared dark-themed page styling components
//
// De-duplicated from AnglerLandingView.swift and GuideLandingView.swift.
// Provides consistent nav-bar appearance, dark background, and a reusable header.

import SwiftUI

// MARK: - User role

/// Distinguishes angler vs guide context so shared views (e.g. Conditions, Community)
/// can render the appropriate toolbar without duplication.
enum AppUserRole { case angler, guide, `public`, researcher }

private struct UserRoleKey: EnvironmentKey {
  static let defaultValue: AppUserRole = .angler // backward-compatible default
}

extension EnvironmentValues {
  var userRole: AppUserRole {
    get { self[UserRoleKey.self] }
    set { self[UserRoleKey.self] = newValue }
  }
}

// MARK: - Angler navigation environment key

/// Environment key that child views call to navigate.
/// Pass `nil` to pop to root (Home).  Pass a destination to pop-to-root then navigate there.
/// The root NavigationStack owner (AnglerLandingView) sets this closure.
private struct NavigateToKey: EnvironmentKey {
  static let defaultValue: (AnglerDestination?) -> Void = { _ in }
}

extension EnvironmentValues {
  var navigateTo: (AnglerDestination?) -> Void {
    get { self[NavigateToKey.self] }
    set { self[NavigateToKey.self] = newValue }
  }
}

// MARK: - Guide navigation

/// Destinations the guide toolbar can navigate to.
enum GuideDestination: Hashable {
  case trips, activities, community, observations, conditions, learn, explore, maps
}

private struct GuideNavigateToKey: EnvironmentKey {
  static let defaultValue: (GuideDestination?) -> Void = { _ in }
}

extension EnvironmentValues {
  var guideNavigateTo: (GuideDestination?) -> Void {
    get { self[GuideNavigateToKey.self] }
    set { self[GuideNavigateToKey.self] = newValue }
  }
}

// MARK: - Role-aware toolbar

/// A toolbar that renders the correct set of tabs depending on `userRole`.
/// Used by shared views (Conditions, Community) so they don't need role-specific logic.
struct RoleAwareToolbar: View {
  let activeTab: String

  @Environment(\.userRole) private var userRole
  @Environment(\.navigateTo) private var navigateTo
  @Environment(\.guideNavigateTo) private var guideNavigateTo
  @ObservedObject private var communityService = CommunityService.shared
  @ObservedObject private var pendingUploads = PendingUploadSummary.shared

  private var socialDisabled: Bool { !communityService.isSocialActive }

  var body: some View {
    switch userRole {
    case .angler:
      anglerToolbar
    case .guide:
      guideToolbar
    case .public:
      publicToolbar
    case .researcher:
      researcherToolbar
    }
  }

  // MARK: Angler tabs — Home, My Trip, [Social], Explore
  @ViewBuilder private var anglerToolbar: some View {
    ToolbarTab(icon: "house", label: "Home") {
      navigateTo(nil)
    }
    ToolbarTab(icon: "suitcase", label: "My Trip") {
      navigateTo(.trip)
    }
    if !socialDisabled {
      ToolbarTab(icon: "message", label: "Social") {
        if activeTab != "community" { navigateTo(.community) }
      }
    }
    ToolbarTab(icon: "book.fill", label: "Learn") {
      if activeTab != "explore" { navigateTo(.explore) }
    }
  }

  // MARK: Public tabs — Home, Catches, [Social], Learn (no Trips)
  @ViewBuilder private var publicToolbar: some View {
    ToolbarTab(icon: "house", label: "Home") {
      guideNavigateTo(nil)
    }
    ToolbarTab(icon: "safari", label: "Activities", badgeCount: pendingUploads.totalPending) {
      if activeTab != "activities" { guideNavigateTo(.activities) }
    }
    if !socialDisabled {
      ToolbarTab(icon: "message", label: "Social") {
        if activeTab != "community" { guideNavigateTo(.community) }
      }
    }
    ToolbarTab(icon: "book.fill", label: "Learn") {
      if activeTab != "explore" { guideNavigateTo(.explore) }
    }
  }

  // MARK: Researcher tabs — Home, Activities, Maps, [Social], Learn
  @ViewBuilder private var researcherToolbar: some View {
    ToolbarTab(icon: "house", label: "Home") {
      guideNavigateTo(nil)
    }
    ToolbarTab(icon: "safari", label: "Activities", badgeCount: pendingUploads.totalPending) {
      if activeTab != "activities" { guideNavigateTo(.activities) }
    }
    ToolbarTab(icon: "map", label: "Maps") {
      if activeTab != "maps" { guideNavigateTo(.maps) }
    }
    if !socialDisabled {
      ToolbarTab(icon: "message", label: "Social") {
        if activeTab != "community" { guideNavigateTo(.community) }
      }
    }
    ToolbarTab(icon: "book.fill", label: "Learn") {
      if activeTab != "explore" { guideNavigateTo(.explore) }
    }
  }

  // MARK: Guide tabs — Home, Trips, Activities, [Social]
  @ViewBuilder private var guideToolbar: some View {
    ToolbarTab(icon: "house", label: "Home") {
      guideNavigateTo(nil)
    }
    ToolbarTab(icon: "mountain.2", label: "Trips") {
      if activeTab != "trips" { guideNavigateTo(.trips) }
    }
    ToolbarTab(icon: "safari", label: "Activities", badgeCount: pendingUploads.totalPending) {
      if activeTab != "activities" { guideNavigateTo(.activities) }
    }
    if !socialDisabled {
      ToolbarTab(icon: "message", label: "Social") {
        if activeTab != "community" { guideNavigateTo(.community) }
      }
    }
  }
}

// MARK: - UINavigationBar styling for iOS 15

struct LegacyNavBarStyle: ViewModifier {
  /// Apply global UINavigationBar appearance once (no-op on subsequent calls).
  private static let applyOnce: Void = {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = .brandNavBar
    appearance.titleTextAttributes = [.foregroundColor: UIColor.brandTextPrimary]
    appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.brandTextPrimary]

    let navBar = UINavigationBar.appearance()
    navBar.standardAppearance = appearance
    navBar.scrollEdgeAppearance = appearance
    navBar.compactAppearance = appearance
    navBar.tintColor = .brandTextPrimary
  }()

  func body(content: Content) -> some View {
    content
      .onAppear { _ = Self.applyOnce }
  }
}

extension View {
  func applyLegacyNavBarStyle() -> some View { modifier(LegacyNavBarStyle()) }
}

// MARK: - iOS 16+ visible toolbar helper

struct VisibleToolbarBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 16.0, *) {
      return AnyView(
        content
          .toolbarBackground(.visible, for: .navigationBar)
          .toolbarBackground(Color.brandNavBar, for: .navigationBar)
          .toolbarColorScheme(.dark, for: .navigationBar)
      )
    } else {
      return AnyView(content)
    }
  }
}

// MARK: - App Header (logo + title + tagline + optional subtitle)

struct AppHeader: View {
  var subtitle: String? = nil
  var onMapTapped: (() -> Void)? = nil
  @ObservedObject private var communityService = CommunityService.shared

  var body: some View {
    let config = communityService.activeCommunityConfig

    VStack(spacing: 0) {
      CommunityLogoView(config: config)

      if let name = config.displayName, !name.isEmpty {
        Text(name)
          .font(.brandTitle2.weight(.bold))
          .foregroundColor(.brandTextPrimary)
          .multilineTextAlignment(.center)
          .padding(.top, 8)
          .accessibilityIdentifier("communityHeaderName")
      }

      if let tag = config.tagline, !tag.isEmpty {
        Text(tag)
          .font(.brandSubheadline)
          .foregroundColor(.brandTextSecondary)
          .multilineTextAlignment(.center)
          .padding(.top, 4)
          .padding(.horizontal, 20)
      }

      ZStack {
        if let onMapTapped {
          HStack {
            Spacer()
            Button(action: onMapTapped) {
              Image(systemName: "map")
                .font(.brandTitle3)
                .foregroundColor(.brandAccent)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
          }
        }
      }
      .padding(.top, 2)

      if let subtitle {
        Text(subtitle)
          .font(.brandTitle3.weight(.semibold))
          .foregroundColor(.brandTextPrimary)
          .multilineTextAlignment(.center)
          .padding(.top, 16)
      }
    }
  }
}

// MARK: - Bottom Toolbar Tab (shared helper)

/// A single tab button used in the pinned bottom toolbar.
/// Provides a consistent icon + label layout across all views.
/// Set `disabled: true` to render the tab greyed-out and non-interactive.
/// Set `badgeCount` > 0 to overlay a small upload-pending indicator.
struct ToolbarTab: View {
  let icon: String
  let label: String
  var disabled: Bool = false
  var badgeCount: Int? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Image(systemName: icon)
          .font(.system(size: 22))
          .foregroundColor(disabled ? .brandTextSecondary.opacity(0.4) : .brandTextPrimary.opacity(0.85))
          .overlay(alignment: .topTrailing) {
            if let count = badgeCount, count > 0 {
              Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.brandAccent)
                .background(
                  Circle()
                    .fill(Color.brandNavBar)
                    .frame(width: 14, height: 14)
                )
                .offset(x: 8, y: -4)
                .accessibilityLabel("\(count) pending upload\(count == 1 ? "" : "s")")
            }
          }
        Text(label)
          .font(.brandCaption2)
          .foregroundColor(disabled ? .brandTextSecondary.opacity(0.4) : .brandTextSecondary)
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
  }
}

// MARK: - Bottom Toolbar

/// The pinned bottom toolbar with a top border and evenly spaced tab buttons.
/// Pass an array of `ToolbarTab` views or any custom content via `@ViewBuilder`.
///
/// Usage:
/// ```swift
/// BottomToolbar {
///   ToolbarTab(icon: "suitcase", label: "My Trip") { showTrip = true }
///   ToolbarTab(icon: "cloud.sun", label: "Conditions") { goToConditions = true }
/// }
/// ```
struct BottomToolbar<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      // Top border
      Rectangle()
        .fill(Color.brandStroke)
        .frame(height: 0.5)

      // Toolbar icons
      HStack(spacing: 0) {
        content
      }
      .padding(.top, 8)
      .padding(.bottom, 4)
    }
    .background(Color.brandNavBar)
  }
}

// MARK: - Dark Page Template

/// A shared page wrapper that provides the consistent dark-themed styling
/// used across Bend Fly Shop views (black background, dark nav bar, white foreground,
/// and an optional pinned bottom toolbar).
///
/// Usage for **pushed** views (no bottom toolbar):
/// ```swift
/// var body: some View {
///   DarkPageTemplate {
///     ScrollView { ... }
///   }
///   .navigationTitle("My Title")
/// }
/// ```
///
/// Usage for **root** views with a bottom toolbar:
/// ```swift
/// var body: some View {
///   DarkPageTemplate(bottomToolbar: {
///     ToolbarTab(icon: "suitcase", label: "My Trip") { ... }
///     ToolbarTab(icon: "cloud.sun", label: "Conditions") { ... }
///   }) {
///     ScrollView { ... }
///   }
/// }
/// ```
struct DarkPageTemplate<Content: View, Toolbar: View>: View {
  let content: Content
  let toolbar: Toolbar?

  /// Creates a template with content and an optional bottom toolbar.
  init(
    @ViewBuilder bottomToolbar: () -> Toolbar,
    @ViewBuilder content: () -> Content
  ) {
    self.toolbar = bottomToolbar()
    self.content = content()
  }

  var body: some View {
    ZStack {
      Color.brandBackground.ignoresSafeArea()
      content
    }
    .navigationBarTitleDisplayMode(.inline)
    .modifier(VisibleToolbarBackground())
    .applyLegacyNavBarStyle()
    .foregroundColor(.brandTextPrimary)
    .preferredColorScheme(.dark)
    .if(toolbar != nil) { view in
      view.safeAreaInset(edge: .bottom) {
        if let toolbar {
          BottomToolbar { toolbar }
        }
      }
    }
  }
}

// No-toolbar convenience initializer
extension DarkPageTemplate where Toolbar == EmptyView {
  /// Creates a template without a bottom toolbar (for pushed views).
  init(@ViewBuilder content: () -> Content) {
    self.toolbar = nil
    self.content = content()
  }
}

// MARK: - Conditional View Modifier Helper

private extension View {
  /// Applies the given transform if the condition is true.
  @ViewBuilder
  func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
    if condition {
      transform(self)
    } else {
      self
    }
  }
}
