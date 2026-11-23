import Foundation

/// Checks follows, subscriptions, followed authors and saved-search alerts
/// while the app is open (#185), like the Windows app's `InAppPolling`.
/// Background refresh only runs once the app is in the background, and
/// whenever iOS chooses, so a reader who keeps Fanficly open, the usual way on
/// a Mac, otherwise never got a check.
///
/// The first check waits a minute so it doesn't compete with launch work, then
/// one runs every `interval`. Coming back to the app doesn't check again before
/// `interval` has passed since the last full check (in the background or here), so
/// switching apps doesn't cost AO3 a poll each time. Each check is the same
/// oldest-first `BackgroundRefresh.runPoll`, which skips itself when another
/// check is already running.
///
/// iPhone and iPad stop the schedule in the background; the Mac keeps it
/// running for as long as the app runs (see `FanficlyApp.updateInAppPolling`).
@MainActor
final class InAppPolling {
    static let shared = InAppPolling()

    /// The first check waits this long after launch (or a return to the app).
    nonisolated static let firstPollDelay: TimeInterval = 60
    nonisolated static let interval: TimeInterval = BackgroundRefresh.defaultInterval

    typealias Sleep = @MainActor @Sendable (TimeInterval) async throws -> Void

    private let sleep: Sleep
    private let lastPoll: @MainActor () -> Date?
    private let now: @MainActor () -> Date
    /// The running schedule; nil when stopped. Internal for tests.
    private(set) var loop: Task<Void, Never>?

    init(
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
        lastPoll: @escaping @MainActor () -> Date? = { BackgroundRefresh.lastPollCompletedAt },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.sleep = sleep
        self.lastPoll = lastPoll
        self.now = now
    }

    /// How long to wait before the first check: a minute, or until `interval`
    /// has passed since the last one, whichever is later. Never more than
    /// `interval`, so a clock set back can't put the check off for longer.
    nonisolated static func firstDelay(lastPoll: Date?, now: Date) -> TimeInterval {
        guard let lastPoll else { return firstPollDelay }
        let untilDue = interval - now.timeIntervalSince(lastPoll)
        return min(interval, max(firstPollDelay, untilDue))
    }

    /// Starts the schedule. Does nothing when it's already running.
    func start(_ poll: @escaping @MainActor @Sendable () async -> Void) {
        guard loop == nil else { return }
        let delay = Self.firstDelay(lastPoll: lastPoll(), now: now())
        let sleep = sleep
        loop = Task {
            do {
                try await sleep(delay)
                while !Task.isCancelled {
                    await poll()
                    try await sleep(InAppPolling.interval)
                }
            } catch {
                // Cancelled: stopped.
            }
        }
    }

    /// Stops the schedule and cancels a check in progress; its oldest-first
    /// queue has saved what it got through, so the next check picks up there.
    func stop() {
        loop?.cancel()
        loop = nil
    }
}
