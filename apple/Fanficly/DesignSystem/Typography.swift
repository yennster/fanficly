import SwiftUI

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
