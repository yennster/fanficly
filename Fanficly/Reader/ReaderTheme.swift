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
    case small = 14, medium = 17, large = 20, xlarge = 23

    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .small:  "Small"
        case .medium: "Medium"
        case .large:  "Large"
        case .xlarge: "Extra Large"
        }
    }
    var cgFloat: CGFloat { CGFloat(rawValue) }
}
