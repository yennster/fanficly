import XCTest
import UIKit

/// Drives the app **in demo mode** through a slow, camera-friendly tour for
/// the App Store app-preview videos. `bin/record-app-previews.sh` runs one
/// method per device while recording the simulator with
/// `simctl io recordVideo`, then post-processes to Apple's app-preview specs.
///
/// The pauses are pacing, not synchronization — keep the whole tour under
/// ~26 s so the trimmed video fits the App Store's 30 s cap. Navigation
/// mirrors `ScreenshotTests` (taps on iPhone, ⌘-shortcuts in the iPad/Mac
/// split view, where sidebar taps don't reliably switch the detail column).
final class PreviewTourTests: XCTestCase {
    private var app: XCUIApplication!
    private var useKeyboardNav = false

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    func testPreviewTourPhone() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        try launchTour(zoom: "1.0", orientation: .portrait)
        runTour(includeCollections: true)
    }

    // The iPad/Mac tours skip the Library/Popular beats: switching tabs in
    // the split view is unreliable under XCUITest (⌘-shortcuts drop, sidebar
    // taps don't always move the detail column), and the persistent sidebar
    // already shows the app's breadth in every frame. Search → reader →
    // narration is the guaranteed-good spine.
    func testPreviewTourPad() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        useKeyboardNav = true
        try launchTour(zoom: "1.0", orientation: .portrait)
        runTour(includeCollections: false)
    }

    /// The "Mac" preview is a landscape iPad capture, like the Mac screenshots
    /// (there is no Mac Catalyst simulator).
    func testPreviewTourMac() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad
                || UIDevice.current.userInterfaceIdiom == .mac else { return }
        useKeyboardNav = true
        try launchTour(zoom: "0.7", orientation: .landscapeRight)
        runTour(includeCollections: false)
    }

    private func launchTour(zoom: String, orientation: UIDeviceOrientation) throws {
        // US formatting ("48,213 words") whatever the simulator's region is.
        app.launchArguments = ["-demoMode", "-app.zoomScale", zoom,
                               "-AppleLocale", "en_US", "-AppleLanguages", "(en)"]
        app.launch()
        pause(1.5)
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = orientation
        pause(1.5)
        #endif
        // The recording script starts capturing shortly after the app process
        // appears; hold the opening frame so the video never opens mid-settle.
        pause(1.0)
    }

    private func runTour(includeCollections: Bool) {
        // 1–2. Library, then Popular — the collection & discovery beats.
        //    These run FIRST: an open reader sticks in the navigation stack,
        //    so the reader is the finale (the same ordering lesson as
        //    ScreenshotTests).
        if includeCollections {
            openSidebarItem("Library", key: "4")
            pause(2.0)
            openSidebarItem("Popular", key: "3")
            pause(2.0)
        }

        // 3. Search — run a saved search so its exact tag chips and results
        //    land on camera. Not typed: `simctl io recordVideo` stops
        //    capturing frames once the software keyboard is up, so a typed
        //    search vanished from the video (it cut straight to the reader).
        //    Demo data answers instantly and offline.
        openSidebarItem("Search", key: "1")
        pause(0.8)
        //    Then scroll the results slowly: the recorder emits no frames
        //    while the screen is perfectly still and squeezes that time out
        //    of the video, so a static results dwell vanished entirely.
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Slow burn, complete")).firstMatch
        if saved.waitForExistence(timeout: 5) {
            saved.tap()
        }
        pause(0.8)
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(130), thenHoldForDuration: 0.3)
        pause(0.4)

        // 4. Open a result into the reader (the first one still on screen
        //    after the scroll); linger, then scroll slowly.
        if app.cells.firstMatch.waitForExistence(timeout: 5) {
            let cells = app.cells.allElementsBoundByIndex
            (cells.first(where: { $0.isHittable }) ?? app.cells.firstMatch).tap()
        }
        pause(2.0)
        app.swipeUp(velocity: .slow)
        pause(1.2)

        // 5. Finale — start narration and let the mini-player + karaoke
        //    highlight play out the video's closing seconds.
        let aa = settingsButton()
        if aa.waitForExistence(timeout: 4) {
            aa.tap()
            pause(1.2)
            let listen = app.buttons["Listen to chapter"].firstMatch
            if listen.waitForExistence(timeout: 3) {
                listen.tap()
                pause(4.0)
            }
        }
    }

    // MARK: - Helpers (mirroring ScreenshotTests)

    private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pause")], timeout: seconds)
    }

    private func settingsButton() -> XCUIElement {
        // firstMatch: the iPad split view can expose the identifier on more
        // than one element, and an ambiguous query throws on tap.
        let byId = app.descendants(matching: .any)
            .matching(identifier: "reader_settings_button").firstMatch
        if byId.exists { return byId }
        return app.buttons["Reader settings"].firstMatch
    }

    private func openSidebarItem(_ title: String, key: String) {
        if useKeyboardNav {
            // The ⌘ keypress dispatches asynchronously and can be dropped, so
            // resend until the target screen's nav bar appears.
            for _ in 0..<6 {
                app.typeKey(key, modifierFlags: .command)
                if app.navigationBars[title].waitForExistence(timeout: 2.5) { break }
            }
            return
        }
        // iPhone: pop back to the root list, then tap the row.
        for _ in 0..<6 {
            if app.navigationBars["Fanficly"].exists { break }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists && back.isHittable { back.tap(); pause(0.6) } else { break }
        }
        let cell = app.collectionViews.staticTexts[title].firstMatch
        let fallback = app.staticTexts[title].firstMatch
        let target = cell.waitForExistence(timeout: 2) ? cell : fallback
        if target.waitForExistence(timeout: 2) {
            if target.isHittable {
                target.tap()
            } else {
                target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            pause(0.8)
        }
    }
}
