//
//  CommunityLogoView.swift
//  SkeenaSystem
//
//  Displays the community logo with a three-tier fallback:
//  1. Persistent on-device cache (CommunityLogoCache) — survives launches,
//     works offline once a community's logo has been seen online at least
//     once. URL-keyed so two communities sharing a logo dedupe automatically.
//  2. Remote download — on cache miss the view fetches and caches the logo
//     itself via .task(id: logoUrl), then re-renders. No dependency on
//     CommunityService.fetchMemberships() pre-filling the cache.
//  3. Bundled asset — Image(config.resolvedLogoAssetName) during load/failure.
//     Falls back to "AppLogo" (Mad Thinker mark) when no asset name is set.
//
//  No spinner is shown — the bundled asset renders immediately while the
//  remote image loads, so there is no visual flicker.
//

import SwiftUI

struct CommunityLogoView: View {
    let config: CommunityConfig
    var size: CGFloat = 160

    @State private var resolvedImage: UIImage?

    var body: some View {
        Group {
            if let uiImage = resolvedImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
            } else {
                bundledLogo
            }
        }
        .frame(width: size, height: size)
        .task(id: config.logoUrl) {
            await loadLogo()
        }
    }

    // Tier 3/4: Bundled asset (resolvedLogoAssetName falls back to "AppLogo",
    // which is the Mad Thinker neutral mark — not any community's branding).
    private var bundledLogo: some View {
        Image(config.resolvedLogoAssetName)
            .resizable()
            .scaledToFit()
    }

    private func loadLogo() async {
        guard let urlString = config.logoUrl, let url = URL(string: urlString) else {
            resolvedImage = nil
            return
        }
        // Tier 1: synchronous cache hit (NSCache or disk)
        if let data = CommunityLogoCache.shared.loadData(for: url),
           let img = UIImage(data: data) {
            resolvedImage = img
            return
        }
        // Tier 2: download, cache, then display
        await CommunityLogoCache.shared.cache(url)
        if let data = CommunityLogoCache.shared.loadData(for: url),
           let img = UIImage(data: data) {
            resolvedImage = img
        }
    }
}
