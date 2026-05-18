import SwiftUI
import UIKit

// Brand color tokens. Today's values mirror the existing dark-first palette.
// When new branding lands (including the planned shift to a lighter background),
// edit only the values below — call sites stay unchanged.
//
// SwiftUI tokens (`Color.brand…`) and UIKit tokens (`UIColor.brand…`) are kept
// side-by-side here so they cannot drift apart during a rebrand.
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    // Backgrounds & surfaces
    static let brandBackground    = Color(hex: "#0B1019")          // deep blue
    static let brandSurface       = Color.white.opacity(0.08)
    static let brandSurfaceMuted  = Color.white.opacity(0.05)
    static let brandNavBar        = Color(hex: "#0B1019")          // seamless with background

    // Strokes & dividers
    static let brandStroke        = Color.white.opacity(0.12)
    static let brandStrokeStrong  = Color.white.opacity(0.15)
    static let brandStrokeSubtle  = Color.white.opacity(0.06)

    // Text
    static let brandTextPrimary   = Color(hex: "#F5F2ED")          // off white
    static let brandTextSecondary = Color(hex: "#F5F2ED").opacity(0.6)
    static let brandTextTertiary  = Color(hex: "#F5F2ED").opacity(0.45)

    // Action & status
    static let brandAccent           = Color(hex: "#47B2F6")       // deep sky blue — primary buttons
    static let brandSuccess          = Color(hex: "#609BAB")       // teal blue — predictions & accents
    static let brandSecondaryAccent  = Color(hex: "#D3ECED")       // soft cyan — secondary options
    static let brandWarning          = Color.orange
    static let brandError            = Color.red

    /// Translucent dark overlay used on top of photos/maps for text legibility.
    static let brandScrim = Color.black

    /// Explicitly white islands within an otherwise dark UI (e.g. a white pill).
    static let brandSurfaceInverted = Color.white

    /// Text/icon color on top of `brandSurfaceInverted` or other light backgrounds.
    static let brandTextOnLight = Color.black

    // MARK: - Researcher Role aliases
    // All roles now share the same palette; these aliases keep the researcher
    // views compiling without a mass rename.
    static let researcherBackground      = brandBackground
    static let researcherTextPrimary     = brandTextPrimary
    static let researcherAccent          = brandAccent
    static let researcherPrediction      = brandSuccess
    static let researcherSecondaryAccent = brandSecondaryAccent
}

// UIKit equivalents for places that touch UIAppearance / UIKit APIs directly
// (e.g. `UINavigationBarAppearance` in `DarkPageTemplate.swift` and
// `UITextView.backgroundColor` in form sheets).
extension UIColor {
    static let brandBackground = UIColor(red: 0x0B/255, green: 0x10/255, blue: 0x19/255, alpha: 1)
    static let brandNavBar     = UIColor(red: 0x0B/255, green: 0x10/255, blue: 0x19/255, alpha: 1)
    static let brandTextPrimary = UIColor(red: 245/255, green: 242/255, blue: 237/255, alpha: 1)
    static let brandAccent     = UIColor(red: 0x47/255, green: 0xB2/255, blue: 0xF6/255, alpha: 1)
    static let brandSurface    = UIColor.white.withAlphaComponent(0.08)

    // Researcher aliases — same palette as global tokens
    static let researcherBackground = brandBackground
    static let researcherAccent     = brandAccent
}
