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

    /// #157: a fandom picked from a search suggestion is a tag chip, not a
    /// `fandomNames` entry, and must not be saved into a "fandom-agnostic" filter.
    func test_savedJSONDropsSearchTagChips() {
        var f = AO3SearchFilters()
        f.otherTagNames = ["Teen Wolf (TV)"]
        f.freeformNames = ["Slow Burn"]
        f.complete = .yes
        XCTAssertEqual(f.unsavedTagNames, ["Teen Wolf (TV)"])

        let restored = AO3SearchFilters.from(savedJSON: f.savedJSON())!
        XCTAssertTrue(restored.otherTagNames.isEmpty, "search tag chips should not be saved")
        XCTAssertEqual(restored.freeformNames, ["Slow Burn"])
        XCTAssertEqual(restored.complete, .yes)
    }

    /// #157 round trip: save in Search with a fandom chip, then apply in a
    /// Browse fandom, in Search with another fandom chip, and on its own.
    func test_savedFilterAppliedInBrowseAndSearchKeepsTheCurrentFandom() {
        var searched = AO3SearchFilters()
        searched.otherTagNames = ["Teen Wolf (TV)"]
        searched.freeformNames = ["Slow Burn"]
        searched.complete = .yes
        searched.kudosCount = ">100"
        let saved = AO3SearchFilters.from(savedJSON: searched.savedJSON())!

        // Browse: Harry Potter, plus the saved filter. One fandom, not two.
        var browse = AO3SearchFilters()
        browse.fandomNames = ["Harry Potter - J. K. Rowling"]
        browse.ratings = [.explicit]  // replaced by the saved filter
        let inBrowse = browse.applyingSaved(saved)
        XCTAssertEqual(inBrowse.fandomNames, ["Harry Potter - J. K. Rowling"])
        XCTAssertTrue(inBrowse.otherTagNames.isEmpty)
        XCTAssertTrue(inBrowse.ratings.isEmpty)
        XCTAssertEqual(inBrowse.freeformNames, ["Slow Burn"])
        XCTAssertEqual(inBrowse.complete, .yes)
        XCTAssertEqual(inBrowse.kudosCount, ">100")
        let browseChips = FilterChip.all(in: inBrowse, subject: "Harry Potter - J. K. Rowling").map(\.id)
        XCTAssertEqual(browseChips, ["freeform|Slow Burn", "complete", "kudos"])

        // Search: the fandom picked there stays, keywords too.
        var search = AO3SearchFilters()
        search.query = "coffee shop"
        search.otherTagNames = ["Sherlock (TV)"]
        let inSearch = search.applyingSaved(saved)
        XCTAssertEqual(inSearch.otherTagNames, ["Sherlock (TV)"])
        XCTAssertEqual(inSearch.query, "coffee shop")
        XCTAssertEqual(inSearch.freeformNames, ["Slow Burn"])
        XCTAssertEqual(FilterChip.all(in: inSearch).map(\.id),
                       ["tag|Sherlock (TV)", "freeform|Slow Burn", "complete", "kudos"])
    }

    /// The widget's saved-filter route applies a saved filter the way the
    /// Browse landing page does: older search tags are dropped, keywords kept.
    func test_routeQueryAppliesASavedFilter() {
        var old = AO3SearchFilters()
        old.query = "coffee"
        old.otherTagNames = ["Teen Wolf (TV)"]
        old.complete = .yes
        let json = String(data: try! JSONEncoder().encode(old), encoding: .utf8)!
        let routed = AO3SearchFilters.savedFilter(fromRouteQuery: json)!
        XCTAssertEqual(routed.query, "coffee")
        XCTAssertTrue(routed.otherTagNames.isEmpty)
        XCTAssertEqual(routed.complete, .yes)
    }

    /// A filter saved before #157 may still carry search tags; applying it
    /// (here from the Browse landing page, with no fandom) drops them.
    func test_applyingAnOlderSavedFilterDropsItsSearchTags() {
        var old = AO3SearchFilters()
        old.otherTagNames = ["Teen Wolf (TV)"]
        old.fandomNames = ["Teen Wolf (TV)"]
        old.ratings = [.teen]
        let applied = AO3SearchFilters().applyingSaved(old)
        XCTAssertTrue(applied.otherTagNames.isEmpty)
        XCTAssertTrue(applied.fandomNames.isEmpty)
        XCTAssertEqual(applied.ratings, [.teen])
    }

    /// Every field a saved filter can set has a chip, in Search's wording,
    /// and each chip removes only its own field.
    func test_filterChipsCoverEveryField() {
        var f = AO3SearchFilters()
        f.title = "Tea"
        f.creators = "someone"
        f.otherTagNames = ["Teen Wolf (TV)"]
        f.fandomNames = ["Harry Potter - J. K. Rowling"]
        f.relationshipNames = ["Draco Malfoy/Harry Potter"]
        f.characterNames = ["Hermione Granger"]
        f.freeformNames = ["Fluff"]
        f.excludedTagNames = ["Major Character Death"]
        f.excludedFreeforms = ["Angst"]
        f.ratings = [.teen]
        f.warnings = [.noWarningsApply]
        f.categories = [.mm]
        f.complete = .yes
        f.crossover = .no
        f.singleChapter = true
        f.wordCount = ">10000"
        f.languageId = "en"
        f.kudosCount = ">100"
        f.hits = ">1000"
        f.commentsCount = ">10"
        f.bookmarksCount = ">5"
        f.revisedAt = "< 1 week"

        let chips = FilterChip.all(in: f)
        XCTAssertEqual(chips.count, 22)
        let labels = chips.map(\.label)
        XCTAssertTrue(labels.contains("One-shots"))
        XCTAssertTrue(labels.contains("In English"))
        XCTAssertTrue(labels.contains("Not Angst"))
        XCTAssertTrue(labels.contains("Updated < 1 week"))
        XCTAssertFalse(FilterChip.all(in: f, subject: "Harry Potter - J. K. Rowling").contains { $0.id.hasPrefix("fandom|") })
        // A ship screen's ship is its title, not a removable filter.
        XCTAssertFalse(FilterChip.all(in: f, subject: "Draco Malfoy/Harry Potter").contains { $0.id.hasPrefix("ship|") })

        for chip in chips {
            var removed = f
            chip.remove(&removed)
            XCTAssertEqual(FilterChip.all(in: removed).map(\.id), chips.map(\.id).filter { $0 != chip.id },
                           "removing \(chip.id)")
        }
        XCTAssertTrue(FilterChip.all(in: AO3SearchFilters()).isEmpty)
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
