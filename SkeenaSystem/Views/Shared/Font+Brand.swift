import SwiftUI

// Brand typography tokens. Today they wrap the iOS system font.
// When the brand sans-serif arrives, swap each value to
// `Font.custom("FamilyName", size: <pt>, relativeTo: <textStyle>)`
// — call sites stay unchanged.
//
// Weight overrides remain at call sites (e.g. `.brandSubheadline.weight(.semibold)`)
// because weight usage is too varied to enumerate.
extension Font {
    static let brandLargeTitle  = Font.custom("NewYork", size: 34, relativeTo: .largeTitle)
    static let brandTitle       = Font.custom("NewYork", size: 28, relativeTo: .title)
    static let brandTitle2      = Font.custom("NewYork", size: 22, relativeTo: .title2)
    static let brandTitle3      = Font.custom("NewYork", size: 20, relativeTo: .title3)
    static let brandHeadline    = Font.custom("NewYork", size: 17, relativeTo: .headline)
    static let brandBody        = Font.custom("NewYork", size: 17, relativeTo: .body)
    static let brandSubheadline = Font.custom("NewYork", size: 15, relativeTo: .subheadline)
    static let brandFootnote    = Font.custom("NewYork", size: 13, relativeTo: .footnote)
    static let brandCaption     = Font.custom("NewYork", size: 12, relativeTo: .caption)
    static let brandCaption2    = Font.custom("NewYork", size: 11, relativeTo: .caption2)
}
