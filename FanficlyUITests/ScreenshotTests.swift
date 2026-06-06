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
    private func findSettingsButton() -> XCUIElement {
        let identifier = app.descendants(matching: .any).element(matching: .any, identifier: "reader_settings_button")
        if identifier.exists && identifier.isHittable { return identifier }
        
        let label = app.buttons["Reader settings"]
        if label.exists && label.isHittable { return label }
        
        let textFormatting = app.buttons["text formatting"]
        if textFormatting.exists && textFormatting.isHittable { return textFormatting }
        
        let aaButton = app.buttons["Aa"]
        if aaButton.exists && aaButton.isHittable { return aaButton }
        
        let aaText = app.staticTexts["Aa"]
        if aaText.exists && aaText.isHittable { return aaText }
        
        // Non-hittable existence checks (for iPhone collapsed state)
        if identifier.exists { return identifier }
        if label.exists { return label }
        if textFormatting.exists { return textFormatting }
        if aaButton.exists { return aaButton }
        if aaText.exists { return aaText }
        
        return identifier // return the non-existent identifier instead of the back button fallback
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

            // Text to speech narration
            var ttsButton = findSettingsButton()
            if !ttsButton.isHittable {
                // On iPhone, trailing toolbar items are collapsed into a default overflow button at the far right
                let navButtons = app.navigationBars.buttons
                let count = navButtons.count
                if count > 0 {
                    let overflowButton = app.buttons["More"].exists ? app.buttons["More"] : navButtons.element(boundBy: count - 1)
                    if overflowButton.waitForExistence(timeout: 3) {
                        overflowButton.tap()
                        usleep(600_000)
                    }
                }
                ttsButton = findSettingsButton() // Refresh after opening overflow menu
            }

            if ttsButton.waitForExistence(timeout: 3) {
                ttsButton.tap()
                usleep(600_000)
                let listenButton = app.buttons["Listen to chapter"]
                if listenButton.waitForExistence(timeout: 3) {
                    listenButton.tap()
                    usleep(1_200_000) // Wait for playback to begin and player bar to appear
                    snap("09-tts")
                    
                    // Stop narration to clean up
                    var ttsButtonToStop = findSettingsButton()
                    if !ttsButtonToStop.isHittable {
                        let navButtons = app.navigationBars.buttons
                        let count = navButtons.count
                        if count > 0 {
                            let overflowButton = app.buttons["More"].exists ? app.buttons["More"] : navButtons.element(boundBy: count - 1)
                            if overflowButton.waitForExistence(timeout: 3) {
                                overflowButton.tap()
                                usleep(600_000)
                            }
                        }
                        ttsButtonToStop = findSettingsButton() // Refresh after opening overflow menu
                    }
                    
                    if ttsButtonToStop.waitForExistence(timeout: 3) {
                        ttsButtonToStop.tap()
                        usleep(600_000)
                        let stopButton = app.buttons["Stop listening"]
                        if stopButton.waitForExistence(timeout: 3) {
                            stopButton.tap()
                            usleep(600_000)
                        }
                    }
                }
            }
        }

        // Library — seeded with followed + downloaded works.
        openSidebarItem("Library")
        usleep(700_000)
        snap("04-library")

        // Browse — category catalog.
        openSidebarItem("Browse")
        usleep(700_000)
        snap("05-browse")

        // Fandoms list within a category (TV Shows)
        let tvShowsCell = app.staticTexts["TV Shows"].firstMatch
        if tvShowsCell.waitForExistence(timeout: 3) {
            tvShowsCell.tap()
            usleep(900_000)
            snap("05-browse-fandoms")
            
            // Pop back to Browse so that the rest of the flow is clean
            let browseBack = app.navigationBars.buttons.element(boundBy: 0)
            if browseBack.exists && browseBack.isHittable { browseBack.tap(); usleep(600_000) }
        }

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
