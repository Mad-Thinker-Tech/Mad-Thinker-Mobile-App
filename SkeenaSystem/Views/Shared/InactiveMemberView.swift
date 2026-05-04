//
//  InactiveMemberView.swift
//  SkeenaSystem
//
//  Shown when the current user's membership in the active community
//  has been deactivated by a guide or admin.
//

import SwiftUI

struct InactiveMemberView: View {
    @StateObject private var communityService = CommunityService.shared
    @StateObject private var auth = AuthService.shared
    @State private var showJoinCommunity = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                HStack {
                    Spacer()
                    Button(action: logoutTapped) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle.badge.xmark")
                                .font(.title3.weight(.semibold))
                            Text("Log out")
                                .font(.footnote.weight(.semibold))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("logoutCapsule")
                }
                .padding(.horizontal, 20)

                Image(systemName: "person.crop.circle.badge.minus")
                    .font(.system(size: 56))
                    .foregroundColor(.orange)

                Text("Community Membership Inactive")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text("Your membership in **\(communityService.activeCommunityName)** is currently inactive. Please contact your guide or lodge administrator to restore access.")
                    .font(.body)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if communityService.hasMultipleCommunities {
                    Button {
                        communityService.clearActiveCommunity()
                    } label: {
                        Text("Switch Community")
                            .font(.headline)
                            .foregroundColor(.black)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.white)
                            .cornerRadius(10)
                    }
                }

                Button {
                    showJoinCommunity = true
                } label: {
                    Text(communityService.hasMultipleCommunities ? "Join Another Community" : "Join a Community")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.white, lineWidth: 1)
                        )
                }

                Button {
                    Task {
                        // Re-hydrate both profile (first/last name) and membership
                        // state. If the admin just activated this member, the
                        // landing view we route into next reads auth.currentFirstName /
                        // currentLastName — if loadUserProfile never completed on
                        // launch (token race, offline cache path), they'd render blank.
                        async let profile: Void = auth.loadUserProfile()
                        async let memberships: Void = communityService.fetchMemberships()
                        _ = await (profile, memberships)
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
            }
        }
        .sheet(isPresented: $showJoinCommunity) {
            JoinCommunityView()
                .preferredColorScheme(.dark)
        }
    }

    private func logoutTapped() {
        Task {
            await auth.signOutRemote()
            await MainActor.run {
                AuthStore.shared.clear()
            }
        }
    }
}
