import XCTest
@testable import Fanficly

final class AO3SearchFiltersTests: XCTestCase {
    private func items(_ build: (inout AO3SearchFilters) -> Void) -> [String: String] {
        var f = AO3SearchFilters()
        build(&f)
        var dict: [String: String] = [:]
        for item in f.queryItems() {
            // keep last for repeated keys; multi keys handled separately below
            dict[item.name] = item.value
        }
        return dict
    }

    func test_emptyFilters_onlyHaveSort() {
        let f = AO3SearchFilters()
        let names = f.queryItems().map(\.name)
        XCTAssertTrue(names.contains("work_search[sort_column]"))
        XCTAssertTrue(names.contains("work_search[sort_direction]"))
        XCTAssertFalse(names.contains("work_search[query]"))
    }

    func test_allStructuredFieldsMap() {
        var f = AO3SearchFilters()
        f.title = "A Title"
        f.creators = "someauthor"
        f.wordCount = "1000-5000"
        f.languageId = "en"
        f.hits = ">1000"
        f.kudosCount = ">500"
        f.commentsCount = ">10"
        f.bookmarksCount = ">5"
        f.revisedAt = ">2024-01-01"
        f.complete = .yes
        f.crossover = .no
        f.singleChapter = true
        let d = Dictionary(uniqueKeysWithValues: f.queryItems().map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(d["work_search[title]"], "A Title")
        XCTAssertEqual(d["work_search[creators]"], "someauthor")
        XCTAssertEqual(d["work_search[word_count]"], "1000-5000")
        XCTAssertEqual(d["work_search[language_id]"], "en")
        XCTAssertEqual(d["work_search[hits]"], ">1000")
        XCTAssertEqual(d["work_search[kudos_count]"], ">500")
        XCTAssertEqual(d["work_search[comments_count]"], ">10")
        XCTAssertEqual(d["work_search[bookmarks_count]"], ">5")
        XCTAssertEqual(d["work_search[revised_at]"], ">2024-01-01")
        XCTAssertEqual(d["work_search[complete]"], "true")
        XCTAssertEqual(d["work_search[crossover]"], "F")
        XCTAssertEqual(d["work_search[single_chapter]"], "1")
    }

    func test_multiValueTagsJoinedWithCommas() {
        var f = AO3SearchFilters()
        f.characterNames = ["Harry Potter", "Hermione Granger"]
        let value = f.queryItems().first { $0.name == "work_search[character_names]" }?.value
        XCTAssertEqual(value, "Harry Potter, Hermione Granger")
    }

    func test_warningsCategoriesEmitArrayKeys() {
        var f = AO3SearchFilters()
        f.warnings = [.majorCharacterDeath]
        f.categories = [.mm, .ff]
        let items = f.queryItems()
        XCTAssertEqual(items.filter { $0.name == "work_search[archive_warning_ids][]" }.count, 1)
        XCTAssertEqual(items.filter { $0.name == "work_search[category_ids][]" }.count, 2)
    }

    func test_singleRatingUsesScalarField() {
        var f = AO3SearchFilters()
        f.ratings = [.explicit]
        let items = f.queryItems()
        // One rating goes through AO3's dedicated single-select field.
        XCTAssertEqual(items.first { $0.name == "work_search[rating_ids]" }?.value, "13")
        XCTAssertTrue(items.filter { $0.name == "work_search[rating_ids][]" }.isEmpty)
        XCTAssertNil(items.first { $0.name == "work_search[query]" })
    }

    func test_multipleRatingsAreOredInQuery() {
        var f = AO3SearchFilters()
        f.ratings = [.explicit, .mature]   // 13 and 12
        let items = f.queryItems()
        // AO3's rating field is single-select, so a rating_ids[] array AND-matches
        // and returns nothing; 2+ ratings must be OR-ed via the query field.
        XCTAssertTrue(items.filter { $0.name.hasPrefix("work_search[rating_ids]") }.isEmpty)
        let q = items.first { $0.name == "work_search[query]" }?.value
        XCTAssertEqual(q, "(rating_ids:12 OR rating_ids:13)")
    }

    func test_multipleRatingsComposeWithExistingQuery() {
        var f = AO3SearchFilters()
        f.query = "coffee"
        f.ratings = [.explicit, .mature]
        let q = f.queryItems().first { $0.name == "work_search[query]" }?.value
        XCTAssertEqual(q, "coffee (rating_ids:12 OR rating_ids:13)")
    }

    func test_excludedFreeformsBecomeNotInQuery() {
        var f = AO3SearchFilters()
        f.query = "harry/draco"
        f.excludedFreeforms = ["Angst", "slow burn"]   // single word vs. phrase
        let q = f.queryItems().first { $0.name == "work_search[query]" }?.value
        XCTAssertEqual(q, "harry/draco NOT Angst NOT \"slow burn\"")
    }

    func test_isEmpty() {
        XCTAssertTrue(AO3SearchFilters().isEmpty)
        var f = AO3SearchFilters()
        f.singleChapter = true
        XCTAssertFalse(f.isEmpty)
    }

    func test_savedJSONRoundTripsAndDropsFandom() {
        var f = AO3SearchFilters()
        f.fandomNames = ["Harry Potter - J. K. Rowling"]
        f.relationshipNames = ["Hermione Granger/Draco Malfoy"]
        f.ratings = [.explicit]
        f.complete = .yes
        f.excludedFreeforms = ["Angst"]
        f.wordCount = ">10000"

        let json = f.savedJSON()
        let restored = AO3SearchFilters.from(savedJSON: json)
        XCTAssertNotNil(restored)
        XCTAssertTrue(restored!.fandomNames.isEmpty, "fandom should not be saved")
        XCTAssertEqual(restored!.relationshipNames, ["Hermione Granger/Draco Malfoy"])
        XCTAssertTrue(restored!.ratings.contains(.explicit))
        XCTAssertEqual(restored!.complete, .yes)
        XCTAssertEqual(restored!.excludedFreeforms, ["Angst"])
        XCTAssertEqual(restored!.wordCount, ">10000")
    }

    func test_fromInvalidJSONIsNil() {
        XCTAssertNil(AO3SearchFilters.from(savedJSON: "not json"))
    }

    func test_suggestedName_summarizesSelectionAndDropsFandom() {
        var f = AO3SearchFilters()
        f.fandomNames = ["Harry Potter - J. K. Rowling"]   // excluded from the name
        f.relationshipNames = ["Hermione Granger/Draco Malfoy"]
        f.freeformNames = ["Slow Burn"]
        f.ratings = [.explicit]
        f.complete = .yes
        let name = f.suggestedName()
        XCTAssertTrue(name.contains("Hermione Granger/Draco Malfoy"))
        XCTAssertTrue(name.contains("Slow Burn"))
        XCTAssertTrue(name.contains("Explicit"))
        XCTAssertTrue(name.contains("Complete"))
        XCTAssertFalse(name.contains("Harry Potter"), "fandom should be excluded")
    }

    func test_suggestedName_emptyForNoSelection() {
        XCTAssertEqual(AO3SearchFilters().suggestedName(), "")
    }

    func test_ratingDisplayNames() {
        XCTAssertEqual(AO3SearchFilters.Rating.explicit.displayName, "Explicit")
        XCTAssertEqual(AO3SearchFilters.Category.mm.displayName, "M/M")
        XCTAssertEqual(AO3SearchFilters.SortColumn.kudosCount.displayName, "Kudos")
    }
}
