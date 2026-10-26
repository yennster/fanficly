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

    /// The page's top and bottom margin (ReaderView.pageVerticalMargin): the
    /// page's own frame, which clips its text, ends this far above the footer.
    private let pageMargin: CGFloat = 12

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

    func test_togglingTheControls_keepsThePageStill() throws {
        let footer = openReader()
        turnToMiddlePage(footer)
        try assertTogglingKeepsThePageStill(footer, "one page", screenshots: ("03-full-screen", "04-controls-back"))
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
        try assertTogglingKeepsThePageStill(footer, "in a wide window",
                                            screenshots: ("08-wide-full-screen", "09-wide-controls-back"))
    }

    func test_fullWidthMargins_keepEveryLineOnThePage() throws {
        // 1.12.0: with Page margins at Full (100%), the last line of iPhone
        // Duo's open book was cut off at the bottom of the page in full
        // screen. At 100% a page reaches the side of the reader (the Duo's
        // toolbar strip). One page at full margins, then a wide window.
        app.terminate()
        for device in ["phone", "pad", "mac"] {
            app.launchArguments += ["-reader.widthPercent.\(device)", "100",
                                    "-reader.spreadWidthPercent.\(device)", "100"]
        }
        app.launch()
        let footer = openReader()
        turnToMiddlePage(footer)
        capture("12-full-margins")
        try assertPageLayout(footer, "full margins")
        #if !targetEnvironment(macCatalyst)
        if !isDuoUnfolded {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(2)
            XCTAssertTrue(footer.waitForExistence(timeout: 8))
            settle()
            turnToMiddlePage(footer)
        }
        #endif
        capture("13-full-margins-wide")
        try assertPageLayout(footer, "full margins in a wide window")
        try assertTogglingKeepsThePageStill(footer, "full margins in a wide window",
                                            screenshots: ("14-full-margins-full-screen", "15-full-margins-controls-back"))
    }

    func test_fullScreen_leavesOnlyThePage() throws {
        // As in Apple Books, a tap on the page's middle third hides every
        // control (no back arrow or full screen button stays behind) and
        // another tap brings them all back. Full screen once hid the whole
        // bar and on iPhone Duo the tap back could go nowhere, trapping the
        // reader, so this checks the tap brings the controls back every time.
        let footer = openReader()
        turnToMiddlePage(footer)
        let bar = footer.frame
        let middle = CGPoint(x: bar.midX, y: bar.minY - 200)
        let systemBack = app.buttons["BackButton"]
        let readerItems = readerToolbarItem
        // The work page's own items (WorkDetailView), hidden through
        // ReaderFullScreenKey.
        let hostItems = app.buttons.matching(NSPredicate(
            format: "label IN {'Save to Library', 'Remove from Library'}"))
        let pageNumber = app.descendants(matching: .any).matching(identifier: "reader.pageNumber").firstMatch
        XCTAssertTrue(systemBack.exists, "the system back button, with the controls up")
        XCTAssertTrue(readerItems.exists, "the reader's toolbar items, with the controls up")
        XCTAssertFalse(pageNumber.exists, "the bare page number only shows in full screen")
        for round in 1...2 {
            tap(middle)
            XCTAssertTrue(waitForAbsence(footer), "round \(round): the controls hid")
            XCTAssertTrue(waitForAbsence(systemBack), "round \(round): full screen hides the system back button")
            settle()
            if round == 1 { capture("10-full-screen-only-the-page") }
            XCTAssertFalse(readerItems.exists, "round \(round): full screen hides the reader's items")
            XCTAssertEqual(hostItems.count, 0, "round \(round): full screen hides the work page's items")
            XCTAssertFalse(app.buttons["reader.fullScreenBack"].exists, "round \(round): no back arrow stays behind")
            XCTAssertTrue(pageNumber.exists, "round \(round): full screen keeps the page number")
            tap(middle)
            XCTAssertTrue(footer.waitForExistence(timeout: 5), "round \(round): a tap brought the controls back")
            XCTAssertTrue(systemBack.waitForExistence(timeout: 5), "round \(round): the toolbar came back with its back button")
            XCTAssertTrue(readerItems.waitForExistence(timeout: 5), "round \(round): the toolbar came back with its items")
            XCTAssertTrue(waitForAbsence(pageNumber), "round \(round): the bare page number went with full screen")
            settle()
        }
        systemBack.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 8), "Back returned to Search")
    }

    func test_scrollingFullScreen_runsEdgeToEdge() throws {
        // Continuous mode in full screen: the text ran up to the top edge but
        // was cut off above a blank band at the bottom. It now runs to the
        // bottom edge too. A picture for a person to check: XCUITest can't
        // see clipping.
        app.terminate()
        app.launchArguments = app.launchArguments.map { $0 == "pageByPage" ? "continuous" : $0 }
        app.launch()
        let items = openReader(pageByPage: false)
        // Scroll into the story (past the title page's links) so text fills
        // the screen top to bottom, then tap it for full screen.
        app.swipeUp()
        settle()
        let window = app.windows.firstMatch.frame
        let screen = CGRect(x: window.minX, y: window.maxY, width: window.width, height: 0)
        // A paragraph well clear of the bars, to see whether the text moves.
        let marker = try XCTUnwrap(try storyTexts(above: screen)
            .filter { $0.frame.minY > window.minY + 150 && $0.text.count > 40 }
            .min { $0.frame.minY < $1.frame.minY }, "story text on screen")
        tap(CGPoint(x: window.midX, y: window.midY))
        XCTAssertTrue(waitForAbsence(items), "full screen")
        settle()
        capture("11-continuous-full-screen")
        let same = try storyTexts(above: screen).first { $0.text == marker.text }
        XCTAssertEqual(same?.frame.minY ?? -1, marker.frame.minY, accuracy: 1, "hiding the controls moved the text")
        tap(CGPoint(x: window.midX, y: window.midY))
        XCTAssertTrue(items.waitForExistence(timeout: 5), "the controls came back")
    }

    // MARK: - Navigation

    /// Opens a demo work from Search (typing leaves the keyboard up as the
    /// reader opens) and returns the page footer once pages are laid out.
    private func openReader(pageByPage: Bool = true, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
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
        // The scrolling modes have no page footer: the reader's own toolbar
        // items show the reader is open.
        let footer = pageByPage
            ? app.descendants(matching: .any).matching(identifier: "reader.pageFooter").firstMatch
            : readerToolbarItem
        XCTAssertTrue(footer.waitForExistence(timeout: 20), "the reader", file: file, line: line)
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
        capture("05-reader-settings-menu")
        let profile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Profile")).firstMatch
        if !profile.waitForExistence(timeout: 4) {
            // On iPhone Duo (iOS 27.1) a software keyboard came up as the
            // menu opened, with no text field on screen, and closed the menu.
            // Name whatever holds keyboard focus so the failure says why.
            let focused = app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
            let holder = focused.exists ? "\(focused.elementType.rawValue) '\(focused.identifier)' '\(focused.label)'" : "nothing"
            XCTFail("the Profile submenu (keyboard up: \(app.keyboards.firstMatch.exists), keyboard focus: \(holder))")
        }
        profile.tap()
        let save = app.buttons["Save Current as New Profile..."].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 4), "Save Current as New Profile…")
        save.tap()
        XCTAssertTrue(app.alerts.textFields.firstMatch.waitForExistence(timeout: 4), "the profile name prompt")
    }

    // MARK: - Layout checks

    /// Hides the controls (full screen) and shows them again, as Apple Books
    /// does: the page doesn't move or re-flow either way. Hidden, the footer
    /// keeps its room but shows only the page number.
    private func assertTogglingKeepsThePageStill(_ footer: XCUIElement, _ context: String,
                                                 screenshots: (hidden: String, shown: String),
                                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let bar = footer.frame
        let label = footer.label
        let shown = try storyTexts(above: bar)
        XCTAssertNotNil(openingWords(shown), "\(context): text on the page", file: file, line: line)
        let pageNumber = app.descendants(matching: .any).matching(identifier: "reader.pageNumber").firstMatch
        // The middle third of the page shows or hides the controls.
        let middle = CGPoint(x: bar.midX, y: bar.minY - 200)
        tap(middle)
        XCTAssertTrue(waitForAbsence(footer), "\(context): the controls hid", file: file, line: line)
        settle()
        capture(screenshots.hidden)
        XCTAssertTrue(pageNumber.exists, "\(context): full screen shows the page number", file: file, line: line)
        if pageNumber.exists {
            XCTAssertEqual(pageNumber.label, label, "\(context): full screen moved to another page", file: file, line: line)
            XCTAssertEqual(pageNumber.frame.midY, bar.midY, accuracy: 2,
                           "\(context): the footer's room changed in full screen", file: file, line: line)
        }
        assertSameText(try storyTexts(above: bar), shown, "\(context): hiding the controls", file: file, line: line)
        try assertTextStaysOnItsPage("\(context), full screen", file: file, line: line)
        tap(middle)
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "\(context): the controls came back", file: file, line: line)
        settle()
        capture(screenshots.shown)
        XCTAssertEqual(footer.label, label, "\(context): showing the controls moved to another page", file: file, line: line)
        assertSameText(try storyTexts(above: footer.frame), shown, "\(context): showing the controls",
                       file: file, line: line)
        try assertPageLayout(footer, "\(context), after toggling the controls", file: file, line: line)
    }

    /// The same paragraphs at the same places (within a point): nothing moved or re-flowed.
    private func assertSameText(_ texts: [(frame: CGRect, text: String)], _ before: [(frame: CGRect, text: String)],
                                _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let order = { (texts: [(frame: CGRect, text: String)]) in
            texts.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        }
        let now = order(texts), then = order(before)
        XCTAssertEqual(now.map(\.text), then.map(\.text), "\(context) re-flowed the page", file: file, line: line)
        for (a, b) in zip(now, then) where abs(a.frame.minX - b.frame.minX) > 1 || abs(a.frame.minY - b.frame.minY) > 1
            || abs(a.frame.width - b.frame.width) > 1 || abs(a.frame.height - b.frame.height) > 1 {
            XCTFail("\(context) moved \"\(a.text.prefix(30))\" from \(b.frame) to \(a.frame)", file: file, line: line)
            break
        }
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
        try assertTextStaysOnItsPage("\(context) (\(footer.label))", file: file, line: line)
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
            // The page clips its text at its own frame, a margin above the edge.
            XCTAssertLessThanOrEqual(bottom, edge - pageMargin + 1,
                                     "\(context): the \(which)'s text runs \(bottom - edge + pageMargin) pt past the page, where it's cut off",
                                     file: file, line: line)
            XCTAssertGreaterThanOrEqual(bottom, edge - maxBlankBelowText,
                                        "\(context): \(edge - bottom) pt blank under the \(which)'s text",
                                        file: file, line: line)
        }
    }

    /// Every line of text on screen lies inside the page that draws it
    /// (`reader.page`, ReaderPageCell's scroll view, which clips it there): a
    /// page holding more than its frame shows cuts its last line off.
    private func assertTextStaysOnItsPage(_ context: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let app: XCUIApplication = self.app
        let window = app.windows.firstMatch.frame
        let found = try MainActor.assumeIsolated {
            var pages: [(page: CGRect, texts: [(frame: CGRect, text: String)])] = []
            func texts(in element: any XCUIElementSnapshot) -> [(frame: CGRect, text: String)] {
                let own: [(frame: CGRect, text: String)] = element.elementType == .staticText && element.frame.height > 0
                    ? [(element.frame, element.label)] : []
                return own + element.children.flatMap(texts)
            }
            func collect(_ element: any XCUIElementSnapshot) {
                // The pages either side of the one showing sit off screen.
                if element.elementType == .scrollView, element.identifier == "reader.page",
                   element.frame.intersection(window).width > element.frame.width / 2 {
                    pages.append((element.frame, texts(in: element)))
                    return
                }
                element.children.forEach(collect)
            }
            collect(try app.snapshot())
            return pages
        }
        XCTAssertFalse(found.isEmpty, "\(context): no page (reader.page) on screen", file: file, line: line)
        for (page, texts) in found {
            // Text the snapshot didn't nest under its page would pass unchecked.
            XCTAssertFalse(texts.isEmpty, "\(context): no text inside the page at \(page)", file: file, line: line)
            for text in texts where text.frame.maxY > page.maxY + 1 || text.frame.minX < page.minX - 1
                || text.frame.maxX > page.maxX + 1 {
                XCTFail("\(context): \"\(text.text.suffix(30))\" at \(text.frame) runs out of its page \(page) and is cut off",
                        file: file, line: line)
                break
            }
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

    /// The reader's own toolbar item: its Aa menu, or the system overflow
    /// a narrow bar (and iPhone Duo's vertical strip) folds it into.
    private var readerToolbarItem: XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier IN {'reader_settings_button', 'BottomOverflowBarButtonItem'}")).firstMatch
    }

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
        // Back up the list until the row shows (the audit swiped down it,
        // further on a short screen or a longer list).
        for _ in 0..<8 where !reader.exists || !reader.isHittable { app.swipeDown() }
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
