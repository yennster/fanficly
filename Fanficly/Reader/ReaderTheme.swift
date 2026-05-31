import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system, light, sepia, dark, oledBlack

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:    "Match System"
        case .light:     "Light"
        case .sepia:     "Sepia"
        case .dark:      "Dark"
        case .oledBlack: "OLED Black"
        }
    }

    func background(for scheme: ColorScheme) -> Color {
        switch self {
        case .system:    Color(.systemBackground)
        case .light:     Color(red: 0.99, green: 0.99, blue: 0.97)
        case .sepia:     Color(red: 0.97, green: 0.93, blue: 0.85)
        case .dark:      Color(red: 0.12, green: 0.12, blue: 0.13)
        case .oledBlack: Color.black
        }
    }

    func foreground(for scheme: ColorScheme) -> Color {
        switch self {
        case .system:    Color(.label)
        case .light:     Color(red: 0.08, green: 0.08, blue: 0.10)
        case .sepia:     Color(red: 0.30, green: 0.20, blue: 0.10)
        case .dark:      Color(red: 0.92, green: 0.92, blue: 0.90)
        case .oledBlack: Color(red: 0.88, green: 0.88, blue: 0.85)
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:                          nil
        case .light, .sepia:                   .light
        case .dark, .oledBlack:                .dark
        }
    }
}

enum ReaderFontSize: Int, CaseIterable, Identifiable {
    case xs = 13, small = 15, medium = 17, large = 20, xlarge = 23, xxlarge = 27

    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .xs:      "Extra Small"
        case .small:   "Small"
        case .medium:  "Medium"
        case .large:   "Large"
        case .xlarge:  "Extra Large"
        case .xxlarge: "Huge"
        }
    }
    var cgFloat: CGFloat { CGFloat(rawValue) }
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

enum ReaderLineSpacing: String, CaseIterable, Identifiable {
    case tight, normal, relaxed, loose

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .tight:   "Tight"
        case .normal:  "Normal"
        case .relaxed: "Relaxed"
        case .loose:   "Loose"
        }
    }
    var points: CGFloat {
        switch self {
        case .tight:   2
        case .normal:  6
        case .relaxed: 11
        case .loose:   16
        }
    }
}

enum ReadingMode: String, CaseIterable, Identifiable {
    case continuous, paginated

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .continuous: "Continuous scroll"
        case .paginated:  "Swipe by chapter"
        }
    }
    var symbol: String {
        switch self {
        case .continuous: "arrow.down"
        case .paginated:  "rectangle.split.3x1"
        }
    }
}
