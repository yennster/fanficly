import XCTest
@testable import Fanficly

/// Library sorting: pinned stories stay on top, every key orders the rest in
/// its chosen direction, stories missing the key sink to the bottom, and ties
/// fall back to a stable order.
final class LibrarySortTests: XCTestCase {
    private struct Story: LibrarySortable {
        var title: String
        var authorName = "author"
        var savedAt = Date(timeIntervalSince1970: 0)
        var lastReadAt: Date?
        var updatedAt: Date?
        var wordCount = 0
        var isPinned = false
    }

    private func day(_ n: Double) -> Date { Date(timeIntervalSince1970: n * 86_400) }
    private func titles(_ stories: [Story]) -> [String] { stories.map(\.title) }

    func test_default_isNewestSavedFirst_withPinnedOnTop() {
        let stories = [
            Story(title: "old", savedAt: day(1)),
            Story(title: "pinned", savedAt: day(0), isPinned: true),
            Story(title: "new", savedAt: day(3)),
        ]
        XCTAssertEqual(titles(LibrarySort.default.sorted(stories)), ["pinned", "new", "old"])
    }

    func test_pinnedStaysOnTop_inEitherDirection() {
        let stories = [
            Story(title: "B"),
            Story(title: "Z", isPinned: true),
            Story(title: "A"),
        ]
        XCTAssertEqual(titles(LibrarySort(key: .title, ascending: true).sorted(stories)), ["Z", "A", "B"])
        XCTAssertEqual(titles(LibrarySort(key: .title, ascending: false).sorted(stories)), ["Z", "B", "A"])
    }

    func test_lastRead_neverReadSinksInBothDirections() {
        let stories = [
            Story(title: "never"),
            Story(title: "monday", lastReadAt: day(1)),
            Story(title: "friday", lastReadAt: day(5)),
        ]
        XCTAssertEqual(titles(LibrarySort(key: .lastRead, ascending: false).sorted(stories)), ["friday", "monday", "never"])
        XCTAssertEqual(titles(LibrarySort(key: .lastRead, ascending: true).sorted(stories)), ["monday", "friday", "never"])
    }

    func test_lastUpdated_missingDateSinks() {
        let stories = [
            Story(title: "no date"),
            Story(title: "older", updatedAt: day(2)),
            Story(title: "newer", updatedAt: day(9)),
        ]
        XCTAssertEqual(titles(LibrarySort(key: .lastUpdated, ascending: false).sorted(stories)), ["newer", "older", "no date"])
        XCTAssertEqual(titles(LibrarySort(key: .lastUpdated, ascending: true).sorted(stories)), ["older", "newer", "no date"])
    }

    func test_title_usesNaturalOrder() {
        let stories = [Story(title: "Part 10"), Story(title: "part 2"), Story(title: "Apple")]
        XCTAssertEqual(titles(LibrarySort(key: .title, ascending: true).sorted(stories)), ["Apple", "part 2", "Part 10"])
        XCTAssertEqual(titles(LibrarySort(key: .title, ascending: false).sorted(stories)), ["Part 10", "part 2", "Apple"])
    }

    func test_author_tiesReadTitleAToZ_whicheverWayAuthorsRun() {
        let stories = [
            Story(title: "Zeta", authorName: "beth"),
            Story(title: "Alpha", authorName: "beth"),
            Story(title: "Mid", authorName: "anna"),
        ]
        XCTAssertEqual(titles(LibrarySort(key: .author, ascending: true).sorted(stories)), ["Mid", "Alpha", "Zeta"])
        XCTAssertEqual(titles(LibrarySort(key: .author, ascending: false).sorted(stories)), ["Alpha", "Zeta", "Mid"])
    }

    func test_length() {
        let stories = [
            Story(title: "short", wordCount: 1_000),
            Story(title: "epic", wordCount: 250_000),
            Story(title: "novella", wordCount: 30_000),
        ]
        XCTAssertEqual(titles(LibrarySort(key: .length, ascending: false).sorted(stories)), ["epic", "novella", "short"])
        XCTAssertEqual(titles(LibrarySort(key: .length, ascending: true).sorted(stories)), ["short", "novella", "epic"])
    }

    func test_ties_fallBackToNewestSavedThenTitle() {
        let stories = [
            Story(title: "b", savedAt: day(1), wordCount: 500),
            Story(title: "a", savedAt: day(1), wordCount: 500),
            Story(title: "c", savedAt: day(4), wordCount: 500),
        ]
        XCTAssertEqual(titles(LibrarySort(key: .length, ascending: false).sorted(stories)), ["c", "a", "b"])
    }

    func test_keysStartInTheirNaturalDirection() {
        XCTAssertFalse(LibrarySortKey.dateSaved.defaultAscending)
        XCTAssertFalse(LibrarySortKey.lastRead.defaultAscending)
        XCTAssertFalse(LibrarySortKey.lastUpdated.defaultAscending)
        XCTAssertFalse(LibrarySortKey.length.defaultAscending)
        XCTAssertTrue(LibrarySortKey.title.defaultAscending)
        XCTAssertTrue(LibrarySortKey.author.defaultAscending)
        XCTAssertEqual(LibrarySortKey.length.directionLabel(ascending: false), "Longest First")
        XCTAssertEqual(LibrarySortKey.title.directionLabel(ascending: true), "A to Z")
        XCTAssertEqual(LibrarySortKey.lastRead.directionLabel(ascending: false), "Newest First")
    }

    func test_unknownPersistedKey_fallsBackToDefault() {
        XCTAssertEqual(LibrarySort(keyRaw: "kudos", ascending: true), .default)
        XCTAssertEqual(LibrarySort(keyRaw: "title", ascending: true), LibrarySort(key: .title, ascending: true))
    }
}
