// SocialFeedView.swift — Placeholder Instagram-style social feed
//
// Demo-only: all data is hardcoded. This will be replaced by a 3rd-party
// social service integration. Lives in the platform layer (Views/Components/)
// because social feeds are not discipline-specific.

import SwiftUI

// MARK: - Mock data

enum SocialFeed { case madThinker, community }

struct SocialPost: Identifiable {
  let id: Int
  let username: String
  let avatarSystemName: String
  /// Asset catalog image name, or nil to show a colored SF Symbol placeholder.
  let assetImage: String?
  let placeholderIcon: String
  let placeholderColor: Color
  let caption: String
  let likesCount: Int
  let commentsCount: Int
  let timeAgo: String
  let feed: SocialFeed
}

private let mockPosts: [SocialPost] = [
  // Mad Thinker feed (5 posts)
  SocialPost(id: 1, username: "river_runner", avatarSystemName: "person.circle.fill",
             assetImage: "social_feed_1", placeholderIcon: "photo", placeholderColor: .brandAccent,
             caption: "Beautiful morning on the water. Can't beat this view!",
             likesCount: 42, commentsCount: 7, timeAgo: "2h", feed: .madThinker),
  SocialPost(id: 2, username: "tightlines_tom", avatarSystemName: "person.circle.fill",
             assetImage: "social_feed_2", placeholderIcon: "photo.fill", placeholderColor: .teal,
             caption: "First catch of the season -- she put up a fight",
             likesCount: 89, commentsCount: 14, timeAgo: "4h", feed: .madThinker),
  SocialPost(id: 3, username: "backcountry_beth", avatarSystemName: "person.circle.fill",
             assetImage: "social_feed_3", placeholderIcon: "photo", placeholderColor: .green,
             caption: "Hiked in to a remote stretch today. Worth every step.",
             likesCount: 63, commentsCount: 5, timeAgo: "6h", feed: .madThinker),
  SocialPost(id: 4, username: "drift_and_cast", avatarSystemName: "person.circle.fill",
             assetImage: "social_feed_4", placeholderIcon: "photo.fill", placeholderColor: .orange,
             caption: "Golden hour on the Deschutes",
             likesCount: 112, commentsCount: 21, timeAgo: "8h", feed: .madThinker),
  SocialPost(id: 5, username: "mayfly_mike", avatarSystemName: "person.circle.fill",
             assetImage: "social_feed_5", placeholderIcon: "photo", placeholderColor: .purple,
             caption: "Nothing beats a heli drop into untouched water",
             likesCount: 37, commentsCount: 3, timeAgo: "10h", feed: .madThinker),
  // Community feed (5 posts)
  SocialPost(id: 6, username: "steelhead_sarah", avatarSystemName: "person.circle.fill",
             assetImage: "social_feed_6", placeholderIcon: "photo.fill", placeholderColor: .pink,
             caption: "Chrome bright and full of energy. What a grab!",
             likesCount: 201, commentsCount: 34, timeAgo: "12h", feed: .community),
  SocialPost(id: 7, username: "wading_deep", avatarSystemName: "person.circle.fill",
             assetImage: "social_feed_7", placeholderIcon: "photo", placeholderColor: .cyan,
             caption: "Fog lifting off the river this morning",
             likesCount: 55, commentsCount: 8, timeAgo: "1d", feed: .community),
  SocialPost(id: 8, username: "catch_and_release", avatarSystemName: "person.circle.fill",
             assetImage: "social_feed_8", placeholderIcon: "photo.fill", placeholderColor: .indigo,
             caption: "Teaching the next generation. She landed her first one today!",
             likesCount: 178, commentsCount: 29, timeAgo: "1d", feed: .community),
  SocialPost(id: 9, username: "flybox_addict", avatarSystemName: "person.circle.fill",
             assetImage: "social_feed_9", placeholderIcon: "photo", placeholderColor: .mint,
             caption: "Tying some streamers for tomorrow. The vise doesn't rest.",
             likesCount: 44, commentsCount: 6, timeAgo: "2d", feed: .community),
  SocialPost(id: 10, username: "riverbend_guide", avatarSystemName: "person.circle.fill",
             assetImage: "social_feed_10", placeholderIcon: "photo.fill", placeholderColor: .brown,
             caption: "Another day at the office. Not a bad commute.",
             likesCount: 95, commentsCount: 11, timeAgo: "2d", feed: .community),
]

// MARK: - Social Feed View

struct SocialFeedView: View {
  @Environment(\.navigateTo) private var navigateTo
  @ObservedObject private var communityService = CommunityService.shared
  @State private var likedPosts: Set<Int> = []
  @State private var showMadThinker = true

  private var communityName: String {
    communityService.activeCommunityConfig.displayName ?? "Community"
  }

  private var filteredPosts: [SocialPost] {
    mockPosts.filter { $0.feed == (showMadThinker ? .madThinker : .community) }
  }

