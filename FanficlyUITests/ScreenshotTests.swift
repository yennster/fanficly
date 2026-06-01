import XCTest

/// Drives the app through its main screens and writes PNG screenshots to
/// the directory given by the FANFICLY_SHOT_DIR environment variable.
/// Run with:
///   xcodebuild test -only-testing:FanficlyUITests/ScreenshotTests \
///     -destination '...' FANFICLY_SHOT_DIR=/abs/path
final class ScreenshotTests: XCTestCase {
    var app: XCUIApplication!
    var shotDir: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Derive repo/docs/screenshots from this source file's path —
        // the simulator runs as the host user and can write there.
        // #filePath = <repo>/FanficlyUITests/ScreenshotTests.swift
        let repoRoot = (((#filePath as NSString)
            .deletingLastPathComponent as NSString)  // FanficlyUITests/
            .deletingLastPathComponent)               // <repo>/
        shotDir = (repoRoot as NSString).appendingPathComponent("docs/screenshots")
        try FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launch()
    }

    private func snap(_ name: String) {
        let shot = app.screenshot()
        let path = (shotDir as NSString).appendingPathComponent("\(name).png")
        do {
            try shot.pngRepresentation.write(to: URL(fileURLWithPath: path))
        } catch {
            // Fall back to an attachment so it's still recoverable.
            let att = XCTAttachment(screenshot: shot)
            att.name = name
            att.lifetime = .keepAlways
            add(att)
        }
    }

    /// Tap the leading nav-bar (back) button until the sidebar is showing.
    /// The sidebar is the only screen whose navigation bar is titled "Fanficly".
    private func revealSidebar() {
        for _ in 0..<5 {
            if app.navigationBars["Fanficly"].exists { return }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists && back.isHittable { back.tap(); usleep(700_000) } else { break }
        }
    }

    private func openSidebarItem(_ title: String) {
        revealSidebar()
        let cell = app.collectionViews.staticTexts[title].firstMatch
        let fallback = app.staticTexts[title].firstMatch
        let target = cell.waitForExistence(timeout: 2) ? cell : fallback
        if target.waitForExistence(timeout: 2) { target.tap(); usleep(900_000) }
    }

    func testCaptureMainScreens() throws {
        // Launch lands on the sidebar — that's the "Fanficly" home.
        usleep(800_000)
        snap("01-home")

        // Search: capture the (deterministic) screen, then results + reader
        // best-effort — those need a live AO3 fetch and are flaky in automation.
        openSidebarItem("Search")
        usleep(600_000)
        snap("02-search")
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 3) {
            field.tap()
            usleep(400_000)
            // Trailing newline triggers the search (handled in SearchView).
            field.typeText("draco/hermione enemies to lovers complete\n")
            if app.cells.firstMatch.waitForExistence(timeout: 25) {
                usleep(700_000)
                snap("03-search-results")
                app.cells.firstMatch.tap()
                sleep(3)
                _ = app.staticTexts.firstMatch.waitForExistence(timeout: 18)
                sleep(2)
                snap("04-reader")
            }
        }

        // Browse categories, then a category's live fandom list (needs network).
        openSidebarItem("Browse")
        usleep(600_000)
        snap("05-browse")
        let firstCategory = app.cells.firstMatch
        if firstCategory.waitForExistence(timeout: 3) {
            firstCategory.tap()
            sleep(4)
            // Only keep this shot if we actually navigated off the category list.
            if app.navigationBars["Browse"].exists == false {
                snap("06-browse-fandoms")
            }
        }

        // Library
        openSidebarItem("Library")
        usleep(600_000)
        snap("07-library")

        // Recently Viewed — the search-results tap above seeds at least one entry.
        openSidebarItem("Recently Viewed")
        usleep(600_000)
        snap("10-recently-viewed")

        // Settings and Reader settings
        openSidebarItem("Settings")
        usleep(600_000)
        snap("08-settings")
        let readerRow = app.staticTexts["Theme & typography"].firstMatch
        if readerRow.waitForExistence(timeout: 3) {
            readerRow.tap()
            sleep(1)
            snap("09-reader-settings")
        }
    }
}
