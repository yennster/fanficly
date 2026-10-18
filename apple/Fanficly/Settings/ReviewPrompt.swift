import Foundation
import Observation

/// When it's OK to ask for an App Store rating. The bar is deliberately high so
/// the prompt only ever reaches people who are clearly enjoying the app: it
/// needs a moment of success (a story just finished, checked by the caller),
/// a few finished stories over several reading days, at least a week since
/// the first read, and it asks at most once per app version and months apart.
/// iOS adds its own cap (three per year) and honors the user's opt-out.
enum ReviewPromptPolicy {
    static let minFinishedStories = 3
    static let minReadingDays = 3
    static let minDaysSinceFirstRead = 7
    static let minDaysBetweenPrompts = 120

    static func shouldAsk(
        now: Date,
        finishedStories: Int,
        readingDays: Int,
        firstReadAt: Date?,
        lastPromptAt: Date?,
        lastPromptVersion: String?,
        currentVersion: String
    ) -> Bool {
        guard finishedStories >= minFinishedStories,
              readingDays >= minReadingDays,
              let firstReadAt,
              now.timeIntervalSince(firstReadAt) >= Double(minDaysSinceFirstRead) * 86_400,
              lastPromptVersion != currentVersion
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
    private static let lastPromptVersionKey = "review.lastPromptVersion"

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
        let version = Bundle.main.shortVersionString
        let lastPromptAt = defaults.object(forKey: Self.lastPromptAtKey) as? Date
        guard ReviewPromptPolicy.shouldAsk(
            now: now,
            finishedStories: stats.filter(\.isFinished).count,
            readingDays: Set(stats.flatMap(\.daySeconds.keys)).count,
            firstReadAt: stats.map(\.firstReadAt).min(),
            lastPromptAt: lastPromptAt,
            lastPromptVersion: defaults.string(forKey: Self.lastPromptVersionKey),
            currentVersion: version
        ) else { return }

        // Recorded up front: StoreKit never says whether the prompt showed.
        defaults.set(now, forKey: Self.lastPromptAtKey)
        defaults.set(version, forKey: Self.lastPromptVersionKey)
        requestCount += 1
    }
}
