import XCTest
@testable import Fanficly

final class FandomCatalogTests: XCTestCase {
    func test_exactCatalogMatchUsesCategorySymbol() {
        // "Harry Potter - J. K. Rowling" is in the Books category (book.closed).
        XCTAssertEqual(FandomCatalog.symbol(for: "Harry Potter - J. K. Rowling"), "book.closed")
        // Genshin is in Video Games (gamecontroller).
        XCTAssertEqual(FandomCatalog.symbol(for: "Genshin Impact (Video Game)"), "gamecontroller")
    }

    func test_suffixHeuristics() {
        XCTAssertEqual(FandomCatalog.symbol(for: "Some New Game (Video Game)"), "gamecontroller")
        XCTAssertEqual(FandomCatalog.symbol(for: "Random Show (TV 2024)"), "tv")
        XCTAssertEqual(FandomCatalog.symbol(for: "Big Hit (Movies)"), "film")
        XCTAssertEqual(FandomCatalog.symbol(for: "Marvel Cinematic Universe"), "film")
        XCTAssertEqual(FandomCatalog.symbol(for: "Some Audio Drama (Podcast)"), "headphones")
        XCTAssertEqual(FandomCatalog.symbol(for: "Naruto (Anime & Manga)"), "sparkles")
        XCTAssertEqual(FandomCatalog.symbol(for: "Formula 1 RPF"), "person.fill")
        XCTAssertEqual(FandomCatalog.symbol(for: "Hadestown - Mitchell (Musical)"), "theatermasks")
    }

    func test_unknownFallsBackToBook() {
        XCTAssertEqual(FandomCatalog.symbol(for: "Something Obscure With No Suffix"), "book.closed")
    }
}
