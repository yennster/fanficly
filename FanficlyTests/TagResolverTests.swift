import XCTest
@testable import Fanficly

final class TagResolverTests: XCTestCase {
    func test_bestMatch_prefersExactCaseInsensitive() {
        let matches = ["Hermione Granger/Draco Malfoy", "Draco Malfoy/Harry Potter"]
        XCTAssertEqual(
            TagResolver.bestMatch(for: "hermione granger/draco malfoy", in: matches),
            "Hermione Granger/Draco Malfoy"
        )
    }

    func test_bestMatch_fallsBackToFirst() {
        let matches = ["Hermione Granger/Draco Malfoy", "Other Ship"]
        XCTAssertEqual(TagResolver.bestMatch(for: "dramione", in: matches), "Hermione Granger/Draco Malfoy")
    }

    func test_bestMatch_emptyReturnsNil() {
        XCTAssertNil(TagResolver.bestMatch(for: "x", in: []))
    }

    func test_candidates_relationshipExpandsSlashVariants() {
        let c = TagResolver.candidates(for: "hermione/draco", field: .relationship)
        XCTAssertTrue(c.contains("hermione/draco"))
        XCTAssertTrue(c.contains("hermione draco"))   // slash -> space
        XCTAssertTrue(c.contains("draco hermione"))   // reversed
    }

    func test_candidates_nonRelationshipIsJustTheTerm() {
        XCTAssertEqual(TagResolver.candidates(for: "Slow Burn", field: .freeform), ["Slow Burn"])
        XCTAssertEqual(TagResolver.candidates(for: "Hermione Granger", field: .character), ["Hermione Granger"])
    }

    func test_resolve_usesMockAutocomplete() async {
        // MockAO3Client echoes the term, so resolution returns the input.
        var filters = AO3SearchFilters()
        filters.relationshipNames = ["Edward/Bella"]
        let resolved = await TagResolver.resolve(filters, using: MockAO3Client())
        XCTAssertEqual(resolved.relationshipNames, ["Edward/Bella"])
    }
}
