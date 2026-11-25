import SwiftUI
import UIKit

enum Typography {
    static let readerBody: Font = .system(.body, design: .serif)
    static let readerTitle: Font = .system(.largeTitle, design: .serif, weight: .bold)
    static let chip: Font = .caption.weight(.medium)
    static let sidebar: Font = .body
}

enum Spacing {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 24
    static let xxl: CGFloat = 32
}

extension View {
    /// Centers this view (a badge or status icon) on the first line of the
    /// `style` text beside it in an `HStack(alignment: .firstTextBaseline)`.
    /// Baseline alignment alone sits a smaller badge on the title's baseline,
    /// so it hangs below the title's middle; this puts the badge's middle at
    /// the title's cap-height middle instead. A title that wraps keeps the
    /// badge on its first line.
    func centeredOnFirstLine(of style: UIFont.TextStyle) -> some View {
        modifier(FirstLineCentering(style: style))
    }
}

private struct FirstLineCentering: ViewModifier {
    let style: UIFont.TextStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        // The font SwiftUI draws the style with at this text size, on this
        // idiom (the Mac's headline is smaller than the iPhone's).
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceIdiom: UIDevice.current.userInterfaceIdiom),
            UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize)),
        ])
        let capHeight = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).capHeight
        content.alignmentGuide(.firstTextBaseline) { d in
            d[VerticalAlignment.center] + capHeight / 2
        }
    }
}
