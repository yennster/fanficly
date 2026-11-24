import XCTest
@testable import Fanficly

/// Reader settings' Voice picker (#184): installed voices grouped by
/// language, the system language first, each group sorted by voice name.
final class VoiceCatalogTests: XCTestCase {
    private let all = [
        VoiceOption(id: "zoe", name: "Zoe", language: "en-US"),
        VoiceOption(id: "amelie", name: "Amélie", language: "fr-CA"),
        VoiceOption(id: "daniel", name: "Daniel", language: "en-GB"),
        VoiceOption(id: "alex", name: "Alex", language: "en-US"),
    ]
    private let names = ["en-US": "English (United States)", "en-GB": "English (United Kingdom)",
                         "fr-CA": "French (Canada)"]

    func test_groups_putTheSystemLanguageFirstAndSortVoicesByName() {
        let groups = VoiceCatalog.groups(from: all, systemLanguage: "fr-FR", languageName: { names[$0] })
        XCTAssertEqual(groups.map(\.tag), ["fr-CA", "en-GB", "en-US"])
        XCTAssertEqual(groups.last?.voices.map(\.id), ["alex", "zoe"])
        XCTAssertEqual(groups.first?.name, "French (Canada)")
    }

    func test_groups_fallBackToTheTagForAnUnnamedLanguage() {
        let groups = VoiceCatalog.groups(from: all, systemLanguage: "en-US", languageName: { _ in nil })
        XCTAssertEqual(groups.map(\.name), groups.map(\.tag))
    }
}
