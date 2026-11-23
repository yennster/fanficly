import XCTest
@testable import Fanficly

/// The App Clip's invocation links (#292) and its handoff to the app.
final class WorkLinkTests: XCTestCase {
    private func link(_ string: String) -> WorkLink? {
        WorkLink(url: URL(string: string)!)
    }

    func test_workLink_parsesIdAndChapter() {
        XCTAssertEqual(link("https://fanficly.app/works/12345"), WorkLink(workId: 12345))
        XCTAssertEqual(link("https://fanficly.app/works/12345/"), WorkLink(workId: 12345))
        XCTAssertEqual(link("https://www.fanficly.app/works/12345?chapter=3"), WorkLink(workId: 12345, chapter: 3))
        XCTAssertEqual(link("https://FANFICLY.APP/Works/7"), WorkLink(workId: 7))
    }

    func test_workLink_ignoresABadChapter() {
        XCTAssertEqual(link("https://fanficly.app/works/9?chapter=0"), WorkLink(workId: 9))
        XCTAssertEqual(link("https://fanficly.app/works/9?chapter=two"), WorkLink(workId: 9))
    }

    func test_workLink_refusesOtherLinks() {
        XCTAssertNil(link("https://archiveofourown.org/works/12345"))
        XCTAssertNil(link("https://fanficly.app/"))
        XCTAssertNil(link("https://fanficly.app/works/"))
        XCTAssertNil(link("https://fanficly.app/works/abc"))
        XCTAssertNil(link("https://fanficly.app/works/-4"))
        XCTAssertNil(link("https://fanficly.app/works/12/chapters/34"))
        XCTAssertNil(link("https://fanficly.app.example.com/works/12"))
        XCTAssertNil(link("fanficly://works/12"))
    }

    func test_workLink_roundTripsThroughItsURL() {
        let shared = WorkLink(workId: 42, chapter: 5)
        XCTAssertEqual(shared.url.absoluteString, "https://fanficly.app/works/42?chapter=5")
        XCTAssertEqual(WorkLink(url: shared.url), shared)
        XCTAssertEqual(WorkLink(workId: 42).url.absoluteString, "https://fanficly.app/works/42")
    }

    func test_workLink_anchorIsTheChaptersStart() {
        XCTAssertEqual(WorkLink(workId: 1, chapter: 4).anchor, ReadingAnchor(chapter: 4, paragraph: 0))
        XCTAssertNil(WorkLink(workId: 1).anchor)
    }

    // MARK: - Handoff

    private var defaults: UserDefaults!
    private let suite = "WorkLinkTests.handoff"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func test_handoff_isTakenOnce() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        ClipHandoff.record(workId: 321, now: now, defaults: defaults)
        XCTAssertEqual(ClipHandoff.take(now: now.addingTimeInterval(60), defaults: defaults), 321)
        XCTAssertNil(ClipHandoff.take(now: now.addingTimeInterval(120), defaults: defaults))
    }

    func test_handoff_keepsTheLatestWork() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        ClipHandoff.record(workId: 1, now: now, defaults: defaults)
        ClipHandoff.record(workId: 2, now: now.addingTimeInterval(10), defaults: defaults)
        XCTAssertEqual(ClipHandoff.take(now: now.addingTimeInterval(20), defaults: defaults), 2)
    }

    func test_handoff_dropsAnOldOne() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        ClipHandoff.record(workId: 5, now: now, defaults: defaults)
        XCTAssertNil(ClipHandoff.take(now: now.addingTimeInterval(ClipHandoff.maximumAge + 1), defaults: defaults))
        // …and clears it, so a later launch doesn't find it either.
        XCTAssertNil(defaults.object(forKey: ClipHandoff.workIdKey))
    }

    func test_handoff_isNilWithNothingRecorded() {
        XCTAssertNil(ClipHandoff.take(defaults: defaults))
    }
}