  var body: some View {
    DarkPageTemplate(bottomToolbar: {
      RoleAwareToolbar(activeTab: "community")
    }) {
      ScrollView {
        VStack(spacing: 0) {
          // Feed scope toggle
          FeedScopeToggle(showMadThinker: $showMadThinker, communityName: communityName)
            .padding(.vertical, 8)

          LazyVStack(spacing: 0) {
            ForEach(filteredPosts) { post in
              SocialPostCard(post: post, isLiked: likedPosts.contains(post.id)) {
                toggleLike(post.id)
              }
              Divider()
                .background(Color.brandStroke)
            }
          }
        }
      }
    }
    .navigationTitle("Social")
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: {}) {
          Image(systemName: "plus.app")
            .font(.brandTitle3)
            .foregroundColor(.brandTextPrimary)
        }
      }
    }
  }

  private func toggleLike(_ id: Int) {
    if likedPosts.contains(id) {
      likedPosts.remove(id)
    } else {
      likedPosts.insert(id)
    }
  }
}

// MARK: - Post Card

private struct SocialPostCard: View {
  let post: SocialPost
  let isLiked: Bool
  let onLike: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header — avatar + username
      HStack(spacing: 10) {
        Image(systemName: post.avatarSystemName)
          .font(.brandTitle2)
          .foregroundColor(.brandTextPrimary.opacity(0.7))
        Text(post.username)
          .font(.brandSubheadline.weight(.semibold))
          .foregroundColor(.brandTextPrimary)
        Spacer()
        Text(post.timeAgo)
          .font(.brandCaption)
          .foregroundColor(.brandTextSecondary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)

      // Photo — real asset or colored placeholder
      if let asset = post.assetImage, UIImage(named: asset) != nil {
        GeometryReader { geo in
          Image(asset)
            .resizable()
            .scaledToFill()
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .frame(height: 360)
      } else {
        ZStack {
          post.placeholderColor.opacity(0.3)
          Image(systemName: post.placeholderIcon)
            .font(.system(size: 48))
            .foregroundColor(post.placeholderColor.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 360)
        .clipped()
      }

      // Action bar — like, comment, share, bookmark
      HStack(spacing: 18) {
        Button(action: onLike) {
          Image(systemName: isLiked ? "heart.fill" : "heart")
            .font(.brandTitle3)
            .foregroundColor(isLiked ? .red : .white)
        }
        .buttonStyle(.plain)

        Image(systemName: "bubble.right")
          .font(.brandTitle3)
          .foregroundColor(.brandTextPrimary)

        Image(systemName: "paperplane")
          .font(.brandTitle3)
          .foregroundColor(.brandTextPrimary)

        Spacer()

        Image(systemName: "bookmark")
          .font(.brandTitle3)
          .foregroundColor(.brandTextPrimary)
      }
      .padding(.horizontal, 14)
      .padding(.top, 10)

      // Likes count
      let adjustedLikes = isLiked ? post.likesCount + 1 : post.likesCount
      Text("\(adjustedLikes) likes")
        .font(.brandSubheadline.weight(.semibold))
        .foregroundColor(.brandTextPrimary)
        .padding(.horizontal, 14)
        .padding(.top, 4)

      // Caption
      HStack(spacing: 0) {
        Text(post.username)
          .font(.brandSubheadline.weight(.semibold))
          .foregroundColor(.brandTextPrimary)
        Text(" ")
        Text(post.caption)
          .font(.brandSubheadline)
          .foregroundColor(.brandTextPrimary.opacity(0.9))
      }
      .padding(.horizontal, 14)
      .padding(.top, 2)
      .lineLimit(2)

      // Comments link
      if post.commentsCount > 0 {
        Text("View all \(post.commentsCount) comments")
          .font(.brandSubheadline)
          .foregroundColor(.brandTextSecondary)
          .padding(.horizontal, 14)
          .padding(.top, 4)
      }

      Spacer().frame(height: 12)
    }
  }
}

// MARK: - Feed Scope Toggle

private struct FeedScopeToggle: View {
  @Binding var showMadThinker: Bool
  let communityName: String

  var body: some View {
    HStack(spacing: 0) {
      toggleButton(label: "Mad Thinker", isSelected: showMadThinker) {
        showMadThinker = true
      }
      toggleButton(label: communityName, isSelected: !showMadThinker) {
        showMadThinker = false
      }
    }
    .background(Color.brandSurface, in: Capsule())
    .padding(.horizontal, 40)
  }

  @ViewBuilder
  private func toggleButton(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button {
      withAnimation(.easeInOut(duration: 0.2)) { action() }
    } label: {
      Text(label)
        .font(.brandSubheadline.weight(.semibold))
        .foregroundColor(isSelected ? .black : .white.opacity(0.6))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(isSelected ? Color.brandTextPrimary : Color.clear, in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}
