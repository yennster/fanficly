import BackgroundTasks
import Foundation
import SwiftData
import os

enum BackgroundRefresh {
    static let identifier = "io.github.yennster.fanficly.subscriptionRefresh"
    private static let logger = Logger(subsystem: "io.github.yennster.fanficly", category: "BackgroundRefresh")

    static func scheduleNext(after seconds: TimeInterval = 4 * 60 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.debug("Scheduled background refresh for \(request.earliestBeginDate?.description ?? "?", privacy: .public)")
        } catch {
            logger.warning("Couldn't schedule background refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    static func runPoll(
        client: any AO3ClientProtocol,
        container: ModelContainer
    ) async {
        let context = ModelContext(container)
        let username = await CredentialStore.shared.storedUsername()
        // Run even when logged out: locally-followed works are still polled.
        let poller = SubscriptionPoller(client: client, context: context, username: username)
        let notified = await poller.runFullPoll()
        logger.info("Background poll posted \(notified, privacy: .public) notifications")
    }
}
