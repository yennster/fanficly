import SwiftUI

/// What the Library (and its folders) can order saved stories by.
enum LibrarySortKey: String, CaseIterable, Identifiable, Sendable {
    case dateSaved, lastRead, lastUpdated, title, author, length

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dateSaved: "Date Saved"
        case .lastRead: "Last Read"
        case .lastUpdated: "Last Updated"
        case .title: "Title"
        case .author: "Author"
        case .length: "Length"
        }
    }

    var systemImage: String {
        switch self {
        case .dateSaved: "bookmark"
        case .lastRead: "book"
        case .lastUpdated: "clock.arrow.circlepath"
        case .title: "textformat"
        case .author: "person"
        case .length: "text.alignleft"
        }
    }

    /// The direction a key starts in when picked: newest, A to Z, or longest
    /// first.
    var defaultAscending: Bool {
        switch self {
        case .title, .author: true
        case .dateSaved, .lastRead, .lastUpdated, .length: false
        }
    }

    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .dateSaved, .lastRead, .lastUpdated: ascending ? "Oldest First" : "Newest First"
        case .title, .author: ascending ? "A to Z" : "Z to A"
        case .length: ascending ? "Shortest First" : "Longest First"
        }
    }
}

/// The fields stories sort by. `Work` conforms; tests use plain values.
protocol LibrarySortable {
    var title: String { get }
    var authorName: String { get }
    var savedAt: Date { get }
    var lastReadAt: Date? { get }
    var updatedAt: Date? { get }
    var wordCount: Int { get }
    var isPinned: Bool { get }
}

extension Work: LibrarySortable {}

struct LibrarySort: Equatable, Sendable {
    var key: LibrarySortKey
    var ascending: Bool

    /// Newest saved first — the Library's order before sorting existed.
    static let `default` = LibrarySort(key: .dateSaved, ascending: false)

    var isDefault: Bool { self == .default }

    static let keyStorageKey = "library.sortKey"
    static let ascendingStorageKey = "library.sortAscending"

    init(key: LibrarySortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    /// From the persisted settings; an unknown key falls back to the default.
    init(keyRaw: String, ascending: Bool) {
        if let key = LibrarySortKey(rawValue: keyRaw) {
            self.init(key: key, ascending: ascending)
        } else {
            self = .default
        }
    }

    /// Pinned stories stay on top; the rest follow the key and direction.
    /// Stories missing the key (never read, no AO3 update date) go last in
    /// either direction, and ties fall back to newest saved, then title, so
    /// the order never shuffles between renders.
    func sorted<T: LibrarySortable>(_ items: [T]) -> [T] {
        items.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            switch compare(a, b) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame:
                if a.savedAt != b.savedAt { return a.savedAt > b.savedAt }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    private func compare<T: LibrarySortable>(_ a: T, _ b: T) -> ComparisonResult {
        switch key {
        case .dateSaved:
            return directed(a.savedAt.compare(b.savedAt))
        case .lastRead:
            return compareMissingLast(a.lastReadAt, b.lastReadAt)
        case .lastUpdated:
            return compareMissingLast(a.updatedAt, b.updatedAt)
        case .title:
            return directed(a.title.localizedStandardCompare(b.title))
        case .author:
            let byAuthor = directed(a.authorName.localizedStandardCompare(b.authorName))
            // One author's stories read A to Z whichever way authors run.
            return byAuthor == .orderedSame ? a.title.localizedStandardCompare(b.title) : byAuthor
        case .length:
            if a.wordCount == b.wordCount { return .orderedSame }
            return directed(a.wordCount < b.wordCount ? .orderedAscending : .orderedDescending)
        }
    }

    private func directed(_ result: ComparisonResult) -> ComparisonResult {
        guard !ascending else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    private func compareMissingLast(_ a: Date?, _ b: Date?) -> ComparisonResult {
        switch (a, b) {
        case let (a?, b?): return directed(a.compare(b))
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        }
    }
}

/// The sort control for saved-story lists. It lives in the content (first in
/// the Library's filter row, atop a folder's list) rather than the navigation
/// bar, and is tinted while a non-default sort is active so a custom order is
/// never a surprise.
struct LibrarySortMenu: View {
    @AppStorage(LibrarySort.keyStorageKey) private var keyRaw = LibrarySort.default.key.rawValue
    @AppStorage(LibrarySort.ascendingStorageKey) private var ascending = LibrarySort.default.ascending

    private var sort: LibrarySort { LibrarySort(keyRaw: keyRaw, ascending: ascending) }

    var body: some View {
        Menu {
            Picker("Sort By", selection: keyBinding) {
                ForEach(LibrarySortKey.allCases) { key in
                    Label(key.title, systemImage: key.systemImage).tag(key)
                }
            }
            .pickerStyle(.inline)

            Picker("Order", selection: $ascending) {
                // The key's natural direction first: "A to Z" above "Z to A".
                let natural = sort.key.defaultAscending
                ForEach([natural, !natural], id: \.self) { asc in
                    Text(sort.key.directionLabel(ascending: asc)).tag(asc)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(sort.isDefault ? Color.primary : Color.accentColor)
                .frame(width: 36, height: 36)
                .background {
                    Circle()
                        .fill(sort.isDefault ? Color(.secondarySystemFill) : Color.accentColor.opacity(0.14))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort")
        .accessibilityValue("\(sort.key.title), \(sort.key.directionLabel(ascending: sort.ascending))")
        .help("Sort stories")
    }

    /// Picking a new key starts it in its natural direction (newest, A to Z,
    /// longest), like Files.
    private var keyBinding: Binding<LibrarySortKey> {
        Binding {
            sort.key
        } set: { newKey in
            guard newKey != sort.key else { return }
            keyRaw = newKey.rawValue
            ascending = newKey.defaultAscending
        }
    }
}
