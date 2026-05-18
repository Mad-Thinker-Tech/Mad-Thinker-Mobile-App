//
//  EnvironmentBanner.swift
//  SkeenaSystem
//
//  Reads ENVIRONMENT_LABEL from Info.plist and renders a colored banner
//  above content for non-production builds so TestFlight beta testers
//  immediately know whether they're on synthetic or production data.
//
//  Color scheme:
//  - DEV   : teal banner (#609BAB)
//  - STAGE : orange banner
//  - PROD or empty : no banner
//  - anything else : gray banner with raw label text
//

import SwiftUI

struct EnvironmentBanner: ViewModifier {
    private var label: String? {
        let value = Bundle.main.infoDictionary?["ENVIRONMENT_LABEL"] as? String
        guard let value, !value.isEmpty, value != "PROD" else { return nil }
        return value
    }

    private var bannerColor: Color {
        switch label {
        case "DEV": return Color(hex: "#609BAB")
        case "STAGE": return .orange
        default: return .gray
        }
    }

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if let label {
                Text(label)
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background(bannerColor)
            }
            content
        }
    }
}

extension View {
    /// Adds an environment indicator banner above the view for non-production builds.
    func environmentBanner() -> some View {
        self.modifier(EnvironmentBanner())
    }
}

// MARK: - Preview

#Preview("DEV banner") {
    Color.gray
        .overlay(Text("Content").foregroundColor(.white))
        .environmentBanner()
        .onAppear {
            // Note: Preview doesn't read real Info.plist; this is illustrative.
        }
}
