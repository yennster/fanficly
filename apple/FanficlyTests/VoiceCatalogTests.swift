import XCTest
@testable import Fanficly

/// Reader settings' Voice picker: which installed voices it lists, and in what order.
final class VoiceCatalogTests: XCTestCase {
    private let all = [
        VoiceOption(id: "c", name: "Zoe", language: "en-US"),
        VoiceOption(id: "a", name: "Amélie", language: "fr-CA"),
        VoiceOption(id: "b", name: "Daniel", language: "en-GB"),
    ]

    func test_options_keepTheLanguageSortedByName() {
        XCTAssertEqual(VoiceCatalog.options(from: all, language: "en").map(\.id), ["b", "c"])
    }

    func test_options_fallBackToEveryVoiceWhenTheLanguageHasNone() {
        XCTAssertEqual(VoiceCatalog.options(from: all, language: "ja").map(\.id), ["a", "b", "c"])
    }
}
