import XCTest
@testable import Fanficly

/// Covers AO3SearchFilters.promptText() — the normalized search-box text
/// shown after a chip is removed.
final class PromptTextTests: XCTestCase {
    func test_includesActiveFilters() {
        var f = AO3SearchFilters()
        f.relationshipNames = ["Hermione Granger/Draco Malfoy"]
        f.ratings = [.explicit]
        f.complete = .yes
        f.singleChapter = true
        f.excludedFreeforms = ["Angst"]

        let text = f.promptText()
        XCTAssertTrue(text.contains("Hermione Granger/Draco Malfoy"))
        XCTAssertTrue(text.contains("Explicit"))
        XCTAssertTrue(text.contains("complete"))
        XCTAssertTrue(text.contains("oneshot"))
        XCTAssertTrue(text.contains("-Angst"))
    }

    func test_removingAFilterDropsItFromText() {
        var f = AO3SearchFilters()
        f.freeformNames = ["Fluff"]
        f.complete = .yes
        XCTAssertTrue(f.promptText().contains("complete"))

        f.complete = .any  // "removed the complete chip"
        let text = f.promptText()
        XCTAssertFalse(text.contains("complete"))
        XCTAssertTrue(text.contains("Fluff"))
    }

    func test_wordCountPhrasing() {
        XCTAssertEqual(AO3SearchFilters.wordCountPhrase(">10000"), "over 10000")
        XCTAssertEqual(AO3SearchFilters.wordCountPhrase("<5000"), "under 5000")
        XCTAssertEqual(AO3SearchFilters.wordCountPhrase("1000-5000"), "between 1000 and 5000")
    }

    func test_emptyFiltersGiveEmptyText() {
        XCTAssertTrue(AO3SearchFilters().promptText().isEmpty)
    }
}
