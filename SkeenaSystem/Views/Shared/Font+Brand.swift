import SwiftUI

// Brand typography tokens using New York (system serif).
// Font.system(_:design:.serif) is the correct path for New York — it supports
// all weight modifiers and Dynamic Type. Font.custom("NewYork", ...) triggers
// SwiftUI weight-descriptor warnings and doesn't resolve weights correctly.
//
// Weight overrides remain at call sites (e.g. `.brandSubheadline.weight(.semibold)`)
// because weight usage is too varied to enumerate.
extension Font {
    static let brandLargeTitle  = Font.system(.largeTitle,  design: .serif)
    static let brandTitle       = Font.system(.title,       design: .serif)
    static let brandTitle2      = Font.system(.title2,      design: .serif)
    static let brandTitle3      = Font.system(.title3,      design: .serif)
    static let brandHeadline    = Font.system(.headline,    design: .serif)
    static let brandBody        = Font.system(.body,        design: .serif)
    static let brandSubheadline = Font.system(.subheadline, design: .serif)
    static let brandFootnote    = Font.system(.footnote,    design: .serif)
    static let brandCaption     = Font.system(.caption,     design: .serif)
    static let brandCaption2    = Font.system(.caption2,    design: .serif)
}
