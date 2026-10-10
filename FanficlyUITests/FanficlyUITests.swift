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
    /// page's bottom margin, the paginator's safety margin, and a paragraph
    /// that needs two lines to start on a page (a lone opening line moves to
    /// the next one), with slack. The bugs left a ~300 pt band.
    private let maxBlankBelowText: CGFloat = 150

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
        XCTAssertEqual(footer.label, before, "backgrounding moved the page or repaginated")
        try assertPageLayout(footer, "after backgrounding")
        #endif
    }

    func test_togglingTheControls_keepsThePage() throws {
        let footer = openReader()
        turnToMiddlePage(footer)
        let before = footer.label
        let bar = footer.frame
        // The middle third of the page shows or hides the controls.
        let middle = CGPoint(x: bar.midX, y: bar.minY - 200)
        tap(middle)
        // iPhone Duo's open-book spread keeps its footer with the controls hidden.
        if !isDuoUnfolded {
            XCTAssertTrue(waitForAbsence(footer), "the controls hid")
        }
        sleep(1)
        tap(middle)
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "the controls came back")
        settle()
        XCTAssertEqual(footer.label, before, "toggling the controls repaginated")
        try assertPageLayout(footer, "after toggling the controls")
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
        if footer.exists && !isDuoUnfolded {
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThanOrEqual(footer.frame.maxY, window.maxY - 50,
                                        "the footer rode \(window.maxY - footer.frame.maxY) pt up on the keyboard")
        }
        app.alerts.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(waitForAbsence(keyboard), "the keyboard went away")
        settle()
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
        try assertPageLayout(footer, "in a wide window")
    }

    // MARK: - Navigation

    /// Opens a demo work from Search (typing leaves the keyboard up as the
    /// reader opens) and returns the page footer once pages are laid out.
    private func openReader(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let field = app.textFields.firstMatch
        // iPhone launches on the sidebar menu; iPad and the Mac show Search.
        if !field.waitForExistence(timeout: 4) {
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
            app.navigationBars.buttons.allElementsBoundByIndex.last?.tap()
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

    /// The footer sits on the bottom edge, and each page on screen is full:
    /// its text ends just above the footer, not short of it and not under it.
    private func assertPageLayout(_ footer: XCUIElement, _ context: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        // Unfolded, XCUITest reports the Duo's frames in portrait while the
        // UI is landscape, so only the page labels above can be checked there.
        guard !isDuoUnfolded else { return }
        let window = app.windows.firstMatch.frame
        let bar = footer.frame
        XCTAssertLessThan(bar.height, 60, "\(context): the footer is \(bar.height) pt tall", file: file, line: line)
        XCTAssertGreaterThanOrEqual(bar.maxY, window.maxY - 50,
                                    "\(context): the footer ends \(window.maxY - bar.maxY) pt above the bottom",
                                    file: file, line: line)
        let texts = try storyTextFrames(above: bar)
        let pages = page(footer)?.isSpread == true
            ? [(bar.minX, bar.midX), (bar.midX, bar.maxX)] : [(bar.minX, bar.maxX)]
        for (index, (minX, maxX)) in pages.enumerated() {
            let which = pages.count > 1 ? (index == 0 ? "left page" : "right page") : "page"
            guard let bottom = texts.filter({ $0.midX >= minX && $0.midX < maxX }).map(\.maxY).max() else {
                XCTFail("\(context): no text on the \(which) (\(footer.label))", file: file, line: line)
                continue
            }
            XCTAssertLessThanOrEqual(bottom, bar.minY + 1,
                                     "\(context): the \(which)'s text runs \(bottom - bar.minY) pt under the footer",
                                     file: file, line: line)
            XCTAssertGreaterThanOrEqual(bottom, bar.minY - maxBlankBelowText,
                                        "\(context): \(bar.minY - bottom) pt blank under the \(which)'s text (\(footer.label))",
                                        file: file, line: line)
        }
    }

    /// Frames of the text across the reader's column(s) above the footer,
    /// from one snapshot (querying each element's frame takes ~0.1 s). The
    /// pages either side of the one showing sit off screen and drop out.
    private func storyTextFrames(above bar: CGRect) throws -> [CGRect] {
        var frames: [CGRect] = []
        func collect(_ element: any XCUIElementSnapshot) {
            let frame = element.frame
            if element.elementType == .staticText, frame.height > 0, frame.minY < bar.minY,
               frame.minX >= bar.minX - 1, frame.maxX <= bar.maxX + 1 {
                frames.append(frame)
            }
            element.children.forEach(collect)
        }
        collect(try app.snapshot())
        return frames
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

    private func tap(_ point: CGPoint) {
        let origin = app.frame.origin
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - origin.x, dy: point.y - origin.y)).tap()
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    /// Pagination, the page-height settle (0.6 s) and the page turn's animation.
    private func settle() {
        usleep(1_500_000)
    }
}
