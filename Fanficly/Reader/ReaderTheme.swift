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
    static let defaultFontSize: Double = 18
    static let fontSizeRange: ClosedRange<Double> = 12...30

    static let defaultLineSpacing: Double = 6
    static let lineSpacingRange: ClosedRange<Double> = 0...20

    static let defaultParagraphSpacing: Double = 16
    static let paragraphSpacingRange: ClosedRange<Double> = 2...44

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
        ("Compact", 8), ("Normal", 16), ("Roomy", 26), ("Airy", 38),
    ]
    static let kerningPresets: [(name: String, value: Double)] = [
        ("Tight", -0.2), ("Standard", 0.0), ("Medium", 0.5), ("Wide", 1.2), ("Extra Wide", 2.2)
    ]
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
