// Bend Fly Shop

import CoreData
import Security
import SwiftUI

@main
struct SkeenaSystemApp: App {
  // Your Core Data stack singleton
  private let persistence = PersistenceController.shared
  @Environment(\.scenePhase) private var scenePhase
    
    /// This initializer runs before the body is evaluated.
      init() {
        // Cross-environment safety net: if the cached access token was issued for
        // a different Supabase project than this build targets, wipe it before
        // AuthService.shared hydrates. Prevents PGRST301 401s when switching
        // between DEV / STAGE / PROD builds on the same simulator / device.
        AuthService.wipeAuthIfProjectMismatch()

        // When launched by UI tests with -resetAuthForUITests, wipe stored tokens
        // so every test run starts from a clean unauthenticated state.
        if CommandLine.arguments.contains("-resetAuthForUITests") {
          Self.clearAuthKeychainEntries()
          UserDefaults.standard.removeObject(forKey: "OfflineLastEmail")
          UserDefaults.standard.removeObject(forKey: "OfflineRememberMeEnabled")
        }
        if CommandLine.arguments.contains("-resetWelcomeStateForUITests") {
          let keys = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("publicWelcome_") }
          keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }
        // Wipes every locally-saved record (catch reports, farmed reports,
        // observations) plus their on-disk photos, so the next test sees an
        // empty Activities list. Runs synchronously at init() before any
        // store reads from disk — the JSON files are gone before
        // `loadAll()` would have a chance to populate `@Published reports`.
        if CommandLine.arguments.contains("-resetSavedLocallyReportsForUITests") {
          Self.clearSavedLocallyRecords()
        }
        // In UI-testing mode, listen for a Darwin notification that the test runner
        // can post to trigger sign-out without going through the SwiftUI toolbar button
        // (NavigationStack ToolbarItems report {-1,-1} hit points to XCUITest).
        if CommandLine.arguments.contains("-uiTesting") {
          Self.registerUITestSignOutHook()
          Self.registerUITestSwitchCommunityHook()
        }
        AppLogging.log("Environment project URL: \(AppEnvironment.shared.projectURL)", level: .info, category: .auth)
        AppLogging.log("Log level: \(AppEnvironment.shared.logLevel)", level: .info, category: .auth)
      }

      /// Registers a Darwin notification observer that signs out when the UI test runner
      /// posts `com.madthinker.uitest.signout`. Darwin notifications cross process
      /// boundaries so the XCUITest host can trigger app-side actions mid-test.
      private static func registerUITestSignOutHook() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
          center,
          nil,
          { _, _, _, _, _ in Task { await AuthService.shared.signOutRemote() } },
          "com.madthinker.uitest.signout" as CFString,
          nil,
          .deliverImmediately
        )
      }

      /// Toggles between the user's two memberships when the test runner posts
      /// `com.madthinker.uitest.toggleCommunity`. This sidesteps the SwiftUI
      /// toolbar `CommunityToolbarButton`, which can't be tapped reliably from
      /// XCUITest in iOS 26 simulators.
      private static func registerUITestSwitchCommunityHook() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
          center,
          nil,
          { _, _, _, _, _ in
            Task { @MainActor in
              let svc = CommunityService.shared
              let current = svc.activeCommunityId
              if let next = svc.memberships.first(where: { $0.communityId != current }) {
                svc.setActiveCommunity(id: next.communityId)
              }
            }
          },
          "com.madthinker.uitest.toggleCommunity" as CFString,
          nil,
          .deliverImmediately
        )
      }

      /// Removes the four on-disk roots that hold per-user records visible
      /// in Activities, plus their associated photos. Stores re-check disk
      /// on next bind and find empty directories, so `@Published reports`
      /// arrays come up empty.
      ///
      /// We delete the *directories themselves* (not just `.savedLocally`
      /// rows) because uploaded rows accumulate too across test runs and
      /// the user wants a clean Activities list, not a partial one. The
      /// directories are recreated lazily by each store's
      /// `ensureRootDirectory()` on the next save.
      private static func clearSavedLocallyRecords() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let roots = [
          "CatchReportsPicMemo",  // CatchReportStore
          "FarmedReports",        // FarmedReportStore (no-catch marks)
          "Observations",         // ObservationStore
          "CatchPhotos",          // PhotoStore (catch + head photos)
          "VoiceNotes",           // VoiceNoteStore (synthetic UI-test memos)
        ]
        for name in roots {
          let url = docs.appendingPathComponent(name, isDirectory: true)
          try? fm.removeItem(at: url)
        }
      }

      private static func clearAuthKeychainEntries() {
        let accounts = [
          "epicwaters.auth.access_token",
          "epicwaters.auth.refresh_token",
          "epicwaters.auth.access_token_exp",
          "OfflineLastPassword",
        ]
        for account in accounts {
          let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: account]
          SecItemDelete(query as CFDictionary)
        }
      }

  var body: some Scene {
    WindowGroup {
      // Switches Login ↔ Landing internally based on auth state
      AppRootView()
        .environment(\.managedObjectContext, persistence.container.viewContext)
        .onAppear {
          // Reduce merge conflicts when background tasks write to Core Data
          persistence.container.viewContext.automaticallyMergesChangesFromParent = true
          persistence.container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        }
        .environmentBanner()
    }
    .onChange(of: scenePhase) { phase in
      // Lightweight safety net to persist any in-flight edits
      if phase == .background || phase == .inactive {
        let context = persistence.container.viewContext
        if context.hasChanges {
          do { try context.save() } catch {
            // You can also log this if you have a logger
            // print("Core Data save on background failed: \(error)")
          }
        }
      }
    }
  }
}
