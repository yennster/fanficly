import XCTest
import UIKit

/// Drives the app **in demo mode** (`-demoMode`) through its hero screens and
/// writes PNG screenshots to `docs/screenshots/`. Demo mode serves a curated,
/// all-ages, fully-offline catalog (see `DemoAO3Client`/`DemoSeed`), so these
/// shots are deterministic and contain no explicit/mature content — exactly
/// what's needed for the App Store.
///
/// Run (per device size):
///   xcodebuild test -only-testing:FanficlyUITests/ScreenshotTests \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' ...
final class ScreenshotTests: XCTestCase {
    var app: XCUIApplication!
    var shotDir: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // #filePath = <repo>/FanficlyUITests/ScreenshotTests.swift
        let repoRoot = (((#filePath as NSString)
            .deletingLastPathComponent as NSString)
            .deletingLastPathComponent)
        // Group raw shots by device so the 6.9" and 13" sets don't clobber.
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        shotDir = ((repoRoot as NSString).appendingPathComponent("docs/screenshots") as NSString)
            .appendingPathComponent(device)
        try FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["-demoMode"]
        app.launch()
    }

    private func snap(_ name: String) {
        let shot = app.screenshot()
        let path = (shotDir as NSString).appendingPathComponent("\(name).png")
        do {
            try shot.pngRepresentation.write(to: URL(fileURLWithPath: path))
        } catch {
            let att = XCTAttachment(screenshot: shot)
            att.name = name
            att.lifetime = .keepAlways
            add(att)
        }
    }

    /// Tap the leading nav-bar (back) button until the sidebar is showing.
    private func revealSidebar() {
        for _ in 0..<6 {
            if app.navigationBars["Fanficly"].exists { return }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists && back.isHittable { back.tap(); usleep(600_000) } else { break }
        }
    }

    private func openSidebarItem(_ title: String) {
        revealSidebar()
        let cell = app.collectionViews.staticTexts[title].firstMatch
        let fallback = app.staticTexts[title].firstMatch
        let target = cell.waitForExistence(timeout: 2) ? cell : fallback
        if target.waitForExistence(timeout: 2) { target.tap(); usleep(800_000) }
    }

    func testCaptureMainScreens() throws {
        usleep(900_000)
        snap("01-home")

        // Search — type a prompt; demo data returns results instantly (offline).
        openSidebarItem("Search")
        usleep(500_000)
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 3) {
            field.tap()
            usleep(300_000)
            field.typeText("found family slow burn complete\n")
            _ = app.cells.firstMatch.waitForExistence(timeout: 6)
            usleep(700_000)
            snap("02-search-results")

            // Reader — open the first result.
            app.cells.firstMatch.tap()
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 6)
            usleep(900_000)
            snap("03-reader")
        }

        // Library — seeded with followed + downloaded works.
        openSidebarItem("Library")
        usleep(700_000)
        snap("04-library")

        // Browse — category catalog.
        openSidebarItem("Browse")
        usleep(700_000)
        snap("05-browse")

        // Recently Viewed — seeded history.
        openSidebarItem("Recently Viewed")
        usleep(700_000)
        snap("06-recently-viewed")

        // Reader settings — themes & typography (the customization story).
        openSidebarItem("Settings")
        usleep(500_000)
        let readerRow = app.staticTexts["Theme & typography"].firstMatch
        if readerRow.waitForExistence(timeout: 3) {
            readerRow.tap()
            usleep(800_000)
            snap("07-reader-settings")
        }

        // Privacy — "what this app sees and stores" (the zero-tracking story).
        // We're in Theme & typography (pushed from Settings). Pop back ONE level
        // to the Settings root, then open the privacy page. On iPad's split view
        // re-selecting the Settings sidebar item won't pop the detail stack, so
        // navigate via the back button instead of openSidebarItem.
        let settingsBack = app.navigationBars.buttons.element(boundBy: 0)
        if settingsBack.exists && settingsBack.isHittable { settingsBack.tap(); usleep(700_000) }
        let privacyRow = app.staticTexts["What this app sees and stores"].firstMatch
        if privacyRow.waitForExistence(timeout: 3) {
            privacyRow.tap()
            usleep(800_000)
            snap("08-privacy")
        }
    }
}
