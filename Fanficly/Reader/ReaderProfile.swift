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
    // Sync bookkeeping. Optional (like widthRaw) so pre-existing JSON still
    // decodes and older app versions ignore the unknown keys — the stored
    // top-level shape must stay a plain [ReaderProfile] array. An entry with
    // deletedAt set is a tombstone: it keeps its full payload (older decoders
    // would fail on missing required fields) and stays in the stored array so
    // the deletion propagates through mergedProfiles, but loadProfiles hides it.
    var updatedAt: Double? = nil
    var deletedAt: Double? = nil

    var isDeleted: Bool { deletedAt != nil }

    /// Tombstones older than this are pruned on save/merge. A device that
    /// hasn't synced within the window can resurrect the profile — the
    /// trade-off for not growing the stored JSON forever.
    static let tombstoneLifetime: TimeInterval = 90 * 24 * 60 * 60

    func isExpiredTombstone(at now: Date) -> Bool {
        guard let deletedAt else { return false }
        return now.timeIntervalSince1970 - deletedAt > Self.tombstoneLifetime
    }

    /// Equality ignoring the sync bookkeeping, used to decide whether a save
    /// actually changed a profile and should stamp a fresh updatedAt.
    func contentEquals(_ other: ReaderProfile) -> Bool {
        var lhs = self
        var rhs = other
        lhs.updatedAt = nil
        lhs.deletedAt = nil
        rhs.updatedAt = nil
        rhs.deletedAt = nil
        return lhs == rhs
    }

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

    /// Decodes every stored entry, including deletion tombstones. Display
    /// paths should use loadProfiles(from:), which filters tombstones out.
    static func decodeProfiles(from jsonString: String) -> [ReaderProfile]? {
        guard let data = jsonString.data(using: .utf8),
              var list = try? JSONDecoder().decode([ReaderProfile].self, from: data) else {
            return nil
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

    static func loadProfiles(from jsonString: String) -> [ReaderProfile] {
        guard let list = decodeProfiles(from: jsonString) else {
            return defaultProfiles
        }
        return list.filter { !$0.isDeleted }
    }

    static func saveProfiles(_ list: [ReaderProfile]) -> String {
        guard let data = try? JSONEncoder().encode(list),
              let str = String(data: data, encoding: .utf8) else {
            return ""
        }
        return str
    }

    /// Encodes an edited profile list, carrying the sync bookkeeping forward
    /// from the previously stored JSON: entries whose content changed are
    /// stamped updatedAt, and names that disappeared from `list` are kept as
    /// tombstones so mergedProfiles can tell a deletion apart from a stale
    /// copy that should be resurrected.
    static func saveProfiles(_ list: [ReaderProfile], previousJSON: String, now: Date = Date()) -> String {
        let previous = decodeProfiles(from: previousJSON) ?? []
        let timestamp = now.timeIntervalSince1970

        var result: [ReaderProfile] = list.map { profile in
            var entry = profile
            entry.deletedAt = nil
            let prior = previous.first { $0.name.localizedCaseInsensitiveCompare(profile.name) == .orderedSame }
            if let prior, !prior.isDeleted, prior.contentEquals(entry) {
                entry.updatedAt = prior.updatedAt
            } else {
                entry.updatedAt = timestamp
            }
            return entry
        }

        for prior in previous where !list.contains(where: { $0.name.localizedCaseInsensitiveCompare(prior.name) == .orderedSame }) {
            var tombstone = prior
            if tombstone.deletedAt == nil { tombstone.deletedAt = timestamp }
            if !tombstone.isExpiredTombstone(at: now) {
                result.append(tombstone)
            }
        }

        return saveProfiles(result)
    }

    /// Merges two stored-profile JSON strings, resolving per-name conflicts
    /// via `resolve(current:incoming:)` so deletions and edits beat stale
    /// copies instead of being unioned back in. Expired tombstones are pruned.
    static func mergedProfiles(localJSON: String?, incomingJSON: String, now: Date = Date()) -> String {
        var merged = decodeProfiles(from: localJSON ?? "") ?? []

        for profile in decodeProfiles(from: incomingJSON) ?? [] {
            if let index = merged.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(profile.name) == .orderedSame }) {
                merged[index] = resolve(current: merged[index], incoming: profile)
            } else {
                merged.append(profile)
            }
        }

        merged.removeAll { $0.isExpiredTombstone(at: now) }
        return saveProfiles(merged)
    }

    /// Conflict resolution for two copies of the same profile: the newest
    /// updatedAt/deletedAt stamp wins, so an edit or deletion beats any stale
    /// copy (a stamp-less pre-tombstone entry counts as oldest). On an exact
    /// tie a tombstone beats a live copy so a same-instant echo can't undo a
    /// delete; between equal-aged live copies the incoming side wins,
    /// preserving the original union behavior for legacy entries.
    private static func resolve(current: ReaderProfile, incoming: ReaderProfile) -> ReaderProfile {
        let currentStamp = max(current.updatedAt ?? 0, current.deletedAt ?? 0)
        let incomingStamp = max(incoming.updatedAt ?? 0, incoming.deletedAt ?? 0)
        if incomingStamp != currentStamp {
            return incomingStamp > currentStamp ? incoming : current
        }
        if current.isDeleted != incoming.isDeleted {
            return current.isDeleted ? current : incoming
        }
        return incoming
    }
}
