import SwiftUI

struct ReaderProfile: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    var themeRaw: String
    var fontFamilyRaw: String
    var widthRaw: String?
    var widthPercent: Double?
    var modeRaw: String
    var fontSizePt: Double
    var lineSpacingPt: Double
    var paragraphSpacingPt: Double
    var pageTurnHaptics: Bool
    var pageTurnAnimations: Bool
    var kerningPt: Double?
    var boldText: Bool?

    @MainActor
    static var deviceActiveProfileKey: String {
        #if targetEnvironment(macCatalyst)
        return "reader.activeProfile.mac"
        #else
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return "reader.activeProfile.pad"
        case .phone:
            return "reader.activeProfile.phone"
        default:
            return "reader.activeProfile.phone"
        }
        #endif
    }

    @MainActor
    static func deviceKey(_ baseKey: String) -> String {
        #if targetEnvironment(macCatalyst)
        return "\(baseKey).mac"
        #else
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return "\(baseKey).pad"
        case .phone:
            return "\(baseKey).phone"
        default:
            return "\(baseKey).phone"
        }
        #endif
    }

    @MainActor
    static func migrateLegacySettingsIfNeeded() {
        let defaults = UserDefaults.standard
        let suffix: String
        #if targetEnvironment(macCatalyst)
        suffix = ".mac"
        #else
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            suffix = ".pad"
        case .phone:
            suffix = ".phone"
        default:
            suffix = ".phone"
        }
        #endif

        let keys = [
            "reader.theme",
            "reader.fontFamily",
            "reader.widthPercent",
            "reader.mode",
            "reader.fontSizePt",
            "reader.lineSpacingPt",
            "reader.paragraphSpacingPt",
            "reader.pageTurnHaptics",
            "reader.pageTurnAnimations",
            "reader.kerningPt",
            "reader.boldText"
        ]

        for key in keys {
            let deviceKey = key + suffix
            if defaults.object(forKey: deviceKey) == nil {
                if let legacyValue = defaults.object(forKey: key) {
                    defaults.set(legacyValue, forKey: deviceKey)
                }
            }
        }
    }

    static let defaultProfiles: [ReaderProfile] = [
        ReaderProfile(
            name: "Default",
            themeRaw: ReaderTheme.system.rawValue,
            fontFamilyRaw: ReaderFontFamily.newYork.rawValue,
            widthRaw: ReaderWidth.medium.rawValue,
            widthPercent: 70.0,
            modeRaw: ReadingMode.continuous.rawValue,
            fontSizePt: ReaderMetrics.defaultFontSize,
            lineSpacingPt: ReaderMetrics.defaultLineSpacing,
            paragraphSpacingPt: ReaderMetrics.defaultParagraphSpacing,
            pageTurnHaptics: false,
            pageTurnAnimations: true,
            kerningPt: ReaderMetrics.defaultKerning,
            boldText: false
        )
    ]

    static func loadProfiles(from jsonString: String) -> [ReaderProfile] {
        guard let data = jsonString.data(using: .utf8),
              var list = try? JSONDecoder().decode([ReaderProfile].self, from: data) else {
            return defaultProfiles
        }
        for i in 0..<list.count {
            if list[i].widthPercent == nil {
                if let raw = list[i].widthRaw {
                    switch raw {
                    case "narrow": list[i].widthPercent = 50.0
                    case "medium": list[i].widthPercent = 70.0
                    case "wide": list[i].widthPercent = 85.0
                    case "full": list[i].widthPercent = 100.0
                    default: list[i].widthPercent = 70.0
                    }
                } else {
                    list[i].widthPercent = 70.0
                }
            }
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
