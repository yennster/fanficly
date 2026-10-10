import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system, light, sepia, dark, oledBlack, dracula

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:    "Match System"
        case .light:     "Light"
        case .sepia:     "Sepia"
        case .dark:      "Dark"
        case .oledBlack: "OLED Black"
        case .dracula:   "Dracula Navy"
        }
    }

    func background(for scheme: ColorScheme) -> Color {
        switch self {
        case .system:    Color(.systemBackground)
        case .light:     Color(red: 0.99, green: 0.99, blue: 0.97)
        case .sepia:     Color(red: 0.97, green: 0.93, blue: 0.85)
        case .dark:      Color(red: 0.12, green: 0.12, blue: 0.13)
        case .oledBlack: Color.black
        case .dracula:   Color(red: 0.157, green: 0.165, blue: 0.212)
        }
    }

    func foreground(for scheme: ColorScheme) -> Color {
        switch self {
        case .system:    Color(.label)
        case .light:     Color(red: 0.08, green: 0.08, blue: 0.10)
        case .sepia:     Color(red: 0.30, green: 0.20, blue: 0.10)
        case .dark:      Color(red: 0.92, green: 0.92, blue: 0.90)
        case .oledBlack: Color(red: 0.88, green: 0.88, blue: 0.85)
        case .dracula:   Color(red: 0.973, green: 0.973, blue: 0.949)
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:                          nil
        case .light, .sepia:                   .light
        case .dark, .oledBlack, .dracula:      .dark
        }
    }
}

/// Numeric reader metrics adjusted by sliders in Settings. Stored as raw
/// point values in @AppStorage so they can vary continuously.
enum ReaderMetrics {
    /// The reading column: `widthPercent` of the container, capped at
    /// `maxLineLengthEm` (~80 characters) when `limitLineLength`. The phone
    /// profile sets it: its width was tuned on a ~400pt screen, and the same
    /// percentage stretches lines unreadably across a wide phone layout — a
    /// Pro Max in landscape, or iPhone Duo's 7.6" inner display, which stays
    /// the phone idiom (and phone settings) while unfolded.
    static func textColumnWidth(containerWidth: CGFloat, widthPercent: Double,
                                fontSize: Double, limitLineLength: Bool) -> CGFloat {
        let column = containerWidth * CGFloat(widthPercent / 100.0)
        guard limitLineLength else { return column }
        return min(column, CGFloat(fontSize * maxLineLengthEm))
    }

    static let maxLineLengthEm: Double = 40

    static let defaultFontSize: Double = 18
    static let fontSizeRange: ClosedRange<Double> = 12...30

    static let defaultLineSpacing: Double = 6
    static let lineSpacingRange: ClosedRange<Double> = 0...20

    static let defaultParagraphSpacing: Double = 16
    static let paragraphSpacingRange: ClosedRange<Double> = 2...80

    static let defaultKerning: Double = 0.0
    static let kerningRange: ClosedRange<Double> = -0.5...3.0

    // Named presets for the reader's quick (Aa) menu. The Settings screen
    // exposes the same values as continuous sliders.
    static let fontSizePresets: [(name: String, value: Double)] = [
        ("Extra Small", 13), ("Small", 15), ("Medium", 18),
        ("Large", 20), ("Extra Large", 23), ("Huge", 27),
    ]
    static let lineSpacingPresets: [(name: String, value: Double)] = [
        ("Tight", 2), ("Normal", 6), ("Relaxed", 11), ("Loose", 16),
    ]
    static let paragraphSpacingPresets: [(name: String, value: Double)] = [
        ("Compact", 8), ("Normal", 16), ("Roomy", 26),
        ("Airy", 38), ("Spacious", 56), ("Expansive", 72),
    ]
    static let kerningPresets: [(name: String, value: Double)] = [
        ("Tight", -0.2), ("Standard", 0.0), ("Medium", 0.5), ("Wide", 1.2), ("Extra Wide", 2.2)
    ]
}

/// Page-by-page's two-page spread: on a wide window (iPhone Duo unfolded,
/// iPad in landscape, the Mac) pages pair up side by side like an open book,
/// with the gutter on iPhone Duo's fold. Pure, so it's unit-tested.
enum ReaderSpread {
    /// Narrower windows keep one page: two columns of ~300 pt read cramped.
    static let minimumWidth: CGFloat = 700
    static let minimumAspect: CGFloat = 1.15
    /// The gutter between pages, also used around a fold thinner than this.
    static let minimumGutter: CGFloat = 56
    /// Two-page mode has its own text-width setting (`reader.spreadWidthPercent`):
    /// each page is half the window, where the one-page setting (70% by
    /// default) would leave wide empty margins on every page.
    static let defaultWidthPercent: Double = 88
    static let widthPercentRange: ClosedRange<Double> = 60...100
    static let widthPresets: [(name: String, value: Double)] = [
        ("Narrow (70%)", 70), ("Medium (80%)", 80), ("Wide (88%)", 88), ("Full (100%)", 100),
    ]

    struct Layout: Equatable {
        /// Both pages share this width, so they paginate identically.
        let pageWidth: CGFloat
        /// Leading x of the left page; the right page starts at `gutter.upperBound`.
        let leftX: CGFloat
        let gutter: ClosedRange<CGFloat>
    }

