import SwiftUI

struct ReaderProfile: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    var themeRaw: String
    var fontFamilyRaw: String
    var widthRaw: String
    var modeRaw: String
    var fontSizePt: Double
    var lineSpacingPt: Double
    var paragraphSpacingPt: Double
    var pageTurnHaptics: Bool
    var pageTurnAnimations: Bool

    static let defaultProfiles: [ReaderProfile] = [
        ReaderProfile(
            name: "Default",
            themeRaw: ReaderTheme.system.rawValue,
            fontFamilyRaw: ReaderFontFamily.newYork.rawValue,
            widthRaw: ReaderWidth.medium.rawValue,
            modeRaw: ReadingMode.continuous.rawValue,
            fontSizePt: ReaderMetrics.defaultFontSize,
            lineSpacingPt: ReaderMetrics.defaultLineSpacing,
            paragraphSpacingPt: ReaderMetrics.defaultParagraphSpacing,
            pageTurnHaptics: false,
            pageTurnAnimations: true
        )
    ]

    static func loadProfiles(from jsonString: String) -> [ReaderProfile] {
        guard let data = jsonString.data(using: .utf8),
              let list = try? JSONDecoder().decode([ReaderProfile].self, from: data) else {
            return defaultProfiles
        }
        return list
    }

    static func saveProfiles(_ list: [ReaderProfile]) -> String {
        guard let data = try? JSONEncoder().encode(list),
              let str = String(data: data, encoding: .utf8) else {
            return ""
        }
        return str
    }
}
