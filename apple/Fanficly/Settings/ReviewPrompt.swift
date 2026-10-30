import Foundation
import Observation

/// When it's OK to ask for an App Store rating. The bar is deliberately high so
/// the prompt only ever reaches people who are clearly enjoying the app: it
/// needs a moment of success (a story just finished, checked by the caller),
/// a few finished stories over several reading days, at least a week since
/// the first read. After that it asks again every few weeks until the reader
/// has rated (or dismissed the prompt, where the platform reports that).
/// iOS and macOS add their own cap (three per year), skip people who already
/// rated, and honor the user's opt-out; StoreKit never tells the app which
/// happened, so on Apple only the Settings "Rate" link stops it.
enum ReviewPromptPolicy {
    static let minFinishedStories = 3
    static let minReadingDays = 3
    static let minDaysSinceFirstRead = 7
    static let minDaysBetweenPrompts = 21

    static func shouldAsk(
        now: Date,
        finishedStories: Int,
        readingDays: Int,
        firstReadAt: Date?,
        lastPromptAt: Date?,
        isDone: Bool
    ) -> Bool {
        guard !isDone,
              finishedStories >= minFinishedStories,
              readingDays >= minReadingDays,
              let firstReadAt,
              now.timeIntervalSince(firstReadAt) >= Double(minDaysSinceFirstRead) * 86_400
        else { return false }
        if let lastPromptAt,
           now.timeIntervalSince(lastPromptAt) < Double(minDaysBetweenPrompts) * 86_400 {
            return false
        }
        return true
    }
}

/// Decides when to show the system rating prompt. The reader reports a story
/// it just finished; when that reader closes, and only then, the policy is
/// checked and `RootView` shows the prompt over the list the reader returns
/// to — never on top of the story text and never mid-read.
@MainActor @Observable
final class ReviewPrompter {
    static let shared = ReviewPrompter()

    /// Bumped when the prompt should show; `RootView` observes it and calls
    /// `requestReview`.
    private(set) var requestCount = 0

    /// A story was finished during the current reading session.
    @ObservationIgnored private var finishedThisSession = false

    static let writeReviewURL = URL(string: "https://apps.apple.com/app/id6775897153?action=write-review")!

    private static let lastPromptAtKey = "review.lastPromptAt"
    /// Set once the reader opens the App Store review page from Settings (the
    /// only sign of rating StoreKit allows); the prompt never asks again after it.
    static let doneKey = "review.done"

    /// Whether the prompt has stopped for good.
    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    /// The reader opened the App Store review page from Settings: count them
    /// as rated and stop asking.
    func openedReviewPage() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
    }

    func storyFinished() {
        finishedThisSession = true
    }

    /// Called as a reader leaves the screen. Loads the reading stats and checks
    /// the policy only if a story was just finished.
    func readerClosed(stats loadStats: () -> [ReadingStatSnapshot], now: Date = .now) {
        guard finishedThisSession else { return }
        finishedThisSession = false
        guard !FanficlyApp.isDemoMode, !FanficlyApp.isTestMode else { return }

        let stats = loadStats()
        let defaults = UserDefaults.standard
        let lastPromptAt = defaults.object(forKey: Self.lastPromptAtKey) as? Date
        guard ReviewPromptPolicy.shouldAsk(
            now: now,
            finishedStories: stats.filter(\.isFinished).count,
            readingDays: Set(stats.flatMap(\.daySeconds.keys)).count,
            firstReadAt: stats.map(\.firstReadAt).min(),
            lastPromptAt: lastPromptAt,
            isDone: Self.isDone
        ) else { return }

        // Recorded up front: StoreKit never says whether the prompt showed.
        defaults.set(now, forKey: Self.lastPromptAtKey)
        requestCount += 1
    }
}
