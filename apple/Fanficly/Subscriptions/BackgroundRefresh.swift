import BackgroundTasks
import Foundation
import SwiftData
import os

enum BackgroundRefresh {
    static let identifier = "io.github.yennster.fanficly.subscriptionRefresh"
    private static let logger = Logger(subsystem: "io.github.yennster.fanficly", category: "BackgroundRefresh")

    /// How often to check: the earliest begin date asked of iOS, and the
    /// in-app schedule's interval (`InAppPolling`).
    static let defaultInterval: TimeInterval = 4 * 60 * 60

    /// A check is running (in the background or in the app). Checks never
    /// overlap: two at once would fetch the same works and could alert twice.
    @MainActor private(set) static var isPolling = false
    /// When the last check in this process started, so a return to the app
    /// doesn't check again too soon after a background check.
    @MainActor private(set) static var lastPollStartedAt: Date?

    static func scheduleNext(after seconds: TimeInterval = defaultInterval) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.debug("Scheduled background refresh for \(request.earliestBeginDate?.description ?? "?", privacy: .public)")
        } catch {
            logger.warning("Couldn't schedule background refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One full check, from the background task or `InAppPolling`. Returns
    /// false, without checking, when another check is already running.
    @MainActor @discardableResult
    static func runPoll(
        client: any AO3ClientProtocol,
        container: ModelContainer
    ) async -> Bool {
        guard !isPolling else {
            logger.debug("Skipped a poll: one is already running")
            return false
        }
        isPolling = true
        lastPollStartedAt = Date()
        defer { isPolling = false }
        let context = ModelContext(container)
        // Repaired first: a stored email address (#144) can't build the
        // subscriptions URL.
        let username = await AuthState.repairedLogin(client: client)
        // Run even when logged out: locally-followed works are still polled.
        let poller = SubscriptionPoller(client: client, context: context, username: username)
        let notified = await poller.runFullPoll()
        logger.info("Poll posted \(notified, privacy: .public) notifications")
        return true
    }
}