    /// The spread for a container, or nil when it's too narrow for two pages.
    /// `fold` is iPhone Duo's division region (in the container's space); a
    /// vertical one near the middle becomes the gutter, otherwise it's centered.
    static func layout(containerSize: CGSize, fold: CGRect?) -> Layout? {
        let w = containerSize.width
        guard w >= minimumWidth, w >= containerSize.height * minimumAspect else { return nil }
        var center = w / 2
        var gutterWidth = minimumGutter
        if let fold, fold.height > fold.width, fold.midX > w * 0.3, fold.midX < w * 0.7 {
            center = fold.midX
            gutterWidth = max(fold.width, minimumGutter)
        }
        let gutter = (center - gutterWidth / 2)...(center + gutterWidth / 2)
        let pageWidth = floor(min(gutter.lowerBound, w - gutter.upperBound))
        guard pageWidth >= 280 else { return nil }
        return Layout(pageWidth: pageWidth, leftX: gutter.lowerBound - pageWidth, gutter: gutter)
    }

    struct Spread: Identifiable, Equatable {
        let left: ChapterPage
        let right: ChapterPage?
        var id: String { left.id }
        func contains(_ pageId: String) -> Bool { left.id == pageId || right?.id == pageId }
    }

    /// Pairs pages two by two within each chapter, so every chapter opens on
    /// a fresh spread (and the pairing doesn't shift as neighboring chapters
    /// load); a chapter with an odd page count ends on a lone left page.
    static func spreads(from pages: [ChapterPage]) -> [Spread] {
        var out: [Spread] = []
        var i = 0
        while i < pages.count {
            let left = pages[i]
            let next = i + 1 < pages.count ? pages[i + 1] : nil
            if let next, next.chapterIndex == left.chapterIndex {
                out.append(Spread(left: left, right: next))
                i += 2
            } else {
                out.append(Spread(left: left, right: nil))
                i += 1
            }
        }
        return out
    }
}

/// The height page-by-page measures its pages for: the page area with the
/// reader controls (nav bar, page footer, narration bar) showing, so a page
/// always fits on screen and hiding the controls only adds bottom margin.
///
/// Pages shrink as soon as the area does, but grow back only once it has held
/// still (`settle`). The area is briefly smaller now and then (a navigation
/// transition, the narration bar, a keyboard inset); when pages could only
/// ever shrink, one such moment left a band of blank space at the foot of
/// every page until the window itself changed size. Pure, so it's unit-tested.
struct PageAreaTracker {
    /// The height pages are measured for (0 = nothing seen yet).
    private(set) var pageHeight: CGFloat = 0
    /// The settled page area with the controls up at this window size (0 =
    /// not seen yet). With the controls hidden the area is taller than a page
    /// may be, so pages grow no further than this.
    private(set) var controlsUpHeight: CGFloat = 0

    /// A new window size (rotation, a split-view resize, iPhone Duo pinning a
    /// video above the app): start over from the area on screen.
    mutating func reset(to area: CGFloat) {
        pageHeight = area
        controlsUpHeight = 0
    }

    /// The page area changed: shrink at once, so text never runs under the controls.
    mutating func observe(_ area: CGFloat) {
        if area < pageHeight - 1 { pageHeight = area }
    }

    /// The page area has held still at `area`: grow back to it, or with the
    /// controls hidden, to the controls-up area at most.
    mutating func settle(_ area: CGFloat, controlsUp: Bool) {
        if controlsUp { controlsUpHeight = area }
        let ceiling = controlsUp ? area : min(area, controlsUpHeight)
        if ceiling > pageHeight + 1 { pageHeight = ceiling }
    }
}

enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case newYork  = "newYork"
    case serif    = "serif"
    case sans     = "sans"
    case rounded  = "rounded"
    case mono     = "mono"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .newYork: "New York"
        case .serif:   "System Serif"
        case .sans:    "System Sans"
        case .rounded: "Rounded"
        case .mono:    "Monospaced"
        }
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .newYork:
            if let custom = UIFont(name: "NewYorkLarge-Regular", size: size)
                ?? UIFont(name: "NewYork-Regular", size: size) {
                return Font(custom)
            }
            return .system(size: size, weight: weight, design: .serif)
        case .serif:   return .system(size: size, weight: weight, design: .serif)
        case .sans:    return .system(size: size, weight: weight, design: .default)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        case .mono:    return .system(size: size, weight: weight, design: .monospaced)
        }
    }

    func uiFont(size: CGFloat) -> UIFont {
        switch self {
        case .newYork:
            if let custom = UIFont(name: "NewYorkLarge-Regular", size: size)
                ?? UIFont(name: "NewYork-Regular", size: size) {
                return custom
            }
            if let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return .systemFont(ofSize: size)
        case .serif:
            if let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return .systemFont(ofSize: size)
        case .sans:
            return .systemFont(ofSize: size)
        case .rounded:
            if let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.rounded) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return .systemFont(ofSize: size)
        case .mono:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

enum ReaderWidth: String, CaseIterable, Identifiable {
    case narrow, medium, wide, full

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .narrow: "Narrow"
        case .medium: "Medium"
        case .wide:   "Wide"
        case .full:   "Full"
        }
    }

    /// Horizontal padding around the text column. Applied to the
    /// scroll content so that the text actually narrows on any device.
    var horizontalPadding: CGFloat {
        switch self {
        case .narrow: 44
        case .medium: 24
        case .wide:   12
        case .full:   2
        }
    }

    /// Maximum text-column width on large screens (iPad/landscape).
    /// Returns nil for `.full`, letting it stretch edge-to-edge.
    var maxColumnWidth: CGFloat? {
        switch self {
        case .narrow: 540
        case .medium: 720
        case .wide:   900
        case .full:   nil
        }
    }
}


enum ReadingMode: String, CaseIterable, Identifiable {
    case continuous, paginated, pageByPage

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .continuous: "Continuous scroll"
        case .paginated:  "Swipe by chapter"
        case .pageByPage: "Page-by-page"
        }
    }
    var symbol: String {
        switch self {
        case .continuous: "arrow.down"
        case .paginated:  "rectangle.split.3x1"
        case .pageByPage: "book.closed"
        }
    }
}
