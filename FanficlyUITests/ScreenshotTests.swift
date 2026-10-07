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
    /// iPad split view navigates by ⌘1–6 keyboard shortcuts instead of tapping
    /// sidebar rows, which doesn't reliably switch the detail column. iPhone
    /// keeps tapping because it uses the collapsed phone navigation shape.
    private var useKeyboardNav = false
    private var currentOrientation: UIDeviceOrientation = .portrait
    /// A real iPhone Duo, unfolded (set once the app's window shows it).
    private var isDuoInner = false

    override func setUpWithError() throws {
        // Best-effort capture: a single flaky navigation step on Mac Catalyst
        // shouldn't abort the whole run and lose every later screen.
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-demoMode"]
    }

    private func setupAndLaunch(device: String, orientation: UIDeviceOrientation) throws {
        currentOrientation = orientation
        let repoRoot = (((#filePath as NSString)
            .deletingLastPathComponent as NSString)
            .deletingLastPathComponent)
        shotDir = ((repoRoot as NSString).appendingPathComponent("docs/screenshots") as NSString)
            .appendingPathComponent(device)
        if device != "duo" {
            try FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
        }

        // US formatting ("48,213 words") whatever the simulator's region is.
        let locale = ["-AppleLocale", "en_US", "-AppleLanguages", "(en)"]
        if device == "mac" {
            app.launchArguments = ["-demoMode", "-app.zoomScale", "0.7"] + locale
        } else if device == "duo" {
            // The unfolded Duo's reader shot shows page-by-page's two-page spread.
            app.launchArguments = ["-demoMode", "-app.zoomScale", "1.0",
                                   "-reader.mode.phone", "pageByPage"] + locale
        } else {
            app.launchArguments = ["-demoMode", "-app.zoomScale", "1.0"] + locale
        }

        app.launch()

        // Let the app finish launching before we rotate.
        let launchExp = XCTestExpectation(description: "Wait for launch")
        _ = XCTWaiter.wait(for: [launchExp], timeout: 3.0)

        // Rotate AFTER launch. Setting the orientation pre-launch is unreliable —
        // the scene can ignore the request, which is what produced the broken
        // (portrait, sidebar-less) "mac" captures. Always setting the requested
        // orientation also resets the simulator after the landscape mac capture
        // so the later iPad portrait capture is actually portrait.
        //
        // Mac Catalyst has no device orientation — setting XCUIDevice.orientation
        // there throws NSInternalInconsistencyException ("Unsupported code path").
        // The Catalyst window is already landscape, so skip rotation entirely.
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = orientation
        let rotExp = XCTestExpectation(description: "Wait for rotation")
        _ = XCTWaiter.wait(for: [rotExp], timeout: 3.0)
        #endif

        // Wait non-blockingly for the app to settle into the final layout.
        let exp = XCTestExpectation(description: "Wait for layout")
        _ = XCTWaiter.wait(for: [exp], timeout: 3.0)

        // iPhone Duo: which display the app is on is only knowable from its
        // window — the test runner's own UIScreen reports the outer display
        // whatever the pose — so pick the folder now. The unfolded inner
        // display is ≥600 pt on its short side; the folded outer one ~466.
        if device == "duo" {
            let frame = app.windows.firstMatch.frame
            let display = min(frame.width, frame.height) >= 600 ? "duo-inner" : "duo-outer"
            shotDir = ((shotDir as NSString).deletingLastPathComponent as NSString).appendingPathComponent(display)
            try FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
            if display == "duo-inner" {
                isDuoInner = true
                // Unfolded, the Duo is a landscape book (fold down the middle),
                // which is also when page-by-page shows its two-page spread.
                currentOrientation = .landscapeLeft
                XCUIDevice.shared.orientation = .landscapeLeft
                _ = XCTWaiter.wait(for: [XCTestExpectation(description: "rotate")], timeout: 2.5)
            }
            // Tap around rather than using ⌘1–9: the shortcuts don't reach the
            // app on the folded Duo, and on the unfolded one (where the
            // sidebar is always showing) iOS 27.1's vertical bars mean no
            // screen exposes a titled navigation bar to confirm a jump by.
            useKeyboardNav = false
        }
    }

    private func snap(_ name: String) {
        // app.screenshot() does a full-screen grab on Mac Catalyst, so it
        // captures whatever window is frontmost (e.g. another app) instead of
        // Fanficly. Capturing the WINDOW element renders the app's own window
        // from its layer — independent of focus or z-order — so we always get
        // Fanficly, cropped to its window (incl. the Mac title bar). Calling
        // app.activate() here is NOT needed and actually destabilises the app
        // reference ("cannot request screenshot data because it does not exist").
        let window = app.windows.firstMatch
        var shot = window.exists ? window.screenshot() : app.screenshot()
        // iPhone Duo: capture the whole display the app is on — the largest
        // screen — at its exact App Store size (window snapshots came back a
        // pixel short, or as a transient window's size).
        if duoDisplay != nil,
           let screen = XCUIScreen.screens.max(by: {
               let a = $0.screenshot().image.size, b = $1.screenshot().image.size
               return a.width * a.height < b.width * b.height
           }) {
            shot = screen.screenshot()
        }
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
        let duo = duoDisplay != nil
        for _ in 0..<6 {
            if app.navigationBars["Fanficly"].exists || (duo && app.staticTexts["Fanficly"].exists) { return }
            if duo {
                // iPhone Duo moves the bars into a vertical strip on the
                // trailing edge, outside the navigation bar — where the first
                // nav-bar button is a screen's own action (e.g. Recently
                // Viewed's Clear), so only tap the back button by name.
                let back = app.buttons["BackButton"]
                if back.exists && back.isHittable { back.tap(); usleep(700_000); continue }
                break
            }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists && back.isHittable { back.tap(); usleep(600_000) } else { break }
        }
    }

    private func openSidebarItem(_ title: String) {
        // Landscape split view: tapping a sidebar row often doesn't switch the
        // detail column. The app registers ⌘1–9 (the "Go" menu) for the sidebar
        // items, so drive navigation by keyboard, which switches the selected
        // tab deterministically. This map MUST stay in sync with the "Go" menu
        // order in FanficlyApp.swift (= SidebarItem.allCases order) — inserting a
        // tab there shifts every later shortcut, which silently scrambles the
        // captures (e.g. ⌘3 lands on Popular, not Library).
        if useKeyboardNav,
           let key = ["Search": "1", "Browse": "2", "Popular": "3", "Library": "4",
                      "Recently Viewed": "5", "Followed Authors": "6", "Bookmarks": "7",
                      "Subscriptions": "8", "Settings": "9"][title] {
            // The ⌘ keypress dispatches asynchronously and the first one after
            // launch is often dropped, so RESEND until the target screen's content
            // nav bar actually appears (the sidebar nav bar is "Fanficly"; each
            // screen's content column carries its own title). This both confirms
            // navigation happened and synchronises before we capture.
            for _ in 0..<6 {
                app.typeKey(key, modifierFlags: .command)
                let landed = app.navigationBars[title].waitForExistence(timeout: 2.5)
                if landed {
                    usleep(700_000)
                    return
                }
            }
            // The keypresses never landed (it happens on a freshly booted
            // simulator): fall through to tapping the sidebar row rather than
            // capturing whatever screen is still showing.
        }
        revealSidebar()
        let cell = app.collectionViews.staticTexts[title].firstMatch
        let fallback = app.staticTexts[title].firstMatch
        let target = cell.waitForExistence(timeout: 2) ? cell : fallback
        if target.waitForExistence(timeout: 2) {
            if target.isHittable {
                target.tap()
            } else {
                // In a persistent split view (landscape iPad / Mac Catalyst) a
                // sidebar row can report as present but "not hittable"; force a
                // hit at its center instead of failing the run.
                target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            usleep(800_000)
        }
    }

    /// Tap a list/detail row by its label. In the iPad landscape split view a
    /// Form/List row is exposed as a button or cell rather than a bare static
    /// text (which is why it taps in portrait but not landscape), so try each
    /// element type, with a coordinate fallback for present-but-not-hittable.
    @discardableResult
    private func tapRow(_ label: String, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for el in [app.staticTexts[label], app.buttons[label], app.cells.staticTexts[label]] {
                if el.exists {
                    if el.isHittable { el.tap() }
                    else { el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                    return true
                }
            }
            usleep(300_000)
        }
        return false
    }
    /// On iPhone, trailing toolbar items collapse into a system overflow
    /// button at the far right of the navigation bar; open it if there is one.
    /// iPhone Duo puts the items in a vertical strip outside any navigation
    /// bar, so there may be nothing to tap — never tap a button that isn't there.
    private func openToolbarOverflow() {
        let more = app.buttons["More"]
        let buttons = app.navigationBars.buttons
        let overflow = more.exists ? more : (buttons.count > 0 ? buttons.element(boundBy: buttons.count - 1) : nil)
        guard let overflow, overflow.waitForExistence(timeout: 3), overflow.isHittable else { return }
        overflow.tap()
        usleep(600_000)
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
    /// Whether this simulator is (or stands in for) an iPhone Duo display. The
    /// inner display is regular width at ~669×951 pt, so an iPad mini in
    /// portrait (744 pt) can stand in for it. On a real Duo (phone idiom) this
    /// process's UIScreen always reports the squat ~466×678 pt outer display —
    /// no other iPhone is wider than 0.6:1 — whatever the pose, so treat the
    /// answer as "is a Duo"; setupAndLaunch picks inner vs outer from the
    /// app's window.
    private var duoDisplay: String? {
        let bounds = UIScreen.main.bounds
        let short = min(bounds.width, bounds.height), long = max(bounds.width, bounds.height)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:   return short < 900 ? "duo-inner" : nil
        case .phone: return short >= 600 ? "duo-inner" : short / long > 0.6 ? "duo-outer" : nil
        default:     return nil
        }
    }

    func testCaptureMainScreens() throws {
        // Duo stand-ins capture into their own folders (testCaptureDuoScreens).
        guard duoDisplay == nil else { return }
        let device: String
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            device = "ipad"
            useKeyboardNav = true
        default:    device = "iphone"
        }
        try setupAndLaunch(device: device, orientation: .portrait)
        try runCaptureFlow()
    }

    /// iPhone Duo screenshots → docs/screenshots/duo-inner (or duo-outer on a
    /// folded Duo simulator). bin/frame-screenshots.py derives the outer set
    /// from the iPhone captures when there's no duo-outer folder.
    func testCaptureDuoScreens() throws {
        guard let display = duoDisplay else { return }
        if display == "duo-inner" && UIDevice.current.userInterfaceIdiom == .pad {
            // iPad mini standing in for the inner display.
            useKeyboardNav = true
            try setupAndLaunch(device: "duo-inner", orientation: .portrait)
        } else {
            // A real iPhone Duo: the folder is chosen from the app's window
            // after launch (setupAndLaunch), since it depends on the pose.
            try setupAndLaunch(device: "duo", orientation: .portrait)
        }
        try runCaptureFlow()
    }

    func testCaptureMacScreens() throws {
        // We capture landscape screenshots on iPad (or Mac Catalyst) for "mac"
        guard UIDevice.current.userInterfaceIdiom == .pad || UIDevice.current.userInterfaceIdiom == .mac else { return }
        guard duoDisplay == nil else { return }
        useKeyboardNav = true
        try setupAndLaunch(device: "mac", orientation: .landscapeRight)
        try runCaptureFlow()
    }

    private func runCaptureFlow() throws {
        usleep(900_000)
        snap("01-home")

        // Library — seeded with followed + downloaded works.
        openSidebarItem("Library")
        usleep(700_000)
        snap("04-library")

        // Browse — category catalog.
        openSidebarItem("Browse")
        usleep(700_000)
        snap("05-browse")

        // Fandoms list within a category (TV Shows)
        if tapRow("TV Shows") {
            usleep(900_000)
            snap("05-browse-fandoms")
            
            // Pop back to Browse so that the rest of the flow is clean
            let browseBack = app.navigationBars.buttons.element(boundBy: 0)
            if browseBack.exists && browseBack.isHittable { browseBack.tap(); usleep(600_000) }
        }

        // Popular — trending fandoms / ships / characters (the discovery story).
        openSidebarItem("Popular")
        usleep(900_000)
        snap("10-popular")

        // Recently Viewed — seeded history.
        openSidebarItem("Recently Viewed")
        usleep(700_000)
        snap("06-recently-viewed")

        // Bookmarks — the logged-in reader's AO3 bookmarks (demo is signed in).
        openSidebarItem("Bookmarks")
        _ = app.cells.firstMatch.waitForExistence(timeout: 6)
        usleep(900_000)
        snap("12-bookmarks")

        // Reader settings — themes & typography (the customization story).
        openSidebarItem("Settings")
        usleep(500_000)
        if tapRow("Theme & typography") {
            usleep(800_000)
            snap("07-reader-settings")
        }

        // Privacy — "what this app sees and stores" (the zero-tracking story).
        // We're in Theme & typography (pushed from Settings). Pop back ONE level
        // to the Settings root, then open the privacy page. On iPad's split view
        // re-selecting the Settings sidebar item won't pop the detail stack, so
        // navigate via the back button instead of openSidebarItem.
        // The row sits below the fold, and a List doesn't create off-screen
        // rows, so scroll until it exists (without this the shot was silently
        // skipped and 08-privacy.png went stale).
        let settingsBack = duoDisplay != nil
            ? app.buttons["BackButton"]
            : app.navigationBars.buttons.element(boundBy: 0)
        if settingsBack.exists && settingsBack.isHittable { settingsBack.tap(); usleep(700_000) }
        for _ in 0..<6 where !app.staticTexts["What this app sees and stores"].exists
                             && !app.buttons["What this app sees and stores"].exists {
            // Swipe the widest list (Settings, not the sidebar) rather than
            // the app: on the unfolded iPhone Duo XCUITest reports the app's
            // frame in portrait while the UI is landscape, so an app-level
            // swipe lands in the wrong place.
            let lists = app.collectionViews.allElementsBoundByIndex
            let list = lists.max { $0.frame.width < $1.frame.width }
            (list ?? app).swipeUp(velocity: .slow)
            usleep(400_000)
        }
        if tapRow("What this app sees and stores") {
            usleep(800_000)
            snap("08-privacy")
        }

        // The sidebar walk can leave a pushed detail that blocks the search
        // field. Relaunch for a clean root while preserving this capture's
        // requested orientation.
        if useKeyboardNav {
            app.launch()
            #if !targetEnvironment(macCatalyst)
            XCUIDevice.shared.orientation = currentOrientation
            #endif
            let relaunchSettle = XCTestExpectation(description: "relaunch settle")
            _ = XCTWaiter.wait(for: [relaunchSettle], timeout: 3.0)
        }

        // Search + reader + TTS run LAST: in the landscape split view the
        // reader sticks in the detail column, so opening it earlier would
        // bleed into every screen captured after it.
        // Search — type a prompt; demo data returns results instantly (offline).
        openSidebarItem("Search")
        usleep(500_000)
        // The search box is a TextField; fall back through the element types in
        // case a platform exposes it differently.
        var field = app.textFields.firstMatch
        if !field.waitForExistence(timeout: 3) {
            if app.textViews.firstMatch.exists { field = app.textViews.firstMatch }
            else if app.searchFields.firstMatch.exists { field = app.searchFields.firstMatch }
        }
        if field.waitForExistence(timeout: 3) {
            field.tap()
            usleep(300_000)
            // The end state of tapping an AO3 tag suggestion plus typing the
            // filter word "complete": two chips over a full page of results.
            // Typed as the equivalent explicit tag, which becomes the same chip
            // on submit, because waiting on live typeahead made the shot flaky
            // (it timed out on iPhone mid-run while passing in isolation).
            field.typeText("tag:\"Slow Burn\" complete\n")
            _ = app.cells.firstMatch.waitForExistence(timeout: 6)
            usleep(700_000)
            snap("02-search-results")

            // Reader — open the first result.
            app.cells.firstMatch.tap()
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 6)
            usleep(900_000)
            if isDuoInner {
                // Collapse the sidebar so the reader gets the whole display
                // (and its two-page spread), then turn past the title page.
                let toggle = app.buttons.matching(NSPredicate(
                    format: "identifier == 'ToggleSidebar' OR label CONTAINS[c] 'sidebar'")).firstMatch
                if toggle.exists && toggle.isHittable { toggle.tap(); usleep(1_200_000) }
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
                usleep(1_200_000)
            }
            snap("03-reader")

            // Comments — open the reader's "Work options" menu (collapsed into the
            // system overflow on iPhone), then the Comments item. Demo mode is
            // signed in, so the thread + composer render. Dismiss with Done after.
            var optionsButton = app.buttons["Work options"]
            if !optionsButton.waitForExistence(timeout: 2) || !optionsButton.isHittable {
                openToolbarOverflow()
                optionsButton = app.buttons["Work options"]
            }
            if optionsButton.waitForExistence(timeout: 3) {
                if optionsButton.isHittable { optionsButton.tap() }
                else { optionsButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                usleep(600_000)
                let commentsItem = app.buttons["Comments"]
                if commentsItem.waitForExistence(timeout: 3) {
                    commentsItem.tap()
                    _ = app.navigationBars["Comments"].waitForExistence(timeout: 6)
                    _ = app.cells.firstMatch.waitForExistence(timeout: 6)
                    usleep(900_000)
                    snap("11-comments")
                    let doneButton = app.buttons["Done"]
                    if doneButton.waitForExistence(timeout: 3) && doneButton.isHittable {
                        doneButton.tap(); usleep(600_000)
                    }
                }
            }

            // Text to speech narration
            var ttsButton = findSettingsButton()
            if !ttsButton.isHittable {
                // On iPhone, trailing toolbar items are collapsed into a default overflow button at the far right
                openToolbarOverflow()
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
                        openToolbarOverflow()
                        ttsButtonToStop = findSettingsButton() // Refresh after opening overflow menu
                    }
                    
                    if ttsButtonToStop.waitForExistence(timeout: 3) {
                        ttsButtonToStop.tap()
                        usleep(600_000)
                        // firstMatch: the narration bar's close button carries the
                        // same "Stop listening" accessibility label as this menu
                        // item, and both are on screen here — an un-disambiguated
                        // query throws on tap. Either element stops narration.
                        let stopButton = app.buttons["Stop listening"].firstMatch
                        if stopButton.waitForExistence(timeout: 3) {
                            stopButton.tap()
                            usleep(600_000)
                        }
                    }
                }
            }
        }
    }
}
