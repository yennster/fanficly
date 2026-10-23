import XCTest
import UIKit

final class FanficlyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_appLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Fanficly"].waitForExistence(timeout: 5))
    }
}

/// Page-by-page layout on whatever device this runs on (CI: an iPhone and an
/// iPad; locally also iPhone Duo or the Mac). The page footer sits on the
/// bottom edge, each page's text runs down to it, and none of that changes
/// when the app is backgrounded, the controls are toggled, a keyboard comes up
/// or the window turns wide enough for two pages. Two bugs this guards
/// against: pages measured for a moment's short layout and left with a band of
/// blank space for good, and the footer riding a keyboard-high inset up the
/// screen. Demo mode with long chapters, so a page mid-chapter is always full.
final class ReaderLayoutTests: XCTestCase {
    private var app: XCUIApplication!

    /// The most blank space a full page may leave under its last line: the
    /// page's bottom margin (12 pt) and a paragraph gap plus a line that
    /// didn't fit (16 + ~27 pt for the
    /// typography these tests set), with slack for text frames. The bugs
    /// left a 130–300 pt band.
    private let maxBlankBelowText: CGFloat = 75

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        var arguments = ["-demoMode", "-demoLongChapters",
                         "-AppleLocale", "en_US", "-AppleLanguages", "(en)",
                         "-app.selectedTabRaw", "search", "-app.zoomScale", "1.0"]
        // Default typography in page-by-page, whatever this simulator was set to.
        for device in ["phone", "pad", "mac"] {
            arguments += ["-reader.mode.\(device)", "pageByPage",
                          "-reader.fontSizePt.\(device)", "18",
                          "-reader.lineSpacingPt.\(device)", "6",
                          "-reader.paragraphSpacingPt.\(device)", "16"]
        }
        app.launchArguments = arguments
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .portrait
        #endif
        app.launch()
    }

    override func tearDownWithError() throws {
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    // MARK: - Tests

    func test_pagesFillTheScreen() throws {
        let footer = openReader()
        turnToMiddlePage(footer)
        capture("01-page")
        try assertPageLayout(footer, "on opening")
    }

    func test_backgrounding_keepsThePageLayout() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("The Mac has no home button.")
        #else
        let footer = openReader()
        turnToMiddlePage(footer)
        let before = footer.label
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(footer.waitForExistence(timeout: 8), "the reader came back")
        settle()
        capture("02-after-backgrounding")
        XCTAssertEqual(footer.label, before, "backgrounding moved the page or repaginated")
        try assertPageLayout(footer, "after backgrounding")
        #endif
    }

    func test_togglingTheControls_fillsThePageAndKeepsItInPlace() throws {
        let footer = openReader()
        turnToMiddlePage(footer)
        try assertFullScreenFillsThePage(footer, "one page", screenshots: ("03-full-screen", "04-controls-back"))
    }

    func test_keyboard_leavesTheFooterAndPagesAlone() throws {
        let footer = openReader()
        turnToMiddlePage(footer)
        let before = footer.label
        // The reader's only text field: naming a new settings profile.
        try openNewProfilePrompt()
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 4) else {
            app.alerts.buttons["Cancel"].firstMatch.tap()
            throw XCTSkip("No on-screen keyboard here (a hardware keyboard is connected).")
        }
        capture("05-keyboard-up")
        if footer.exists {
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThanOrEqual(footer.frame.maxY, window.maxY - 50,
                                        "the footer rode \(window.maxY - footer.frame.maxY) pt up on the keyboard")
        }
        app.alerts.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(waitForAbsence(keyboard), "the keyboard went away")
        settle()
        capture("06-after-keyboard")
        XCTAssertEqual(footer.label, before, "the keyboard repaginated the reader")
        try assertPageLayout(footer, "after the keyboard")
    }

    func test_wideWindow_showsTwoFullPages() throws {
        // A wide window shows a two-page spread: iPad or an iPhone in
        // landscape, iPhone Duo unfolded, the Mac (its window is already wide).
        let footer = openReader()
        turnToMiddlePage(footer)
        #if !targetEnvironment(macCatalyst)
        if !isDuoUnfolded {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(2)
        }
        #endif
        XCTAssertTrue(footer.waitForExistence(timeout: 8))
        settle()
        if !isDuoUnfolded {
            // Same rule as ReaderSpread.layout: at least 700 pt wide, 1.15× wider
            // than tall, and two pages of at least 280 pt with a 56 pt gutter.
            let bar = footer.frame
            let pageHeight = bar.minY - readerTopEdge(above: bar)
            let expectSpread = bar.width >= 700 && bar.width >= pageHeight * 1.15 && (bar.width - 56) / 2 >= 280
            XCTAssertEqual(page(footer)?.isSpread, expectSpread,
                           "\(bar.width)×\(pageHeight) pt window shows \(footer.label)")
        } else {
            XCTAssertEqual(page(footer)?.isSpread, true, "unfolded iPhone Duo shows \(footer.label)")
        }
        turnToMiddlePage(footer)
        capture("07-wide-window")
        try assertPageLayout(footer, "in a wide window")
        try assertFullScreenFillsThePage(footer, "in a wide window",
                                         screenshots: ("08-wide-full-screen", "09-wide-controls-back"))
    }

    func test_fullScreen_keepsTheToolbar() throws {
        // Full screen used to hide the whole toolbar, leaving only an
        // invisible tap on the page's middle third, which on iPhone Duo could
        // go nowhere: the reader was a trap. The system toolbar (its back
        // button and Show reader controls) now stays in every mode.
        let footer = openReader()
        turnToMiddlePage(footer)
        let bar = footer.frame
        // The reader's own back button, never a sidebar row of the same name.
        let readerBar = app.navigationBars.containing(.button, identifier: "reader.fullScreenToggle").firstMatch
        let back = readerBar.exists && readerBar.buttons["BackButton"].exists
            ? readerBar.buttons["BackButton"]
            : app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the system back button")
        tap(CGPoint(x: bar.midX, y: bar.minY - 200))
        XCTAssertTrue(waitForAbsence(footer), "the controls hid")
        settle()
        capture("10-full-screen-toolbar")
        XCTAssertTrue(back.exists && back.isHittable, "full screen keeps the back button")
        // Show reader controls: in the bar, or in the system overflow (More)
        // where a narrow bar or iPhone Duo's vertical strip folds it.
        let toggle = app.buttons["reader.fullScreenToggle"]
        if !(toggle.exists && toggle.isHittable) {
            let overflow = app.buttons["BottomOverflowBarButtonItem"].firstMatch
            XCTAssertTrue(overflow.exists && overflow.isHittable, "full screen keeps Show reader controls or the More button")
            overflow.tap()
        }
        let show = app.buttons.matching(NSPredicate(
            format: "identifier == 'reader.fullScreenToggle' OR label == 'Show reader controls'")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 4), "full screen keeps Show reader controls")
        XCTAssertEqual(show.label, "Show reader controls")
        show.tap()
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "Show reader controls brought the controls back")
        settle()
        tap(CGPoint(x: bar.midX, y: bar.minY - 200))
        XCTAssertTrue(waitForAbsence(footer), "full screen again")
        back.tap()
        XCTAssertTrue(waitForAbsence(app.buttons["reader.fullScreenToggle"], timeout: 8), "Back left the reader")
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 8), "Back returned to Search")
    }

    // MARK: - Navigation

    /// Opens a demo work from Search (typing leaves the keyboard up as the
    /// reader opens) and returns the page footer once pages are laid out.
    private func openReader(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let field = app.textFields.firstMatch
        // iPhone launches on the sidebar menu; iPad and the Mac show Search.
        // Right after the simulator boots, the app can take ~30 s to launch
        // and a tap on the menu can go nowhere while it settles, so tap
        // again until Search opens.
        for _ in 0..<3 where !field.waitForExistence(timeout: 5) {
            let row = app.staticTexts["Search"].firstMatch
            if row.waitForExistence(timeout: 4) { row.tap() }
        }
        XCTAssertTrue(field.waitForExistence(timeout: 8), "the search field", file: file, line: line)
        field.tap()
        field.typeText("river\n")
        let title = "The Long Way Home"
        let result = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        let cell = result.waitForExistence(timeout: 10) ? result : app.cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "search results", file: file, line: line)
        cell.tap()
        let footer = app.descendants(matching: .any).matching(identifier: "reader.pageFooter").firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 20), "the page-by-page footer", file: file, line: line)
        if isDuoUnfolded {
            // Unfolded, the Duo keeps the sidebar beside the reader, which
            // leaves it too narrow for the two-page spread: hide it.
            let hide = app.buttons["Hide Sidebar"].firstMatch
            if hide.exists && hide.isHittable { hide.tap() }
        }
        settle()
        return footer
    }

    /// Turns forward until both edges of what's on screen are full pages in
    /// the middle of a chapter: not its first page (the title page or the
    /// chapter heading) nor its last (which may be short).
    private func turnToMiddlePage(_ footer: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<10 {
            if let page = page(footer), page.first >= 3, page.last < page.total { return }
            let before = footer.label
            let bar = footer.frame
            tap(CGPoint(x: bar.minX + bar.width * 0.9, y: bar.minY - 120))  // the turn-forward third
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label != %@", before), object: footer)], timeout: 3)
        }
        XCTFail("never reached a page mid-chapter: \(footer.label)", file: file, line: line)
    }

    private func openNewProfilePrompt() throws {
        let settings = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'reader_settings_button' OR label == 'Reader settings'")).firstMatch
        if !settings.exists || !settings.isHittable {
            // A narrow nav bar folds trailing items into the system overflow.
            // iPhone Duo's vertical strip has no navigation bar: its overflow
            // is the strip's More button.
            let overflow = app.buttons["BottomOverflowBarButtonItem"].firstMatch
            if overflow.exists && overflow.isHittable {
                overflow.tap()
            } else {
                app.navigationBars.buttons.allElementsBoundByIndex.last?.tap()
            }
        }
        guard settings.waitForExistence(timeout: 4) else { throw XCTSkip("Couldn't find the reader settings menu.") }
        settings.tap()
        let profile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Profile")).firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 4), "the Profile submenu")
        profile.tap()
        let save = app.buttons["Save Current as New Profile..."].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 4), "Save Current as New Profile…")
        save.tap()
        XCTAssertTrue(app.alerts.textFields.firstMatch.waitForExistence(timeout: 4), "the profile name prompt")
    }

    // MARK: - Layout checks

    /// Hides the controls (full screen) and shows them again. Hidden, the
    /// page footer goes too (iPhone Duo included) and the page re-paginates
    /// to fill the room they left (it used to leave it blank); both ways the
    /// page keeps its first line.
    private func assertFullScreenFillsThePage(_ footer: XCUIElement, _ context: String,
                                              screenshots: (hidden: String, shown: String),
                                              file: StaticString = #filePath, line: UInt = #line) throws {
        let bar = footer.frame
        let shown = try storyTexts(above: bar)
        let firstWords = try XCTUnwrap(openingWords(shown), "\(context): text on the page", file: file, line: line)
        // The middle third of the page shows or hides the controls.
        let middle = CGPoint(x: bar.midX, y: bar.minY - 200)
        tap(middle)
        XCTAssertTrue(waitForAbsence(footer), "\(context): the controls hid", file: file, line: line)
        settle()
        capture(screenshots.hidden)
        // The footer's bottom edge is the page area's.
        let hidden = try storyTexts(above: CGRect(x: bar.minX, y: bar.maxY, width: bar.width, height: 0))
        XCTAssertEqual(openingWords(hidden), firstWords, "\(context): hiding the controls moved the page",
                       file: file, line: line)
        // Text on both sides of the middle: a two-page spread.
        let twoPages = { (texts: [(frame: CGRect, text: String)]) in
            texts.contains { $0.frame.minX > bar.midX } && texts.contains { $0.frame.maxX < bar.midX }
        }
        XCTAssertEqual(twoPages(hidden), twoPages(shown), "\(context): full screen switched between one page and two",
                       file: file, line: line)
        // Full screen's pages run to the bottom of the screen, where the
        // footer's bottom edge was.
        assertPagesFull(hidden, endingAt: bar.maxY, spread: twoPages(shown), across: bar,
                        "\(context), full screen", file: file, line: line)
        // The room gained: the footer's, plus the nav bar's where the text
        // moves up into it. Room for a paragraph gap and a line (~45 pt here)
        // must take more text; less may legitimately not.
        let top = { (texts: [(frame: CGRect, text: String)]) in texts.map(\.frame.minY).min() ?? 0 }
        let gained = bar.height + top(shown) - top(hidden)
        if gained >= 60 {
            XCTAssertGreaterThan(characters(hidden), characters(shown),
                                 "\(context): full screen gained \(gained) pt but the page holds no more text: the room stayed blank",
                                 file: file, line: line)
        } else {
            XCTAssertGreaterThanOrEqual(characters(hidden), characters(shown),
                                        "\(context): full screen lost text", file: file, line: line)
        }
        tap(middle)
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "\(context): the controls came back", file: file, line: line)
        settle()
        capture(screenshots.shown)
        XCTAssertEqual(openingWords(try storyTexts(above: footer.frame)), firstWords,
                       "\(context): showing the controls moved the page", file: file, line: line)
        try assertPageLayout(footer, "\(context), after toggling the controls", file: file, line: line)
    }

    /// The footer sits on the bottom edge, and each page on screen is full:
    /// its text ends just above the footer, not short of it and not under it.
    private func assertPageLayout(_ footer: XCUIElement, _ context: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let window = app.windows.firstMatch.frame
        let bar = footer.frame
        XCTAssertLessThan(bar.height, 60, "\(context): the footer is \(bar.height) pt tall", file: file, line: line)
        XCTAssertGreaterThanOrEqual(bar.maxY, window.maxY - 50,
                                    "\(context): the footer ends \(window.maxY - bar.maxY) pt above the bottom",
                                    file: file, line: line)
        assertPagesFull(try storyTexts(above: bar), endingAt: bar.minY, spread: page(footer)?.isSpread == true,
                        across: bar, "\(context) (\(footer.label))", file: file, line: line)
    }

    /// Each page on screen ends just above `edge` (the bottom of the page
    /// area): never past it, and no more than `maxBlankBelowText` short.
    private func assertPagesFull(_ texts: [(frame: CGRect, text: String)], endingAt edge: CGFloat, spread: Bool,
                                 across bar: CGRect, _ context: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let pages = spread ? [(bar.minX, bar.midX), (bar.midX, bar.maxX)] : [(bar.minX, bar.maxX)]
        for (index, (minX, maxX)) in pages.enumerated() {
            let which = pages.count > 1 ? (index == 0 ? "left page" : "right page") : "page"
            guard let bottom = texts.filter({ $0.frame.midX >= minX && $0.frame.midX < maxX }).map(\.frame.maxY).max() else {
                XCTFail("\(context): no text on the \(which)", file: file, line: line)
                continue
            }
            XCTAssertLessThanOrEqual(bottom, edge + 1,
                                     "\(context): the \(which)'s text runs \(bottom - edge) pt past the page area",
                                     file: file, line: line)
            XCTAssertGreaterThanOrEqual(bottom, edge - maxBlankBelowText,
                                        "\(context): \(edge - bottom) pt blank under the \(which)'s text",
                                        file: file, line: line)
        }
    }

    /// Frames of the text across the reader's column(s) above the footer.
    private func storyTextFrames(above bar: CGRect) throws -> [CGRect] {
        try storyTexts(above: bar).map(\.frame)
    }

    /// The text across the reader's column(s) above `bar` (the footer), one
    /// element per paragraph on the page, from one snapshot (querying each
    /// element takes ~0.1 s). The pages either side of the one showing sit off
    /// screen and drop out.
    private func storyTexts(above bar: CGRect) throws -> [(frame: CGRect, text: String)] {
        // The snapshot isn't Sendable, so walk it on the main actor (which UI
        // tests run on) and hand back plain values. Capture only the app: the
        // test case itself can't cross into the main actor.
        let app: XCUIApplication = self.app
        return try MainActor.assumeIsolated {
            var texts: [(frame: CGRect, text: String)] = []
            func collect(_ element: any XCUIElementSnapshot) {
                let frame = element.frame
                if element.elementType == .staticText, frame.height > 0, frame.minY < bar.minY,
                   frame.minX >= bar.minX - 1, frame.maxX <= bar.maxX + 1 {
                    texts.append((frame, element.label))
                }
                element.children.forEach(collect)
            }
            collect(try app.snapshot())
            return texts
        }
    }

    /// The first words on the page (on the left page of a spread).
    private func openingWords(_ texts: [(frame: CGRect, text: String)]) -> String? {
        texts.min { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            .map { String($0.text.prefix(40)) }
    }

    private func characters(_ texts: [(frame: CGRect, text: String)]) -> Int {
        texts.reduce(0) { $0 + $1.text.count }
    }

    /// The bottom of the reader's nav bar (the top of its page area).
    private func readerTopEdge(above bar: CGRect) -> CGFloat {
        let bars = app.navigationBars.allElementsBoundByIndex.map { $0.frame }
            .filter { $0.minX <= bar.midX && $0.maxX >= bar.midX && $0.maxY <= bar.minY }
        return bars.map(\.maxY).max() ?? app.windows.firstMatch.frame.minY
    }

    private struct PageNumbers {
        let first: Int, last: Int, total: Int
        var isSpread: Bool { last > first }
    }

    /// "Chapter 1 · Landfall, page 3 of 12" or "…, pages 3–4 of 12".
    private func page(_ footer: XCUIElement) -> PageNumbers? {
        let label = footer.label
        guard let range = label.range(of: #"pages? \d+(–\d+)? of \d+"#, options: .regularExpression) else { return nil }
        let numbers = label[range].split { !$0.isNumber }.compactMap { Int($0) }
        guard let first = numbers.first, let total = numbers.last, numbers.count >= 2 else { return nil }
        return PageNumbers(first: first, last: numbers.count == 3 ? numbers[1] : first, total: total)
    }

    // MARK: - Helpers

    /// iPhone Duo unfolded: phone idiom, but no other iPhone is 600 pt across.
    private var isDuoUnfolded: Bool {
        let window = app.windows.firstMatch.frame
        return UIDevice.current.userInterfaceIdiom == .phone && min(window.width, window.height) >= 600
    }

    /// Taps a point in the frames' coordinates, measured from the window: the
    /// unfolded Duo reports the app's own frame in portrait while the window
    /// and everything in it are landscape.
    private func tap(_ point: CGPoint) {
        let window = app.windows.firstMatch
        let origin = window.frame.origin
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - origin.x, dy: point.y - origin.y)).tap()
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    /// Saves what's on screen to build/reader-layout-screenshots/<device>/
    /// (CI uploads that folder as the reader-layout-screenshots artifact) and
    /// attaches it to the test result. Taken before a step's checks, so a
    /// failure still leaves a picture of it.
    private func capture(_ name: String) {
        #if targetEnvironment(macCatalyst)
        let shot = app.windows.firstMatch.screenshot()
        #else
        // Unfolded, iPhone Duo's main screen is its dark outer display.
        let shot = isDuoUnfolded ? app.windows.firstMatch.screenshot() : XCUIScreen.main.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let repoRoot = ((#filePath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let device = UIDevice.current.name.replacingOccurrences(of: " ", with: "-")
        let folder = (repoRoot as NSString).appendingPathComponent("build/reader-layout-screenshots/\(device)")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent("\(name).png")))
    }

    /// Pagination, the page-height settle (0.6 s) and the page turn's animation.
    private func settle() {
        usleep(1_500_000)
    }
}

