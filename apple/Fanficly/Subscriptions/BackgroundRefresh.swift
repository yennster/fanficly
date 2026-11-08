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

    /// A check is running: a full one (background or in-app) or the
    /// Subscriptions or Search tab's own. They never overlap (`exclusive`):
    /// two at once would fetch the same works and could alert twice.
    @MainActor private(set) static var isPolling = false
    /// When the last full check in this process finished without being cut
    /// off, so a return to the app doesn't check again too soon after one.
    /// A cut-off check doesn't count: most of its queue went unchecked.
    @MainActor private(set) static var lastPollCompletedAt: Date?

    /// Runs `check` unless another check is running, in which case it returns
    /// nil without running it.
    @MainActor
    static func exclusive<T>(_ check: @MainActor () async -> T) async -> T? {
        guard !isPolling else {
            logger.debug("Skipped a check: one is already running")
            return nil
        }
        isPolling = true
        defer { isPolling = false }
        return await check()
    }

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
        let notified: Int? = await exclusive {
            let context = ModelContext(container)
            // Repaired first: a stored email address (#144) can't build the
            // subscriptions URL.
            let username = await AuthState.repairedLogin(client: client)
            // Run even when logged out: locally-followed works are still polled.
            let poller = SubscriptionPoller(client: client, context: context, username: username)
            let count = await poller.runFullPoll()
            if !Task.isCancelled { lastPollCompletedAt = Date() }
            return count
        }
        guard let notified else { return false }
        logger.info("Poll posted \(notified, privacy: .public) notifications")
        return true
    }
}
