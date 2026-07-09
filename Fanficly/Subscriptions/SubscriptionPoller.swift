import Foundation
import SwiftData
import UserNotifications
import os

@MainActor
struct SubscriptionPoller {
    let client: any AO3ClientProtocol
    let context: ModelContext
    /// AO3 username for syncing account subscriptions; nil when logged out
    /// (locally-followed works are still polled).
    let username: String?
    private let logger = Logger(subsystem: "io.github.yennster.fanficly", category: "SubscriptionPoller")

    func syncSubscriptionList() async throws -> [AO3Subscription] {
        guard let username else { return [] }
        let fresh = try await client.fetchSubscriptions(username: username)
        let freshKeys = Set(fresh.map(\.key))

        let descriptor = FetchDescriptor<SubscriptionRecord>()
        let existing = (try? context.fetch(descriptor)) ?? []
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })

        for sub in fresh {
            if let rec = existingByKey[sub.key] {
                rec.displayName = sub.title
                rec.authorName = sub.author ?? rec.authorName
            } else {
                let rec = SubscriptionRecord(
                    key: sub.key,
                    kind: sub.kind.rawValue,
                    displayName: sub.title,
                    authorName: sub.author ?? ""
                )
                context.insert(rec)
            }
        }
        // Fail closed on pruning: an empty fetch with records on hand is far
        // more likely a stale session or markup drift than a mass
        // unsubscribe, and a wrong delete also destroys the
        // lastSeenChapterCount baselines new-chapter alerts compare against.
        // (The parser already throws on a login page; this guards the rest.)
        if !fresh.isEmpty {
            for rec in existing where !freshKeys.contains(rec.key) {
                context.delete(rec)
            }
        }
        try? context.save()
        return fresh
    }

    func checkForNewChapters() async -> Int {
        var notifyCount = 0
        for rec in workSubscriptionRecords() {
            notifyCount += await checkWorkSubscription(rec)
        }
        try? context.save()
        return notifyCount
    }

    /// Poll locally-followed works (no AO3 login required) for new chapters.
    func checkFollowedWorks() async -> Int {
        var notifyCount = 0
        for work in followedWorks() {
            notifyCount += await checkFollowedWork(work)
        }
        try? context.save()
        return notifyCount
    }

    /// Poll locally-followed authors (no AO3 login required) for newly
    /// published works, notifying once per new work.
    func checkFollowedAuthors() async -> Int {
        var notifyCount = 0
        for author in followedAuthors() {
            notifyCount += await checkFollowedAuthor(author)
        }
        try? context.save()
        return notifyCount
    }

    /// One unit of poll work — any of the three followable record kinds,
    /// ordered by how stale its last check is.
    private enum PollTarget {
        case workSubscription(SubscriptionRecord)
        case followedWork(Work)
        case followedAuthor(FollowedAuthor)

        var lastCheckedAt: Date? {
            switch self {
            case .workSubscription(let rec): rec.lastCheckedAt
            case .followedWork(let work): work.lastCheckedAt
            case .followedAuthor(let author): author.lastCheckedAt
            }
        }
    }

    func runFullPoll() async -> Int {
        do {
            _ = try await syncSubscriptionList()
        } catch {
            logger.warning("Subscriptions list fetch failed: \(error.localizedDescription, privacy: .public)")
        }

        // Interleave all three record kinds oldest-check-first rather than a
        // fixed subs → works → authors order. Every check costs one throttled
        // (1 req/s) request and a BGAppRefreshTask only gets ~30s, so a fixed
        // order permanently starves the last category once the earlier ones
        // outgrow the budget; oldest-first means whatever was cut off last
        // time is exactly what runs first this time.
        var targets: [PollTarget] = []
        if username != nil {
            targets += workSubscriptionRecords().map(PollTarget.workSubscription)
        }
        targets += followedWorks().map(PollTarget.followedWork)
        targets += followedAuthors().map(PollTarget.followedAuthor)
        targets.sort { ($0.lastCheckedAt ?? .distantPast) < ($1.lastCheckedAt ?? .distantPast) }

        var total = 0
        for target in targets {
            // The BG scheduler cancels us at expiry — stop cleanly and keep
            // the progress saved so far.
            if Task.isCancelled { break }
            switch target {
            case .workSubscription(let rec): total += await checkWorkSubscription(rec)
            case .followedWork(let work): total += await checkFollowedWork(work)
            case .followedAuthor(let author): total += await checkFollowedAuthor(author)
            }
            // Save after every record so an expiring BG task keeps its
            // lastCheckedAt stamps — they drive the rotation.
            try? context.save()
        }
        WidgetDataStore.updateAll(context: context)
        return total
    }

    // MARK: - Per-record checks

    /// Check one AO3 work subscription for a new chapter (one throttled
    /// request). Returns the number of notifications posted.
    private func checkWorkSubscription(_ rec: SubscriptionRecord) async -> Int {
        // Stamp the attempt up front: a permanently-failing record (deleted
        // work, parse drift) must not stay "oldest" forever and hog the head
        // of the round-robin queue.
        defer { rec.lastCheckedAt = .now }
        let parts = rec.key.split(separator: ":")
        guard parts.count == 2, let workId = Int(parts[1]) else { return 0 }
        do {
            let meta = try await client.fetchWorkMetadata(id: workId)
            var notifyCount = 0
            if let lastSeen = rec.lastSeenChapterCount,
               meta.chapterCount > lastSeen {
                await postNewChapterNotification(
                    title: rec.displayName,
                    oldCount: lastSeen,
                    newCount: meta.chapterCount,
                    workId: workId
                )
                notifyCount = 1
            }
            rec.lastSeenChapterCount = meta.chapterCount
            return notifyCount
        } catch {
            logger.warning("Skipping work \(workId): \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    private func checkFollowedWork(_ work: Work) async -> Int {
        defer { work.lastCheckedAt = .now }
        do {
            let meta = try await client.fetchWorkMetadata(id: work.ao3Id)
            var notifyCount = 0
            if let lastSeen = work.lastSeenChapterCount, meta.chapterCount > lastSeen {
                await postNewChapterNotification(
                    title: work.title,
                    oldCount: lastSeen,
                    newCount: meta.chapterCount,
                    workId: work.ao3Id
                )
                notifyCount = 1
            }
            work.lastSeenChapterCount = meta.chapterCount
            return notifyCount
        } catch {
            logger.warning("Skipping followed work \(work.ao3Id): \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    private func checkFollowedAuthor(_ author: FollowedAuthor) async -> Int {
        defer { author.lastCheckedAt = .now }
        do {
            let result = try await client.fetchAuthorWorks(username: author.username, page: 1)
            let latestIds = result.works.map(\.id)
            let known = Set(author.knownWorkIds)
            var notifyCount = 0
            // Only notify once we have a baseline — a freshly-followed
            // author is seeded at follow time, but guard the empty case so
            // a first poll never alerts for the whole back catalogue.
            if !known.isEmpty {
                let newWorks = result.works.filter { !known.contains($0.id) }
                if !newWorks.isEmpty {
                    await postNewWorkNotification(
                        author: author.displayName,
                        newWorks: newWorks
                    )
                    notifyCount = newWorks.count
                }
            }
            author.knownWorkIds = Array(known.union(latestIds))
            return notifyCount
        } catch {
            logger.warning("Skipping author \(author.username, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    // MARK: - Record fetches

    private func workSubscriptionRecords() -> [SubscriptionRecord] {
        let descriptor = FetchDescriptor<SubscriptionRecord>(
            predicate: #Predicate { $0.kind == "work" }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func followedWorks() -> [Work] {
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.isFollowed == true })
        return (try? context.fetch(descriptor)) ?? []
    }

    private func followedAuthors() -> [FollowedAuthor] {
        let descriptor = FetchDescriptor<FollowedAuthor>()
        return ((try? context.fetch(descriptor)) ?? []).filter { !$0.username.isEmpty }
    }

    private func postNewWorkNotification(author: String, newWorks: [AO3WorkSummary]) async {
        let content = UNMutableNotificationContent()
        content.title = author
        if newWorks.count == 1, let work = newWorks.first {
            content.body = "New work: \(work.title)"
            content.userInfo = ["workId": work.id]
        } else {
            content.body = "\(newWorks.count) new works posted"
        }
        content.sound = .default
        let newestId = newWorks.first?.id ?? 0
        let request = UNNotificationRequest(
            identifier: "author-\(author)-newwork-\(newestId)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func postNewChapterNotification(title: String, oldCount: Int, newCount: Int, workId: Int) async {
        let content = UNMutableNotificationContent()
        content.title = title
        let added = newCount - oldCount
        content.body = added == 1
            ? "1 new chapter posted (\(newCount) total)"
            : "\(added) new chapters posted (\(newCount) total)"
        content.sound = .default
        content.userInfo = ["workId": workId]
        let request = UNNotificationRequest(
            identifier: "work-\(workId)-update-\(newCount)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

enum NotificationsAuthorization {
    static func request() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    /// Fire-and-forget request for the local-follow flow. Follows are the
    /// headline logged-out feature and their whole payoff is the poller's
    /// new-chapter/new-work notifications, so ask the moment the user first
    /// follows something — never gated on an AO3 login. Skipped in demo and
    /// unit-test runs so screenshot automation and tests never trip the
    /// system permission alert.
    @MainActor
    static func requestAfterFollow() {
        guard !FanficlyApp.isDemoMode, !FanficlyApp.isTestMode else { return }
        Task { _ = await request() }
    }
}
