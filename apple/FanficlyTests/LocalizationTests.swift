import XCTest
@testable import Fanficly

/// The String Catalog (`Fanficly/Localizable.xcstrings`) must ship in the app
/// bundle, and the screens moved to it must find their strings there. Nothing is
/// translated yet, so every key reads back as its English source text.
final class LocalizationTests: XCTestCase {
    private let missing = "\u{0}missing"

    private func lookup(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: missing, table: "Localizable")
    }

    func test_catalogShipsInTheAppBundle() {
        XCTAssertEqual(lookup("Settings"), "Settings")
    }

    func test_settingsStrings_readBackUnchangedInEnglish() {
        let keys = [
            "Account",
            "Theme & typography",
            "Last synced",
            "Never",
            "Content & Safety",
            "Rate Fanficly on the App Store",
            "Library File",
            "Export Library File…",
            "Import Library File…",
            "Library Imported",
            "That file couldn't be imported. Make sure it's a Fanficly library file and try again.",
            "What this app sees and stores",
            "What we collect",
            "Nothing. No analytics, no crash reports, no device IDs, no telemetry.",
            """
            • Your AO3 session cookie (in iOS Keychain), so you stay logged in.
            • Works you've saved offline, your notes and tags on them, and your reading position (in app storage).
            • Your preferences (theme, font size).
            • An optional backup of your library and settings in your private iCloud storage, if iCloud Sync is enabled.
            """,
        ]
        for key in keys {
            XCTAssertEqual(lookup(key), key)
        }
    }

    func test_unknownKey_isNotInTheCatalog() {
        XCTAssertEqual(lookup("Not a Fanficly string"), missing)
    }
}
