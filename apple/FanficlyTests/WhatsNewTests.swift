import XCTest
import UIKit
@testable import Fanficly

/// What's New (#422): the shared changelog's releases for this app, and when
/// the sheet shows after an update.
final class WhatsNewTests: XCTestCase {
    private let sample = Data("""
    {
      "about": "ignored",
      "releases": [
        { "version": "2.1.0", "themes": [
            { "icon": "sparkles", "title": "Both", "detail": "Everywhere." },
            { "icon": "bell", "title": "Mac", "detail": "Apple only.", "platforms": ["apple"] },
            { "icon": "book", "title": "PC", "detail": "Windows only.", "platforms": ["windows"] }
        ] },
        { "version": "2.0.1", "date": "2026-11-02", "themes": [
            { "icon": "book", "title": "PC", "detail": "Windows only.", "platforms": ["windows"] }
        ] },
        { "version": "2.0.0", "date": "2026-10-19", "platforms": ["apple"], "themes": [
            { "icon": "book", "title": "Old", "detail": "From the release's platforms." }
        ] }
      ]
    }
    """.utf8)

    func test_keepsOnlyThisAppsThemes_andDropsEmptyReleases() throws {
        let apple = try WhatsNew.releases(from: sample, platform: "apple")
        XCTAssertEqual(apple.map(\.version), ["2.1.0", "2.0.0"])
        XCTAssertEqual(apple[0].themes.map(\.title), ["Both", "Mac"])
        XCTAssertEqual(apple[1].themes.map(\.title), ["Old"])

        let windows = try WhatsNew.releases(from: sample, platform: "windows")
        XCTAssertEqual(windows.map(\.version), ["2.1.0", "2.0.1"])
        XCTAssertEqual(windows[0].themes.map(\.title), ["Both", "PC"])
    }

    func test_displayVersionAndDate() throws {
        let releases = try WhatsNew.releases(from: sample, platform: "windows")
        XCTAssertEqual(releases[0].displayVersion, "2.1")
        XCTAssertNil(releases[0].displayDate)
        XCTAssertEqual(releases[1].displayVersion, "2.0.1")
        // The changelog's day whatever the time zone.
        XCTAssertNotNil(releases[1].displayDate)
        XCTAssertTrue(releases[1].displayDate?.contains("2026") == true)
        XCTAssertTrue(releases[1].displayDate?.contains("2") == true)
    }

    func test_bundledChangelog_isValid() {
        // The app bundles the repository's changelog/whats-new.json.
        let releases = WhatsNew.allReleases
        XCTAssertFalse(releases.isEmpty, "changelog/whats-new.json is missing from the app or doesn't decode")
        XCTAssertEqual(Set(releases.map(\.version)).count, releases.count, "a version is listed twice")
        for release in releases {
            XCTAssertFalse(release.themes.isEmpty)
            for theme in release.themes {
                XCTAssertFalse(theme.title.isEmpty, release.version)
                XCTAssertFalse(theme.detail.isEmpty, release.version)
                XCTAssertNotNil(UIImage(systemName: theme.icon), "\(release.version): no SF Symbol \(theme.icon)")
            }
        }
    }

    func test_showsOnlyShippedReleases_upToThisBuild() throws {
        let all = try WhatsNew.releases(from: sample, platform: "apple")  // 2.1.0 (no date), 2.0.0
        // The undated 2.1.0 hasn't shipped yet.
        XCTAssertEqual(WhatsNew.released(all, appVersion: "2.1.0").map(\.version), ["2.0.0"])
        let dated = all.map { r -> WhatsNewRelease in var r = r; r.date = r.date ?? "2026-11-24"; return r }
        XCTAssertEqual(WhatsNew.released(dated, appVersion: "2.1.0").map(\.version), ["2.1.0", "2.0.0"])
        // A build older than an entry (a hotfix, a beta) doesn't show it.
        XCTAssertEqual(WhatsNew.released(dated, appVersion: "2.0.3").map(\.version), ["2.0.0"])
        XCTAssertEqual(WhatsNew.released(dated, appVersion: "2.10.0").map(\.version), ["2.1.0", "2.0.0"])
    }

    private func release(_ version: String) -> WhatsNewRelease {
        WhatsNewRelease(version: version, themes: [.init(icon: "sparkles", title: "T", detail: "D")])
    }

    func test_updateShowsTheNewestRelease() {
        let newest = release("2.1.0")
        XCTAssertEqual(WhatsNew.launchDecision(newest: newest, lastSeen: "2.0.0", isExistingUser: true, openedIntoContent: false),
                       .show(newest))
        // Updating from a version before What's New existed shows it too.
        XCTAssertEqual(WhatsNew.launchDecision(newest: newest, lastSeen: nil, isExistingUser: true, openedIntoContent: false),
                       .show(newest))
    }

    func test_onlyOncePerRelease() {
        XCTAssertEqual(WhatsNew.launchDecision(newest: release("2.1.0"), lastSeen: "2.1.0", isExistingUser: true, openedIntoContent: false),
                       .nothing)
    }

    func test_freshInstallRecordsWithoutShowing() {
        XCTAssertEqual(WhatsNew.launchDecision(newest: release("2.1.0"), lastSeen: nil, isExistingUser: false, openedIntoContent: false),
                       .record("2.1.0"))
        XCTAssertEqual(WhatsNew.launchDecision(newest: release("2.1.0"), lastSeen: nil, isExistingUser: false, openedIntoContent: true),
                       .record("2.1.0"))
    }

    func test_launchIntoAStoryWaitsForTheNextLaunch() {
        XCTAssertEqual(WhatsNew.launchDecision(newest: release("2.1.0"), lastSeen: "2.0.0", isExistingUser: true, openedIntoContent: true),
                       .nothing)
    }

    func test_noChangelogDoesNothing() {
        XCTAssertEqual(WhatsNew.launchDecision(newest: nil, lastSeen: nil, isExistingUser: true, openedIntoContent: false), .nothing)
    }
}
