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
        // 1. Search empty state (launch lands here)
        usleep(800_000)
        snap("01-search-empty")

        // 2 + 3. Search results and reader (best-effort; needs network)
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 3) {
            field.tap()
            usleep(400_000)
            // Trailing newline triggers the search (handled in SearchView).
            field.typeText("draco/hermione enemies to lovers complete\n")
            // Results: AO3 round-trip + parse, allow generous time.
            if app.cells.firstMatch.waitForExistence(timeout: 25) {
                usleep(700_000)
                snap("02-search-results")
                app.cells.firstMatch.tap()
                // Full work fetch + chapter render.
                sleep(3)
                _ = app.staticTexts.firstMatch.waitForExistence(timeout: 18)
                sleep(2)
                snap("03-reader")
                let typo = app.buttons["textformat.size"].firstMatch
                if typo.waitForExistence(timeout: 3) {
                    typo.tap()
                    usleep(900_000)
                    snap("04-typography")
                    app.tap()
                }
                revealSidebar()
            }
        }

        // Browse categories and a category's fandoms
        openSidebarItem("Browse")
        snap("05-browse")
        let firstCategory = app.cells.firstMatch
        if firstCategory.waitForExistence(timeout: 3) {
            firstCategory.tap()
            sleep(4)
            snap("06-browse-fandoms")
        }

        // Library
        openSidebarItem("Library")
        snap("07-library")

        // Settings and Reader settings
        openSidebarItem("Settings")
        snap("08-settings")
        let readerRow = app.staticTexts["Theme & typography"].firstMatch
        if readerRow.waitForExistence(timeout: 3) {
            readerRow.tap()
            sleep(1)
            snap("09-reader-settings")
        }
    }
}
