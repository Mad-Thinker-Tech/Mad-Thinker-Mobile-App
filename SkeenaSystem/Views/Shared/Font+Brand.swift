import SwiftUI

// Brand typography tokens. Today they wrap the iOS system font (SF Pro).
// When the brand sans-serif arrives, swap each value to
// `Font.custom("FamilyName", size: <pt>, relativeTo: <textStyle>)`
// — call sites stay unchanged.
//
// Weight overrides remain at call sites (e.g. `.brandSubheadline.weight(.semibold)`)
// because weight usage is too varied to enumerate.
extension Font {
    static let brandLargeTitle  = Font.largeTitle
    static let brandTitle       = Font.title
    static let brandTitle2      = Font.title2
    static let brandTitle3      = Font.title3
    static let brandHeadline    = Font.headline
    static let brandBody        = Font.body
    static let brandSubheadline = Font.subheadline
    static let brandFootnote    = Font.footnote
    static let brandCaption     = Font.caption
    static let brandCaption2    = Font.caption2
}
