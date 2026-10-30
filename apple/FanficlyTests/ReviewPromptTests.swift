import XCTest
import SwiftData
@testable import Fanficly

/// The App Store rating prompt must stay well-timed: only for readers with
/// real history, every few weeks at most, never again once they've rated, and
/// only on the read that actually finishes a story.
@MainActor
final class ReviewPromptTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

    private func ask(finished: Int = 3, days: Int = 3, firstRead: Date? = nil,
                     lastPrompt: Date? = nil, isDone: Bool = false) -> Bool {
        ReviewPromptPolicy.shouldAsk(
            now: now, finishedStories: finished, readingDays: days,
            firstReadAt: firstRead ?? daysAgo(60), lastPromptAt: lastPrompt, isDone: isDone
        )
    }

    func test_engagedReader_neverAskedBefore_isAsked() {
        XCTAssertTrue(ask())
    }

    func test_needsEnoughFinishedStoriesAndReadingDays() {
        XCTAssertFalse(ask(finished: 2))
        XCTAssertFalse(ask(days: 2))
    }

    func test_needsAWeekSinceTheFirstRead() {
        XCTAssertFalse(ask(firstRead: daysAgo(6)))
        XCTAssertTrue(ask(firstRead: daysAgo(7)))
        XCTAssertFalse(ReviewPromptPolicy.shouldAsk(
            now: now, finishedStories: 9, readingDays: 9, firstReadAt: nil,
            lastPromptAt: nil, isDone: false))
    }

    func test_asksAgainEveryFewWeeks() {
        XCTAssertFalse(ask(lastPrompt: daysAgo(20)))
        XCTAssertTrue(ask(lastPrompt: daysAgo(21)))
        // Someone asked under the old once-per-version rules is asked again
        // on the new cadence, whatever version they're on.
        XCTAssertTrue(ask(lastPrompt: daysAgo(130)))
    }

    func test_neverAgainOnceRated() {
        XCTAssertFalse(ask(isDone: true))
        XCTAssertFalse(ask(lastPrompt: daysAgo(400), isDone: true))
    }

    func test_openingTheReviewPage_stopsThePrompt() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: ReviewPrompter.doneKey)
        defer { defaults.set(saved, forKey: ReviewPrompter.doneKey) }
        defaults.removeObject(forKey: ReviewPrompter.doneKey)
        XCTAssertFalse(ReviewPrompter.isDone)
        ReviewPrompter.shared.openedReviewPage()
        XCTAssertTrue(ReviewPrompter.isDone)
    }

    // MARK: - The "just finished" cue

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([ReadingStat.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        return ModelContext(container)
    }

    private func record(progress: Double, in context: ModelContext) -> Bool {
        ReadingStatsStore.record(
            ao3Id: 42, title: "A Fic", author: "someone", fandoms: [], categories: [],
            relationships: [], rating: "", wordCount: 10_000, seconds: 60,
            progress: progress, isComplete: true, date: now, in: context
        )
    }

    func test_record_flagsOnlyTheReadThatFinishesTheStory() throws {
        let context = try makeContext()
        XCTAssertFalse(record(progress: 0.4, in: context), "mid-read isn't a finish")
        XCTAssertTrue(record(progress: 1.0, in: context), "reaching the end is")
        XCTAssertFalse(record(progress: 1.0, in: context), "re-reading a finished story isn't new")
        XCTAssertFalse(record(progress: 0.2, in: context), "a re-skim never un-finishes")
    }

    func test_record_firstReadThatAlreadyFinishes_counts() throws {
        let context = try makeContext()
        XCTAssertTrue(record(progress: 0.97, in: context), "complete work at 95%+ is finished")
    }
}