/// Library, Stats, Subscriptions and Settings at the largest accessibility text
/// size (RM-019). Each screen's icon-only buttons must carry a spoken label,
/// and Xcode's accessibility audit runs over what's on screen. Demo mode, so
/// every screen has content without a network or an AO3 login.
final class NonReaderAccessibilityTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    func test_library() throws {
        open(tab: "library", title: "Library")
        assertLabeled(["Sort"])
        audit("library")
    }

    func test_stats() throws {
        open(tab: "stats", title: "Stats")
        assertLabeled(["Share"])
        audit("stats")
        // The ‹ › period buttons only show for a dated period. At this text
        // size the period picker is a menu (segments clip their titles).
        let week = app.buttons["Week"].firstMatch
        if !week.waitForExistence(timeout: 2) {
            let menu = app.buttons.matching(NSPredicate(
                format: "label == 'Period' OR label CONTAINS 'All Time'")).firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 3), "the period menu")
            menu.tap()
        }
        if week.waitForExistence(timeout: 3) { week.tap() }
        assertLabeled(["Previous week", "Next week"])
        audit("stats-week")
    }

    func test_subscriptions() throws {
        open(tab: "subscriptions", title: "Subscriptions")
        // Demo mode starts with none stored; Refresh fetches the demo list.
        let empty = app.buttons["Refresh"].firstMatch
        if empty.waitForExistence(timeout: 3) { empty.tap() }
        usleep(2_000_000)
        assertLabeled(["Refresh subscriptions"])
        audit("subscriptions")
    }

    func test_settings() throws {
        open(tab: "settings", title: "Settings")
        audit("settings")
        for page in 1...4 {
            app.swipeUp()
            usleep(500_000)
            audit("settings-\(page)")
        }
        let reader = app.buttons["Theme & typography"].firstMatch
        for _ in 0..<4 where !reader.exists { app.swipeDown() }
        if reader.waitForExistence(timeout: 3) {
            reader.tap()
            usleep(1_000_000)
            audit("reader-settings")
            // The text-size row's −/+ buttons are icon-only.
            for _ in 0..<6 where !app.buttons["Increase Text size"].exists { app.swipeUp() }
            assertLabeled(["Decrease Text size", "Increase Text size"])
            audit("reader-settings-sliders")
        } else {
            XCTFail("Theme & typography row")
        }
    }

    // MARK: - Helpers

    /// Launches at the largest accessibility text size on `tab`. iPhone
    /// launches on the sidebar menu, so tap the row there when the tab isn't
    /// already showing.
    private func open(tab: String, title: String, file: StaticString = #filePath, line: UInt = #line) {
        app.launchArguments = ["-demoMode",
                               "-AppleLocale", "en_US", "-AppleLanguages", "(en)",
                               "-app.selectedTabRaw", tab, "-app.zoomScale", "1.0",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let bar = app.navigationBars[title]
        if !bar.waitForExistence(timeout: 8) {
            let row = app.staticTexts[title].firstMatch
            for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
            if row.exists { row.tap() }
        }
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the \(title) screen", file: file, line: line)
        usleep(1_000_000)
    }

    /// Every one of these buttons is on screen, found by its spoken label.
    private func assertLabeled(_ labels: [String], file: StaticString = #filePath, line: UInt = #line) {
        for label in labels {
            XCTAssertTrue(app.buttons[label].firstMatch.waitForExistence(timeout: 5),
                          "a button labeled \"\(label)\"", file: file, line: line)
        }
    }

    /// Runs Xcode's accessibility audit and logs every issue it finds, with a
    /// screenshot of the screen it ran on.
    private func audit(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "a11y-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
        do {
            try app.performAccessibilityAudit { issue in
                let element = issue.element
                print("A11Y-AUDIT [\(name)] type=\(issue.auditType.rawValue) \(issue.compactDescription) | label=\"\(element?.label ?? "")\" id=\"\(element?.identifier ?? "")\" kind=\(element?.elementType.rawValue ?? 0) frame=\(element?.frame ?? .zero) | \(issue.detailedDescription)")
                return true
            }
        } catch {
            print("A11Y-AUDIT [\(name)] audit failed: \(error)")
        }
    }
}
