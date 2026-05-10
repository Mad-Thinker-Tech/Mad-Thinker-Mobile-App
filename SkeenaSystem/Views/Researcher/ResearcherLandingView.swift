// Bend Fly Shop
//
// ResearcherLandingView.swift — Landing screen for the "researcher" role in
// Conservation communities. Jumps directly into the catch recording chat
// with the community logo above it.

import CoreLocation
import SwiftUI
import UIKit

struct ResearcherLandingView: View {
  /// User-visible mode label. Researchers are *always* in conservation mode —
  /// this is a fixed label, not a toggle. Exposed so tests can lock the copy.
  static let conservationModeLabel = "Conservation Mode"

  /// Combine first + last name for the activity-row "Member:" line. Pure
  /// function so tests can lock the trimming/empty-handling without standing
  /// up an AuthService mock. Returns the empty string only when *both* parts
  /// are empty/whitespace.
  static func researcherName(first: String?, last: String?) -> String {
    let f = (first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let l = (last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(f) \(l)".trimmingCharacters(in: .whitespaces)
  }

  @StateObject private var auth = AuthService.shared
  @ObservedObject private var communityService = CommunityService.shared

  @StateObject private var chatVM = CatchChatViewModel()
  @StateObject private var loc = LocationManager()

  @State private var showConfirmation = false
  @State private var goToManageAccount = false

  // Path-based nav so the bottom toolbar's "Catches" button can push the
  // reports list the same way guide/public landing views do.
  @State private var navPath = NavigationPath()

  var body: some View {
    NavigationStack(path: $navPath) {
      DarkPageTemplate(bottomToolbar: {
        RoleAwareToolbar(activeTab: "home")
      }) {
        VStack(spacing: 0) {
          // ── Header: name (leading) + Conservation Mode (trailing) ─
          VStack(spacing: 0) {
            // Researchers are always in conservation mode — this is a static
            // label, not a toggle, and mirrors the guide landing row.
            HStack(spacing: 12) {
              Text("\(auth.currentFirstName ?? "") \(auth.currentLastName ?? "")")
                .font(.brandCaption.weight(.semibold))
                .foregroundColor(.brandTextPrimary)

              Spacer()

              Text(Self.conservationModeLabel)
                .font(.brandCaption.weight(.semibold))
                .foregroundColor(.brandSuccess)
                .accessibilityIdentifier("conservationModeLabel")
            }
            .padding(.horizontal, 20)

            CommunityLogoView(config: communityService.activeCommunityConfig, size: 120)
              .frame(maxWidth: .infinity)
          }
          .padding(.top, 12)

          // ── Fisheries Conditions ─────────────────────────────────
          // Mirrors the guide tile at GuideLandingView.swift:332. The
          // per-fishery detail view auto-hides Conditions Recall and
          // Tactics for non-guide roles via existing role gates.
          Button { handleNavigateTo(.conditions) } label: {
            HStack(spacing: 8) {
              Image(systemName: "water.waves")
                .font(.brandCaption)
                .foregroundColor(.brandTextPrimary)
              Text("Fisheries Conditions")
                .font(.brandCaption.weight(.semibold))
                .foregroundColor(.brandTextPrimary)
              Spacer()
              Image(systemName: "chevron.right")
                .font(.brandCaption.weight(.semibold))
                .foregroundColor(.brandTextPrimary.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.brandSurface, in: RoundedRectangle(cornerRadius: 14))
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 16)
          .padding(.top, 12)
          .padding(.bottom, 8)
          .accessibilityIdentifier("fishingForecastTile")

          // ── Catch chat ───────────────────────────────────────────
          CatchChatView(viewModel: chatVM)
        }
      }
      .navigationDestination(isPresented: $goToManageAccount) {
        ManageProfileView().environmentObject(auth)
      }
      .navigationDestination(for: GuideDestination.self) { dest in
        // Researcher toolbar exposes Home, Activities, Maps, [Social], Learn.
        // Anything outside that set is EmptyView so a toolbar layout drift
        // is caught visibly instead of silently routing somewhere wrong.
        switch dest {
        case .activities:
          ActivitiesView()
            .environment(\.userRole, .researcher)
            .environment(\.guideNavigateTo, handleNavigateTo)
        case .community:
          SocialFeedView()
            .environment(\.userRole, .researcher)
            .environment(\.guideNavigateTo, handleNavigateTo)
        case .explore:
          ExploreView()
            .environment(\.userRole, .researcher)
            .environment(\.guideNavigateTo, handleNavigateTo)
        case .maps:
          ResearcherMapView()
            .environment(\.userRole, .researcher)
            .environment(\.guideNavigateTo, handleNavigateTo)
        case .conditions:
          // Reuses the guide-side conditions list + per-fishery detail.
          // The detail view's Conditions Recall and Tactics toolbar
          // buttons gate on `role == .guide`, so they auto-hide here.
          FishingForecastRequestView()
            .environment(\.userRole, .researcher)
            .environment(\.guideNavigateTo, handleNavigateTo)
        case .trips, .observations, .learn:
          EmptyView()
        }
      }
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          HStack(spacing: 12) {
            Button(action: { goToManageAccount = true }) {
              Image(systemName: "person.circle")
                .font(.brandTitle3.weight(.semibold))
                .foregroundColor(.brandTextPrimary)
            }
            .accessibilityIdentifier("manageProfileButton")
            CommunityToolbarButton()
          }
        }
        if let donation = communityService.activeCommunityConfig.resolvedDonation {
          ToolbarItem(placement: .principal) {
            Link(destination: donation.url) {
              HStack(spacing: 6) {
                Image(systemName: "leaf.fill")
                  .font(.brandSubheadline)
                  .foregroundColor(.brandTextPrimary)
                Text("Donate")
                  .font(.brandCaption)
                  .foregroundColor(.brandTextPrimary)
              }
            }
            .accessibilityIdentifier("communityDonationLink")
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: logoutTapped) {
            HStack(spacing: 6) {
              Image(systemName: "person.crop.circle.badge.xmark")
                .font(.brandSubheadline)
                .foregroundColor(.brandTextPrimary)
              Text("Log out")
                .font(.brandCaption)
                .foregroundColor(.brandTextPrimary)
            }
          }
          .accessibilityIdentifier("logoutCapsule")
        }
      }
      .onAppear {
        loc.request()
        loc.start()
        chatVM.startConversationIfNeeded()
      }
      .onReceive(loc.$lastLocation) { location in
        chatVM.updateLocation(location)
      }
      .onChange(of: chatVM.saveRequested) { newValue in
        if newValue {
          chatVM.saveRequested = false
          showConfirmation = true
        }
      }
      .fullScreenCover(isPresented: $showConfirmation) {
        ResearcherCatchConfirmationView(
          chatVM: chatVM,
          onConfirm: {
            // Persist the catch to CatchReportStore ONLY on the confirm
            // path — the cancel path deliberately drops it. The store
            // writes to Documents/CatchReportsPicMemo and publishes the
            // new record so ReportsListView picks it up immediately.
            saveResearcherCatchIfPossible()
            showConfirmation = false
            resetForNextCatch()
          },
          onCancel: {
            showConfirmation = false
            resetForNextCatch()
          }
        )
      }
      .tint(.brandAccent)
      .fullScreenCover(isPresented: $chatVM.showRecordObservation, onDismiss: {
        // The sheet can be dismissed via Cancel (no observation saved) or
        // via Save (onSaved fires first). In both cases reset the chat so
        // the researcher sees the Catch / Observation icons again.
        chatVM.resetForNewCatch()
      }) {
        RecordObservationSheet { _ in
          chatVM.showRecordObservation = false
        }
      }
    }
    .environment(\.userRole, .researcher)
    .environment(\.guideNavigateTo, handleNavigateTo)
    .environmentObject(auth)
  }

  // MARK: - Actions

  private func logoutTapped() {
    Task {
      await auth.signOutRemote()
      await MainActor.run {
        AuthStore.shared.clear()
      }
    }
  }

  /// Reset the chat VM so the researcher can record another catch immediately.
  private func resetForNextCatch() {
    chatVM.resetForNewCatch()
  }

  // MARK: - Navigation

  /// Toolbar destination handler shared with ReportsListView / SocialFeedView
  /// via the `guideNavigateTo` environment value. Pops to root on nil, otherwise
  /// replaces the nav path with the tapped destination (matches the guide and
  /// conservation landing view pattern).
  private func handleNavigateTo(_ destination: GuideDestination?) {
    guard let destination else {
      navPath = NavigationPath()
      return
    }
    var newPath = NavigationPath()
    newPath.append(destination)
    navPath = newPath
  }

  // MARK: - Persistence

  /// Persists the current researcher catch via `CatchReportStore.createFromChat`.
  /// Called from the confirmation view's Confirm button before the chat is
  /// reset. Researchers always fish solo, so trip/lodge/guide fields are nil
  /// and memberId comes from `AuthService.shared.currentMemberId`.
  private func saveResearcherCatchIfPossible() {
    guard let snapshot = chatVM.makeCatchSnapshot() else {
      AppLogging.log("[ResearcherSave] makeCatchSnapshot() returned nil — nothing to save", level: .error, category: .catch)
      return
    }

    let memberId = (AuthService.shared.currentMemberId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let communityName = CommunityService.shared.activeCommunityName
    let communityId = CommunityService.shared.activeCommunityId

    // The pending-upload row reuses the `guideName` column to display the
    // report author's name regardless of role (see `CatchReportRow` in
    // ReportsListView). Populating it here lets researcher rows show
    // "Researcher: <name>" instead of "Researcher: —".
    let researcherName = Self.researcherName(
      first: AuthService.shared.currentFirstName,
      last: AuthService.shared.currentLastName
    )

    AppLogging.log("[ResearcherSave] memberId='\(memberId)' communityId='\(communityId ?? "nil")' communityName='\(communityName)'", level: .debug, category: .catch)
    AppLogging.log("[ResearcherSave] store \(CatchReportStore.shared.bindingDebugDescription)", level: .debug, category: .catch)
    AppLogging.log("[ResearcherSave] snapshot species='\(snapshot.species ?? "nil")' photo='\(snapshot.photoFilename ?? "nil")' headPhoto='\(snapshot.headPhotoFilename ?? "nil")'", level: .debug, category: .catch)

    // Fix: the Combine auto-rebind may not have fired yet if the view
    // appeared before the publisher delivered on the main queue. Force
    // a rebind so the store is scoped before we write.
    if !CatchReportStore.shared.isBound, !memberId.isEmpty, communityId != nil {
      AppLogging.log("[ResearcherSave] store unbound — forcing rebind before save", level: .debug, category: .catch)
      CatchReportStore.shared.rebind(memberId: memberId, communityId: communityId)
    }

    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    let deviceDescription = "\(UIDevice.current.model) \(UIDevice.current.systemVersion)"

    let reportCountBefore = CatchReportStore.shared.reports.count

    CatchReportStore.shared.createFromChat(
      memberId: memberId.isEmpty ? "Unknown" : memberId,
      species: snapshot.species,
      sex: snapshot.sex,
      lengthInches: snapshot.lengthInches ?? 0,
      lifecycleStage: snapshot.lifecycleStage,
      river: snapshot.riverName,
      classifiedWatersLicenseNumber: nil,
      lat: snapshot.latitude,
      lon: snapshot.longitude,
      photoFilename: snapshot.photoFilename,
      headPhotoFilename: snapshot.headPhotoFilename,
      voiceNoteId: snapshot.voiceNoteId,
      tripId: nil,
      tripName: nil,
      tripStartDate: nil,
      tripEndDate: nil,
      guideName: researcherName.isEmpty ? nil : researcherName,
      community: communityName,
      communityId: communityId,
      lodge: nil,
      initialRiverName: snapshot.initialRiverName,
      initialSpecies: snapshot.initialSpecies,
      initialLifecycleStage: snapshot.initialLifecycleStage,
      initialSex: snapshot.initialSex,
      initialLengthInches: snapshot.initialLengthInches,
      mlFeatureVector: snapshot.mlFeatureVector,
      lengthSource: snapshot.lengthSource,
      modelVersion: snapshot.modelVersion,
      girthInches: snapshot.girthInches,
      weightLbs: snapshot.weightLbs,
      weightDivisor: snapshot.weightDivisor,
      weightDivisorSource: snapshot.weightDivisorSource,
      girthRatio: snapshot.girthRatio,
      girthRatioSource: snapshot.girthRatioSource,
      initialLengthForMeasurements: snapshot.initialLengthForMeasurements,
      initialGirthInches: snapshot.initialGirthInches,
      initialWeightLbs: snapshot.initialWeightLbs,
      initialWeightDivisor: snapshot.initialWeightDivisor,
      initialWeightDivisorSource: snapshot.initialWeightDivisorSource,
      initialGirthRatio: snapshot.initialGirthRatio,
      initialGirthRatioSource: snapshot.initialGirthRatioSource,
      conservationOptIn: snapshot.conservationOptIn,
      mlTrainingOptOut: snapshot.mlTrainingOptOut,
      floyId: snapshot.floyId,
      pitId: snapshot.pitId,
      scaleEnvelopeId: snapshot.scaleEnvelopeId,
      finEnvelopeId: snapshot.finEnvelopeId,
      appVersion: appVersion,
      deviceDescription: deviceDescription,
      platform: "iOS",
      catchDate: chatVM.photoTimestamp
    )

    let reportCountAfter = CatchReportStore.shared.reports.count
    AppLogging.log("[ResearcherSave] reports before=\(reportCountBefore) after=\(reportCountAfter) — \(reportCountAfter > reportCountBefore ? "SAVED OK" : "⚠️ REPORT NOT ADDED")", level: .debug, category: .catch)
  }
}
